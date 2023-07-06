// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.6.0) (token/ERC20/IERC20.sol)

pragma solidity ^0.8.6;

interface IGlacierOracle {
    function getPrice(address) external view returns (uint256);
    function getTokensForOneUSDC(address) external view returns (uint256);
    function getTokensForUSDC(address, uint256) external view returns (uint256);
    function getUSDCForTokens(address, uint256) external view returns (uint256);
    function getAVAXForTokens(address, uint256) external view returns (uint256);
}
