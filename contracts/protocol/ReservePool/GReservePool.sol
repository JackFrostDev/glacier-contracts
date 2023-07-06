// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy, ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {IGReserveStrategy} from "../../interfaces/IGReserveStrategy.sol";
import {IGReservePool} from "../../interfaces/IGReservePool.sol";
import {AccessControlManager} from "../../AccessControlManager.sol";
import {AddressUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";

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
    uint256 public constant _maxStrategies = 5;

    /// @notice The default strategy weight
    uint256 public constant _defaultStrategyWeigth = 100;

    struct Strategy {
        IGReserveStrategy logic;
        uint256 deposited;
        uint256 weight;
    }

    /// @notice The strategies to atomically deposit and withdraw funds
    /// @dev _strategies[0] is always the default strategy which is to just hold funds
    mapping(uint64 => Strategy) public _strategies;

    /// @notice The amount of strategies this reserve pool has currently
    uint64 public _strategyCount;

    /// @notice The admin for proxy contracts
    ProxyAdmin public proxyAdmin;

    /// @notice Emitted when a deposit is made
    event Deposit(address indexed user, uint256 amount);

    /// @notice Emitted when a withdrawal is made
    event Withdraw(address indexed user, uint256 amount);

    error NotContract();

    function initialize(address _wavaxAddress) public initializer {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(RESERVE_POOL_MANAGER, msg.sender);

        WAVAX = _wavaxAddress;
        proxyAdmin = new ProxyAdmin();

        // The default strategy is to just sit on the funds
        _totalWeight = _defaultStrategyWeigth;
        _strategies[0].weight = _defaultStrategyWeigth;
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
    function addStrategy(IGReserveStrategy implementation, uint256 weight, bytes memory initializer) external isRole(RESERVE_POOL_MANAGER) returns (address newStrategy) {
        require(_totalReserves == 0, "ACTIVE_DEPOSITS");
        require(_strategyCount < _maxStrategies, "TOO_MANY_STRATEGIES");
        if(!AddressUpgradeable.isContract(address(implementation))){
            revert NotContract();
        }
        newStrategy = _deployProxy(address(implementation), initializer);
        _strategies[_strategyCount] = Strategy({logic: IGReserveStrategy(newStrategy), weight: weight, deposited: 0});
        _strategyCount++;
        _totalWeight += weight;        

        // Approve the Aave strategy to spend the balance of `asset` in this contract
        // This is required so that when a deposit is made the Aave strategy can move funds in
        IERC20Upgradeable(WAVAX).approve(address(newStrategy), type(uint256).max);
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
        _totalWeight = _defaultStrategyWeigth;
        _strategies[0].weight = _defaultStrategyWeigth;
    }

    /**
     * @notice Replace a strategy implementation by an other
     */
    function updateStrategy(uint64 strategyId, address oldImplementation, address newImplementation, bytes memory initializer) external isRole(RESERVE_POOL_MANAGER) {
       require(strategyId < _strategyCount, "INDEX_OUT_OF_BOUNDS");
       if(!AddressUpgradeable.isContract(newImplementation)){
            revert NotContract();
       }
       Strategy storage strategyToReplace = _strategies[strategyId];
       ITransparentUpgradeableProxy proxy = ITransparentUpgradeableProxy(address(strategyToReplace.logic));
       // prevent from upgrade the wrong strategy
       address currentImplementation = proxyAdmin.getProxyImplementation(proxy);
       require(currentImplementation == oldImplementation, "IMPLEMENTATION_NOT_MATCH");

       if (initializer.length > 0){
            proxyAdmin.upgradeAndCall(proxy, newImplementation, initializer);     
       }
       else{
            proxyAdmin.upgrade(proxy, newImplementation);
       } 
    }

    /**
     * @notice Return a strategy by is id and this implementation address
     */
    function getStrategy(uint64 strategyId) external view returns (Strategy memory strategy, address implementation) {
       require(strategyId < _strategyCount, "INDEX_OUT_OF_BOUNDS");
       strategy = _strategies[strategyId];
       ITransparentUpgradeableProxy proxy = ITransparentUpgradeableProxy(address(strategy.logic));
       implementation = proxyAdmin.getProxyImplementation(proxy);    
    }

    /**
     * @notice Returns the total amount of AVAX this contract manages
     */
    function totalReserves() external view virtual returns (uint256) {
        return _totalReserves;
    }

    /**
     * @notice Deposits AVAX into the reserve pool, which can have optional extra atomic actions applied to it as voted
     */
    function deposit(uint256 amount) external virtual isRole(RESERVE_POOL_MANAGER) {
        require(amount > 0, "ZERO_DEPOSIT");
        IERC20Upgradeable(WAVAX).transferFrom(msg.sender, address(this), amount);

        for (uint64 i = 1; i < _strategyCount; ++i) {
            Strategy storage strategy = _strategies[i];
            uint256 depositAmount = strategy.weight * amount / _totalWeight;
            strategy.logic.deposit(depositAmount);
            strategy.deposited += depositAmount;
        }        

        _totalReserves += amount;
        emit Deposit(msg.sender, amount);
    }

    /**
     * @notice Withdraws an `amount` of AVAX from the reserve pool
     * @dev Equally withdraws from each strategy based on the weightings
     */
    function withdraw(uint256 amount) public virtual isRole(RESERVE_POOL_MANAGER) {
        require(amount > 0, "ZERO_WITHDRAW");

        uint256 balance = IERC20Upgradeable(WAVAX).balanceOf(address(this));

        for (uint64 i = 1; i < _strategyCount; ++i) {
            Strategy storage strategy = _strategies[i];
            uint256 withdrawAmount = strategy.weight * amount / _totalWeight;
            strategy.logic.withdraw(withdrawAmount);
            strategy.deposited -= withdrawAmount;
        }

        uint256 totalWithdraw = IERC20Upgradeable(WAVAX).balanceOf(address(this)) - balance; 
        // total withdraw can be bigger with yield, we transfer yield to glavaxcontract
        uint256 amountTransfered = totalWithdraw > amount ? totalWithdraw : amount;

        IERC20Upgradeable(WAVAX).transferFrom(address(this), msg.sender, amountTransfered);

        _totalReserves -= amount;
        emit Withdraw(msg.sender, amount);
    }

    /**
     * @notice Helper function to withdraw all currently deposited AVAX from the contract
     * @dev    This is only ever used to help reset and reconfigure strategies
     */
    function withdrawAll() public virtual isRole(RESERVE_POOL_MANAGER) {
        require(_totalReserves > 0, "NO_RESERVES");
        withdraw(_totalReserves);
    }

    /**
     * @notice Create a new proxy contract for strategy
     */
    function _deployProxy(address implementation, bytes memory initializer) internal returns (address) {
        return address(new TransparentUpgradeableProxy(implementation, address(proxyAdmin), initializer));
    }
}
