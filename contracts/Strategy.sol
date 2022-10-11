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

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    //For apr calculations
    uint internal constant DAYS_PER_YEAR = 365;
    uint internal constant SECONDS_PER_DAY = 60 * 60 * 24;
    uint internal constant SECONDS_PER_YEAR = 365 days;
    //Used for apr calculations
    uint public BASE_MANTISSA;
    uint public BASE_INDEX_SCALE;

    // if set to true, the strategy will not try to repay debt by selling want
    bool public leaveDebtBehind;

    // NOTE: LTV = Loan-To-Value = debt/collateral
    // Target LTV: ratio up to which which we will borrow
    uint16 public targetLTVMultiplier = 7_000;

    // Warning LTV: ratio at which we will repay
    uint16 public warningLTVMultiplier = 8_000; // 80% of liquidation LTV

    // support
    uint16 internal constant MAX_BPS = 10_000; // 100%

    //This is the address of the main V3 pool
    Comet public comet;
    //This is the token we will be borrowing/supplying
    address public baseToken;
    
    CometRewards public constant rewardsContract = 
        CometRewards(0x1B0e765F6224C21223AeA2af16c1C46E38885a40); 
    
    //The vault we will deposit the baseToken into
    IVault public yVault;

    address internal constant comp = 
        0xc00e94Cb662C3520282E6f5717214004A7f26888;
    address internal constant weth = 
        0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Uniswap v3 router
    ISwapRouter internal constant router =
        ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    //Fees for the V3 pools
    uint24 public compToEthFee;
    uint24 public ethToBaseFee;
    uint24 public ethToWantFee;

    //Needs to be set to at least comet.baseBorrowMin()
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
    ) external onlyEmergencyAuthorized {
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
        compToEthFee = _compToEthFee;
        ethToBaseFee = _ethToBaseFee;
        ethToWantFee = _ethToWantFee;
    }

    function _initializeThis(
        address _comet,
        uint24 _ethToWantFee, 
        address _yVault,
        string memory _strategyName
    ) internal {
        // Make sure we only initialize one time
        require(address(comet) == address(0), "!comet");
        comet = Comet(_comet);

        baseToken = comet.baseToken();
        minThreshold = comet.baseBorrowMin();
        yVault = IVault(_yVault);

        require(baseToken == address(yVault.token()), "!base");

        BASE_MANTISSA = comet.baseScale();
        BASE_INDEX_SCALE = comet.baseIndexScale();

        want.safeApprove(_comet, type(uint256).max);
        IERC20(baseToken).safeApprove(_comet, type(uint256).max);
        IERC20(baseToken).safeApprove(_yVault, type(uint256).max);
        IERC20(comp).safeApprove(address(router), type(uint256).max);

        //Default to .3% pool
        compToEthFee = 3000;
        //Default to .05% pool
        ethToBaseFee = 500;
        ethToWantFee = _ethToWantFee;

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
        address sender = msg.sender;
        _initialize(_vault, sender, sender, sender);
        _initializeThis(_comet, _ethToWantFee, _yVault, _strategyName);
    }

    // ----------------- MAIN STRATEGY FUNCTIONS -----------------

    function estimatedTotalAssets() public view override returns (uint256) {
        //Returns the amount of want we have plus the collateral supplied plus an estimation of the rewards we are owed
        // minus the difference in amount supplied and amount borrowed of the base token
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

        _profit = totalAssetsAfterProfit > totalDebt ? totalAssetsAfterProfit - totalDebt : 0;

        uint256 _amountFreed;
        (_amountFreed, _loss) = liquidatePosition(_debtOutstanding + _profit);

        _debtPayment = Math.min(_debtOutstanding, _amountFreed);

        if (_loss > _profit) {
            // Example:
            // debtOutstanding 100, profit 50, _amountFreed 100, _loss 50
            // loss should be 0, (50-50)
            // profit should endup in 0
            _loss = _loss - _profit;
            _profit = 0;
        } else {
            // Example:
            // debtOutstanding 100, profit 50, _amountFreed 140, _loss 10
            // _profit should be 40, (50 profit - 10 loss)
            // loss should end up in be 0
            _profit = _profit - _loss;
            _loss = 0;
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 wantBalance = balanceOfWant();

        // if we have enough want to deposit more, we do
        // NOTE: we do not skip the rest of the function if we don't as it may need to repay or take on more debt
        if (wantBalance > _debtOutstanding) {
            _supply(
                address(want),
                Math.min(
                    wantBalance - _debtOutstanding, 
                    //Check supply cap wont be reached for want
                    getSupplyCap() - uint256(comet.totalsCollateral(address(want)).totalSupplyAsset)
            ));
        }

        // NOTE: debt + collateral calcs are done in USD
        uint256 collateralInUsd = _toUsd(balanceOfCollateral(), address(want));

        // if there is no want deposited into compound, don't do nothing
        // this means no debt is borrowed from compound too
        if (collateralInUsd == 0) {
            return;
        }

        uint256 debtInUsd = _toUsd(balanceOfDebt(), baseToken);
        uint256 currentLiquidationThreshold = getLiquidateCollateralFactor();

        uint256 currentLTV = debtInUsd * 1e18 / collateralInUsd;
        uint256 targetLTV = _getTargetLTV(currentLiquidationThreshold); // 70% under liquidation Threshold
        uint256 warningLTV = _getWarningLTV(currentLiquidationThreshold); // 80% under liquidation Threshold

        // decide in which range we are and act accordingly:
        // SUBOPTIMAL(borrow) (e.g. from 0 to 60% liqLTV)
        // HEALTHY(do nothing) (e.g. from 60% to 80% liqLTV)
        // UNHEALTHY(repay) (e.g. from 80% to 100% liqLTV)

        // we use our target cost of capital to calculate how much debt we can take on / how much debt we need to repay
        // in order to bring costs back to an acceptable range
        // currentProtocolDebt => total amount of debt taken by all compound's borrowers
        // maxProtocolDebt => amount of total debt at which the cost of capital is equal to our acceptable costs
        // if the current protocol debt is higher than the max protocol debt, we will repay debt

        uint256 currentBorrowApr = getBorrowApr(0);
        uint256 currentRewardApr = getRewardAprForBorrowBase(0);

        if (targetLTV > currentLTV && currentBorrowApr < currentRewardApr) {
            // SUBOPTIMAL RATIO: our current Loan-to-Value is lower than what we want
            // AND costs are lower than our max acceptable costs

            // we need to take on more debt
            uint256 targetDebtUsd =
                collateralInUsd * targetLTV / 1e18;

            uint256 amountToBorrowUsd = targetDebtUsd - debtInUsd; // safe bc we checked ratios
            uint256 currentProtocolDebt = comet.totalBorrow();
            uint256 maxProtocolDebt = comet.totalSupply();
            // cap the amount of debt we are taking according to our acceptable costs
            // if with the new loan we are increasing our cost of capital over what is healthy
            if (currentProtocolDebt + _fromUsd(amountToBorrowUsd, baseToken) > maxProtocolDebt) {
                // Can't underflow because it's checked in the previous if condition
                amountToBorrowUsd = _toUsd(maxProtocolDebt - currentProtocolDebt, baseToken);
            }

            //We want to make sure that the reward apr > borrow apr so we dont reprot a loss
            uint256 expectedBorrowApr = getBorrowApr(_fromUsd(amountToBorrowUsd, baseToken));
            uint256 expectedRewardApr = getRewardAprForBorrowBase(_fromUsd(amountToBorrowUsd, baseToken));
            if(expectedBorrowApr > expectedRewardApr) {
                amountToBorrowUsd = 0;
            }

            // convert to BaseToken
            uint256 amountToBorrowBT =
                _fromUsd(amountToBorrowUsd, baseToken);
            //Need to have at least a min set by comet
            if (balanceOfDebt() + amountToBorrowBT > minThreshold) {
                _withdraw(baseToken, amountToBorrowBT);
            }
        } else if (currentLTV > warningLTV) {
            // UNHEALTHY RATIO
            // we may be in this case if the current cost of capital is higher than our max cost of capital
            // we repay debt to set it to targetLTV
            uint256 targetDebtUsd = targetLTV * collateralInUsd / 1e18;
            //Check for apr calculations
            uint256 amountToRepayUsd = debtInUsd - targetDebtUsd;

            uint256 amountToRepayBT =
                _fromUsd(amountToRepayUsd, baseToken);
            uint256 withdrawnBT = _withdrawFromYVault(amountToRepayBT); // we withdraw from BaseToken vault
            _repayTokenDebt(withdrawnBT); // we repay the BaseToken debt with compound
        } else if(currentBorrowApr > currentRewardApr) {
            //Liquidate everything so not to report a loss
            liquidatePosition(estimatedTotalAssets());
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

        // We first repay whatever we need to repay to keep healthy ratios
        uint256 amountToRepayBT = _calculateAmountToRepay(_amountNeeded);
        // we repay the BaseToken debt with the amount withdrawn from the vault
        _repayTokenDebt(_withdrawFromYVault(amountToRepayBT)); 

        // it will return the free amount of want
        _withdrawWant(_amountNeeded);

        balance = balanceOfWant();
        // we check if we withdrew less than expected AND should buy BaseToken with want (realising losses)
        if (
            _amountNeeded > balance &&
            balanceOfDebt() > 0 && // still some debt remaining
            balanceOfBaseToken() + balanceOfVault() == 0 && // but no capital to repay
            !leaveDebtBehind // if set to true, the strategy will not try to repay debt by selling want
        ) {
            // using this part of code will result in losses but it is necessary to unlock full collateral in case of wind down
            // we calculate how much want we need to fulfill the want request
            uint256 remainingAmountWant = _amountNeeded - balance;
            // then calculate how much BaseToken we need to unlock collateral
            amountToRepayBT = _calculateAmountToRepay(remainingAmountWant);

            // we buy BaseToken with Want
            _buyBaseTokenWithWant(balanceOfDebt());

            // we repay debt to actually unlock collateral
            // after this, balanceOfDebt should be 0
            _repayTokenDebt(balanceOfDebt());

            // then we try withdraw once more
            _withdrawWant(remainingAmountWant);
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
        //Withraw from vault first to know exactly how much we need to pay back
        _withdrawFromYVault(yVault.balanceOf(address(this)));
        //Claim and sell all rewards to cover debt
        _claimAndSellRewards();
        //Pay back debt and withdrawal all collateral
        _repayTokenDebt(type(uint256).max);
        _withdraw(address(want), _maxWithdrawal());
        
        uint256 baseBalance = balanceOfBaseToken();
        if(baseBalance > 0) {
            IERC20(baseToken).safeTransfer(_newStrategy, baseBalance);
        }

        uint256 compBalance = IERC20(comp).balanceOf(address(this));
        if(compBalance > 0) {
            IERC20(comp).safeTransfer(_newStrategy, baseBalance);
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
        // 2. costs are not acceptable and we need to repay debt
        uint256 collateralInUsd = _toUsd(balanceOfCollateral(), address(want));

        // Nothing to rebalance if we do not have collateral locked
        if (collateralInUsd == 0) {
            return false;
        }

        uint256 debtInUsd = _toUsd(balanceOfDebt(), baseToken);
        uint256 currentLiquidationThreshold = getLiquidateCollateralFactor();

        uint256 currentLTV = debtInUsd * 1e18 / collateralInUsd;
        uint256 targetLTV = _getTargetLTV(currentLiquidationThreshold);
        uint256 warningLTV = _getWarningLTV(currentLiquidationThreshold);

        if (currentLTV > warningLTV) {
            return IBaseFeeGlobal(0xf8d0Ec04e94296773cE20eFbeeA82e76220cD549)
                        .basefee_global() <= maxGasPriceToTend;
        }

        if (
            (currentLTV < targetLTV && targetLTV - currentLTV > 1000) || // WE NEED TO TAKE ON MORE DEBT (we need a 10p.p (1000bps) difference)
                (getBorrowApr(0) < getRewardAprForBorrowBase(0)) // UNHEALTHY BORROWING COSTS
        ) {
            return isBaseFeeAcceptable();
        }

        return false;
    }

    // ----------------- INTERNAL FUNCTIONS SUPPORT -----------------

    function _withdrawFromYVault(uint256 _amountBT) internal returns (uint256) {
        if (_amountBT == 0) {
            return 0;
        }
        // no need to check allowance bc the contract == token
        uint256 balancePrior = balanceOfBaseToken();
        uint256 sharesToWithdraw =
            Math.min(
                _baseTokenToYShares(_amountBT),
                yVault.balanceOf(address(this))
            );
        if (sharesToWithdraw == 0) {
            return 0;
        }
        yVault.withdraw(sharesToWithdraw, address(this), maxLoss);
        return balanceOfBaseToken() - balancePrior;
    }

    /*
    * Supply an asset that this contract holds to Compound III
    * This is used both to supply collateral as well as the baseToken
    */
    function _supply(address asset, uint amount) internal {
        if (amount == 0) return;
        comet.supply(asset, amount);
    }

    /*
    * Withdraws an asset from Compound III to this contract
    * for both collateral and borrowing baseToken
    */
    function _withdraw(address asset, uint amount) internal {
        if (amount == 0) return;
        comet.withdraw(asset, amount);
    }

    function _repayTokenDebt(uint256 amount) internal {
        if (amount == 0) {
            return;
        }

        // we cannot pay more than loose balance
        amount = Math.min(amount, balanceOfBaseToken());
        // we do pay more than we owe
        amount = Math.min(amount, balanceOfDebt());
        _supply(baseToken, amount);
    }

    //withdraw an amount including any want balance
    function _withdrawWant(uint256 amount) internal {
        uint256 toWithdraw = Math.min(amount, _maxWithdrawal());

        _withdraw(address(want), toWithdraw);
    }

    function _maxWithdrawal() internal view returns (uint256) {
        uint256 collateralInUsd = _toUsd(balanceOfCollateral(), address(want));
        uint256 debtInUsd = _toUsd(balanceOfDebt(), baseToken);

        uint256 neededCollateralUsd = debtInUsd * 1e18 / _getTargetLTV(getLiquidateCollateralFactor());

        if (neededCollateralUsd > collateralInUsd) {
            return 0;
        }
        //Return either our collateral balance or based off ltv
        return
            _fromUsd(collateralInUsd - neededCollateralUsd, address(want));
    }

    function _calculateAmountToRepay(uint256 amount)
        internal
        view
        returns (uint256)
    {
        if (amount == 0) {
            return 0;
        }
        // we check if the collateral that we are withdrawing leaves us in a risky range, we then take action
        uint256 newCollateralUsd = _toUsd(balanceOfCollateral() - amount, address(want));
        uint256 targetLTV = _getTargetLTV(getLiquidateCollateralFactor());
        uint256 debtInUsd = _toUsd(balanceOfDebt(), baseToken);

        uint256 targetDebtUsd = newCollateralUsd * targetLTV / 1e18;
        //Repay only if our target debt is lower than our current debt
        return targetDebtUsd < debtInUsd ? _fromUsd(debtInUsd - targetDebtUsd, baseToken) : 0;
    }

    // ----------------- INTERNAL CALCS -----------------

    //Returns the _amount of _token in terms of USD, i.e 1e8
    function _toUsd(uint256 _amount, address _token) internal view returns(uint256) {
        if(_amount == 0 || _amount == type(uint256).max) return _amount;
        uint256 usdPrice = getCompoundPrice(getPriceFeedAddress(_token));
        //usd price is returned as 1e8
        return _amount * usdPrice / (10 ** IERC20Extended(_token).decimals());
    }

    //Returns the _amount of usd (1e8) in terms of want
    function _fromUsd(uint256 _amount, address _token) internal view returns(uint256) {
        if(_amount == 0 || _amount == type(uint256).max) return _amount;
        uint256 usdPrice = getCompoundPrice(getPriceFeedAddress(_token));
        return _amount * (10 ** IERC20Extended(_token).decimals()) / usdPrice;
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
    //if for some reason supplied is higher it will return 0
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
    function getBorrowApr(uint256 newAmount) public view returns (uint) {
        uint256 borrows = comet.totalBorrow();
        uint256 supply = comet.totalSupply();

        uint256 newUtilization = (borrows + newAmount) * 1e18 / supply;
        //uint utilization = comet.getUtilization();
        return comet.getBorrowRate(newUtilization) * SECONDS_PER_YEAR;  
    }

    /*
    * Get the current reward for borrowing APR in Compound III
    * @param rewardTokenPriceFeed The address of the reward token (e.g. COMP) price feed
    * @return The reward APR in USD as a decimal scaled up by 1e18
    */
    function getRewardAprForBorrowBase(uint newAmount) public view returns (uint) {
        uint rewardTokenPriceInUsd = getCompoundPrice(getPriceFeedAddress(comp));
        uint basePriceInUsd = getCompoundPrice(comet.baseTokenPriceFeed());
        uint baseTotalBorrow = comet.totalBorrow() + newAmount;
        uint baseTrackingBorrowSpeed = comet.baseTrackingBorrowSpeed();
        uint rewardToBorrowersPerDay = baseTrackingBorrowSpeed * SECONDS_PER_DAY * (BASE_INDEX_SCALE / BASE_MANTISSA);
        uint borrowBaseRewardApr = (rewardTokenPriceInUsd * rewardToBorrowersPerDay / (baseTotalBorrow * basePriceInUsd)) * DAYS_PER_YEAR;
        return borrowBaseRewardApr;
    }

    //Returns the supply cap of the want token
    function getSupplyCap() internal view returns(uint256) {
        return uint256(comet.getAssetInfoByAddress(address(want)).supplyCap);
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
    function getPriceFeedAddress(address asset) public view returns (address) {
        if(asset == baseToken) return comet.baseTokenPriceFeed();
        return comet.getAssetInfoByAddress(asset).priceFeed;
    }

    /*
    * Get the current price of an asset from the protocol's persepctive
    */
    function getCompoundPrice(address singleAssetPriceFeed) public view returns (uint) {
        return comet.getPrice(singleAssetPriceFeed);
    }

    function delegatedAssets() external view override returns (uint256) {
        // returns total debt borrowed in want (which is the delegatedAssets)
        return _fromUsd(_toUsd(balanceOfVault(), baseToken), address(want));
    }

    function _getTargetLTV(uint256 liquidationThreshold)
        internal
        view
        returns (uint256)
    {
        return
            liquidationThreshold * uint256(targetLTVMultiplier) / MAX_BPS;
    }

    function _getWarningLTV(uint256 liquidationThreshold)
        internal
        view
        returns (uint256)
    {
        return
            liquidationThreshold * uint256(warningLTVMultiplier) / MAX_BPS;
    }

    // ----------------- TOKEN CONVERSIONS -----------------

    function _claimAndSellRewards() internal {
        _claimRewards();

        uint256 compBalance = IERC20(comp).balanceOf(address(this));

        if(compBalance <= minToSell) return;

        uint256 baseNeeded = baseTokenOwedBalance();

        if(baseNeeded > 0) {

            bytes memory path =
                abi.encodePacked(
                    baseToken, 
                    ethToBaseFee,// base-ETH
                    weth, 
                    compToEthFee, // ETH-want
                    comp
                    );

            // Proceeds from Comp are not subject to minExpectedSwapPercentage
            // so they could get sandwiched if we end up in an uncle block
            router.exactOutput(
                ISwapRouter.ExactOutputParams(
                    path,
                    address(this),
                    block.timestamp,
                    baseNeeded, //How much we want out
                    compBalance
                )
            );
        }

        compBalance = IERC20(comp).balanceOf(address(this));

        if(compBalance > minToSell) {
            _sellCompToWant(compBalance);
        }
    }

    function _sellCompToWant(uint256 _amount) internal {
        if(address(want) == weth) {
            ISwapRouter.ExactInputSingleParams memory params =
                ISwapRouter.ExactInputSingleParams(
                    comp, // tokenIn
                    address(want), // tokenOut
                    compToEthFee, // comp-eth fee
                    address(this), // recipient
                    block.timestamp, // deadline
                    _amount, // amountIn
                    0, // amountOut
                    0 // sqrtPriceLimitX96
                );

            router.exactInputSingle(params);
            
        } else {
            bytes memory path =
                abi.encodePacked(
                    comp, // comp-ETH
                    compToEthFee,
                    weth, // ETH-want
                    ethToWantFee,
                    address(want)
                );

            // Proceeds from Comp are not subject to minExpectedSwapPercentage
            // so they could get sandwiched if we end up in an uncle block
            router.exactInput(
                ISwapRouter.ExactInputParams(
                    path,
                    address(this),
                    block.timestamp,
                    _amount,
                    0
                )
            );
        }
    }

    /*
    * Gets the amount of reward tokens due to this contract address
    */
    function getRewardsOwed() public view returns (uint) {
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
        _claimRewards();
    }

    function _claimRewards() internal {
        rewardsContract.claim(address(comet), address(this), true);
    }

    function _buyBaseTokenWithWant(uint256 _amount) internal {
        if (_amount == 0) {
            return;
        }
        uint256 maxWantBalance = _fromUsd(_toUsd(_amount, baseToken), address(want)) * 9800 / MAX_BPS;
        _checkAllowance(address(router), address(want), maxWantBalance);
        if(address(want) == weth || baseToken == weth) {
            ISwapRouter.ExactOutputSingleParams memory params =
                ISwapRouter.ExactOutputSingleParams(
                    address(want), // tokenIn
                    baseToken, // tokenOut
                    ethToWantFee, // want-eth fee
                    address(this), // recipient
                    block.timestamp, // deadline
                    _amount, // amountOut
                    maxWantBalance, // amountIn
                    0 // sqrtPriceLimitX96
                );

            router.exactOutputSingle(params);
            
        } else {
            bytes memory path =
                abi.encodePacked(
                    baseToken, //Token out
                    ethToBaseFee,
                    weth, // middle token
                    ethToWantFee,
                    address(want) // token in
                );

            router.exactOutput(
                ISwapRouter.ExactOutputParams(
                    path,
                    address(this),
                    block.timestamp,
                    _amount,
                    maxWantBalance
                )
            );
        }
    }

    function _checkAllowance(
        address _contract,
        address _token,
        uint256 _amount
    ) internal {
        if (IERC20(_token).allowance(address(this), _contract) < _amount) {
            IERC20(_token).safeApprove(_contract, 0);
            IERC20(_token).safeApprove(_contract, type(uint256).max);
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
    
    // check if the current baseFee is below our external target
    function isBaseFeeAcceptable() internal view returns (bool) {
        return
            IBaseFee(0xb5e1CAcB567d98faaDB60a1fD4820720141f064F)
                .isCurrentBaseFeeAcceptable();
    }
}