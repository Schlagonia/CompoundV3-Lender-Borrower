// SPDX-License-Identifier: MIT
pragma solidity >=0.8.12;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IVault is IERC20 {
    function token() external view returns (address);

    function decimals() external view returns (uint256);

    function deposit() external;

    function pricePerShare() external view returns (uint256);

    function withdraw() external returns (uint256);

    function withdraw(uint256 amount) external returns (uint256);

    function withdraw(
        uint256 amount,
        address account,
        uint256 maxLoss
    ) external returns (uint256);

    function availableDepositLimit() external view returns (uint256);

    function governance() external view returns (address);
}
