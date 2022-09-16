// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import { IJoeRouter02 } from "@traderjoe-xyz/core/contracts/traderjoe/interfaces/IJoeRouter02.sol";

import { IGLendingPool } from "../../interfaces/IGLendingPool.sol";
import { IWAVAX } from "../../interfaces/IWAVAX.sol";
import { IGlacierOracle } from "../../interfaces/IGlacierOracle.sol";
import { AccessControlManager } from "../../AccessControlManager.sol";

/**
 * @title  GLendingPool implementation
 * @author Jack Frost
 * @notice The lending pool is a whitelisted pool of funds that can be loaned out by specified clients. The loans are uncollateralized and 0% interest.
 */
contract GLendingPool is Initializable, IGLendingPool, AccessControlManager {

    /// @notice The Oracle contract to retrieve onchain price information
    IGlacierOracle public oracle;

    /// @notice The WAVAX contract
    IWAVAX public WAVAX;

    /// @notice The USDC contract
    IERC20Upgradeable public USDC;

    /// @notice The DEX contract to facilitate swaps
    IJoeRouter02 public dex;

    /// @notice A struct describing how much AVAX was borrowed and/or bought
    struct LoanDetails {
        uint256 borrowed;
        uint256 bought;
    }

    /// @notice A mapping of each address and their loan details
    mapping (address => LoanDetails) public _loans;

    /// @notice The total amount of AVAX this contract has loaned out
    uint256 public _totalLoaned;

    /// @notice The total amount of AVAX this contract has bought
    uint256 public _totalBought;

    /// @notice Emitted when someone borrows AVAX
    event Borrowed(address user, uint256 amount);

    /// @notice Emitted when someone borrows AVAX via purchasing
    event BoughtAndBorrowed(address user, uint256 amount);

    /// @notice Emitted when someone repays borrowed AVAX
    event Repayed(address payer, address client, uint256 amount);

    /// @notice Emitted when someone repays borrowed AVAX which is then sold
    event RepayedAndSold(address payer, address client, uint256 avaxSold, uint256 usdcReceived);

    function initialize(address _oracle, address _dexAddress, address _wavaxAddress, address _usdcAddress) initializer public {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        
        oracle = IGlacierOracle(_oracle);
        dex = IJoeRouter02(_dexAddress);
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
    function totalReserves() virtual external view returns (uint256) {
        return IERC20Upgradeable(address(WAVAX)).balanceOf(address(this));
    }

    /**
     * @notice Returns the total loaned AVAX
     */
    function totalLoaned() virtual external view returns (uint256) {
        return _totalLoaned;
    }

    /**
     * @notice Returns the total bought AVAX
     */
    function totalBought() virtual external view returns (uint256) {
        return _totalBought;
    }

    /**
     * @notice Returns the total bought and loaned AVAX
     */
    function totalOwed() virtual external view returns(uint256) {
        return _totalLoaned + _totalBought;
    }

    /**
     * @notice Returns the total amount of usable USDC inside this contract
     */
    function usableUSDC() public view returns (uint256) {
        return USDC.balanceOf(address(this));
    }

    /**
     * @notice Returns how much AVAX this contract is able to purchase
     */
    function purchasingPower() virtual public view returns (uint256) {
        uint256 usdcAmount = usableUSDC();
        if (usdcAmount > 0) {
            return oracle.getTokensForUSDC(address(WAVAX), usdcAmount);
        } else {
            return 0;
        }
    }

    /**
     * @notice Borrows an amount of AVAX from this contract, opening up a loan
     */
    function borrow(uint256 amount) virtual external isRole(LENDING_POOL_CLIENT) returns (uint256) {
        require(amount > 0, "ZERO_BORROW");
        require(amount <= IERC20Upgradeable(address(WAVAX)).balanceOf(address(this)), "EXCEEDED_BORROW_AMOUNT");
        _totalLoaned += amount;
        _loans[msg.sender].borrowed += amount;
        IERC20Upgradeable(address(WAVAX)).transfer(msg.sender, amount);
        emit Borrowed(msg.sender, amount);
        return amount;
    }
    
    /**
     * @notice Repays back an amount of AVAX to this contract. Anyone can repay a loan for anyone
     */
    function repay(address client, uint256 amount) virtual external returns (uint256) {
        require(amount > 0, "ZERO_REPAY");
        require(_loans[client].borrowed >= amount, "EXCEEDED_REPAY_AMOUNT");
        _totalLoaned -= amount;
        _loans[client].borrowed -= amount;
        IERC20Upgradeable(address(WAVAX)).transferFrom(msg.sender, address(this), amount);
        emit Repayed(client, msg.sender, amount);
        return amount;
    }

    /**
     * @notice Buys AVAX and borrows it
     */
    function buyAndBorrow(uint256 amount) virtual external isRole(LENDING_POOL_CLIENT) returns (uint256)  {
        require(amount > 0, "ZERO_BORROW");
        uint256 avaxBought = _buy(amount);
        _totalBought += avaxBought;
        _loans[msg.sender].bought += avaxBought;
        IERC20Upgradeable(address(WAVAX)).transfer(msg.sender, avaxBought);
        emit BoughtAndBorrowed(msg.sender, avaxBought);
        return avaxBought;
    }

    /**
     * @notice Repays a bought and borrowed position
     */
    function repayBought(address client, uint256 amount) virtual external returns (uint256) {
        require(amount > 0, "ZERO_REPAY");
        require(_loans[client].bought >= amount, "EXCEEDED_REPAY_AMOUNT");

        uint256 usdcReceived = _sell(amount);

        _totalBought -= amount;
        _loans[client].bought -= amount;
        IERC20Upgradeable(address(WAVAX)).transferFrom(client, address(this), amount);
        emit RepayedAndSold(msg.sender, client, amount, usdcReceived);
        return usdcReceived;
    }

    /**
     * @notice Purchases as much AVAX as possible using `amount` in USDC
     * @param amount The exact amount of AVAX to purchase using as little USDC as possible
     */
    function _buy(uint256 amount) internal returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = address(USDC);
        path[1] = address(WAVAX);

        // Tries to buy `amount` AVAX using as much USDC as possible up to `usableUSDC()`
        uint256 maxAvax = purchasingPower();
        uint256 avaxAmount = amount > maxAvax ? maxAvax : amount;
        IERC20Upgradeable(address(USDC)).approve(address(dex), type(uint256).max);

        uint[] memory amounts = dex.swapExactTokensForTokens(
            avaxAmount,
            0,
            path,
            address(this),
            block.timestamp + 360
        );

        return amounts[1];
    }

    /**
     * @notice Sells `amount` of AVAX for as much USDC as possible
     * @param amount The exact amount of AVAX to sell for as much USDC as possible
     */
    function _sell(uint256 amount) internal returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = address(WAVAX);
        path[1] = address(USDC);

        // Sells exactly `avaxAmount` AVAX to receive as much USDC as possible
        IERC20Upgradeable(address(WAVAX)).approve(address(dex), amount);
        uint[] memory amounts = dex.swapExactTokensForTokens(
            amount, 
            0, 
            path,
            address(this),
            block.timestamp + 120
        );

        return amounts[1];
    }
}