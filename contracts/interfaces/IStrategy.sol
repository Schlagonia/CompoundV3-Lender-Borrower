// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.12;

import {IVault} from "./IVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IStrategy {
    function name() external view returns (string memory);

    function vault() external view returns (IVault);

    function want() external view returns (IERC20);

    function strategist() external view returns (address);

    function keeper() external view returns (address);

    function depositer() external view returns (address);

    function baseToken() external view returns (address);

    function estimatedTotalAssets() external view returns (uint256);
}