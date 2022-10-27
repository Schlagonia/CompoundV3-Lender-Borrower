// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.12;
pragma experimental ABIEncoderV2;

import {IVault} from "./interfaces/IVault.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {CometStructs} from "./interfaces/CompoundV3/CompoundV3.sol";
import {Comet} from "./interfaces/CompoundV3/CompoundV3.sol";
import {CometRewards} from "./interfaces/CompoundV3/CompoundV3.sol";

/********************
 *  Depositer contract for the Compound V3 lender borrower. The same address cannot both borrow and lend the base token, so
 *      the base strategy will supply collateral and borrow the base token, then this contract will deposit that token back into compound.
 *   Made by @Schlagonia
 *   https://github.com/Schlagonia/CompoundV3-Lender-Borrower
 *
 ********************* */

contract Depositer {
    using SafeERC20 for IERC20;
    using Address for address;

    //Used for cloning
    bool original = true;

    //Used for Comp apr calculations
    uint64 internal constant DAYS_PER_YEAR = 365;
    uint64 internal constant SECONDS_PER_DAY = 60 * 60 * 24;
    uint64 internal constant SECONDS_PER_YEAR = 365 days;
    uint256 internal BASE_MANTISSA;
    uint256 internal BASE_INDEX_SCALE;
    
    //This is the address of the main V3 pool
    Comet public comet;
    //This is the token we will be borrowing/supplying
    IERC20 public baseToken;
    //The contract to get Comp rewards from
    CometRewards public constant rewardsContract = 
        CometRewards(0x1B0e765F6224C21223AeA2af16c1C46E38885a40); 

    IStrategy public strategy;

    //The reward Token
    address internal constant comp = 
        0xc00e94Cb662C3520282E6f5717214004A7f26888;

    modifier onlyGovernance() {
        checkGovernance();
        _;
    }

    modifier onlyStrategy() {
        checkStrategy();
        _;
    }

    function checkGovernance() internal view {
        require(msg.sender == strategy.vault().governance(), "!authorized");
    }


    function checkStrategy() internal view {
        require(msg.sender == address(strategy), "!authorized");
    }

    constructor(address _comet) {
        _initialize(_comet);
    }

    event Cloned(address indexed clone);

    function cloneDepositer(
        address _comet
    ) external returns (address newDepositer) {
        require(original, "!original");
        newDepositer = _clone(_comet);
    }

    function _clone(address _comet) internal returns (address newDepositer) {
        // Copied from https://github.com/optionality/clone-factory/blob/master/contracts/CloneFactory.sol
        bytes20 addressBytes = bytes20(address(this));

        assembly {
            // EIP-1167 bytecode
            let clone_code := mload(0x40)
            mstore(clone_code, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(add(clone_code, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            newDepositer := create(0, clone_code, 0x37)
        }

        Depositer(newDepositer).initialize(_comet);
        emit Cloned(newDepositer);
    }

    function initialize(address _comet) external {
        _initialize(_comet);
    }

    function _initialize(address _comet) internal {
        require(address(comet) == address(0), "!initiliazd");
        comet = Comet(_comet);
        baseToken = IERC20(comet.baseToken());

        baseToken.safeApprove(_comet, type(uint256).max);

        //For APR calculations
        BASE_MANTISSA = comet.baseScale();
        BASE_INDEX_SCALE = comet.baseIndexScale();
    }

    function setStrategy(address _strategy) external {
        //Can only set the strategy once
        require(address(strategy) == address(0), "set");

        strategy = IStrategy(_strategy);

        //make sure it has the same base token
        require(address(baseToken) == strategy.baseToken(), "!base");
        //Make sure this contract is set as the depositer
        require(address(this) == address(strategy.depositer()), "!depositer");
    }
    
    function cometBalance() public view returns (uint256){
        return comet.balanceOf(address(this));
    }

    //Non-view function to accrue account for most accurate accounting
    function accruedCometBalance() public returns(uint256) {
        comet.accrueAccount(address(this));
        return comet.balanceOf(address(this));
    }

    function withdraw(uint256 _amount) external onlyStrategy {
        if (_amount == 0) return;

        comet.withdraw(address(baseToken), _amount);

        uint256 balance = baseToken.balanceOf(address(this));
        require(balance >= _amount, "!bal");
        baseToken.transfer(address(strategy), balance);
    }

    function deposit() external onlyStrategy {
        uint256 _amount = baseToken.balanceOf(address(strategy));
        if (_amount == 0) return;
        
        baseToken.transferFrom(msg.sender, address(this), _amount);
        comet.supply(address(baseToken), _amount);
    }

    function claimRewards() external onlyStrategy {
        rewardsContract.claim(address(comet), address(this), true);

        uint256 compBal = IERC20(comp).balanceOf(address(this));

        if(compBal > 0) {
            IERC20(comp).transfer(address(strategy), compBal);
        }
    }

    // ----------------- COMET VIEW FUNCTIONS -----------------

    //We put these in the depositer contract to save byte code in the main strategy

    /*
    * Gets the amount of reward tokens due to this contract and the base strategy
    */
    function getRewardsOwed() public view returns (uint256) {
        CometStructs.RewardConfig memory config = rewardsContract.rewardConfig(address(comet));
        uint256 accrued = comet.baseTrackingAccrued(address(this)) + comet.baseTrackingAccrued(address(strategy));
        if (config.shouldUpscale) {
            accrued *= config.rescaleFactor;
        } else {
            accrued /= config.rescaleFactor;
        }
        uint256 claimed = 
            rewardsContract.rewardsClaimed(address(comet), address(this)) + 
                rewardsContract.rewardsClaimed(address(comet), address(strategy));

        return accrued > claimed ? accrued - claimed : 0;
    }

    function getNetBorrowApr(uint256 newAmount) public view returns(uint256 netApr) {
        uint256 borrowApr = getBorrowApr(newAmount);
        uint256 supplyApr = getSupplyApr(newAmount);
        //supply rate can be higher than borrow when utilization is very high
        netApr = borrowApr > supplyApr ? borrowApr - supplyApr : 0;
    }

    /*
    * Get the current supply APR in Compound III
    */
    function getSupplyApr(uint256 newAmount) internal view returns (uint) {
        unchecked {   
            return comet.getSupplyRate(
                    (comet.totalBorrow() + newAmount) * 1e18 / (comet.totalSupply() + newAmount) 
                        ) * SECONDS_PER_YEAR;
        }
    }

    /*
    * Get the current borrow APR in Compound III
    */
    function getBorrowApr(uint256 newAmount) internal view returns (uint256) {
        unchecked {
            return comet.getBorrowRate(
                     (comet.totalBorrow() + newAmount) * 1e18 / (comet.totalSupply() + newAmount) //New utilization
                            ) * SECONDS_PER_YEAR;  
        }
    }

    function getNetRewardApr(uint256 newAmount) public view returns (uint256) {
        unchecked {
            return getRewardAprForBorrowBase(newAmount) + getRewardAprForSupplyBase(newAmount);
        }
    }
    
    /*
    * Get the current reward for supplying APR in Compound III
    * @param rewardTokenPriceFeed The address of the reward token (e.g. COMP) price feed
    * @return The reward APR in USD as a decimal scaled up by 1e18
    */
    function getRewardAprForSupplyBase(uint256 newAmount) internal view returns (uint) {
        unchecked {
            uint256 rewardToSuppliersPerDay =  comet.baseTrackingSupplySpeed() * SECONDS_PER_DAY * BASE_INDEX_SCALE / BASE_MANTISSA;
            if(rewardToSuppliersPerDay == 0) return 0;
            return (getCompoundPrice(comp) * 
                        rewardToSuppliersPerDay / 
                            ((comet.totalSupply() + newAmount) * 
                                getCompoundPrice(address(baseToken)))) * 
                                    DAYS_PER_YEAR;
        }
    }

    /*
    * Get the current reward for borrowing APR in Compound III
    * @param rewardTokenPriceFeed The address of the reward token (e.g. COMP) price feed
    * @return The reward APR in USD as a decimal scaled up by 1e18
    */
    function getRewardAprForBorrowBase(uint256 newAmount) internal view returns (uint256) {
        //borrowBaseRewardApr = (rewardTokenPriceInUsd * rewardToBorrowersPerDay / (baseTokenTotalBorrow * baseTokenPriceInUsd)) * DAYS_PER_YEAR;
        unchecked {
            uint256 rewardToBorrowersPerDay =  comet.baseTrackingBorrowSpeed() * SECONDS_PER_DAY * BASE_INDEX_SCALE / BASE_MANTISSA;
            if(rewardToBorrowersPerDay == 0) return 0;
            return (getCompoundPrice(comp) * 
                        rewardToBorrowersPerDay / 
                            ((comet.totalBorrow() + newAmount) * 
                                getCompoundPrice(address(baseToken)))) * 
                                    DAYS_PER_YEAR;
        }
    }

    /*
    * Get the price feed address for an asset
    */
    function getPriceFeedAddress(address asset) internal view returns (address) {
        if(asset == address(baseToken)) return comet.baseTokenPriceFeed();
        return comet.getAssetInfoByAddress(asset).priceFeed;
    }

    /*
    * Get the current price of an asset from the protocol's persepctive
    */
    function getCompoundPrice(address asset) internal view returns (uint256) {
        return comet.getPrice(getPriceFeedAddress(asset));
    }

    function manualWithdraw() external onlyGovernance {
        //Withdraw everything we have
        comet.withdraw(address(baseToken), accruedCometBalance());
        //Transfer the full balance to Gov
        baseToken.transfer(
            strategy.vault().governance(), 
            baseToken.balanceOf(address(this))
        );
    }
}