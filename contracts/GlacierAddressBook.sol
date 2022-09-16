// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import { AccessControlManager } from "./AccessControlManager.sol";

/**
 * @title GlacierAddressBook contract
 * @author Jack Frost
 * @notice Holds and manages the addresses for the Glacier protocol
 */
contract GlacierAddressBook is Initializable, AccessControlManager {

    address public wavaxAddress;

    address public usdcAddress;

    address public reservePoolAddress;

    address public lendingPoolAddress;

    address public oracleAddress;

    address public networkWalletAddress;

    function initialize(
        address _wavaxAddress,
        address _usdcAddress,
        address _reservePoolAddress,
        address _lendingPoolAddress,
        address _oracleAddress,
        address _networkWalletAddress
    ) initializer public {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        wavaxAddress = _wavaxAddress;
        usdcAddress = _usdcAddress;
        reservePoolAddress = _reservePoolAddress;
        lendingPoolAddress = _lendingPoolAddress;
        oracleAddress = _oracleAddress;
        networkWalletAddress = _networkWalletAddress;
    }

    function setWAVAXAddress(address _wavaxAddress) external isRole(DEFAULT_ADMIN_ROLE) {
        wavaxAddress = _wavaxAddress;
    }

    function setUSDCAddress(address _usdcAddress) external isRole(DEFAULT_ADMIN_ROLE) {
        usdcAddress = _usdcAddress;
    }

    function setReservePoolAddress(address _reservePoolAddress) external isRole(DEFAULT_ADMIN_ROLE) {
        reservePoolAddress = _reservePoolAddress;
    }

    function setLendingPoolAddress(address _lendingPoolAddress) external isRole(DEFAULT_ADMIN_ROLE) {
        lendingPoolAddress = _lendingPoolAddress;
    }

    function setOracleAddress(address _oracleAddress) external isRole(DEFAULT_ADMIN_ROLE) {
        oracleAddress = _oracleAddress;
    }

    function setNetworkWalletAddress(address _networkWalletAddress) external isRole(DEFAULT_ADMIN_ROLE) {
        networkWalletAddress = _networkWalletAddress;
    }
}