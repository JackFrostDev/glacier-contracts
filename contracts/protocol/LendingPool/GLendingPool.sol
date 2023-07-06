// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

import {IGLendingPool} from "../../interfaces/IGLendingPool.sol";
import {IWAVAX} from "../../interfaces/IWAVAX.sol";
import {AccessControlManager} from "../../AccessControlManager.sol";

import "hardhat/console.sol";

/**
 * @title  GLendingPool implementation
 * @author Jack Frost
 * @notice The lending pool is a whitelisted pool of funds that can be loaned out by specified clients. The loans are uncollateralized and 0% interest.
 */
contract GLendingPool is Initializable, IGLendingPool, AccessControlManager {
    /// @notice The WAVAX contract
    IWAVAX public WAVAX;

    /// @notice The USDC contract
    IERC20Upgradeable public USDC;

    /// @notice The total amount of AVAX this contract has loaned out
    uint256 public _totalLoaned;

    /// @notice Emitted when someone borrows AVAX
    event Borrowed(address user, uint256 amount);

    /// @notice Emitted when someone repays borrowed AVAX
    event Repayed(address user, uint256 amount);

    function initialize(address _wavaxAddress, address _usdcAddress) public initializer {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        WAVAX = IWAVAX(_wavaxAddress);
        USDC = IERC20Upgradeable(_usdcAddress);
    }

    /**
     * @notice Configures a given address to be able to use this contract to loan out funds
     */
    function setClient(address client) external isRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(LENDING_POOL_CLIENT, client);
    }

    /**
     * @notice Removes an address as a client for this contract
     */
    function removeClient(address client) external isRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(LENDING_POOL_CLIENT, client);
    }

    /**
     * @notice Returns the total reserves
     */
    function totalReserves() external view virtual returns (uint256) {
        return IERC20Upgradeable(address(WAVAX)).balanceOf(address(this));
    }

    /**
     * @notice Returns the total loaned AVAX
     */
    function totalLoaned() external view virtual returns (uint256) {
        return _totalLoaned;
    }

    /**
     * @notice Returns the total amount of usable USDC inside this contract
     */
    function usableUSDC() public view returns (uint256) {
        return USDC.balanceOf(address(this));
    }

    /**
     * @notice Borrows an amount of AVAX from this contract, opening up a loan
     */
    function borrow(uint256 amount) external virtual isRole(LENDING_POOL_CLIENT) returns (uint256) {
        require(amount > 0, "ZERO_BORROW");
        require(amount <= IERC20Upgradeable(address(WAVAX)).balanceOf(address(this)), "EXCEEDED_BORROW_AMOUNT");
        _totalLoaned += amount;
        IERC20Upgradeable(address(WAVAX)).transfer(msg.sender, amount);
        emit Borrowed(msg.sender, amount);
        return amount;
    }

    /**
     * @notice Repays back an amount of AVAX to this contract. Anyone can repay a loan for anyone
     */
    function repay(uint256 amount) external virtual returns (uint256) {
        require(amount > 0, "ZERO_REPAY");
        require(_totalLoaned >= amount, "EXCEEDED_REPAY_AMOUNT");
        _totalLoaned -= amount;
        IERC20Upgradeable(address(WAVAX)).transferFrom(msg.sender, address(this), amount);
        emit Repayed(msg.sender, amount);
        return amount;
    }
}
