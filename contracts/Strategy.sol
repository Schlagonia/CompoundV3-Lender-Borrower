// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.12;
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

interface IBaseFee {
    function isCurrentBaseFeeAcceptable() external view returns (bool);
}

interface IBaseFeeGlobal {
    function basefee_global() external view returns (uint256);
}
 
/********************
 *   Strategy to farm the rewards on Compound V3 by providing any of the possible collateral assets and then borrowing the base token
 *      The base token is then deposited into the corresponding Yearn vault and borrowing rewards are harvested.
 *   Made by @Schlagonia
 *   https://github.com/Schlagonia/CompoundV3-Lender-Borrower
 *
 ********************* */

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    //Used for Comp apr calculations
    uint64 internal constant DAYS_PER_YEAR = 365;
    uint64 internal constant SECONDS_PER_DAY = 60 * 60 * 24;
    uint64 internal constant SECONDS_PER_YEAR = 365 days;
    uint64 internal BASE_MANTISSA;
    uint64 internal BASE_INDEX_SCALE;

    // if set to true, the strategy will not try to repay debt by selling want
    bool public leaveDebtBehind;

    //This is the address of the main V3 pool
    Comet public comet;
    //This is the token we will be borrowing/supplying
    address public baseToken;
    //The contract to get Comp rewards from
    CometRewards public constant rewardsContract = 
        CometRewards(0x1B0e765F6224C21223AeA2af16c1C46E38885a40); 
    
    //The Yearn vault we will deposit the baseToken into
    IVault public yVault;

    //The reward Token
    address internal constant comp = 
        0xc00e94Cb662C3520282E6f5717214004A7f26888;
    //The reference token
    address internal constant weth = 
        0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Uniswap v3 router
    ISwapRouter internal constant router =
        ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    //Fees for the V3 pools
    mapping (address => mapping (address => uint24)) public uniFees;

    // NOTE: LTV = Loan-To-Value = debt/collateral
    // Target LTV: ratio up to which which we will borrow
    uint16 public targetLTVMultiplier = 7_000;

    // Warning LTV: ratio at which we will repay
    uint16 public warningLTVMultiplier = 8_000; // 80% of liquidation LTV

    // support
    uint16 internal constant MAX_BPS = 10_000; // 100%
    //Thresholds
    uint256 internal minThreshold;
    uint256 public minToSell;
    uint256 public maxLoss;
    uint256 public maxGasPriceToTend;
    
    string internal strategyName;

    constructor(
        address _vault,
        address _comet,
        uint24 _ethToWantFee,
        address _yVault,
        string memory _strategyName
    ) BaseStrategy(_vault) {
        _initializeThis(_comet, _ethToWantFee, _yVault, _strategyName);
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
        uint256 _maxLoss,
        uint256 _maxGasPriceToTend
    ) external onlyAuthorized {
        require(
            _warningLTVMultiplier <= 9_000 &&
                _targetLTVMultiplier <= _warningLTVMultiplier
        );
        targetLTVMultiplier = _targetLTVMultiplier;
        warningLTVMultiplier = _warningLTVMultiplier;
        minToSell = _minToSell;
        leaveDebtBehind = _leaveDebtBehind;
        maxGasPriceToTend = _maxGasPriceToTend;

        require(_maxLoss <= 10_000);
        maxLoss = _maxLoss;
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
        uniFees[address(want)][weth] = _ethToWantFee;
        uniFees[weth][address(want)] = _ethToWantFee;
        
        uniFees[comp][weth] = _compToEthFee;
        uniFees[weth][comp] = _compToEthFee;

        uniFees[baseToken][weth] = _ethToBaseFee;
        uniFees[weth][baseToken] = _ethToBaseFee;
    }

    function _initializeThis(
        address _comet,
        uint24 _ethToWantFee, 
        address _yVault,
        string memory _strategyName
    ) internal {
        // Make sure we only initialize one time
        require(address(comet) == address(0));
        comet = Comet(_comet);

        //Get the baseToken we wil borrow and the min
        baseToken = comet.baseToken();
        minThreshold = comet.baseBorrowMin();
        yVault = IVault(_yVault);

        require(baseToken == address(yVault.token()));

        //For APR calculations
        BASE_MANTISSA = uint64(comet.baseScale());
        BASE_INDEX_SCALE = uint64(comet.baseIndexScale());

        want.safeApprove(_comet, type(uint256).max);
        IERC20(baseToken).safeApprove(_comet, type(uint256).max);
        IERC20(baseToken).safeApprove(_yVault, type(uint256).max);
        IERC20(comp).safeApprove(address(router), type(uint256).max);
        IERC20(baseToken).safeApprove(address(router), type(uint256).max);

        //Default to .3% pool for comp/eth and to .05% pool for eth/usdc
        _setFees(3000, 500, _ethToWantFee);

        strategyName = _strategyName;

        // Set health check to health.ychad.eth
        healthCheck = 0xDDCea799fF1699e98EDF118e0629A974Df7DF012;
    }

    function initialize(
        address _vault,
        address _comet,
        uint24 _ethToWantFee,
        address _yVault,
        string memory _strategyName
    ) external {
        _initialize(_vault,  msg.sender,  msg.sender,  msg.sender);
        _initializeThis(_comet, _ethToWantFee, _yVault, _strategyName);
    }

    // ----------------- MAIN STRATEGY FUNCTIONS -----------------

    function estimatedTotalAssets() public view override returns (uint256) {
        //Returns the amount of want and collateral supplied plus an estimation of the rewards we are owed
        // minus the difference in amount supplied and amount borrowed of the base token
        //This needs to account for rewards in order to not show a loss for harvestTrigger, but should not be relied upon.
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

        // claim rewards, even out baseToken deposits and borrows and sell remainder to want
        //This will accrue the account as well so all future calls are accurate
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
        //Accrue account for accurate balances for tend calls
        comet.accrueAccount(address(this));

        // If the cost to borrow > rewards rate we will pull out all funds to not report a loss
        // We will rely on rewards to pay the interest and any returns from the vault are extra
        // Do not expect the vault return to be > the borrow cost, and harvest are speratic and can't
        // always be relied on to cover the borrowing costs
        if(getBorrowApr(0) > getRewardAprForBorrowBase(0)) {
            //Liquidate everything so not to report a loss
            liquidatePosition(balanceOfCollateral() + balanceOfWant());
            //Return since we dont want to do anything else
            return;
        }

        uint256 wantBalance = balanceOfWant();

        // if we have enough want to deposit more, we do
        // NOTE: we do not skip the rest of the function if we don't as it may need to repay or take on more debt
        if (wantBalance > _debtOutstanding) {
            _supply(
                address(want),
                Math.min(
                    wantBalance - _debtOutstanding, 
                    //Check supply cap wont be reached for want
                    uint256(comet.getAssetInfoByAddress(address(want)).supplyCap) - uint256(comet.totalsCollateral(address(want)).totalSupplyAsset)
            ));
        }

        // NOTE: debt + collateral calcs are done in USD
        uint256 collateralInUsd = _toUsd(balanceOfCollateral(), address(want));

        // if there is no want deposited into compound, don't do anything
        // this means no debt is borrowed from compound too
        if (collateralInUsd == 0) {
            return;
        }

        uint256 debtInUsd = _toUsd(balanceOfDebt(), baseToken);
        //uint256 currentLiquidationThreshold = getLiquidateCollateralFactor();

        uint256 currentLTV = debtInUsd * 1e18 / collateralInUsd;
        uint256 targetLTV = _getTargetLTV(); // 70% under liquidation Threshold

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
            uint256 currentProtocolDebt = comet.totalBorrow();
            uint256 maxProtocolDebt = comet.totalSupply();
            // cap the amount of debt we are taking according to what is available from Compound
            if (currentProtocolDebt + _fromUsd(amountToBorrowUsd, baseToken) > maxProtocolDebt) {
                // Can't underflow because it's checked in the previous if condition
                amountToBorrowUsd = _toUsd(maxProtocolDebt - currentProtocolDebt, baseToken);
            }

            //We want to make sure that the reward apr > borrow apr so we dont reprot a loss
            //Borrowing will cause the borrow apr to go up and the rewards apr to go down
            if(
                getBorrowApr(_fromUsd(amountToBorrowUsd, baseToken)) > 
                getRewardAprForBorrowBase(_fromUsd(amountToBorrowUsd, baseToken))
            ) {
                //If we would push it over the limit dont borrow anything
                amountToBorrowUsd = 0;
            }

            // convert to BaseToken
            uint256 amountToBorrowBT =
                _fromUsd(amountToBorrowUsd, baseToken);
            //Need to have at least the min set by comet
            if (balanceOfDebt() + amountToBorrowBT > minThreshold) {
                _withdraw(baseToken, amountToBorrowBT);
            }
        } else if (currentLTV > _getWarningLTV()) {
            // UNHEALTHY RATIO
            // we repay debt to set it to targetLTV
            uint256 targetDebtUsd = targetLTV * collateralInUsd / 1e18;
            
            //Withdraw the difference from the vault
            _withdrawFromYVault(_fromUsd(debtInUsd - targetDebtUsd, baseToken)); // we withdraw from BaseToken vault
            _repayTokenDebt(); // we repay the BaseToken debt with compound
        }

        if (balanceOfBaseToken() > 0) {
            yVault.deposit();
        }
    }

    function liquidateAllPositions()
        internal
        override
        returns (uint256 _amountFreed)
    {
        (_amountFreed, ) = liquidatePosition(estimatedTotalAssets());
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
        //Accrue account for accurate balances
        comet.accrueAccount(address(this));
        // We first repay whatever we need to repay to keep healthy ratios
        _withdrawFromYVault(_calculateAmountToRepay(needed)); 
        // we repay the BaseToken debt with the amount withdrawn from the vault
        _repayTokenDebt();
        //Withdraw as much as we can up to the amount needed while maintaning a health ltv
        _withdraw(address(want), Math.min(needed, _maxWithdrawal()));
        // it will return the free amount of want
        balance = balanceOfWant();
        // we check if we withdrew less than expected AND should buy BaseToken with want (realising losses)
        if (
            _amountNeeded > balance &&
            balanceOfDebt() > 0 && // still some debt remaining
            balanceOfBaseToken() + balanceOfVault() == 0 && // but no capital to repay
            !leaveDebtBehind // if set to true, the strategy will not try to repay debt by selling want
        ) {
            // using this part of code will result in losses but it is necessary to unlock full collateral in case of wind down
            //This should only occur when depleting the strategy so we want to swap the full amount of our debt
            // we buy BaseToken with Want
            _buyBaseTokenWithWant(balanceOfDebt());

            // we repay debt to actually unlock collateral
            // after this, balanceOfDebt should be 0
            _repayTokenDebt();

            // then we try withdraw once more
            _withdraw(address(want), _maxWithdrawal());
        }

        balance = balanceOfWant();
        if (_amountNeeded > balance) {
            _liquidatedAmount = balance;
            _loss = _amountNeeded - balance;
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function prepareMigration(address _newStrategy) internal override {
        //Withraw from vault first to know exactly how much we can pay back
        yVault.withdraw(yVault.balanceOf(address(this)), address(this), maxLoss);

        //Accrue account for accurate balances
        comet.accrueAccount(address(this));

        if(!leaveDebtBehind) {
            //If we dont want to leave debt behind sell all rewards to pay all the debt back
            _claimAndSellRewards();
        }
        //Pay back debt and withdrawal all collateral
        _repayTokenDebt();
        _withdraw(address(want), _maxWithdrawal());
        
        uint256 baseBalance = balanceOfBaseToken();
        if(baseBalance > 0) {
            IERC20(baseToken).safeTransfer(_newStrategy, baseBalance);
        }
    }

    function harvestTrigger(uint256 callCostInWei) public view override returns (bool) {
        if(super.harvestTrigger(callCostInWei)) {
            isBaseFeeAcceptable();
        }
    }

    function tendTrigger(uint256 callCost) public view override returns (bool) {
        if (harvestTrigger(callCost)) {
            //harvest takes priority
            return false;
        }
    
        if(comet.isLiquidatable(address(this))) return true;
        // we adjust position if:
        // 1. LTV ratios are not in the HEALTHY range (either we take on more debt or repay debt)
        // 2. costs are acceptable and we need to repay debt
        uint256 collateralInUsd = _toUsd(balanceOfCollateral(), address(want));

        // Nothing to rebalance if we do not have collateral locked
        if (collateralInUsd == 0) {
            return false;
        }

        //uint256 currentLiquidationThreshold = getLiquidateCollateralFactor();
        uint256 currentLTV = _toUsd(balanceOfDebt(), baseToken) * 1e18 / collateralInUsd;
        uint256 targetLTV = _getTargetLTV();
        
        //Check if we are over our warning LTV
        if (currentLTV >  _getWarningLTV()) {
            //We have a higher tolerance for gas cost here since we are close to liquidation
            return IBaseFeeGlobal(0xf8d0Ec04e94296773cE20eFbeeA82e76220cD549)
                        .basefee_global() <= maxGasPriceToTend;
        }
        
        if (// WE NEED TO TAKE ON MORE DEBT (we need a 10p.p (1000bps) difference)
            (currentLTV < targetLTV && targetLTV - currentLTV > 1e17) || 
                (getBorrowApr(0) > getRewardAprForBorrowBase(0)) // UNHEALTHY BORROWING COSTS
        ) {
            return isBaseFeeAcceptable();
        }

        return false;
    }

    function isBaseFeeAcceptable() internal view returns(bool) {
        return IBaseFee(0xb5e1CAcB567d98faaDB60a1fD4820720141f064F)
                    .isCurrentBaseFeeAcceptable();
    }

    // ----------------- INTERNAL FUNCTIONS SUPPORT -----------------

    function _withdrawFromYVault(uint256 _amountBT) internal {
        if (_amountBT == 0) return;

        // no need to check allowance bc the contract == token
        uint256 balancePrior = balanceOfBaseToken();
        //Only withdraw what we dont already have free
        _amountBT = balancePrior >= _amountBT ? 0 : _amountBT - balancePrior;
        uint256 sharesToWithdraw =
            Math.min(
                _baseTokenToYShares(_amountBT),
                yVault.balanceOf(address(this))
            );
        if (sharesToWithdraw == 0) return;

        yVault.withdraw(sharesToWithdraw, address(this), maxLoss);
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
        // we cannot pay more than loose balance
        // we do pay more than we owe
        _supply(baseToken, Math.min(balanceOfBaseToken(), balanceOfDebt()));
    }

    function _maxWithdrawal() internal view returns (uint256) {
        uint256 collateralInUsd = _toUsd(balanceOfCollateral(), address(want));
        uint256 debtInUsd = _toUsd(balanceOfDebt(), baseToken);

        //If there is no debt we can withdraw everything
        if(debtInUsd == 0) return balanceOfCollateral();

        //What we need to maintain a health LTV
        uint256 neededCollateralUsd = debtInUsd * 1e18 / _getTargetLTV();
        //We need more collateral so we cant withdraw anything
        if (neededCollateralUsd > collateralInUsd) {
            return 0;
        }
        //Return the difference in terms of want
        return
            _fromUsd(collateralInUsd - neededCollateralUsd, address(want));
    }

    function _calculateAmountToRepay(uint256 amount)
        internal
        view
        returns (uint256)
    {
        if (amount == 0) return 0;
        if(amount >= balanceOfCollateral()) return balanceOfDebt();
        
        // we check if the collateral that we are withdrawing leaves us in a risky range, we then take action
        uint256 newCollateralUsd = _toUsd(balanceOfCollateral() - amount, address(want));
        uint256 debtInUsd = _toUsd(balanceOfDebt(), baseToken);

        uint256 targetDebtUsd = newCollateralUsd * _getTargetLTV() / 1e18;
        //Repay only if our target debt is lower than our current debt
        return targetDebtUsd < debtInUsd ? _fromUsd(debtInUsd - targetDebtUsd, baseToken) : 0;
    }

    // ----------------- INTERNAL CALCS -----------------

    //Returns the _amount of _token in terms of USD, i.e 1e8
    function _toUsd(uint256 _amount, address _token) internal view returns(uint256) {
        if(_amount == 0) return _amount;
        //usd price is returned as 1e8
        return _amount * getCompoundPrice(getPriceFeedAddress(_token)) / (10 ** IERC20Extended(_token).decimals());
    }

    //Returns the _amount of usd (1e8) in terms of want
    function _fromUsd(uint256 _amount, address _token) internal view returns(uint256) {
        if(_amount == 0) return _amount;
        return _amount * (10 ** IERC20Extended(_token).decimals()) / getCompoundPrice(getPriceFeedAddress(_token));
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

    function balanceOfVault() public view returns(uint256) {
        return yVault.balanceOf(address(this)) * yVault.pricePerShare() / (10**yVault.decimals());
    }

    function balanceOfDebt() public view returns (uint256) {
        return comet.borrowBalanceOf(address(this));
    }

    //Returns the negative position of base token. i.e. borrowed - supplied
    //if supplied is higher it will return 0
    function baseTokenOwedBalance() public view returns(uint256) {
        uint256 supplied = balanceOfVault();
        uint256 borrowed = balanceOfDebt();
        uint256 loose = balanceOfBaseToken();
        
        //If they are the same or supply > debt return 0
        if(supplied + loose >= borrowed) return 0;

        return borrowed - supplied - loose;
    }

    function baseTokenOwedInWant() public view returns(uint256) {
        return _fromUsd(_toUsd(baseTokenOwedBalance(), baseToken), address(want));
    }

    function rewardsInWant() public view returns(uint256) {
        return _fromUsd(_toUsd(getRewardsOwed(), comp), address(want)) * 9_000 / MAX_BPS;
    }

    function _baseTokenToYShares(uint256 amount)
        internal
        view
        returns (uint256)
    {
        return amount * (10**yVault.decimals()) / yVault.pricePerShare();
    }

    /*
    * Get the current borrow APR in Compound III
    */
    function getBorrowApr(uint256 newAmount) internal view returns (uint256) {

        return comet.getBorrowRate(
                    (comet.totalBorrow() + newAmount) * 1e18 / comet.totalSupply() //New utilization
                        ) * SECONDS_PER_YEAR;  
    }

    /*
    * Get the current reward for borrowing APR in Compound III
    * @param rewardTokenPriceFeed The address of the reward token (e.g. COMP) price feed
    * @return The reward APR in USD as a decimal scaled up by 1e18
    */
    function getRewardAprForBorrowBase(uint256 newAmount) internal view returns (uint256) {
        //borrowBaseRewardApr = (rewardTokenPriceInUsd * rewardToBorrowersPerDay / (baseTokenTotalBorrow * baseTokenPriceInUsd)) * DAYS_PER_YEAR;
        uint256 rewardToBorrowersPerDay =  comet.baseTrackingBorrowSpeed() * SECONDS_PER_DAY * BASE_INDEX_SCALE / BASE_MANTISSA;
        return (getCompoundPrice(getPriceFeedAddress(comp)) * 
                    rewardToBorrowersPerDay / 
                        ((comet.totalBorrow() + newAmount) * 
                            getCompoundPrice(comet.baseTokenPriceFeed()))) * 
                                DAYS_PER_YEAR;
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
    function getPriceFeedAddress(address asset) internal view returns (address) {
        if(asset == baseToken) return comet.baseTokenPriceFeed();
        return comet.getAssetInfoByAddress(asset).priceFeed;
    }

    /*
    * Get the current price of an asset from the protocol's persepctive
    */
    function getCompoundPrice(address singleAssetPriceFeed) internal view returns (uint256) {
        return comet.getPrice(singleAssetPriceFeed);
    }

    function delegatedAssets() external view override returns (uint256) {
        // returns total debt borrowed in want (which is the delegatedAssets)
        return _fromUsd(_toUsd(balanceOfVault(), baseToken), address(want));
    }

    //External function used to easisly calculate the current LTV of the strat
    function getCurrentLTV() external view returns(uint256) {
        return _toUsd(balanceOfDebt(), baseToken) * 1e18 / _toUsd(balanceOfCollateral(), address(want));
    }

    function _getTargetLTV()
        internal
        view
        returns (uint256)
    {
        return
            getLiquidateCollateralFactor() * targetLTVMultiplier / MAX_BPS;
    }

    function _getWarningLTV()
        internal
        view
        returns (uint256)
    {
        return
            getLiquidateCollateralFactor() * warningLTVMultiplier / MAX_BPS;
    }

    // ----------------- HARVEST / TOKEN CONVERSIONS -----------------

    /*
    * Gets the amount of reward tokens due to this contract address
    */
    function getRewardsOwed() public view returns (uint256) {
        CometStructs.RewardConfig memory config = rewardsContract.rewardConfig(address(comet));
        uint256 accrued = comet.baseTrackingAccrued(address(this));
        if (config.shouldUpscale) {
            accrued *= config.rescaleFactor;
        } else {
            accrued /= config.rescaleFactor;
        }
        uint256 claimed = rewardsContract.rewardsClaimed(address(comet), address(this));

        return accrued > claimed ? accrued - claimed : 0;
    }

    function claimRewards() external onlyKeepers {
        rewardsContract.claim(address(comet), address(this), true);
    }

    function _claimAndSellRewards() internal {
        rewardsContract.claim(address(comet), address(this), true);

        uint256 compBalance = IERC20(comp).balanceOf(address(this));

        if(compBalance <= minToSell) return;

        uint256 baseNeeded = baseTokenOwedBalance();

        if(baseNeeded > 0) {
            //We estimate how much we will need in order to get the amount of base
            //Accounts for slippage and diff from oracle price, just to assure no horrible sandwhich
            uint256 maxComp = _fromUsd(_toUsd(baseNeeded, baseToken), comp) * 10_500 / MAX_BPS;
            if(maxComp < compBalance) {
                //IF we have enough swap and exact amount out
                _swapFrom(comp, baseToken, baseNeeded, maxComp);
            } else {
                //if not swap everything we have
                _swapTo(comp, baseToken, compBalance);
            }
        } else if(balanceOfVault() > balanceOfDebt()) {
            //if vault balance is > owed pull those funds and swap to want
            baseNeeded = balanceOfVault() - balanceOfDebt();
            //withdraw the diff from the vault
            _withdrawFromYVault(baseNeeded);
            //Swap to want, check in case of any loss from the vault withdraw
            _swapTo(baseToken, address(want), Math.min(baseNeeded, balanceOfBaseToken()));
        }
        
        compBalance = IERC20(comp).balanceOf(address(this));

        if(compBalance > minToSell) {
            _swapTo(comp, address(want), compBalance);
        }
    }

    function _buyBaseTokenWithWant(uint256 _amount) internal {
        //Need to account for both slippage and diff in the oracle price.
        //Should be only swapping very small amounts so its just to make sure there is no massive sandwhich
        uint256 maxWantBalance = _fromUsd(_toUsd(_amount, baseToken), address(want)) * 10_500 / MAX_BPS;
        //Under 10 can cause rounding errors from token conversions, no need to swap that small amount  
        if (maxWantBalance <= 10) return;

        //This should rarely if ever happen so we approve only what is needed
        IERC20(address(want)).safeApprove(address(router), 0);
        IERC20(address(want)).safeApprove(address(router), maxWantBalance);
        _swapFrom(address(want), baseToken, _amount, maxWantBalance);   
    }

    function _swapTo(address _from, address _to, uint256 _amountFrom) internal {
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
    function manualWithdrawAndRepayDebt(uint256 _amount, uint256 _maxLoss) external onlyAuthorized {
        if(_amount > 0) {
            yVault.withdraw(_amount, address(this), _maxLoss);
        }
        _repayTokenDebt();
    }
}