// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.12;
pragma experimental ABIEncoderV2;

import "./Strategy.sol";

contract CompV3LenderBorrowerCloner {
    address public immutable original;

    event Cloned(address indexed clone);
    event Deployed(address indexed original);

    constructor(
        address _vault,
        address _comet,
        uint24 _ethToWantFee,
        address _yVault,
        string memory _strategyName
    ) {
        Strategy _original = new Strategy(_vault, _comet, _ethToWantFee, _yVault, _strategyName);
        emit Deployed(address(_original));

        original = address(_original);
        Strategy(_original).setStrategyParams(
            7_000, // targetLTVMultiplier (default: 7_000)
            8_000, // warningLTVMultiplier default: 8_000
            1e10, // 2**256-1
            false, // leave debt behind (default: false)
            1, // maxLoss (default: 1)
            60 * 1e9 // max base fee to perform non-emergency tends (default: 60 gwei)
        );

        Strategy(_original).setRewards(msg.sender);
        Strategy(_original).setKeeper(msg.sender);
        Strategy(_original).setStrategist(msg.sender);
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
        address _yVault,
        string memory _strategyName
    ) external returns (address newStrategy) {
        // Copied from https://github.com/optionality/clone-factory/blob/master/contracts/CloneFactory.sol
        bytes20 addressBytes = bytes20(original);
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

        Strategy(newStrategy).initialize(_vault, _comet, _ethToWantFee, _yVault, _strategyName);

        Strategy(newStrategy).setStrategyParams(
            7_000, // targetLTVMultiplier (default: 7_000)
            8_000, // warningLTVMultiplier default: 8_000
            1e10, // max debt to take
            false, // leave debt behind (default: false)
            1, // maxLoss (default: 1)
            60 * 1e9 // max base fee to perform non-emergency tends (default: 60 gwei)
        );

        Strategy(newStrategy).setKeeper(_keeper);
        Strategy(newStrategy).setRewards(_rewards);
        Strategy(newStrategy).setStrategist(_strategist);

        emit Cloned(newStrategy);
    }
}
