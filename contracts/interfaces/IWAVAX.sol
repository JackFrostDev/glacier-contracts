// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.6.0) (token/ERC20/IERC20.sol)

pragma solidity >=0.5.0;

interface IWAVAX {
    function deposit() external payable;
    function withdraw(uint256) external;
}