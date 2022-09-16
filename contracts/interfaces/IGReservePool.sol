// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.6.0) (token/ERC20/IERC20.sol)

pragma solidity ^0.8.6;

interface IGReservePool {
    function totalReserves() external view returns (uint256);
    function deposit(uint256) external;
    function withdraw(uint256) external;
}