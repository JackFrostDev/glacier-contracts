// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Test } from "@forge-std/Test.sol";
import { console } from "@forge-std/console.sol";
import { GlacierAddressBook } from "contracts/GlacierAddressBook.sol";

import { Fixture } from "test/foundry/Fixture.t.sol";

contract GlAVAXUnitTests is Fixture {

    uint256 public constant TEN_AVAX = 10 * 10**18;
    uint256 public constant ONE_HUNDRED_AVAX = 100 * 10**18;
    uint256 public constant ONE_THOUSAND_AVAX = 1000 * 10**18;

    event Deposit(address indexed user, uint256 avaxAmount, uint64 referralCode);
    event Withdraw(address indexed user, uint256 avaxAmount);
    event UserWithdrawRequest(address indexed user, uint256 avaxAmount);
    event ProtocolWithdrawRequest(uint256 avaxAmount);
    event CancelWithdrawRequest(address indexed user, uint256 id);
    event Claim(address indexed user, uint256 avaxAmount);
    event NetworkThrottled(address indexed user);
    event RefillAVAX(uint256 amount);
    event FufilledUserWithdrawal(address indexed user, uint256 requestID, uint256 amount);

    function setUp() public override {
        super.setUp();

        deal(deployer, INITIAL_DEPLOYER_AVAX_BALANCE*10**18);
        deal(alice, INITIAL_ACTOR_AVAX_BALANCE*10**18);
        deal(bob, INITIAL_ACTOR_AVAX_BALANCE*10**18);
        deal(charlie, INITIAL_ACTOR_AVAX_BALANCE*10**18);
    }

    /****************************** SetUp ****************************************/

    function test_setUp_glAVAX() public {
        assertEq(glAVAXToken.name(), "Glacial AVAX");
        assertEq(glAVAXToken.symbol(), "glAVAX");
        assertEq(glAVAXToken.decimals(), 18);
    }

    function test_setUp_glAVAX_addressBook() public {
        GlacierAddressBook addressBookFromContract_ = glAVAXToken.addresses();
        assertEq(address(addressBookFromContract_), address(glacierAddressBook));
        assertEq(addressBookFromContract_.wavaxAddress(), glacierAddressBook.wavaxAddress());
        assertEq(addressBookFromContract_.usdcAddress(), glacierAddressBook.usdcAddress());
        assertEq(addressBookFromContract_.reservePoolAddress(), glacierAddressBook.reservePoolAddress());
        assertEq(addressBookFromContract_.lendingPoolAddress(), glacierAddressBook.lendingPoolAddress());
        assertEq(addressBookFromContract_.oracleAddress(), glacierAddressBook.oracleAddress());
        assertEq(addressBookFromContract_.networkWalletAddress(), glacierAddressBook.networkWalletAddress());
    }

    function test_setUp_EnableDeployerAsAdmin() public {
        assertTrue(glAVAXToken.hasRole(bytes32(0x00), deployer));
    }

    function test_setUp_EnableDeployerAsNetworkManager() public {
        assertTrue(glAVAXToken.hasRole(glAVAXToken.NETWORK_MANAGER(), deployer));
    }

    function test_setUp_ReservePercentageIsSetCorrectly() public {
        vm.prank(deployer);
        glAVAXToken.setReservePercentage(reservePercentage);
        assertEq(glAVAXToken.reservePercentage(), 1000);
    }
    
    function test_setUp_NetworkTotalIsSetCorrectly() public {
        uint256 amount_ = 10000 ether;
        vm.prank(deployer);
        glAVAXToken.setNetworkTotal(amount_);
        assertEq(glAVAXToken.totalNetworkAVAX(), amount_);
        assertEq(glAVAXToken.totalAVAX(), amount_);
    }

    /****************************** Deposit ****************************************/

    // Logic

    function test_Deposit() public {
        // Save balance before deposit
        uint256 balanceBefore = wAvaxToken.balanceOf(address(glAVAXToken));
        // Ensure event emits correctly
        vm.expectEmit(true, false, false, true, address(glAVAXToken));
        emit Deposit(alice, TEN_AVAX, 0);

        // Deposited AVAX successfully (contract receives WAVAX)
        vm.prank(alice);
        glAVAXToken.deposit{ value: TEN_AVAX }(0);

        uint256 withdrawable = TEN_AVAX - glAVAXToken.MINIMUM_LIQUIDITY();

        // Save balance after deposit
        uint256 balanceAfter = wAvaxToken.balanceOf(address(glAVAXToken));
        // User receives the correct amount of glAVAX token
        assertEq((balanceAfter - balanceBefore), TEN_AVAX);
        assertEq(glAVAXToken.balanceOf(alice), withdrawable);
    }

    function test_Deposit_afterRebalance() public {
        // Deposit
        vm.prank(alice);
        glAVAXToken.deposit{ value: TEN_AVAX }(0);
        // Rebalance
        vm.prank(deployer);
        glAVAXToken.rebalance();
        // Deposit
        vm.prank(alice);
        glAVAXToken.deposit{ value: TEN_AVAX }(0);

        // User receives the correct amount of glAVAX token after rebasing
        assertEq(glAVAXToken.balanceOf(alice), TEN_AVAX * 2 - glAVAXToken.MINIMUM_LIQUIDITY());
    }

    // Validation

    function test_revert_Deposit_ZeroDeposit() public {
        // Expected revert
        vm.expectRevert("ZERO_DEPOSIT");
        // Revert if trying to deposit zero
        vm.prank(charlie);
        glAVAXToken.deposit{ value: 0 }(0);
    }

    function test_revert_glAVAX_AVAX_Exchange() public view {
        console.log("avaxFromGlavax not implemented");
    }

    function test_revert_Direct_Deposit() public {
        // origin different from sender expected to success
        vm.prank(charlie, alice);        
        (bool sent, ) = payable(glAVAXToken).call{value:1 ether, gas:50000}("");
        // Expected success 
        assertEq(sent,true);

        // Revert if trying to send direct avax
        vm.prank(charlie, charlie);

        (bool sent2, ) = payable(glAVAXToken).call{value:1 ether, gas:50000}("");
        // Expected failed 
        assertEq(sent2,false);
    }


    /****************************** Rebalance ****************************************/

    // Logic

    function test_Rebalance() public {
        // Set up deposits
        vm.prank(alice);
        glAVAXToken.deposit{ value: TEN_AVAX }(0);
        vm.prank(bob);
        glAVAXToken.deposit{ value: ONE_HUNDRED_AVAX }(0);
        // Save reserve and network balance before rebalance
        uint256 reserveBalanceBefore = wAvaxToken.balanceOf(address(reservePool));
        uint256 networkBalanceBefore = networkWalletAddress.balance;

        // Rebalanced glAVAX contract successfully
        vm.prank(deployer);
        glAVAXToken.rebalance();

        // Save reserve and network balance after rebalance
        uint256 reserveBalanceAfter = wAvaxToken.balanceOf(address(reservePool));
        uint256 networkBalanceAfter = networkWalletAddress.balance;
        // Reserve pool successfully filled up
        assertGt((reserveBalanceAfter - reserveBalanceBefore), 0);
        assertEq((reserveBalanceAfter - reserveBalanceBefore), (TEN_AVAX + ONE_HUNDRED_AVAX) * glAVAXToken.reservePercentage() / 1e4);
        // Excess AVAX sent to the network
        assertGt((networkBalanceAfter - networkBalanceBefore), 0);
        assertEq((networkBalanceAfter - networkBalanceBefore), (TEN_AVAX + ONE_HUNDRED_AVAX) * (1e4 - glAVAXToken.reservePercentage()) / 1e4);
    }

    // Validation

    function test_revert_Rebalance_IncorrectRole() public {
        // Expected revert
        vm.expectRevert("INCORRECT_ROLE");
        // Revert if called by a non-network manager account
        vm.prank(alice);
        glAVAXToken.rebalance();
    }

    function test_Rebalance_glAVAX_AVAX_Exchange() public view {
        console.log("avaxFromGlavax not implemented");
    }

    /****************************** Withdraw ****************************************/
    
    function _setUpDeposits() internal {
        vm.prank(alice);
        glAVAXToken.deposit{ value: ONE_THOUSAND_AVAX }(0);
        vm.prank(bob);
        glAVAXToken.deposit{ value: ONE_THOUSAND_AVAX }(0);
        vm.prank(deployer);
        glAVAXToken.rebalance();
        vm.prank(charlie);
        glAVAXToken.deposit{ value: ONE_HUNDRED_AVAX }(0);
        vm.prank(bob);
        glAVAXToken.approve(bob, ONE_THOUSAND_AVAX);
    }

    // logic

    function test_Withdraw() public {
        // Set up deposits
        _setUpDeposits();
        // Ensure event emits correctly
        vm.expectEmit(true, false, false, true, address(glAVAXToken));
        emit Withdraw(alice, TEN_AVAX);
        // Save balance before withdraw
        uint256 balanceBefore = alice.balance;

        // Withdraw
        vm.prank(alice);
        glAVAXToken.withdraw(TEN_AVAX);

        // Save balance after withdraw
        uint256 balanceAfter = alice.balance;
        // User receives correct amount of AVAX
        assertGt((balanceAfter - balanceBefore), 0);        
    }

    function test_Withdraw_Throttle() public {
        // Set up deposits
        _setUpDeposits();
        
        // Withdraw
        vm.prank(bob);
        glAVAXToken.withdraw(ONE_THOUSAND_AVAX);

        // Network correctly throttles when a large withdrawal is made
        assertEq(glAVAXToken.throttleNetwork(), true);
    }

    // Validation

    function test_revert_Withdraw_ZeroWithdraw() public {
        // Expected revert
        vm.expectRevert("ZERO_WITHDRAW");
        // Revert if trying to withdraw zero
        vm.prank(alice);
        glAVAXToken.withdraw(0);
    }

    function test_revert_Withdraw_InsufficientBalance() public {
        // Expected revert
        vm.expectRevert("INSUFFICIENT_BALANCE");
        // Revert if trying to withdraw with no glAVAX balance
        vm.prank(daniel);
        glAVAXToken.withdraw(TEN_AVAX);
    }

    /****************************** Withdraw Request ****************************************/

    // General

    function test_WithdrawRequest() public {
        // Set up deposits
        _setUpDeposits();
        // Ensure event emits correctly
        vm.expectEmit(true, false, false, false, address(glAVAXToken));
        emit UserWithdrawRequest(bob, 0); // Check event with address and any value for second param
        // When withdrawing a large amount a withdraw request is created
        vm.prank(bob);
        glAVAXToken.withdraw(ONE_THOUSAND_AVAX);
        

        // Request specifications
        uint256 requestId = glAVAXToken.requestIdFromUserIndex(bob, 0);
        uint256 requestAmount = glAVAXToken.requestById(requestId).amount; 
        uint256 withdrawRequestAmount = (ONE_THOUSAND_AVAX - (lendingPoolWavax*10**wAvaxToken.decimals()) - ONE_HUNDRED_AVAX) - ((ONE_THOUSAND_AVAX + ONE_THOUSAND_AVAX) / 10);
        // Withdraw amount correct
        assertEq(withdrawRequestAmount, requestAmount);
    }

    function test_revert_WithdrawRequest_InsufficientBalance() public {
        // Set up deposits
        _setUpDeposits();
        // Withdraw a large amount
        vm.prank(bob);
        glAVAXToken.withdraw(ONE_THOUSAND_AVAX);
        // Expected revert
        vm.expectRevert("INSUFFICIENT_BALANCE");

        // Revert if trying to withdraw more than allowed
        vm.prank(bob);
        glAVAXToken.withdraw(100);
    }

    // Cancel

    function test_Cancel() public {
        // Set up deposits
        _setUpDeposits();
        // Withdraw a large amount
        vm.prank(bob);
        glAVAXToken.withdraw(ONE_THOUSAND_AVAX);
        // Ensure event emits correctly
        vm.expectEmit(true, false, false, false, address(glAVAXToken));
        emit CancelWithdrawRequest(bob, 0); // Check event with address and any value for second param

        // Cancel withdraw
        vm.prank(bob);
        glAVAXToken.cancel(0);

        // Check balances
        uint256 balance = glAVAXToken.balanceOf(bob);
        uint256 withdrawRequestAmount = (ONE_THOUSAND_AVAX - (lendingPoolWavax*10**wAvaxToken.decimals()) - ONE_HUNDRED_AVAX) - ((ONE_THOUSAND_AVAX + ONE_THOUSAND_AVAX) / 10);
        // User receives back their glAVAX
        assertEq(balance, withdrawRequestAmount);
    }

    function test_CancelAll() public {
        // Set up deposits
        _setUpDeposits();
        // Withdraws
        vm.startPrank(bob);
        glAVAXToken.withdraw(ONE_THOUSAND_AVAX - ONE_HUNDRED_AVAX); // Req 1   (Index 0)
        glAVAXToken.withdraw(100);                                  // Req 2   (Index 1)
        glAVAXToken.withdraw(100);                                  // Req 3   (Index 2)
        glAVAXToken.withdraw(100);                                  // Req 4   (Index 3)
        glAVAXToken.withdraw(100);                                  // Req 5   (Index 4)
        glAVAXToken.withdraw(100);                                  // Req 6   (Index 5)
        glAVAXToken.withdraw(100);                                  // Req 7   (Index 6)
        

        // Cancel All
        glAVAXToken.cancelAll();
        vm.stopPrank();

        for(uint256 i = 0; i <= 6; i++){
            // Expected revert
            vm.expectRevert("INDEX_OUT_OF_BOUNDS");
            // Request is no longer readable in the contract
            glAVAXToken.requestIdFromUserIndex(bob, i);
        }    
    }

    function test_revert_Cancel_NotReadable() public {
        // Set up deposits
        _setUpDeposits();
        // Withdraw a large amount
        vm.prank(bob);
        glAVAXToken.withdraw(ONE_THOUSAND_AVAX);
        
        // Cancel withdraw
        vm.prank(bob);
        glAVAXToken.cancel(0);

        // Expected revert
        vm.expectRevert("INDEX_OUT_OF_BOUNDS");
        // Request is no longer readable in the contract
        glAVAXToken.requestIdFromUserIndex(bob, 0);
    }

    // Claim

    function test_Claim() public {
        // Set up deposits
        _setUpDeposits();
        // Withdraws
        vm.startPrank(bob);
        glAVAXToken.withdraw(ONE_THOUSAND_AVAX - ONE_HUNDRED_AVAX);
        glAVAXToken.withdraw(100);                                  
        glAVAXToken.withdraw(100);                                  
        vm.stopPrank();
        // Fulfill withdraws
        vm.prank(deployer);

        glAVAXToken.fufillWithdrawal{ value:ONE_THOUSAND_AVAX }();
        // Ensure event emits correctly
        vm.expectEmit(true, false, false, false, address(glAVAXToken)); 
        emit Claim(bob, 0); // Check event with address and any value for second param

        // Save balance before claim
        uint256 balanceBefore = bob.balance;
        // 'Claim All' successfully claims every pending withdrawal request
        vm.prank(bob);
        glAVAXToken.claimAll();

        // Save balance after claim
        uint256 balanceAfter = bob.balance;
        // User receives AVAX from claiming
        assertGt(balanceAfter - balanceBefore, 0);
    }

    // not compatible with new mechanism
    // function test_revert_Claim_RequestNotFufilled() public {
    //     // Set up deposits
    //     _setUpDeposits();
    //     // Withdraw
    //     vm.prank(bob);
    //     glAVAXToken.withdraw(ONE_THOUSAND_AVAX);
    //     // Expected revert
    //     vm.expectRevert("NOT_CLAIMABLE");

    //     // User cannot claim a request that isn't yet fufilled
    //     vm.prank(bob);
    //     glAVAXToken.claim(0);

    // }

    function test_revert_Claim_RequestAlreadyClaimed() public {
        // Set up deposits
        _setUpDeposits();
        // Withdraw
        vm.prank(bob);
        glAVAXToken.withdraw(ONE_THOUSAND_AVAX);
        // Fulfill withdraw
        vm.prank(deployer);
        glAVAXToken.fufillWithdrawal{ value:ONE_THOUSAND_AVAX }();
        // Claim
        vm.prank(bob);
        glAVAXToken.claim(0);

        // Expected revert
        vm.expectRevert("NOT_CLAIMABLE");
        // User cannot claim a request that has already been claimed
        vm.prank(bob);
        glAVAXToken.claim(0);
    }
}
