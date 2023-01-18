// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

import { IGReserveStrategy } from "../../interfaces/IGReserveStrategy.sol";
import { IGReservePool } from "../../interfaces/IGReservePool.sol";
import { AccessControlManager } from  "../../AccessControlManager.sol";

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
        uint256 deposited;
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
     * @notice Adds a new strategy to the reserve pool, this is a setup function
     * 
     *         Requirements:
     *              - There can only be upwards of 5 strategies, including the default (just holding it in the contract)
     *              - There has to be no active deposits on the reserve pool (i.e. this contract manages 0 AVAX)
     */
    function addStrategy(IGReserveStrategy strategy, uint256 weight) external isRole(RESERVE_POOL_MANAGER) {
        require(_totalReserves == 0, "ACTIVE_DEPOSITS");
        require(_strategyCount < _maxStrategies, "TOO_MANY_STRATEGIES");
        _strategies[_strategyCount] = Strategy({ logic: strategy, weight: weight, deposited: 0 });
        _strategyCount++;
        _totalWeight += weight;

        // Approve the Aave strategy to spend the balance of `asset` in this contract
        // This is required so that when a deposit is made the Aave strategy can move funds in 
        IERC20Upgradeable(WAVAX).approve(address(strategy), type(uint256).max);
    }

    /**
     * @notice Clears and resets the strategies on the reserve pool, this is a setup function. 
     *
     *         Requirements:
     *              - There has to be no active deposits on the reserve pool (i.e. this contract manages 0 AVAX)
     */
    function clearStrategies() external isRole(RESERVE_POOL_MANAGER) {
        require(_totalReserves == 0, "ACTIVE_DEPOSITS");

        // Then clears the strategies
        for (uint64 i = 1; i < _strategyCount; ++i) {
            delete _strategies[i];
        }

        // The default strategy is to just sit on the funds
        _strategyCount = 1;
        _totalWeight = 100;
        _strategies[0].weight = 100;
    }
    
    /**
     * @notice Returns the total amount of AVAX this contract manages
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
            Strategy storage strategy = _strategies[i];
            uint256 depositAmount = strategy.weight * amount / _totalWeight;
            strategy.logic.deposit(depositAmount);
            strategy.deposited += depositAmount;
        }

        _totalReserves += deposited;
        emit Deposit(msg.sender, deposited);
    }

    /**
     * @notice Withdraws an `amount` of AVAX from the reserve pool
     * @dev Equally withdraws from each strategy based on the weightings
     */
    function withdraw(uint256 amount) virtual public isRole(RESERVE_POOL_MANAGER) {
        require(amount > 0, "ZERO_WITHDRAW");
        uint256 totalAmount = amount;

        /// If using the default strategy, remove the portion of onhand AVAX so we can proportionally grab the strategy AVAX 
        if (_strategies[0].weight > 0) {
            amount -= _strategies[0].weight * amount / _totalWeight;
        }

        for (uint64 i = 1; i < _strategyCount; ++i) {
            Strategy storage strategy = _strategies[i];
            uint256 withdrawAmount = strategy.weight * amount / _totalWeight;
            strategy.logic.withdraw(withdrawAmount);
            strategy.deposited -= withdrawAmount;
        }

        IERC20Upgradeable(WAVAX).transferFrom(address(this), msg.sender, totalAmount);

        _totalReserves -= totalAmount;
        emit Withdraw(msg.sender, totalAmount);
    }

    /**
     * @notice Helper function to withdraw all currently deposited AVAX from the contract
     * @dev    This is only ever used to help reset and reconfigure strategies
     */
    function withdrawAll() virtual public isRole(RESERVE_POOL_MANAGER) {
        require(_totalReserves > 0, "NO_RESERVES");
        withdraw(_totalReserves);
    }
}