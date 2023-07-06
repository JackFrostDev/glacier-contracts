// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { console } from "@forge-std/console.sol";

import { Fixture } from "../Fixture.t.sol";


contract LendingPoolFuzzTests is Fixture {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Borrowed(address user, uint256 amount);
    event Repayed(address user, uint256 amount);

    function setUp() public override {
        super.setUp();
        vm.prank(deployer);
        lendingPool.setClient(deployer);
    }

    /****************************** Borrow ****************************************/ 

    function test_fuzz_borrow(uint256 borrowAmount_, uint256 poolBalance_) public {
        borrowAmount_ = bound(borrowAmount_, 0, type(uint256).max - wAvaxToken.totalSupply());
        deal(address(wAvaxToken), address(lendingPool), poolBalance_); 

        vm.startPrank(deployer);
        if (borrowAmount_ == 0) {
            vm.expectRevert("ZERO_BORROW");
            lendingPool.borrow(borrowAmount_);
        }
        else if (borrowAmount_ > poolBalance_) {
            vm.expectRevert("EXCEEDED_BORROW_AMOUNT");
            lendingPool.borrow(borrowAmount_);
        } else {
            uint256 balanceBefore_ = wAvaxToken.balanceOf(deployer);
            uint256 loanAmountBefore_ = lendingPool.totalLoaned();

            vm.expectEmit(true, true, true, true, address(wAvaxToken));
            emit Transfer(address(lendingPool), deployer, borrowAmount_);
            vm.expectEmit(true, true, true, true, address(lendingPool));
            emit Borrowed(deployer, borrowAmount_);

            lendingPool.borrow(borrowAmount_);
            
            uint256 balanceAfter_ = wAvaxToken.balanceOf(deployer);
            assertEq(balanceAfter_ - balanceBefore_, borrowAmount_);

            uint256 loanAmountAfter_ = lendingPool.totalLoaned();
            assertEq(loanAmountAfter_ - loanAmountBefore_, borrowAmount_);
        }

        vm.stopPrank();
    }

    /****************************** Repay ****************************************/ 

    function test_fuzz_repay(uint256 borrowAmount_, uint256 repayAmount_, uint256 tokenApproval_) public {
        borrowAmount_ = bound(borrowAmount_, 0, type(uint256).max - wAvaxToken.totalSupply());
        deal(address(wAvaxToken), address(lendingPool), borrowAmount_);  
        
        vm.startPrank(deployer);
        if (borrowAmount_ == 0) vm.expectRevert("ZERO_BORROW");
        lendingPool.borrow(borrowAmount_);
        wAvaxToken.approve(address(lendingPool), tokenApproval_);

        if (repayAmount_ > borrowAmount_) {
            vm.expectRevert("EXCEEDED_REPAY_AMOUNT");
            lendingPool.repay(repayAmount_);
        }
        else if (repayAmount_ == 0) {
            vm.expectRevert("ZERO_REPAY");
            lendingPool.repay(repayAmount_);
        }
        else if (repayAmount_ > tokenApproval_) {
            vm.expectRevert();
            lendingPool.repay(repayAmount_);
        }
        else {
            uint256 balanceBefore_ = wAvaxToken.balanceOf(deployer);
            uint256 loanAmountBefore_ = lendingPool.totalLoaned();

            vm.expectEmit(true, true, true, true, address(wAvaxToken));
            emit Transfer(deployer, address(lendingPool), repayAmount_);
            vm.expectEmit(true, true, true, true, address(lendingPool));
            emit Repayed(deployer, repayAmount_);

            lendingPool.repay(repayAmount_);
            
            uint256 balanceAfter_ = wAvaxToken.balanceOf(deployer);
            assertEq(balanceBefore_ - balanceAfter_, repayAmount_);

            uint256 loanAmountAfter_ = lendingPool.totalLoaned();
            assertEq(loanAmountBefore_ - loanAmountAfter_, repayAmount_);
        }

        vm.stopPrank();
    }

    /****************************** Buy and Borrow ****************************************/ 

    // Not Implemented

    /****************************** Repay Bought ****************************************/ 

    // Not Implemented
}