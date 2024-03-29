// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.15;
pragma experimental ABIEncoderV2;

import {IVault} from "./interfaces/IVault.sol";
import {BaseStrategy} from "@yearn/yearn-vaults/contracts/BaseStrategy.sol";

import "./interfaces/IERC20Extended.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {CometStructs} from "./interfaces/CompoundV3/CompoundV3.sol";
import {Comet} from "./interfaces/CompoundV3/CompoundV3.sol";
import {CometRewards} from "./interfaces/CompoundV3/CompoundV3.sol";
import {ISwapRouter} from "./interfaces/UniswapV3/ISwapRouter.sol";

interface IBaseFeeGlobal {
    function basefee_global() external view returns (uint256);
}

interface IDepositer{
    function deposit() external;
    function setStrategy() external;
    function claimRewards() external;
    function getRewardsOwed() external view returns (uint256);
    function accruedCometBalance() external returns (uint256);
    function getNetBorrowApr(uint256) external view returns (uint256);
    function getNetRewardApr(uint256) external view returns(uint256);
    function withdraw(uint256 _amount) external;
    function baseToken() external view returns(IERC20);
    function cometBalance() external view returns(uint256);
}
 
/********************
 *   Strategy to farm the rewards on Compound V3 by providing any of the possible collateral assets and then borrowing the base token
 *      The base token is then deposited back into compound through a seperate Depositer contract. Borrowing and supply rewards are harvested.
 *   Made by @Schlagonia
 *   https://github.com/Schlagonia/CompoundV3-Lender-Borrower
 *
 ********************* */

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    // if set to true, the strategy will not try to repay debt by selling rewards or want
    bool public leaveDebtBehind;

    // This is the address of the main V3 pool
    Comet public comet;
    // This is the token we will be borrowing/supplying
    address public baseToken;
    // The contract to get Comp rewards from
    CometRewards public constant rewardsContract = 
        CometRewards(0x1B0e765F6224C21223AeA2af16c1C46E38885a40); 
    
    // The Contract that will deposit the baseToken back into Compound
    IDepositer public depositer;

    // The reward Token
    address internal constant comp = 
        0xc00e94Cb662C3520282E6f5717214004A7f26888;
    // The reference token
    address internal constant weth = 
        0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Uniswap v3 router
    ISwapRouter internal constant router =
        ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    // Fees for the Uni V3 pools
    mapping (address => mapping (address => uint24)) public uniFees;

    // mapping of price feeds. Cheaper and management can customize if needed
    mapping (address => address) public priceFeeds;

    // NOTE: LTV = Loan-To-Value = debt/collateral
    // Target LTV: ratio up to which which we will borrow up to liquidation threshold
    uint16 public targetLTVMultiplier = 7_000;

    // Warning LTV: ratio at which we will repay
    uint16 public warningLTVMultiplier = 8_000; // 80% of liquidation LTV

    // support
    uint16 internal constant MAX_BPS = 10_000; // 100%
    //Thresholds
    uint256 internal minThreshold;
    uint256 public minToSell;
    uint256 public maxGasPriceToTend;
    
    string internal strategyName;

    constructor(
        address _vault,
        address _comet,
        uint24 _ethToWantFee,
        address _depositer,
        string memory _strategyName
    ) BaseStrategy(_vault) {
        _initializeThis(_comet, _ethToWantFee, _depositer, _strategyName);
    }

    // ----------------- PUBLIC VIEW FUNCTIONS -----------------

    function name() external view override returns (string memory) {
        return strategyName;
    }

    // ----------------- SETTERS -----------------
    // we put all together to save contract bytecode (!)
    function setStrategyParams(
        uint16 _targetLTVMultiplier,
        uint16 _warningLTVMultiplier,
        uint256 _minToSell,
        bool _leaveDebtBehind,
        uint256 _maxGasPriceToTend
    ) external onlyAuthorized {
        require(
            _warningLTVMultiplier <= 9_000 &&
                _targetLTVMultiplier < _warningLTVMultiplier
        );
        targetLTVMultiplier = _targetLTVMultiplier;
        warningLTVMultiplier = _warningLTVMultiplier;
        minToSell = _minToSell;
        leaveDebtBehind = _leaveDebtBehind;
        maxGasPriceToTend = _maxGasPriceToTend;
    }

    function setPriceFeed(address token, address priceFeed) external onlyAuthorized {
        // just check it doesnt revert
        comet.getPrice(priceFeed);
        priceFeeds[token] = priceFeed;
    }

    function setFees(
        uint24 _compToEthFee,
        uint24 _ethToBaseFee,
        uint24 _ethToWantFee
    ) external onlyAuthorized {
        _setFees(_compToEthFee, _ethToBaseFee, _ethToWantFee);
    }

    function _setFees(
        uint24 _compToEthFee,
        uint24 _ethToBaseFee,
        uint24 _ethToWantFee
    ) internal {
        address _weth = weth;
        uniFees[address(want)][_weth] = _ethToWantFee;
        uniFees[_weth][address(want)] = _ethToWantFee;
        
        uniFees[comp][_weth] = _compToEthFee;
        uniFees[_weth][comp] = _compToEthFee;

        uniFees[baseToken][_weth] = _ethToBaseFee;
        uniFees[_weth][baseToken] = _ethToBaseFee;
    }

    function _initializeThis(
        address _comet,
        uint24 _ethToWantFee, 
        address _depositer,
        string memory _strategyName
    ) internal {
        // Make sure we only initialize one time
        require(address(comet) == address(0));
        comet = Comet(_comet);

        //Get the baseToken we wil borrow and the min
        baseToken = comet.baseToken();
        minThreshold = comet.baseBorrowMin();

        depositer = IDepositer(_depositer);
        require(baseToken == address(depositer.baseToken()), "!base");

        // to supply want as collateral
        want.safeApprove(_comet, type(uint256).max);
        // to repay debt
        IERC20(baseToken).safeApprove(_comet, type(uint256).max);
        // for depositer to pull funds to deposit
        IERC20(baseToken).safeApprove(_depositer, type(uint256).max);
        // to sell reward tokens
        IERC20(comp).safeApprove(address(router), type(uint256).max);

        //Default to .3% pool for comp/eth and to .05% pool for eth/baseToken
        _setFees(3000, 500, _ethToWantFee);

        // set default price feeds
        priceFeeds[baseToken] = comet.baseTokenPriceFeed();
        // default to COMP/USD
        priceFeeds[comp] = 0xdbd020CAeF83eFd542f4De03e3cF0C28A4428bd5;
        // default to given feed for want
        priceFeeds[address(want)] = comet.getAssetInfoByAddress(address(want)).priceFeed;

        strategyName = _strategyName;

        // Set health check to health.ychad.eth
        healthCheck = 0xDDCea799fF1699e98EDF118e0629A974Df7DF012;
    }

    function initialize(
        address _vault,
        address _comet,
        uint24 _ethToWantFee,
        address _depositer,
        string memory _strategyName
    ) external {
        _initialize(_vault,  msg.sender,  msg.sender,  msg.sender);
        _initializeThis(_comet, _ethToWantFee, _depositer, _strategyName);
    }

    // ----------------- MAIN STRATEGY FUNCTIONS -----------------

    function estimatedTotalAssets() public view override returns (uint256) {
        //Returns the amount of want and collateral supplied plus an estimation of the rewards we are owed
        // minus the difference in amount supplied and amount borrowed of the base token
        //This needs to account for rewards in order to not show an inaccurate loss for harvestTrigger, but should not be relied upon.
        return
            balanceOfWant() + // balance of want
                balanceOfCollateral() + // asset suplied as collateral
                    rewardsInWant() - //expected rewards amount
                        baseTokenOwedInWant(); // liabilities
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        uint256 totalDebt = vault.strategies(address(this)).totalDebt;

        // 1. claim rewards, 2. even baseToken deposits and borrows 3. sell remainder of rewards to want.
        // This will accrue this account as well as the depositer so all future calls are accurate
        _claimAndSellRewards();
 
        //base token owed should be 0 here but we count it just in case
        uint256 totalAssetsAfterProfit = 
            balanceOfWant() + 
                balanceOfCollateral() -
                    baseTokenOwedInWant();

        if (totalDebt > totalAssetsAfterProfit) {
            // we have losses
            _loss = totalDebt - totalAssetsAfterProfit;
        } else {
            // we have profit
            _profit = totalAssetsAfterProfit - totalDebt;
        }

        (uint256 _amountFreed, ) = liquidatePosition(_debtOutstanding + _profit);

        _debtPayment = Math.min(_debtOutstanding, _amountFreed);
        //Adjust profit in case we had any losses from liquidatePosition
        _profit = _amountFreed - _debtPayment;   
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        // cache comet for all future calls
        Comet _comet = comet;
        // Accrue account for accurate balances for tend calls
        _comet.accrueAccount(address(this));

        // If the cost to borrow > rewards rate we will pull out all funds to not report a loss
        if(getNetBorrowApr(0) > getNetRewardApr(0)) {
            // Liquidate everything so not to report a loss
            liquidatePosition(balanceOfCollateral() + balanceOfWant());
            // Return since we dont want to do anything else
            return;
        }

        uint256 wantBalance = balanceOfWant();
        address _want = address(want);
        // if we have enough want to deposit more, we do
        // NOTE: we do not skip the rest of the function if we don't as it may need to repay or take on more debt
        if (wantBalance > _debtOutstanding) {
            _supply(
                _want,
                Math.min(
                    wantBalance - _debtOutstanding, 
                    //Check supply cap wont be reached for want
                    uint256(_comet.getAssetInfoByAddress(_want).supplyCap) - uint256(_comet.totalsCollateral(_want).totalSupplyAsset)
            ));
        }

        // NOTE: debt + collateral calcs are done in USD
        uint256 collateralInUsd = _toUsd(balanceOfCollateral(), _want);

        // if there is no want deposited into compound, don't do anything
        // this means no debt is borrowed from compound too
        if (collateralInUsd == 0) {
            return;
        }
        
        // cache baseToken to save a couple of sLoads in normal behavior
        address _baseToken = baseToken;

        // convert debt to USD
        uint256 debtInUsd = _toUsd(balanceOfDebt(), _baseToken);

        // LTV numbers are always in 1e18
        uint256 currentLTV = debtInUsd * 1e18 / collateralInUsd;
        uint256 targetLTV = _getTargetLTV(); // 70% under default liquidation Threshold

        // decide in which range we are and act accordingly:
        // SUBOPTIMAL(borrow) (e.g. from 0 to 70% liqLTV)
        // HEALTHY(do nothing) (e.g. from 70% to 80% liqLTV)
        // UNHEALTHY(repay) (e.g. from 80% to 100% liqLTV)

        if (targetLTV > currentLTV) {
            // SUBOPTIMAL RATIO: our current Loan-to-Value is lower than what we want
            // AND costs are lower than our max acceptable costs

            // we need to take on more debt
            uint256 targetDebtUsd =
                collateralInUsd * targetLTV / 1e18;

            uint256 amountToBorrowUsd = targetDebtUsd - debtInUsd; // safe bc we checked ratios
            // convert to BaseToken
            uint256 amountToBorrowBT = _fromUsd(amountToBorrowUsd, _baseToken);

            uint256 currentProtocolDebt = _comet.totalBorrow();
            uint256 maxProtocolDebt = _comet.totalSupply();
            // cap the amount of debt we are taking according to what is available from Compound
            if (currentProtocolDebt + amountToBorrowBT > maxProtocolDebt) {
                // Can't underflow because it's checked in the previous if condition
                amountToBorrowUsd = _toUsd(maxProtocolDebt - currentProtocolDebt, _baseToken);
            }

            // We want to make sure that the reward apr > borrow apr so we dont reprot a loss
            // Borrowing will cause the borrow apr to go up and the rewards apr to go down
            if(
                getNetBorrowApr(amountToBorrowBT) > 
                getNetRewardApr(amountToBorrowBT)
            ) {
                // If we would push it over the limit dont borrow anything
                amountToBorrowBT = 0;
            }

            // Need to have at least the min set by comet
            if (balanceOfDebt() + amountToBorrowBT > minThreshold) {
                _withdraw(baseToken, amountToBorrowBT);
            }

        } else if (currentLTV > _getWarningLTV()) {
            // UNHEALTHY RATIO
            // we repay debt to set it to targetLTV
            uint256 targetDebtUsd = targetLTV * collateralInUsd / 1e18;
            
            // Withdraw the difference from the Depositer
            _withdrawFromDepositer(_fromUsd(debtInUsd - targetDebtUsd, _baseToken)); // we withdraw from BaseToken depositer
            _repayTokenDebt(); // we repay the BaseToken debt with compound
        }

        if (balanceOfBaseToken() > 0) {
            depositer.deposit();
        }
    }

    function liquidateAllPositions()
        internal
        override
        returns (uint256 _amountFreed)
    {
        (_amountFreed, ) = liquidatePosition(balanceOfCollateral() + balanceOfWant());
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 balance = balanceOfWant();
        // if we have enough want to take care of the liquidatePosition without actually liquidating positons
        if (balance >= _amountNeeded) {
            return (_amountNeeded, 0);
        }
        // NOTE: amountNeeded is in want
        // NOTE: repayment amount is in BaseToken
        // NOTE: collateral and debt calcs are done in USD

        uint256 needed = _amountNeeded - balance;
        // Accrue account for accurate balances
        comet.accrueAccount(address(this));
        // We first repay whatever we need to repay to keep healthy ratios
        _withdrawFromDepositer(_calculateAmountToRepay(needed)); 
        // we repay the BaseToken debt with the amount withdrawn from the vault
        _repayTokenDebt();
        // Withdraw as much as we can up to the amount needed while maintaning a health ltv
        _withdraw(address(want), Math.min(needed, _maxWithdrawal()));
        // it will return the free amount of want
        balance = balanceOfWant();
        // we check if we withdrew less than expected, we have not more baseToken left AND should harvest or buy BaseToken with want (potentially realising losses)
        if (
            _amountNeeded > balance && // if we didn't get enough
            balanceOfDebt() > 0 && // still some debt remaining
            balanceOfBaseToken() + balanceOfDepositer() == 0 && // but no capital to repay
            !leaveDebtBehind // if set to true, the strategy will not try to repay debt by selling want
        ) {
            // using this part of code may result in losses but it is necessary to unlock full collateral in case of wind down
            // This should only occur when depleting the strategy so we want to swap the full amount of our debt
            // we buy BaseToken first with available rewards then with Want
            _buyBaseToken();

            // we repay debt to actually unlock collateral
            // after this, balanceOfDebt should be 0
            _repayTokenDebt();

            // then we try withdraw once more
            // still withdraw with target LTV since management can potentially save any left over manually 
            _withdraw(address(want), _maxWithdrawal());
            // re-update the balance
            balance = balanceOfWant();
        }

        if (_amountNeeded > balance) {
            _liquidatedAmount = balance;
            _loss = _amountNeeded - balance;
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    // manualWithdrawAndRepayDebt should be called previous to migration in order
    // to pay back any outstanding debt before migration
    function prepareMigration(address _newStrategy) internal override {
        // still check max withdraw in case of dust borrow balances
        _withdraw(address(want), _maxWithdrawal());
        
        uint256 baseBalance = balanceOfBaseToken();
        if(baseBalance > 0) {
            IERC20(baseToken).safeTransfer(_newStrategy, baseBalance);
        }
    }

    function tendTrigger(uint256 callCost) public view override returns (bool) {
        if (harvestTrigger(callCost)) {
            // harvest takes priority
            return false;
        }
    
        // if we are in danger of being liquidated tend no matter what
        if(comet.isLiquidatable(address(this))) return true;

        // we adjust position if:
        // 1. LTV ratios are not in the HEALTHY range (either we take on more debt or repay debt)
        // 2. costs are acceptable
        uint256 collateralInUsd = _toUsd(balanceOfCollateral(), address(want));

        // Nothing to rebalance if we do not have collateral locked
        if (collateralInUsd == 0) return false;

        uint256 currentLTV = _toUsd(balanceOfDebt(), baseToken) * 1e18 / collateralInUsd;
        uint256 targetLTV = _getTargetLTV();
        
        // Check if we are over our warning LTV
        if (currentLTV >  _getWarningLTV()) {
            // We have a higher tolerance for gas cost here since we are closer to liquidation
            return IBaseFeeGlobal(0xf8d0Ec04e94296773cE20eFbeeA82e76220cD549)
                        .basefee_global() <= maxGasPriceToTend;
        }
        
        if (// WE NEED TO TAKE ON MORE DEBT (we need a 10p.p (1000bps) difference)
            (currentLTV < targetLTV && targetLTV - currentLTV > 1e17) || 
                (getNetBorrowApr(0) > getNetRewardApr(0)) // UNHEALTHY BORROWING COSTS
        ) {
            return isBaseFeeAcceptable();
        }

        return false;
    }

    // ----------------- INTERNAL FUNCTIONS SUPPORT -----------------

    function _withdrawFromDepositer(uint256 _amountBT) internal {
        uint256 balancePrior = balanceOfBaseToken();
        // Only withdraw what we dont already have free
        _amountBT = balancePrior >= _amountBT ? 0 : _amountBT - balancePrior;
        if (_amountBT == 0) return;

        // Make sure we have enough balance. This accrues the account first.
        _amountBT =
            Math.min(
                _amountBT,
                depositer.accruedCometBalance()
            );
        // need to check liquidity of the comet
        _amountBT =
            Math.min(
                _amountBT,
                IERC20(baseToken).balanceOf(address(comet))
            );

        depositer.withdraw(_amountBT);
    }

    /*
    * Supply an asset that this contract holds to Compound III
    * This is used both to supply collateral as well as the baseToken
    */
    function _supply(address asset, uint256 amount) internal {
        if (amount == 0) return;
        comet.supply(asset, amount);
    }

    /*
    * Withdraws an asset from Compound III to this contract
    * for both collateral and borrowing baseToken
    */
    function _withdraw(address asset, uint256 amount) internal {
        if (amount == 0) return;
        comet.withdraw(asset, amount);
    }

    function _repayTokenDebt() internal {
        // we cannot pay more than loose balance or more than we owe
        _supply(baseToken, Math.min(balanceOfBaseToken(), balanceOfDebt()));
    }

    function _maxWithdrawal() internal view returns (uint256) {
        uint256 collateralInUsd = _toUsd(balanceOfCollateral(), address(want));
        uint256 debtInUsd = _toUsd(balanceOfDebt(), baseToken);

        // If there is no debt we can withdraw everything
        if(debtInUsd == 0) return balanceOfCollateral();

        // What we need to maintain a health LTV
        uint256 neededCollateralUsd = debtInUsd * 1e18 / _getTargetLTV();
        // We need more collateral so we cant withdraw anything
        if (neededCollateralUsd > collateralInUsd) {
            return 0;
        }
        // Return the difference in terms of want
        return
            _fromUsd(collateralInUsd - neededCollateralUsd, address(want));
    }

    function _calculateAmountToRepay(uint256 amount)
        internal
        view
        returns (uint256)
    {
        if (amount == 0) return 0;
        uint256 collateral = balanceOfCollateral();
        // to unlock all collateral we must repay all the debt
        if(amount >= collateral) return balanceOfDebt();
        
        // we check if the collateral that we are withdrawing leaves us in a risky range, we then take action
        uint256 newCollateralUsd = _toUsd(collateral - amount, address(want));

        uint256 targetDebtUsd = newCollateralUsd * _getTargetLTV() / 1e18;
        uint256 targetDebt = _fromUsd(targetDebtUsd, baseToken);
        uint256 currentDebt = balanceOfDebt();
        // Repay only if our target debt is lower than our current debt
        return targetDebt < currentDebt ? currentDebt - targetDebt : 0;
    }

    // ----------------- INTERNAL CALCS -----------------

    // Returns the _amount of _token in terms of USD, i.e 1e8
    function _toUsd(uint256 _amount, address _token) internal view returns(uint256) {
        if(_amount == 0) return _amount;
        // usd price is returned as 1e8
        unchecked {
            return _amount * getCompoundPrice(_token) / (10 ** IERC20Extended(_token).decimals());
        }
    }

    // Returns the _amount of usd (1e8) in terms of _token
    function _fromUsd(uint256 _amount, address _token) internal view returns(uint256) {
        if(_amount == 0) return _amount;
        unchecked {
            return _amount * (10 ** IERC20Extended(_token).decimals()) / getCompoundPrice(_token);
        }
    }

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function balanceOfCollateral() public view returns (uint256) {
        return uint256(comet.userCollateral(address(this), address(want)).balance);
    }

    function balanceOfBaseToken() public view returns(uint256) {
        return IERC20(baseToken).balanceOf(address(this));
    }

    function balanceOfDepositer() public view returns(uint256) {
        return depositer.cometBalance();
    }

    function balanceOfDebt() public view returns (uint256) {
        return comet.borrowBalanceOf(address(this));
    }

    // Returns the negative position of base token. i.e. borrowed - supplied
    // if supplied is higher it will return 0
    function baseTokenOwedBalance() public view returns(uint256) {
        uint256 supplied = balanceOfDepositer();
        uint256 borrowed = balanceOfDebt();
        uint256 loose = balanceOfBaseToken();
        
        // If they are the same or supply > debt return 0
        if(supplied + loose >= borrowed) return 0;

        unchecked {
            return borrowed - supplied - loose;
        }
    }

    function baseTokenOwedInWant() internal view returns(uint256) {
        return _fromUsd(_toUsd(baseTokenOwedBalance(), baseToken), address(want));
    }

    function rewardsInWant() public view returns(uint256) {
        // underreport by 10% for safety
        return _fromUsd(_toUsd(depositer.getRewardsOwed(), comp), address(want)) * 9_000 / MAX_BPS;
    }

    // We put the logic for these APR functions in the depositer contract to save byte code in the main strategy \\
    function getNetBorrowApr(uint256 newAmount) public view returns(uint256) {
        return depositer.getNetBorrowApr(newAmount);
    }

    function getNetRewardApr(uint256 newAmount) public view returns (uint256) {
        return depositer.getNetRewardApr(newAmount);
    }

    /*
    * Get the liquidation collateral factor for an asset
    */
    function getLiquidateCollateralFactor() public view returns (uint256) {
        return uint256(comet.getAssetInfoByAddress(address(want)).liquidateCollateralFactor);
    }

    /*
    * Get the price feed address for an asset
    */
    function getPriceFeedAddress(address asset) internal view returns (address priceFeed) {
        priceFeed = priceFeeds[asset];
        if(priceFeed == address(0)) {
            priceFeed = comet.getAssetInfoByAddress(asset).priceFeed;
        }
    }

    /*
    * Get the current price of an asset from the protocol's persepctive
    */
    function getCompoundPrice(address asset) internal view returns (uint256 price) {
        price = comet.getPrice(getPriceFeedAddress(asset));
        // If weth is base token we need to scale response to e18
        if(price == 1e8 && asset == weth) price = 1e18; 
    }

    // External function used to easisly calculate the current LTV of the strat
    function getCurrentLTV() external view returns(uint256) {
        unchecked {
            return _toUsd(balanceOfDebt(), baseToken) * 1e18 / _toUsd(balanceOfCollateral(), address(want));
        }
    }

    function _getTargetLTV()
        internal
        view
        returns (uint256)
    {
        unchecked {
            return
                getLiquidateCollateralFactor() * targetLTVMultiplier / MAX_BPS;
        }
    }

    function _getWarningLTV()
        internal
        view
        returns (uint256)
    {
        unchecked{
            return
                getLiquidateCollateralFactor() * warningLTVMultiplier / MAX_BPS;
        }
    }

    // ----------------- HARVEST / TOKEN CONVERSIONS -----------------

    function claimRewards() external onlyKeepers {
        _claimRewards();
    }

    function _claimRewards() internal {
        rewardsContract.claim(address(comet), address(this), true);
        // Pull rewards from depositer even if not incentivised to accrue the account
        depositer.claimRewards();   
    }

    function _claimAndSellRewards() internal {
        _claimRewards();

        address _comp = comp;

        uint256 compBalance = IERC20(_comp).balanceOf(address(this));

        if(compBalance <= minToSell) return;

        uint256 baseNeeded = baseTokenOwedBalance();

        if(baseNeeded > 0) {
            address _baseToken = baseToken;
            // We estimate how much we will need in order to get the amount of base
            // Accounts for slippage and diff from oracle price, just to assure no horrible sandwhich
            uint256 maxComp = _fromUsd(_toUsd(baseNeeded, _baseToken), _comp) * 10_500 / MAX_BPS;
            if(maxComp < compBalance) {
                // If we have enough swap and exact amount out
                _swapFrom(_comp, _baseToken, baseNeeded, maxComp);
            } else {
                // if not swap everything we have
                _swapTo(_comp, _baseToken, compBalance);
            }
        }
        
        compBalance = IERC20(_comp).balanceOf(address(this));
        // Anything over the amount to cover debt is profit
        if(compBalance > minToSell) {
            _swapTo(_comp, address(want), compBalance);
        }
    }

    // This should only ever get called when withdrawing all funds from the strategy if there is debt left over.
    // It will first try and sell rewards for the needed amount of base token. then will swap want
    // Using this in a normal withdraw can cause it to be sandwhiched which is why we use rewards first
    function _buyBaseToken() internal {
        // We should be able to get the needed amount from rewards tokens. 
        // We first try that before swapping want and reporting losses.
        _claimAndSellRewards();

        uint256 baseStillOwed = baseTokenOwedBalance();
        // Check if our debt balance is still greater than our base token balance
        if(baseStillOwed > 0) {
            // Need to account for both slippage and diff in the oracle price.
            // Should be only swapping very small amounts so its just to make sure there is no massive sandwhich
            uint256 maxWantBalance = _fromUsd(_toUsd(baseStillOwed, baseToken), address(want)) * 10_500 / MAX_BPS;
            // Under 10 can cause rounding errors from token conversions, no need to swap that small amount  
            if (maxWantBalance <= 10) return;

            // This should rarely if ever happen so we approve only what is needed
            IERC20(address(want)).safeApprove(address(router), 0);
            IERC20(address(want)).safeApprove(address(router), maxWantBalance);
            _swapFrom(address(want), baseToken, baseStillOwed, maxWantBalance);   
        }
    }

    function _swapTo(
        address _from, 
        address _to, 
        uint256 _amountFrom
    ) internal {
        if(_from == weth || _to == weth) {
            ISwapRouter.ExactInputSingleParams memory params =
                ISwapRouter.ExactInputSingleParams(
                    _from, // tokenIn
                    _to, // tokenOut
                    uniFees[_from][_to], // from-eth fee
                    address(this), // recipient
                    block.timestamp, // deadline
                    _amountFrom, // amountIn
                    0, // amountOut
                    0 // sqrtPriceLimitX96
                );

            router.exactInputSingle(params);
        } else {
            bytes memory path =
                abi.encodePacked(
                    _from, // from-ETH
                    uniFees[_from][weth],
                    weth, // ETH-to
                    uniFees[weth][_to],
                    _to
                );

            router.exactInput(
                ISwapRouter.ExactInputParams(
                    path,
                    address(this),
                    block.timestamp,
                    _amountFrom,
                    0
                )
            );
        }
    }

    function _swapFrom(
        address _from, 
        address _to, 
        uint256 _amountTo, 
        uint256 _maxAmountFrom
    ) internal {
        if(_from == weth || _to == weth) {
            ISwapRouter.ExactOutputSingleParams memory params =
                ISwapRouter.ExactOutputSingleParams(
                    _from, // tokenIn
                    _to, // tokenOut
                    uniFees[_from][_to], // want-eth fee
                    address(this), // recipient
                    block.timestamp, // deadline
                    _amountTo, // amountOut
                    _maxAmountFrom, // amountIn
                    0 // sqrtPriceLimitX96
                );

            router.exactOutputSingle(params);
        } else {
            bytes memory path =
                abi.encodePacked(
                    _to, 
                    uniFees[weth][_to],// to-ETH
                    weth, 
                    uniFees[_from][weth], // ETH-from
                    _from
                    );

            router.exactOutput(
                ISwapRouter.ExactOutputParams(
                    path,
                    address(this),
                    block.timestamp,
                    _amountTo, //How much we want out
                    _maxAmountFrom
                )
            );
        }
    }

    function ethToWant(uint256 _amtInWei)
        public
        view
        override
        returns (uint256)
    {
        return _fromUsd(_toUsd(_amtInWei, weth), address(want));
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}
    
    //Manual function available to management to withdraw from vault and repay debt
    function manualWithdrawAndRepayDebt(uint256 _amount) external onlyAuthorized {
        if(_amount > 0) {
            depositer.withdraw(_amount);
        }
        _repayTokenDebt();
    }
}