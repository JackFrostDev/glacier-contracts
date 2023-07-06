// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.6.0) (token/ERC20/IERC20.sol)

pragma solidity ^0.8.6;

interface IGLendingPool {
    function totalReserves() external view returns (uint256);
    function totalLoaned() external view returns (uint256);
    function borrow(uint256) external returns (uint256);
    function repay(uint256) external returns (uint256);
}
