// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

import { IGReserveStrategy } from "../../interfaces/IGReserveStrategy.sol";
import { IGReservePool } from "../../interfaces/IGReservePool.sol";
import { AccessControlManager } from  "../../AccessControlManager.sol";

import "hardhat/console.sol";

/**
 * @title  Glacial Reserve Pool implementation
 * @author Jack Frost
 * @notice The reserve pool is responsible for holding funds, and optionally delegating them into onchain and atomic stategies based on voting.
 */
contract GReservePool is Initializable, IGReservePool, AccessControlManager {

    /// @notice The WAVAX contract
    address public WAVAX;

    /// @notice The total amount of AVAX this contract manages
    uint256 public _totalReserves;

    /// @notice The total weight of the AVAX distributions
    uint256 public _totalWeight;

    /// @notice The maximum allowed strategies for this pool
    uint256 public _maxStrategies;

    struct Strategy {
        IGReserveStrategy logic;
        uint256 weight;
    }

    /// @notice The strategies to atomically deposit and withdraw funds
    /// @dev _strategies[0] is always the default strategy which is to just hold funds
    mapping (uint64 => Strategy) public _strategies;

    /// @notice The amount of strategies this reserve pool has currently 
    uint64 public _strategyCount;

    /// @notice Emitted when a deposit is made
    event Deposit(address indexed user, uint256 amount);

    /// @notice Emitted when a withdrawal is made
    event Withdraw(address indexed user, uint256 amount);

    function initialize(address _wavaxAddress) initializer public {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(RESERVE_POOL_MANAGER, msg.sender);

        WAVAX = _wavaxAddress;

        // The default strategy is to just sit on the funds
        _maxStrategies = 5;
        _totalWeight = 100;
        _strategies[0].weight = 100;
        _strategyCount = 1;
    }

    /**
     * @notice Removes an address from being able to manage this contract
     */
    function setManager(address manager) external isRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(RESERVE_POOL_MANAGER, manager);
    }

    /**
     * @notice Removes an address from being able to manage this contract
     */
    function removeManager(address manager) external isRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(RESERVE_POOL_MANAGER, manager);
    }

    /**
     * @notice Clears the strategies fro
     */
    function clearStrategies() external isRole(RESERVE_POOL_MANAGER) {
        for (uint64 i = 1; i < _strategyCount; ++i) {
            delete _strategies[i];
        }

        // The default strategy is to just sit on the funds
        _strategyCount = 1;
        _totalWeight = 100;
        _strategies[0].weight = 100;
    }

    /**
     * @notice Adds a new strategy to the reserve pool
     * @dev Be weary as multiple strategies could increase the gas consumption of the entire protocol
     */
    function addStrategy(IGReserveStrategy strategy, uint256 weight) external isRole(RESERVE_POOL_MANAGER) {
        require(_strategyCount < _maxStrategies, "TOO_MANY_STRATEGIES");
        _strategies[_strategyCount] = Strategy({ logic: strategy, weight: weight });
        _strategyCount++;
        _totalWeight += weight;

        // Approve the Aave strategy to spend the balance of `asset` in this contract
        // This is required so that when a deposit is made the Aave strategy can move funds in 
        IERC20Upgradeable(WAVAX).approve(address(strategy), type(uint256).max);
    }
    
    /**
     * @notice Returns the total reserves
     */
    function totalReserves() virtual external view returns (uint256) {
        return _totalReserves;
    }

    /**
     * @notice Deposits AVAX into the reserve pool, which can have optional extra atomic actions applied to it as voted
     */
    function deposit(uint256 amount) virtual external isRole(RESERVE_POOL_MANAGER) {
        require(amount > 0, "ZERO_DEPOSIT");
        uint256 deposited = amount;
        IERC20Upgradeable(WAVAX).transferFrom(msg.sender, address(this), amount);

        /// If using the default strategy, remove the portion of AVAX that we hold in this contract so that the right amount is deposited into strategies
        Strategy memory defaultStrat = _strategies[0];
        if (defaultStrat.weight > 0) {
            amount -= defaultStrat.weight * amount / _totalWeight;
        }

        for (uint64 i = 1; i < _strategyCount; ++i) {
            Strategy memory strategy = _strategies[i];
            uint256 depositAmount = strategy.weight * amount / _totalWeight;
            strategy.logic.deposit(depositAmount);
        }

        _totalReserves += deposited;
        emit Deposit(msg.sender, deposited);
    }

    /**
     * @notice Withdraws AVAX from the reserve pool
     */
    function withdraw(uint256 amount) virtual external isRole(RESERVE_POOL_MANAGER) {
        require(amount > 0, "ZERO_WITHDRAW");
        uint256 totalAmount = amount;

        /// If using the default strategy, remove the portion of onhand AVAX so we can proportionally grab the strategy AVAX 
        if (_strategies[0].weight > 0) {
            amount -= _strategies[0].weight * amount / _totalWeight;
        }

        for (uint64 i = 1; i < _strategyCount; ++i) {
            Strategy memory strategy = _strategies[i];
            uint256 withdrawAmount = strategy.weight * amount / _totalWeight;
            strategy.logic.withdraw(withdrawAmount);
        }

        IERC20Upgradeable(WAVAX).transferFrom(address(this), msg.sender, totalAmount);

        _totalReserves -= totalAmount;
        emit Withdraw(msg.sender, totalAmount);
    }
}