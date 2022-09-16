// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

contract AccessControlManager is AccessControlUpgradeable {

    /// @notice If a wallet or a contract has this role set, they can restore the network and request withdrawals from the Glacier Network
    bytes32 public constant NETWORK_MANAGER = keccak256("NETWORK_MANAGER");

    /// @notice If a wallet or contract has this role set, they can deposit and withdraw from the reserve pool
    bytes32 public constant RESERVE_POOL_MANAGER = keccak256("RESERVE_POOL_MANAGER");

    /// @notice If a wallet or contract has this role set, they can borrow and take loans from the lending pool requiring them to pay back
    bytes32 public constant LENDING_POOL_CLIENT = keccak256("LENDING_POOL_CLIENT");

    /// @notice If a wallet or contract has this role set, they can manage the claim pool
    bytes32 public constant CLAIM_POOL_MANAGER = keccak256("CLAIM_POOL_MANAGER");

    /// @notice If a wallet or contract has this role set, they're able to use certain strategies 
    bytes32 public constant STRATEGY_USER = keccak256("STRATEGY_USER");

    /// @notice Modifier to test that the caller has a specific role (interface to AccessControl)
    modifier isRole(bytes32 role) {
        require(hasRole(role, msg.sender), "INCORRECT_ROLE");
        _;
    }
}