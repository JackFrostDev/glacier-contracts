// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Fixture } from "./Fixture.t.sol";

contract GlacierAddressBookTests is Fixture {
    function setUp() public override {
        super.setUp();
    }

    function testSetWAVAXAddress() public {
        vm.prank(deployer);
        glacierAddressBook.setWAVAXAddress(address(wAvaxToken));
        assertEq(glacierAddressBook.wavaxAddress(), address(wAvaxToken));
    }

    function testSetUSDCAddress() public {
        vm.prank(deployer);
        glacierAddressBook.setUSDCAddress(address(usdcToken));
        assertEq(glacierAddressBook.usdcAddress(), address(usdcToken));
    }

    function testSetReservePoolAddress() public {
        vm.prank(deployer);
        glacierAddressBook.setReservePoolAddress(address(reservePool));
        assertEq(glacierAddressBook.reservePoolAddress(), address(reservePool));
    }

    function testSetLendingPoolAddress() public {
        vm.prank(deployer);
        glacierAddressBook.setLendingPoolAddress(address(lendingPool));
        assertEq(glacierAddressBook.lendingPoolAddress(), address(lendingPool));
    }

    function testSetOracleAddress() public {
        vm.prank(deployer);
        glacierAddressBook.setOracleAddress(deployer);
        assertEq(glacierAddressBook.oracleAddress(), deployer);
    }

    function testSetNetworkWalletAddress() public {
        vm.prank(deployer);
        glacierAddressBook.setNetworkWalletAddress(deployer);
        assertEq(glacierAddressBook.networkWalletAddress(), deployer);
    }

    function testSetWAVAXAddress_revertIfNotDeployer() public {
        vm.prank(alice);
        vm.expectRevert("INCORRECT_ROLE");
        glacierAddressBook.setWAVAXAddress(deployer);
    }

    function testSetUSDCAddress_revertIfNotDeployer() public {
        vm.prank(alice);
        vm.expectRevert("INCORRECT_ROLE");
        glacierAddressBook.setUSDCAddress(deployer);
    }

    function testSetReservePoolAddress_revertIfNotDeployer() public {
        vm.prank(alice);
        vm.expectRevert("INCORRECT_ROLE");
        glacierAddressBook.setReservePoolAddress(deployer);
    }

    function testSetLendingPoolAddress_revertIfNotDeployer() public {
        vm.prank(alice);
        vm.expectRevert("INCORRECT_ROLE");
        glacierAddressBook.setLendingPoolAddress(deployer);
    }

    function testSetOracleAddress_revertIfNotDeployer() public {
        vm.prank(alice);
        vm.expectRevert("INCORRECT_ROLE");
        glacierAddressBook.setOracleAddress(deployer);
    }

    function testSetNetworkWalletAddress_revertIfNotDeployer() public {
        vm.prank(alice);
        vm.expectRevert("INCORRECT_ROLE");
        glacierAddressBook.setNetworkWalletAddress(deployer);
    }
}