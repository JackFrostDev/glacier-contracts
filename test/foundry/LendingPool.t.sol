// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { console } from "@forge-std/console.sol";

import { Fixture } from "./Fixture.t.sol";


contract LendingPoolUnitTests is Fixture {
    uint256 public constant TEN_AVAX = 10 ether;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Borrowed(address user, uint256 amount);
    event Repayed(address client, uint256 amount);

    function setUp() public override {
        super.setUp();
        vm.prank(deployer);
        lendingPool.setClient(deployer);
    }

    /****************************** Deployment ****************************************/ 

    function test_setOracleAddress() public view {
        console.log("oracle not implemented");
    }

    function test_setAVAXAddress() public {
        address avax_ = address(lendingPool.WAVAX());
        assertEq(avax_, address(wAvaxToken));
    }

    function test_setUSDCAddress() public {
        address usdc_ = address(lendingPool.USDC());
        assertEq(usdc_, address(usdcToken));
    }

    function test_setDexAddress() public view {
        console.log("dex address not implemented");
    }

    function test_EnableDeployerAsAdmin() public {
        assertTrue(lendingPool.hasRole(lendingPool.DEFAULT_ADMIN_ROLE(), deployer));
    }

    function test_EnableGlAVAXAsALendingPoolClient() public {
        vm.startPrank(deployer);
        lendingPool.grantRole(lendingPool.LENDING_POOL_CLIENT(), address(glAVAXToken));
        vm.stopPrank();
        assertTrue(lendingPool.hasRole(lendingPool.LENDING_POOL_CLIENT(), address(glAVAXToken)));
    }

    /****************************** General ****************************************/ 

    function test_CheckAVAXReserves() public {
        uint256 initialAvaxAmount_ = lendingPool.totalReserves();

        uint256 wAvaxAmount = uint256(5000)*10**wAvaxToken.decimals();

        vm.prank(deployer);
        wAvaxToken.transfer(address(lendingPool), wAvaxAmount);
        assertEq(initialAvaxAmount_ + wAvaxAmount, lendingPool.totalReserves());
        assertEq(initialAvaxAmount_ + wAvaxAmount, wAvaxToken.balanceOf(address(lendingPool)));
    }

    function test_CheckUSDCReserves() public {
        uint256 usdcAmount_ = uint256(3000)*10**usdcToken.decimals();

        vm.prank(deployer);
        usdcToken.transfer(address(lendingPool), usdcAmount_);
        assertEq(usdcAmount_, lendingPool.usableUSDC());
        assertEq(usdcAmount_, usdcToken.balanceOf(address(lendingPool)));
    }

    function test_removeClient() public {
        address newClient_ = makeAddr("newClient");

        vm.prank(deployer);
        lendingPool.setClient(newClient_);
        assertTrue(lendingPool.hasRole(keccak256("LENDING_POOL_CLIENT"), newClient_));

        vm.prank(deployer);
        lendingPool.removeClient(newClient_);
        assertFalse(lendingPool.hasRole(keccak256("LENDING_POOL_CLIENT"), newClient_));
    }

    function test_BuyingPower() public view {
        console.log("buying power not implemented");
    }

    /****************************** Borrow ****************************************/ 
    
    // Validation 

    function test_revert_ifBorrowingWithANonClientWallet() public {
        uint256 wAvaxAmount = uint256(5000)*10**wAvaxToken.decimals();
        vm.prank(deployer);
        wAvaxToken.transfer(address(lendingPool), wAvaxAmount);
        vm.prank(alice);
        vm.expectRevert("INCORRECT_ROLE");
        lendingPool.borrow(TEN_AVAX);
    }

    function test_revert_ifAmountIsZero() public {
        uint256 wAvaxAmount = uint256(5000)*10**wAvaxToken.decimals();
        vm.startPrank(deployer);
        wAvaxToken.transfer(address(lendingPool), wAvaxAmount);
        vm.expectRevert("ZERO_BORROW");
        lendingPool.borrow(0);
        vm.stopPrank();
    }

    function test_revert_ifExceedingTheTotalBorrowAmountAvailable() public {
        uint256 initialWavaxAmount_ = lendingPool.totalReserves();
        uint256 wAvaxAmount = uint256(1)*10**wAvaxToken.decimals();
        vm.startPrank(deployer);
        wAvaxToken.transfer(address(lendingPool), wAvaxAmount);
        vm.expectRevert("EXCEEDED_BORROW_AMOUNT");
        lendingPool.borrow(TEN_AVAX + initialWavaxAmount_);
        vm.stopPrank();
    }

    // Logic

    function _beforeEach_Borrow_Logic() internal {
        uint256 wAvaxAmount = uint256(5000)*10**wAvaxToken.decimals();
        vm.prank(deployer);
        wAvaxToken.transfer(address(lendingPool), wAvaxAmount);
        uint256 usdcAmount_ = uint256(20000)*10**usdcToken.decimals();
        vm.prank(deployer);
        usdcToken.transfer(address(lendingPool), usdcAmount_);
    }

    function test_BorrowedAVAXSuccessfully() public {
        _beforeEach_Borrow_Logic();

        uint256 balanceBefore_ = wAvaxToken.balanceOf(deployer);
        uint256 loanAmountBefore_ = lendingPool.totalLoaned();

        vm.expectEmit(true, true, true, true, address(wAvaxToken));
        emit Transfer(address(lendingPool), deployer, TEN_AVAX);
        vm.expectEmit(true, true, true, true, address(lendingPool));
        emit Borrowed(deployer, TEN_AVAX);

        vm.prank(deployer);
        lendingPool.borrow(TEN_AVAX);
        
        uint256 balanceAfter_ = wAvaxToken.balanceOf(deployer);
        assertEq(balanceAfter_ - balanceBefore_, TEN_AVAX);

        uint256 loanAmountAfter_ = lendingPool.totalLoaned();
        assertEq(loanAmountAfter_ - loanAmountBefore_, TEN_AVAX);
    }

    /****************************** Repay ****************************************/ 

    function _beforeEach_Repay() internal returns(uint256 borrowAmount_) {
        borrowAmount_ = uint256(1000)*10**wAvaxToken.decimals();

        vm.startPrank(deployer);
        uint256 wAvaxAmount = uint256(5000)*10**wAvaxToken.decimals();
        wAvaxToken.transfer(address(lendingPool), wAvaxAmount);
        uint256 usdcAmount_ = uint256(20000)*10**usdcToken.decimals();
        usdcToken.transfer(address(lendingPool), usdcAmount_);
        
        lendingPool.borrow(borrowAmount_);
        vm.stopPrank();
    }

    // Validation

    function test_revert_ifRepayingZero() public {
        vm.prank(deployer);
        vm.expectRevert("ZERO_REPAY");
        lendingPool.repay(0);
    }

    function test_revert_ifRepayingTooMuch() public {
        uint256 borrowAmount_ = _beforeEach_Repay();
        vm.prank(deployer);
        vm.expectRevert("EXCEEDED_REPAY_AMOUNT");
        lendingPool.repay(borrowAmount_ + 1);
    }

    function test_revert_ifRepayingWithoutTokenApproval() public {
        uint256 borrowAmount_ = _beforeEach_Repay();
        vm.startPrank(deployer);
        wAvaxToken.approve(address(lendingPool), 0);
        vm.expectRevert();
        lendingPool.repay(borrowAmount_);
        vm.stopPrank();
    }

    // Logic

    function test_RepayedAVAXSuccessfully() public {
        uint256 borrowAmount_ = _beforeEach_Repay();
        uint256 balanceBefore_ = wAvaxToken.balanceOf(deployer);
        uint256 loanAmountBefore_ = lendingPool.totalLoaned();

        vm.expectEmit(true, true, true, true, address(wAvaxToken));
        emit Transfer(deployer, address(lendingPool), borrowAmount_);
        vm.expectEmit(true, true, true, true, address(lendingPool));
        emit Repayed(deployer, borrowAmount_);

        vm.prank(deployer);
        lendingPool.repay(borrowAmount_);
        
        uint256 balanceAfter_ = wAvaxToken.balanceOf(deployer);
        assertEq(balanceBefore_ - balanceAfter_, borrowAmount_);

        uint256 loanAmountAfter_ = lendingPool.totalLoaned();
        assertEq(loanAmountBefore_ - loanAmountAfter_, borrowAmount_);
    }

    /****************************** Buy and Borrow ****************************************/ 

    // Not Implemented

    /****************************** Repay Bought ****************************************/ 

    // Not Implemented
}