// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.6.0) (token/ERC20/IERC20.sol)

pragma solidity ^0.8.6;

interface IGLendingPool {
    function totalReserves() external view returns (uint256);
    function totalLoaned() external view returns (uint256);
    function totalBought() external view returns (uint256);
    function totalOwed() external view returns(uint256);
    function purchasingPower() external returns (uint256);
    function borrow(uint256) external returns (uint256);
    function repay(address, uint256) external returns (uint256);
    function buyAndBorrow(uint256) external returns (uint256);
    function repayBought(address, uint256) external returns (uint256);
}
