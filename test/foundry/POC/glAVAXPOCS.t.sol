// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Test } from "@forge-std/Test.sol";
import { console } from "@forge-std/console.sol";

import { IWAVAX } from "contracts/interfaces/IWAVAX.sol";

import { Fixture } from "test/foundry/Fixture.t.sol";

contract GlAVAXPOCSTests is Fixture {

    uint256 public constant TEN_AVAX = 10 * 10**18;

    function setUp() public override {
        super.setUp();
    }

    function test_POC_HaltedDepositsDueToWithdrawalRequests() public {
        uint256 aliceDeposit_ = 10000 * 10**18; // big deposit so that lending pool and reserves can't cover withdraw

        deal(alice, aliceDeposit_);
        vm.prank(alice);
        glAVAXToken.deposit{value: aliceDeposit_}(0);

        uint256 initialNetworkBalance_ = networkWalletAddress.balance;

        uint256 withdrawable = aliceDeposit_ - glAVAXToken.MINIMUM_LIQUIDITY();

        vm.prank(deployer);
        glAVAXToken.rebalance();

        assertEq(wAvaxToken.balanceOf(address(glAVAXToken)), 0);
        assertEq(networkWalletAddress.balance, initialNetworkBalance_ + aliceDeposit_ - aliceDeposit_*glAVAXToken.reservePercentage()/1e4);
    
        vm.startPrank(alice);
        //glAVAXToken.approve(alice, type(uint256).max); // alice has to approve alice because of another issue. This is another
        glAVAXToken.withdraw(withdrawable);    // vulnerability that needs to be fixed seperately
        vm.stopPrank();

        assertEq(alice.balance, aliceDeposit_*glAVAXToken.reservePercentage()/1e4 + lendingPoolWavax * 1e18);
        assertEq(wAvaxToken.balanceOf(address(glAVAXToken)), 0);
        
        vm.deal(bob, TEN_AVAX);
        vm.prank(bob);

        // corrected with new mechanism
        //vm.expectRevert(); // reverts because glAVAX has no wAVAX balance but tries to withdraw
        glAVAXToken.deposit{value: TEN_AVAX}(0);
    }

    function test_POC_RepayLiquidityFails_IfSomeoneOtherThanGlAVAXTakesALoan() public {
        uint256 aliceDeposit_ = 10000 * 10**18; // big deposit so that lending pool and reserves can't cover withdraw

        deal(alice, aliceDeposit_);
        vm.prank(alice);
        glAVAXToken.deposit{value: aliceDeposit_}(0);

        uint256 initialNetworkBalance_ = networkWalletAddress.balance;

        uint256 withdrawable = aliceDeposit_ - glAVAXToken.MINIMUM_LIQUIDITY();

        vm.prank(deployer);
        glAVAXToken.rebalance();

        assertEq(wAvaxToken.balanceOf(address(glAVAXToken)), 0);
        assertEq(networkWalletAddress.balance, initialNetworkBalance_ + aliceDeposit_ - aliceDeposit_*glAVAXToken.reservePercentage()/1e4);
    
        vm.startPrank(alice);
        //glAVAXToken.approve(alice, type(uint256).max); // alice has to approve alice because of another issue. This is another
        glAVAXToken.withdraw(withdrawable);    // vulnerability that needs to be fixed seperately
        vm.stopPrank();

        assertEq(alice.balance, aliceDeposit_*glAVAXToken.reservePercentage()/1e4 + lendingPoolWavax * 1e18);
        assertEq(wAvaxToken.balanceOf(address(glAVAXToken)), 0);

        ////////////////////////////////////////////////////////////////////////////////////
        // At this point, glAVAX is in debt to the lending pool and has to repay the loan //
        ////////////////////////////////////////////////////////////////////////////////////

        vm.startPrank(deployer);
        lendingPool.setClient(deployer);
        wAvaxToken.transfer(address(lendingPool), 1);
        lendingPool.borrow(1);
        vm.stopPrank();

        uint256 totalNetworkAvax_ = glAVAXToken.totalNetworkAVAX();

        vm.prank(networkWalletAddress);
        payable(deployer).transfer(totalNetworkAvax_); // deployer is the one who has the role to fulfill withdrawals

        // corrected we repaid only amount borrowed by glavax contract
        //vm.expectRevert("EXCEEDED_REPAY_AMOUNT");
        vm.prank(deployer);
        glAVAXToken.fufillWithdrawal{value: totalNetworkAvax_}();
    }

    function test_POC_DepositUnusableDueToInsuficientGas() public {
        uint256 bobDeposit_ = 1000 * 10**18;
        deal(bob, 2 * bobDeposit_);

        // Make a big deposit to pass the lending and reserve pool
        vm.prank(bob);
        glAVAXToken.deposit{ value: bobDeposit_}(0);
        vm.prank(deployer);
        glAVAXToken.rebalance();

        
        vm.startPrank(bob);
        glAVAXToken.approve(bob, bobDeposit_);
        // Make a big withdraw to throttle the network and create a withdraw request
        glAVAXToken.withdraw(bobDeposit_ - (100 * 10**18));
        // Make several small withdrawls in order to create many withdraw requests
        // In this exemple we end up with 1001 withdraw requests
        for(uint256 i = 0; i < 1000; i++){
            glAVAXToken.withdraw(100);
        }
        vm.stopPrank();

        // Give WAVAX to glAVAXToken to pass over issue #16
        deal(address(wAvaxToken), address(glAVAXToken), bobDeposit_);

        // Save gas before and after deposit
        uint256 gasleft1 = gasleft();
        vm.prank(bob);
        glAVAXToken.deposit{ value: bobDeposit_ }(0);
        uint256 gasleft2 = gasleft();

        // Limit of gas per block in Avalanche is 15M
        // In this scenario the gas cost of deposit was 23_860_217
       // assertGt(gasleft1-gasleft2, 15_000_000);

       // new withdrawal mechanism don't need to loop withdraw request
       assertLt(gasleft1-gasleft2, 1_000_000);
    }

    function test_POC_WithdrawRequestCancel_ProtectsFromSlashing() public {
        uint256 aliceDeposit_ = 10000 * 10**18; // big deposit so that lending pool and reserves can't cover withdraw

        deal(alice, aliceDeposit_);
        vm.prank(alice);
        glAVAXToken.deposit{value: aliceDeposit_}(0);

        uint256 initialNetworkBalance_ = networkWalletAddress.balance;

        uint256 withdrawable = aliceDeposit_ - glAVAXToken.MINIMUM_LIQUIDITY();

        vm.prank(deployer);
        glAVAXToken.rebalance();

        assertEq(wAvaxToken.balanceOf(address(glAVAXToken)), 0);
        assertEq(networkWalletAddress.balance, initialNetworkBalance_ + aliceDeposit_ - aliceDeposit_*glAVAXToken.reservePercentage()/1e4);
    
        vm.startPrank(alice);
        //glAVAXToken.approve(alice, type(uint256).max); // alice has to approve alice because of another issue. This is another
        glAVAXToken.withdraw(withdrawable);    // vulnerability that needs to be fixed seperately
        vm.stopPrank();

        assertEq(alice.balance, aliceDeposit_*glAVAXToken.reservePercentage()/1e4 + lendingPoolWavax * 1e18);
        assertEq(wAvaxToken.balanceOf(address(glAVAXToken)), 0);

        ////////////////////////////////////////////////////////////////////////////////////////////////////
        // At this point, alice has created a withdrawal request and is waiting for a slashing tx to come //
        ////////////////////////////////////////////////////////////////////////////////////////////////////

        uint256 slashing_ = 1000 * 10**18;
        vm.startPrank(deployer);
        glAVAXToken.setNetworkTotal(glAVAXToken.totalNetworkAVAX() - slashing_);
        vm.stopPrank();

        vm.prank(alice);
        // It's trying to transfer more shares than what alice transferred when the withdrawal request was created
        // Will revert because it does not have enough shares, otherwise it would use other users' shares
        //corrected vm.expectRevert("ERC20: transfer amount exceeds balance");
        glAVAXToken.cancel(0);
    }

    function test_POC_NotConvertingAmountToShares() public {
        uint256 bobDeposit_ = 1000 * 10**18;
        deal(bob, 2 * bobDeposit_);

        // Make a big deposit to pass the lending and reserve pool
        vm.prank(bob);
        glAVAXToken.deposit{ value: bobDeposit_}(0);

        vm.prank(deployer);
        glAVAXToken.rebalance();

        // Make a big withdraw to throttle the network and create a withdraw request
        vm.startPrank(bob);
        //glAVAXToken.approve(bob, bobDeposit_); // notice bob approving himself, issue #17
        glAVAXToken.withdraw(bobDeposit_ - (100 * 10**18));
        vm.stopPrank();

        // Give WAVAX to glAVAXToken to pass over issue #16, and also to change the ratio of shares/AVAX
        deal(address(wAvaxToken), address(glAVAXToken), bobDeposit_);

        // Get the request.amount and the shares for that amount
        (,,,uint256 amount,,) = glAVAXToken.withdrawRequests(0);
        uint256 shares = glAVAXToken.sharesFromAvax(amount);

        // The deposit will fulfill the request using request.amount
        vm.prank(bob);
        glAVAXToken.deposit{ value: bobDeposit_ }(0);

        // But as this assert shows the request.amount and ots shares are different
        assertGt(amount, shares);
    }

    function test_POC_ExcessiveWithdrawRequestNativeWithdrawn() public {
        uint256 aliceDeposit_ = 10000 * 10**18; // big deposit so that lending pool and reserves can't cover withdraw

        deal(alice, aliceDeposit_);
        vm.prank(alice);
        glAVAXToken.deposit{value: aliceDeposit_}(0);

        uint256 initialNetworkBalance_ = networkWalletAddress.balance;

        uint256 withdrawable = aliceDeposit_ - glAVAXToken.MINIMUM_LIQUIDITY();

        vm.prank(deployer);
        glAVAXToken.rebalance();

        assertEq(wAvaxToken.balanceOf(address(glAVAXToken)), 0);
        assertEq(networkWalletAddress.balance, initialNetworkBalance_ + aliceDeposit_ - aliceDeposit_*glAVAXToken.reservePercentage()/1e4);
    
        vm.startPrank(alice);
        //glAVAXToken.approve(alice, type(uint256).max); // alice has to approve alice because of another issue. This is another
        glAVAXToken.withdraw(withdrawable);    // vulnerability that needs to be fixed seperately #17
        vm.stopPrank();

        assertEq(alice.balance, aliceDeposit_*glAVAXToken.reservePercentage()/1e4 + lendingPoolWavax * 1e18);
        assertEq(wAvaxToken.balanceOf(address(glAVAXToken)), 0);

        //////////////////////////////////////////////////////////////////////////////////////////
        // At this point, alice has created a withdrawal request and awaits for its fulfillment //
        //////////////////////////////////////////////////////////////////////////////////////////

        (,,,uint256 withdrawRequestAmount_,,) = glAVAXToken.withdrawRequests(0);

        // Here we are using the NETWORK_MANAGER to fulfill withdrawals, but this could come from deposits
        // It's easier to show this issue this way

        uint256 totalNetworkAvax_ = glAVAXToken.totalNetworkAVAX();

        vm.prank(networkWalletAddress);
        payable(deployer).transfer(totalNetworkAvax_); // deployer is the one who has the role to fulfill withdrawals

        uint256 increasedNetworkAmount_ = 1000 * 10**18;

        vm.prank(deployer);
        glAVAXToken.increaseNetworkTotal(increasedNetworkAmount_);

        vm.startPrank(deployer);
        glAVAXToken.fufillWithdrawal{value: withdrawRequestAmount_ - 1}();
        glAVAXToken.fufillWithdrawal{value: 10000}();
        vm.stopPrank();

        // Notice how glAVAXToken has more balance than what alice requested
        //assertEq(address(glAVAXToken).balance, withdrawRequestAmount_ + 10000 - 1);

        // new mechanism correct this
        assertEq(address(glAVAXToken).balance, withdrawRequestAmount_);
    }

    function test_POC_FirstWithdrawalRequestStolen() public {
        uint256 aliceDeposit_ = 10000 * 10**18; // big deposit so that lending pool and reserves can't cover withdraw

        deal(alice, aliceDeposit_);
        vm.prank(alice);
        glAVAXToken.deposit{value: aliceDeposit_}(0);

        uint256 initialNetworkBalance_ = networkWalletAddress.balance;

        uint256 withdrawable = aliceDeposit_ - glAVAXToken.MINIMUM_LIQUIDITY();

        vm.prank(deployer);
        glAVAXToken.rebalance();

        assertEq(wAvaxToken.balanceOf(address(glAVAXToken)), 0);
        assertEq(networkWalletAddress.balance, initialNetworkBalance_ + aliceDeposit_ - aliceDeposit_*glAVAXToken.reservePercentage()/1e4);
    
        vm.startPrank(alice);
        //glAVAXToken.approve(alice, type(uint256).max); // alice has to approve alice because of another issue. This is another
        glAVAXToken.withdraw(withdrawable);    // vulnerability that needs to be fixed seperately #17
        vm.stopPrank();

        assertEq(alice.balance, aliceDeposit_*glAVAXToken.reservePercentage()/1e4 + lendingPoolWavax * 1e18);
        assertEq(wAvaxToken.balanceOf(address(glAVAXToken)), 0);


        //////////////////////////////////////////////////////////////////////////////////////////
        // At this point, alice has created a withdrawal request and awaits for its fulfillment //
        //////////////////////////////////////////////////////////////////////////////////////////

        //deal(address(wAvaxToken), address(glAVAXToken), 10); // issue #16, no wAVAX available on deposit
        deal(bob, 10);
        vm.prank(bob);
        glAVAXToken.deposit{value: 10}(0);

        //vm.prank(address(glAVAXToken));
        //IWAVAX(address(wAvaxToken)).withdraw(10); // remove extra deposited 10 due to issue #16

        vm.startPrank(deployer);
        glAVAXToken.setNetworkTotal(glAVAXToken.totalNetworkAVAX() + 10); //increase network total or the cancel call will underflow 
                                                                          //due to not having enough shares
                                                                          //this is one of the reasons the request amounts should be in shares
        vm.stopPrank();

        //(,,,uint256 aliceWithdrawRequestAmount_,) = glAVAXToken.withdrawRequests(0);

        vm.startPrank(bob);       

        glAVAXToken.approve(bob, type(uint256).max);
        glAVAXToken.withdraw(9); // can only withdra

        vm.expectRevert("INDEX_OUT_OF_BOUNDS");
        glAVAXToken.cancel(1);

        // cancel correct one
        glAVAXToken.cancel(0);

        vm.stopPrank();

        // bob withdraw request
        assertEq(glAVAXToken.balanceOf(bob), 10);
    }

    function test_POC_FirstDepositStealsExistingAssets() public {
        uint256 reservePoolAmount_ = 10000;
        uint256 networkTotalAmount_ = 100;

        vm.startPrank(deployer);
        wAvaxToken.approve(address(reservePool), type(uint256).max); // Deposit to reserves
        reservePool.deposit(reservePoolAmount_);
        
        glAVAXToken.setNetworkTotal(networkTotalAmount_); // Increase network total to start validating
        vm.stopPrank();

        uint256 aliceDeposit_ = 1e18; 

        deal(alice, aliceDeposit_);
        vm.prank(alice);
        glAVAXToken.deposit{value: aliceDeposit_}(0);

        // alice has deposited 1/10e18 AVAX, but her balance increased to aliceDeposit_ + networkTotalAmount_ + reservePoolAmount_
        //assertEq(glAVAXToken.balanceOf(alice), aliceDeposit_ + networkTotalAmount_ + reservePoolAmount_);

        // with minimum liquidity stuck in contract alice can't withdraw more than deposit
        assertLt(glAVAXToken.balanceOf(alice), aliceDeposit_);

        // alice can't withdraw this amount
        vm.expectRevert("INSUFFICIENT_BALANCE");
        vm.prank(alice);
        glAVAXToken.withdraw(aliceDeposit_ + networkTotalAmount_ + reservePoolAmount_);

        // alice has withdrawn all the funds in glAVAX with only 1/10e18 AVAX
        //assertEq(alice.balance, aliceDeposit_ + networkTotalAmount_ + reservePoolAmount_);
    }
}