// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.15;
pragma experimental ABIEncoderV2;

import "./Depositer.sol";
import "./Strategy.sol";

contract CompV3LenderBorrowerCloner {
    address public immutable originalDepositer;
    address public immutable originalStrategy;

    event Cloned(address indexed depositer, address indexed strategy);
    event Deployed(address indexed depositer, address indexed strategy);

    constructor(
        address _vault,
        address _comet,
        uint24 _ethToWantFee,
        string memory _strategyName
    ) {
        Depositer _depositer = new Depositer(_comet);
        Strategy _strategy = new Strategy(_vault, _comet, _ethToWantFee, address(_depositer), _strategyName);

        originalDepositer = address(_depositer);
        originalStrategy = address(_strategy);

        emit Deployed(originalDepositer, originalStrategy);

        _depositer.setStrategy(originalStrategy);

        Strategy(_strategy).setStrategyParams(
            7_000, // targetLTVMultiplier (default: 7_000)
            8_000, // warningLTVMultiplier default: 8_000
            1e10, // min rewards to sell
            false, // leave debt behind (default: false)
            40 * 1e9, // max base fee to perform non-emergency tends (default: 40 gwei)
            0xdbd020CAeF83eFd542f4De03e3cF0C28A4428bd5 // COMP/USD price feed
        );

        Strategy(_strategy).setRewards(msg.sender);
        Strategy(_strategy).setKeeper(msg.sender);
        Strategy(_strategy).setStrategist(msg.sender);
    }

    function name() external pure returns (string memory) {
        return "Yearn-CompV3LenderBorrowerCloner@0.4.3";
    }

    function cloneCompV3LenderBorrower(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _comet,
        uint24 _ethToWantFee,
        string memory _strategyName
    ) external returns (address newDepositer, address newStrategy) {
        newDepositer = Depositer(originalDepositer).cloneDepositer(_comet);
        // Copied from https://github.com/optionality/clone-factory/blob/master/contracts/CloneFactory.sol
        bytes20 addressBytes = bytes20(originalStrategy);
        assembly {
            // EIP-1167 bytecode
            let clone_code := mload(0x40)
            mstore(
                clone_code,
                0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000
            )
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(
                add(clone_code, 0x28),
                0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000
            )
            newStrategy := create(0, clone_code, 0x37)
        }

        Strategy(newStrategy).initialize(_vault, _comet, _ethToWantFee, newDepositer, _strategyName);

        Depositer(newDepositer).setStrategy(newStrategy);
        
        Strategy(newStrategy).setStrategyParams(
            7_000, // targetLTVMultiplier (default: 7_000)
            8_000, // warningLTVMultiplier default: 8_000
            1e10, // min rewards to sell
            false, // leave debt behind (default: false)
            40 * 1e9, // max base fee to perform non-emergency tends (default: 40 gwei)
            0xdbd020CAeF83eFd542f4De03e3cF0C28A4428bd5 // COMP/USD price feed
        );

        Strategy(newStrategy).setKeeper(_keeper);
        Strategy(newStrategy).setRewards(_rewards);
        Strategy(newStrategy).setStrategist(_strategist);

        emit Cloned(newDepositer, newStrategy);
    }
}
