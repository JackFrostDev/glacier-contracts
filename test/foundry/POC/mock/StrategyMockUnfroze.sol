// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

import {IPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";
import {IRewardsController} from "@aave/periphery-v3/contracts/rewards/interfaces/IRewardsController.sol";

import {IGReserveStrategy} from "contracts/interfaces/IGReserveStrategy.sol";
import {AccessControlManager} from "contracts/AccessControlManager.sol";
import {console} from "@forge-std/console.sol";

/**
 * @title  An Aave V3 adapter for the reserve strategy
 * @author Jack Frost
 * @notice Enables the caller to deposit and withdraw atomically from the Aave V3 lending market
 */
contract StrategyMockUnfroze is Initializable, AccessControlManager, ReentrancyGuardUpgradeable, IGReserveStrategy {
    /// @notice The address of the reserve pool address
    address public reservePoolAddress;

    /// @notice The address of the asset to use in the reserve strategy
    address public asset;

    /// @notice The address of the aToken
    address public aToken;

    /// @notice The address of the Aave V3 Lending Pool
    address public aavePoolAddress;

    /// @notice The address of the Aave V3 Rewards Controller
    address public aaveRewardsController;

    /// @notice When true the contract becames frozen
    bool public frozen;

    /**
     * @notice Initialize the Aave strategy
     */
    function initialize(
        address _reservePoolAddress,
        address _asset,
        address _aavePoolAddress,
        address _aaveRewardsController
    ) external initializer {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(STRATEGY_USER, _reservePoolAddress);

        reservePoolAddress = _reservePoolAddress;
        asset = _asset;
        aavePoolAddress = _aavePoolAddress;
        aToken = IPool(_aavePoolAddress).getReserveData(_asset).aTokenAddress;
        aaveRewardsController = _aaveRewardsController;

        frozen = false;

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
        IPool(aavePoolAddress).supply(asset, amount, address(this), 0);
    }

    /**
     * @notice Withdraw from Aave V3
     * @dev Withdraws on behalf of the reserve pool (i.e. the reserve pool holds any receipt or derivatives)
     */
    function withdraw(uint256 amount) external virtual isRole(STRATEGY_USER) nonReentrant {
        require(amount > 0, "ZERO_WITHDRAW");
        _claim();
        IPool(aavePoolAddress).withdraw(asset, amount, address(this));
        //require(IERC20Upgradeable(asset).balanceOf(address(this)) > amount, "INSUFFICIENT_AMOUNT");
        IERC20Upgradeable(asset).transferFrom(
            address(this), msg.sender, IERC20Upgradeable(asset).balanceOf(address(this))
        );
    }

    /**
     * @notice Withdraw from Aave V3
     * @dev Withdraws on behalf of the reserve pool (i.e. the reserve pool holds any receipt or derivatives)
     */
    function mockWithdrawTransferDirectly(uint256 amount) external virtual isRole(STRATEGY_USER) nonReentrant {
        require(amount > 0, "ZERO_WITHDRAW");
        address[] memory assets = new address[](1);
        assets[0] = aToken;
        IRewardsController(aaveRewardsController).claimAllRewards(assets, reservePoolAddress);
        IPool(aavePoolAddress).withdraw(asset, amount, reservePoolAddress);
    }


    /**
     * @notice Withdraw from Aave V3
     * @dev Withdraws on behalf of the reserve pool (i.e. the reserve pool holds any receipt or derivatives)
     */
    function mockWithdrawNoAmountRequire(uint256 amount) external virtual isRole(STRATEGY_USER) nonReentrant {
        require(amount > 0, "ZERO_WITHDRAW");
        _claim();
        IPool(aavePoolAddress).withdraw(asset, amount, address(this));
        //require(IERC20Upgradeable(asset).balanceOf(address(this)) > amount, "INSUFFICIENT_AMOUNT");
        IERC20Upgradeable(asset).transferFrom(
            address(this), msg.sender, IERC20Upgradeable(asset).balanceOf(address(this))
        );
    }

    /**
     * @notice Withdraw from Aave V3
     * @dev Withdraws on behalf of the reserve pool (i.e. the reserve pool holds any receipt or derivatives)
     */
    function mockWithdrawWithRequire(uint256 amount) external virtual isRole(STRATEGY_USER) nonReentrant {
        require(amount > 0, "ZERO_WITHDRAW");
        _claim();
        IPool(aavePoolAddress).withdraw(asset, amount, address(this));
        require(IERC20Upgradeable(asset).balanceOf(address(this)) > amount, "INSUFFICIENT_AMOUNT");
        IERC20Upgradeable(asset).transferFrom(
            address(this), msg.sender, IERC20Upgradeable(asset).balanceOf(address(this))
        );
    }

    /**
     * @notice Make the strategy freeze or unfreeze
     */
    function setFrozen(bool freeze) external {
        frozen = freeze;
    }

    /**
     * @notice Claims any rewards earned on top of the lending interest
     */
    function _claim() internal {
        address[] memory assets = new address[](1);
        assets[0] = aToken;
        IRewardsController(aaveRewardsController).claimAllRewardsToSelf(assets);
    }
}