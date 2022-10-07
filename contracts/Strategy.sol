// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.12;
pragma experimental ABIEncoderV2;

import {BaseStrategy} from "@yearn/yearn-vaults/contracts/BaseStrategy.sol";

import "./interfaces/IERC20Extended.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IVault} from "./interfaces/IVault.sol";

import {CometStructs} from "./interfaces/CompoundV3/CompoundV3.sol";
import {Comet} from "./interfaces/CompoundV3/CompoundV3.sol";
import {CometRewards} from "./interfaces/CompoundV3/CompoundV3.sol";
import {ISwapRouter} from "./interfaces/UniswapV3/ISwapRouter.sol";
import {ITradeFactory} from "./interfaces/ySwaps/ITradeFactory.sol";

interface IBaseFee {
    function isCurrentBaseFeeAcceptable() external view returns (bool);
}

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;

    //For apr calculations
    uint internal constant DAYS_PER_YEAR = 365;
    uint internal constant SECONDS_PER_DAY = 60 * 60 * 24;
    uint internal constant SECONDS_PER_YEAR = 365 days;

    // max interest rate we can afford to pay for borrowing investment token
    // amount in Ray (1e27 = 100%)
    uint256 public acceptableCostsRay;

    // max amount to borrow. used to manually limit amount (for yVault to keep APY)
    uint256 public maxTotalBorrowIT;

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
    uint public BASE_MANTISSA;
    uint public BASE_INDEX_SCALE;
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
    //Address of the trad factory if we want to use it
    address public tradeFactory;
    //Needs to be set to at least comet.baseBorrowMin
    uint256 internal minThreshold;
    uint256 public maxLoss;
    uint256 public maxGasPriceToTend;
    string internal strategyName;

    event RepayDebt(uint256 repayAmount, uint256 previousDebtBalance);

    constructor(
        address _vault,
        address _comet,
        uint24 _ethToWantFee,
        address _yVault,
        string memory _strategyName
    ) public BaseStrategy(_vault) {
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
        uint256 _acceptableCostsRay,
        uint256 _maxTotalBorrowIT,
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
        acceptableCostsRay = _acceptableCostsRay;
        maxTotalBorrowIT = _maxTotalBorrowIT;
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
        require(address(comet) == address(0), "already initiliazed"); // dev: strategy already initialized
        comet = Comet(_comet);

        yVault = IVault(_yVault);
        baseToken = comet.baseToken();
        require(baseToken == address(yVault.token()), "wrong yvualt");

        BASE_MANTISSA = comet.baseScale();
        BASE_INDEX_SCALE = comet.baseIndexScale();

        want.safeApprove(_comet, type(uint256).max);
        IERC20(baseToken).safeApprove(_comet, type(uint256).max);

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
    ) public {
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

        //rewards in want and base token owed should be 0 here
        uint256 totalAssetsAfterProfit = estimatedTotalAssets();

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
            uint256 amountToDeposit = wantBalance - _debtOutstanding;
            _supply(address(want), amountToDeposit);
        }

        // NOTE: debt + collateral calcs are done in ETH
        uint256 collateralInUsd = _toUsd(balanceOfCollateral(), address(want));

        // if there is no want deposited into aave, don't do nothing
        // this means no debt is borrowed from aave too
        if (collateralInUsd == 0) {
            return;
        }

        uint256 debtInUsd = _toUsd(balanceOfDebt(), baseToken);
        uint256 currentLiquidationThreshold = getLiquidateCollateralFactor();

        uint256 currentLTV = debtInUsd * MAX_BPS / collateralInUsd;
        uint256 targetLTV = _getTargetLTV(currentLiquidationThreshold); // 60% under liquidation Threshold
        uint256 warningLTV = _getWarningLTV(currentLiquidationThreshold); // 80% under liquidation Threshold

        // decide in which range we are and act accordingly:
        // SUBOPTIMAL(borrow) (e.g. from 0 to 60% liqLTV)
        // HEALTHY(do nothing) (e.g. from 60% to 80% liqLTV)
        // UNHEALTHY(repay) (e.g. from 80% to 100% liqLTV)

        // we use our target cost of capital to calculate how much debt we can take on / how much debt we need to repay
        // in order to bring costs back to an acceptable range
        // currentProtocolDebt => total amount of debt taken by all Aave's borrowers
        // maxProtocolDebt => amount of total debt at which the cost of capital is equal to our acceptable costs
        // if the current protocol debt is higher than the max protocol debt, we will repay debt

        uint256 currentProtocolDebt = comet.totalBorrow();
        uint256 maxProtocolDebt = comet.totalSupply();

        if (targetLTV > currentLTV && currentProtocolDebt < maxProtocolDebt) {
            // SUBOPTIMAL RATIO: our current Loan-to-Value is lower than what we want
            // AND costs are lower than our max acceptable costs

            // we need to take on more debt
            uint256 targetDebtUsd =
                collateralInUsd * targetLTV / MAX_BPS;

            uint256 amountToBorrowUsd = targetDebtUsd - debtInUsd; // safe bc we checked ratios

            // cap the amount of debt we are taking according to our acceptable costs
            // if with the new loan we are increasing our cost of capital over what is healthy
            if (currentProtocolDebt + amountToBorrowUsd > maxProtocolDebt) {
                // Can't underflow because it's checked in the previous if condition
                amountToBorrowUsd = maxProtocolDebt - currentProtocolDebt;
            }

            uint256 maxTotalBorrowUsd =
                _toUsd(maxTotalBorrowIT, baseToken);
            if (debtInUsd + amountToBorrowUsd > maxTotalBorrowUsd) {
                amountToBorrowUsd = maxTotalBorrowUsd > debtInUsd
                    ? maxTotalBorrowUsd - debtInUsd
                    : 0;
            }

            // convert to InvestmentToken
            uint256 amountToBorrowIT =
                _fromUsd(amountToBorrowUsd, baseToken);

            if (amountToBorrowIT > 0) {
                _withdraw(baseToken, amountToBorrowIT);
            }
        } else if (
            currentLTV > warningLTV || currentProtocolDebt > maxProtocolDebt
        ) {
            // UNHEALTHY RATIO
            // we may be in this case if the current cost of capital is higher than our max cost of capital
            // we repay debt to set it to targetLTV
            uint256 targetDebtUsd =
                targetLTV * collateralInUsd / MAX_BPS;
            uint256 amountToRepayUsd =
                targetDebtUsd < debtInUsd
                    ? debtInUsd - targetDebtUsd
                    : 0;

            if (maxProtocolDebt == 0) {
                amountToRepayUsd = debtInUsd;
            } else if (currentProtocolDebt > maxProtocolDebt) {
                // NOTE: take into account that we are withdrawing from yvVault which might have a GenLender lending to Aave
                // REPAY = (currentProtocolDebt - maxProtocolDebt) / (1 - TargetUtilisation)
                // coming from
                // TargetUtilisation = (totalDebt - REPAY) / (currentLiquidity - REPAY)
                // currentLiquidity = maxProtocolDebt / TargetUtilisation

                uint256 iterativeRepayAmountUsd =
                    currentProtocolDebt -
                        maxProtocolDebt *
                            WadRayMath.RAY /
                                (uint256(WadRayMath.RAY) - targetUtilisationRay);
                amountToRepayUsd = Math.max(
                    amountToRepayUsd,
                    iterativeRepayAmountUsd
                );
            }
            emit RepayDebt(amountToRepayUsd, debtInUsd);

            uint256 amountToRepayIT =
                _fromUsd(amountToRepayUsd, baseToken);
            uint256 withdrawnIT = _withdrawFromYVault(amountToRepayIT); // we withdraw from investmentToken vault
            _repayTokenDebt(withdrawnIT); // we repay the investmentToken debt with Aave
        }

        uint256 balanceIT = balanceOfBaseToken();
        if (balanceIT > 0) {
            _checkAllowance(
                address(yVault),
                baseToken,
                balanceIT
            );

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
        // NOTE: repayment amount is in investmentToken
        // NOTE: collateral and debt calcs are done in ETH (always, see Aave docs)

        // We first repay whatever we need to repay to keep healthy ratios
        uint256 amountToRepayIT = _calculateAmountToRepay(_amountNeeded);
        uint256 withdrawnIT = _withdrawFromYVault(amountToRepayIT); // we withdraw from investmentToken vault
        _repayTokenDebt(withdrawnIT); // we repay the investmentToken debt with Aave

        // it will return the free amount of want
        _withdrawWant(_amountNeeded);

        balance = balanceOfWant();
        // we check if we withdrew less than expected AND should buy investmentToken with want (realising losses)
        if (
            _amountNeeded > balance &&
            balanceOfDebt() > 0 && // still some debt remaining
            balanceOfBaseToken() + balanceofVault() == 0 && // but no capital to repay
            !leaveDebtBehind // if set to true, the strategy will not try to repay debt by selling want
        ) {
            // using this part of code will result in losses but it is necessary to unlock full collateral in case of wind down
            // we calculate how much want we need to fulfill the want request
            uint256 remainingAmountWant = _amountNeeded - balance;
            // then calculate how much InvestmentToken we need to unlock collateral
            amountToRepayIT = _calculateAmountToRepay(remainingAmountWant);

            // we buy investmentToken with Want
            _buyBaseTokenWithWant(amountToRepayIT);

            // we repay debt to actually unlock collateral
            // after this, balanceOfDebt should be 0
            _repayTokenDebt(amountToRepayIT);

            // then we try withdraw once more
            _withdrawWant(remainingAmountWant);
        }

        uint256 totalAssets = balanceOfWant();
        if (_amountNeeded > totalAssets) {
            _liquidatedAmount = totalAssets;
            _loss = _amountNeeded - totalAssets;
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function prepareMigration(address _newStrategy) internal override {
        // nothing to do since debt cannot be migrated
    }

    function harvestTrigger(uint256 callCost)
        public
        view
        override
        returns (bool)
    {
        // we harvest if:
        // 1. stakedAave is ready to be converted to Aave and sold
    }

    function tendTrigger(uint256 callCost) public view override returns (bool) {
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

        uint256 currentLTV = debtInUsd * MAX_BPS / collateralInUsd;
        uint256 targetLTV = _getTargetLTV(currentLiquidationThreshold);
        uint256 warningLTV = _getWarningLTV(currentLiquidationThreshold);

        return
            AaveLenderBorrowerLib.shouldRebalance(
                baseToken,
                acceptableCostsRay,
                targetLTV,
                warningLTV,
                collateralInUsd,
                totalDebtETH,
                maxGasPriceToTend
            );
    }

    // ----------------- INTERNAL FUNCTIONS SUPPORT -----------------

    // ------------------ YEARN VAULT FUNCTIONS --------------------- \\
    
    function _withdrawFromYVault(uint256 _amountIT) internal returns (uint256) {
        if (_amountIT == 0) {
            return 0;
        }
        // no need to check allowance bc the contract == token
        uint256 balancePrior = balanceOfBaseToken();
        uint256 sharesToWithdraw =
            Math.min(
                _investmentTokenToYShares(_amountIT),
                yVault.balanceOf(address(this))
            );
        if (sharesToWithdraw == 0) {
            return 0;
        }
        yVault.withdraw(sharesToWithdraw, address(this), maxLoss);
        return balanceOfBaseToken().sub(balancePrior);
    }

    function _investmentTokenToYShares(uint256 amount)
        internal
        view
        returns (uint256)
    {
        return amount * (10**yVault.decimals()) / yVault.pricePerShare();
    }

    function _claimAndSellRewards() internal {
        _claimRewards();

        uint256 compBalance = IERC20(comp).balanceOf(address(this));

        if(compBalance == 0) return;

        uint256 baseNeeded = baseTokenOwedBalance();

        if(baseNeeded > 0) {

            bytes memory path =
                abi.encodePacked(
                    comp, // comp-ETH
                    compToEthFee,
                    weth, // ETH-want
                    ethToBaseFee,
                    baseToken
                    );

            // Proceeds from Comp are not subject to minExpectedSwapPercentage
            // so they could get sandwiched if we end up in an uncle block
            router.exactOutput(
                ISwapRouter.ExactOutputParams(
                    path,
                    address(this),
                    now,
                    baseNeeded, //How much we want out
                    0
                )
            );
        }

        compBalance = IERC20(comp).balanceOf(address(this));

        if(compBalance > 0) {
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
                    now, // deadline
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
                    now,
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
        return comet.userBasic(address(this)).baseTrackingAccrued;
    }

    function claimRewards() external onlyKeepers {
        _claimRewards();
    }

    function _claimRewards() internal {
        rewardsContract.claim(address(comet), address(this), true);
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

    /*
    * Repays an entire borrow of the base asset from Compound III
    */
    function _repayFullBorrow() internal {
        comet.supply(baseToken, type(uint256).max);
    }

    /*
    * Get the current supply APR in Compound III
    */
    function getSupplyApr() public view returns (uint) {
        uint utilization = comet.getUtilization();
        return comet.getSupplyRate(utilization) * SECONDS_PER_YEAR * 100;
    }

    /*
    * Get the current borrow APR in Compound III
    */
    function getBorrowApr() public view returns (uint) {
        uint utilization = comet.getUtilization();
        return comet.getBorrowRate(utilization) * SECONDS_PER_YEAR * 100;  
    }

    /*
    * Get the amount of base asset that can be borrowed by an account
    *     scaled up by 10 ^ 8
    */
    function getBorrowableAmount(address account) public view returns (int) {

        uint8 numAssets = comet.numAssets();
        uint16 assetsIn = comet.userBasic(account).assetsIn;
        uint64 si = comet.totalsBasic().baseSupplyIndex;
        uint64 bi = comet.totalsBasic().baseBorrowIndex;
        address baseTokenPriceFeed = comet.baseTokenPriceFeed();

        int liquidity = int(
        presentValue(comet.userBasic(account).principal, si, bi) *
        int256(getCompoundPrice(baseTokenPriceFeed)) /
        int256(1e8)
        );

        for (uint8 i = 0; i < numAssets; i++) {
            if (isInAsset(assetsIn, i)) {
                CometStructs.AssetInfo memory asset = comet.getAssetInfo(i);
                uint newAmount = uint(comet.userCollateral(account, asset.asset).balance) * getCompoundPrice(asset.priceFeed) / 1e8;
                liquidity += int(
                newAmount * asset.borrowCollateralFactor / 1e18
                );
            }
        }   
        return liquidity;
    }

    /*
    * Get the borrow collateral factor for an asset
    */
    function getBorrowCollateralFactor() public view returns (uint256) {
        return uint256(comet.getAssetInfoByAddress(address(want)).borrowCollateralFactor);
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

    function _repayTokenDebt(uint256 amount) internal {
        if (amount == 0) {
            return;
        }

        // we cannot pay more than loose balance
        amount = Math.min(amount, balanceOfBaseToken());
        // we cannot pay more than we owe
        amount = Math.min(amount, balanceOfDebt());
    }

    //withdraw an amount including any want balance
    function _withdrawWant(uint256 amount) internal {
        uint256 toWithdraw = Math.min(amount, _maxWithdrawal());

        _withdraw(address(want), toWithdraw);
    }

    function _maxWithdrawal() internal view returns (uint256) {
        uint256 collateralInUsd = _toUsd(balanceOfCollateral(), address(want));
        uint256 debtInUsd = _toUsd(balanceOfDebt(), baseToken);

        uint256 ltv = debtInUsd * MAX_BPS / collateralInUsd;

        uint256 minCollateralUsd =
            ltv > 0 ? debtInUsd * MAX_BPS / ltv : collateralInUsd;
        if (minCollateralUsd > collateralInUsd) {
            return 0;
        }
        //Return either our collateral balance or based off ltv
        return
            _fromUsd(collateralInUsd - minCollateralUsd, address(want));
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
        uint256 collateralInUsd = _toUsd(balanceOfCollateral(), address(want));
        uint256 debtInUsd = _toUsd(balanceOfDebt(), baseToken);

        uint256 currentLTV = debtInUsd * MAX_BPS / collateralInUsd;
   
        uint256 currentLiquidationThreshold = getLiquidateCollateralFactor();

        uint256 warningLTV = _getWarningLTV(currentLiquidationThreshold);
        uint256 targetLTV = _getTargetLTV(currentLiquidationThreshold);
        uint256 amountUsd = _toUsd(amount, address(want));
        return
            AaveLenderBorrowerLib.calculateAmountToRepay(
                amountETH,
                collateralInUsd,
                totalDebtETH,
                warningLTV,
                targetLTV,
                baseToken,
                minThreshold
            );
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

    // ----------------- INTERNAL CALCS -----------------
    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function balanceOfCollateral() public view returns (uint256) {
        return uint256(comet.userCollateral(address(this), address(want)).balance);
    }

    function balanceOfBaseToken() public view returns(uint256) {
        IERC20(baseToken).balanceOf(address(this));
    }

    function balanceofVault() public view returns(uint256) {
        return yVault.balanceOf(address(this)) * yVault.pricePerShare() / (10**yVault.decimals());
    }

    function balanceOfDebt() public view returns (uint256) {
        return comet.borrowBalanceOf(address(this));
    }

    //Returns the negative position of base token. i.e. borrowed - supplied
    //if for some reason supplied is higher it will return 0
    function baseTokenOwedBalance() public view returns(uint256) {
        uint256 supplied = balanceofVault();
        uint256 borrowed = balanceOfDebt();
        uint256 loose = balanceOfBaseToken();
        
        //If they are the same or supply > debt return 0
        if(supplied + loose >= borrowed) return 0;

        return borrowed - supplied - loose;
    }

    function delegatedAssets() external view override returns (uint256) {
        // returns total debt borrowed in want (which is the delegatedAssets)
        return _fromUsd(_toUsd(balanceofVault(), baseToken), address(want));
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

    function _buyBaseTokenWithWant(uint256 _amount) internal {
        if (_amount == 0) {
            return;
        }

        _checkAllowance(address(router), address(want), _amount);
        if(address(want) == weth || baseToken == weth) {
            ISwapRouter.ExactOutputSingleParams memory params =
                ISwapRouter.ExactOutputSingleParams(
                    address(want), // tokenIn
                    baseToken, // tokenOut
                    ethToWantFee, // want-eth fee
                    address(this), // recipient
                    now, // deadline
                    _amount, // amountOut
                    0, // amountIn
                    0 // sqrtPriceLimitX96
                );

            router.exactOutputSingle(params);
            
        } else {
            bytes memory path =
                abi.encodePacked(
                    address(want), //Token in
                    ethToWantFee,
                    weth, // middle token
                    ethToBaseFee,
                    baseToken // token out
                );

            // Proceeds from Comp are not subject to minExpectedSwapPercentage
            // so they could get sandwiched if we end up in an uncle block
            router.exactOutput(
                ISwapRouter.ExactOutputParams(
                    path,
                    address(this),
                    now,
                    _amount,
                    0
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

    //Returns the _amount of _token in terms of USD, i.e 1e8
    function _toUsd(uint256 _amount, address _token) internal view returns(uint256) {
        uint256 usdPrice = getCompoundPrice(getPriceFeedAddress(_token));
        //usd price is returned as 1e8
        return _amount * usdPrice / IERC20Extended(_token).decimals();
    }

    //Returns the _amount of usd (1e8) in terms of want
    function _fromUsd(uint256 _amount, address _token) internal view returns(uint256) {
        uint256 usdPrice = getCompoundPrice(getPriceFeedAddress(_token));
        return _amount * IERC20Extended(_token).decimals() / usdPrice;
    }

    function baseTokenOwedInWant() public view returns(uint256) {
        return _fromUsd(_toUsd(baseTokenOwedBalance(), baseToken), address(want));
    }

    function rewardsInWant() public view returns(uint256) {
        return _fromUsd(_toUsd(getRewardsOwed(), comp), address(want)) * 9_000 / MAX_BPS;
    }

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}
    
    // ---------------------- YSWAPS FUNCTIONS ----------------------
    function setTradeFactory(address _tradeFactory) external onlyGovernance {
        if (tradeFactory != address(0)) {
            _removeTradeFactoryPermissions();
        }

        ITradeFactory tf = ITradeFactory(_tradeFactory);

        IERC20(comp).safeApprove(_tradeFactory, type(uint256).max);
        tf.enable(comp, address(want));
        
        tradeFactory = _tradeFactory;
    }

    function removeTradeFactoryPermissions() external onlyAuthorized {
        _removeTradeFactoryPermissions();
    }

    function _removeTradeFactoryPermissions() internal {
        IERC20(comp).safeApprove(tradeFactory, 0);
        
        tradeFactory = address(0);
    }
}