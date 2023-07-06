// SPDX-License-Identifier: MIT

pragma solidity ^0.8.6;

import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

interface IglAVAX is IERC20Upgradeable {
    function sharesFromAvax(uint256) external view returns (uint256);
    function avaxFromShares(uint256) external view returns (uint256);
    function netAVAX() external view returns (uint256);
}
