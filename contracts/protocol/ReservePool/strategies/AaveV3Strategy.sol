// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

import { IPool } from "@aave/core-v3/contracts/interfaces/IPool.sol";
import { IRewardsController } from "@aave/periphery-v3/contracts/rewards/interfaces/IRewardsController.sol";

import { IGReserveStrategy } from "../../../interfaces/IGReserveStrategy.sol";
import { AccessControlManager } from "../../../AccessControlManager.sol";

/**
 * @title  An Aave V3 adapter for the reserve strategy
 * @author Jack Frost
 * @notice Enables the caller to deposit and withdraw atomically from the Aave V3 lending market
 */
contract AaveV3Strategy is Initializable, AccessControlManager, ReentrancyGuardUpgradeable, IGReserveStrategy {

    /// @notice The address of the reserve pool address
    address public reservePoolAddress;

    /// @notice The address of the asset to use in the reserve strategy
    address public asset;

    /// @notice The address of the Aave V3 Lending Pool
    address public aavePoolAddress;

    /// @notice The address of the Aave V3 Rewards Controller
    address public aaveRewardsController;
    
    /**
     * @notice Initialize the Aave strategy
     */
    function initialize(address _reservePoolAddress, address _asset, address _aavePoolAddress, address _aaveRewardsController) external initializer {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(STRATEGY_USER, _reservePoolAddress);

        reservePoolAddress = _reservePoolAddress;
        asset = _asset;
        aavePoolAddress = _aavePoolAddress;
        aaveRewardsController = _aaveRewardsController;

        // Approve Aave to spend the `asset` balance thats in this contract so it can deposit
        // This is requires so that the reserve pool can deposit tokens 
        IERC20Upgradeable(asset).approve(aavePoolAddress, type(uint256).max);

        // Approve the reserve pool to spend the balance of `asset` in this contract
        // This is required so that the reserve pool can withdraw tokens 
        IERC20Upgradeable(asset).approve(_reservePoolAddress, type(uint256).max);
    }

    /**
     * @notice Deposit into Aave V3
     * @dev Deposits on behalf of the reserve pool (i.e. the reserve pool holds any receipt or derivatives)
     */
    function deposit(uint256 amount) external virtual isRole(STRATEGY_USER) nonReentrant {
        require(amount > 0, "ZERO_DEPOSIT");
        IERC20Upgradeable(asset).transferFrom(msg.sender, address(this), amount);
        IPool(aavePoolAddress).supply(asset, amount, reservePoolAddress, 0);
    }

    /**
     * @notice Withdraw from Aave V3
     * @dev Withdraws on behalf of the reserve pool (i.e. the reserve pool holds any receipt or derivatives)
     */
    function withdraw(uint256 amount) external virtual isRole(STRATEGY_USER) nonReentrant {
        require(amount > 0, "ZERO_WITHDRAW");
        _claim();
        IPool(aavePoolAddress).withdraw(asset, amount, reservePoolAddress);
        require(IERC20Upgradeable(asset).balanceOf(address(this)) > amount, "INSUFFICIENT_AMOUNT");
        IERC20Upgradeable(asset).transferFrom(address(this), msg.sender, IERC20Upgradeable(asset).balanceOf(address(this)));
    }

    /**
     * @notice Claims any rewards earned on top of the lending interest
     */
    function _claim() internal {
        address[] memory assets = new address[](1);
        assets[0] = asset;
        IRewardsController(aaveRewardsController).claimAllRewardsToSelf(assets);
    }
}