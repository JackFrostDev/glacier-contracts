// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Test } from "@forge-std/Test.sol";
import { console } from "@forge-std/console.sol";
import { GlacierAddressBook } from "contracts/GlacierAddressBook.sol";
import { AaveV3Strategy } from "contracts/protocol/ReservePool/strategies/AaveV3Strategy.sol";
import { IGReserveStrategy } from "contracts/interfaces/IGReserveStrategy.sol";
import { IRewardsController } from "@aave/periphery-v3/contracts/rewards/interfaces/IRewardsController.sol";
import { IPool } from "@aave/core-v3/contracts/interfaces/IPool.sol";
import { GReservePool } from "contracts/protocol/ReservePool/GReservePool.sol";

import { Fixture } from "test/foundry/Fixture.t.sol";

contract ReservePoolFuzzTests is Fixture {

    address public constant aaveV3Address = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address public constant rewardsController = 0x929EC64c34a17401F460460D4B9390518E5B473e;

    uint256 public constant TEN_AVAX = 10 * 10**18;

    AaveV3Strategy public aaveStrategy;

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);

    function setUp() public override {
        super.setUp();

        vm.prank(deployer);
        reservePool.setManager(deployer);

        deal(deployer, INITIAL_DEPLOYER_AVAX_BALANCE*10**18);
    }

    /****************************** Admin Function ****************************************/
    function _deployStrategy() internal {
        // Deploy strategy
        aaveStrategy = new AaveV3Strategy();
    }

    function _getAaveParamaters() internal view returns (bytes memory) {
        return
            abi.encodeWithSelector(
                AaveV3Strategy.initialize.selector,
                address(reservePool),
                address(wAvaxToken),
                aaveV3Address,
                rewardsController
            );
    }

    function test_fuzz_addStrategy(uint256 weight_, uint256 count_) public {
        _deployStrategy();

        weight_ = bound(weight_, 0, 1000);
        count_ = bound(count_, 1, 10);

        // Add new strategy
        uint256 maxStrategies = reservePool._maxStrategies();
        uint256 totalWeigth_ = 100;

        // Add multiple strategies
        for(uint64 i = 1; i < count_; i++) {
            if(i >= maxStrategies) {
                // Expected revert
                vm.expectRevert("TOO_MANY_STRATEGIES");
                // Strategy cant exceed max strategies
                vm.prank(deployer);
                reservePool.addStrategy(aaveStrategy, weight_, _getAaveParamaters());
            } else {
                // Add strategy
                vm.prank(deployer);
                reservePool.addStrategy(aaveStrategy, weight_, _getAaveParamaters());

                (GReservePool.Strategy memory strategy, address implementationAave) = reservePool.getStrategy(i);
                uint256 totalWeight = reservePool._totalWeight();
                totalWeigth_ += weight_;       

                assertEq(implementationAave, address(aaveStrategy));
                assertEq(reservePool._strategyCount(), 1+i);
                assertEq(strategy.weight, weight_);
                assertEq(totalWeight, totalWeigth_);
            }
        }
    }

    /****************************** Deposit ****************************************/

    function test_fuzz_deposit(uint256 depositAmount_) public {
        // Limit deposit amount 
        depositAmount_ = bound(depositAmount_, 0, deployer.balance);

        if(depositAmount_ == 0) {
            // Expected revert
            vm.expectRevert("ZERO_DEPOSIT");
            // Revert if depositing zero
            vm.prank(deployer);
            reservePool.deposit(depositAmount_);
        } else {            
            vm.startPrank(deployer);
            // Approve
            wAvaxToken.approve(address(reservePool), depositAmount_);

            // Deposit event emitted
            vm.expectEmit(true, true, true, true, address(reservePool));
            emit Deposit(deployer, depositAmount_);

            // Deposit
            reservePool.deposit(depositAmount_);
            vm.stopPrank();

            // Deposits AVAX successfully into the reserve pool
            assertEq(reservePool.totalReserves(), depositAmount_);
            assertEq(wAvaxToken.balanceOf(address(reservePool)), depositAmount_);
        }
    }

    function test_fuzz_Deposit_withStrategies(uint256 depositAmount_) public {
        _deployStrategy();
        
        vm.prank(deployer);
        reservePool.addStrategy(aaveStrategy, 100, _getAaveParamaters());

        // Limit deposit amount 
        depositAmount_ = bound(depositAmount_, 0, deployer.balance);

        // Check for deposit zero in both strategies
        if(depositAmount_ == 0 || (100 * depositAmount_ / reservePool._totalWeight()) == 0) { 
            // Revert if depositing zero
            vm.startPrank(deployer);
            wAvaxToken.approve(address(reservePool), depositAmount_);
           
            // Expected revert
            vm.expectRevert("ZERO_DEPOSIT");   
            reservePool.deposit(depositAmount_);
            vm.stopPrank();
        } else {
            vm.startPrank(deployer);
            // Approve
            wAvaxToken.approve(address(reservePool), depositAmount_);

            // Deposit event emitted
            vm.expectEmit(true, true, true, true, address(reservePool));
            emit Deposit(deployer, depositAmount_);

            // Deposit
            reservePool.deposit(depositAmount_);
            vm.stopPrank();

            // Deposits AVAX successfully into the reserve pool
            assertEq(reservePool.totalReserves(), depositAmount_);
            // Reserve pool holds the AVAX yield bearing token 
            assertGt(wAvaxToken.balanceOf(address(reservePool)), 0);
        }
        
        
    }

    /****************************** Withdrawals ****************************************/

    // Logic

    function test_fuzz_Withdraw(uint256 depositAmount_, uint256 withdrawAmount_) public{
        // Limit deposit and withdraw amount 
        depositAmount_ = bound(depositAmount_, 1, deployer.balance);
        withdrawAmount_ = bound(withdrawAmount_, 0, depositAmount_);

        vm.startPrank(deployer);
        wAvaxToken.approve(address(reservePool), depositAmount_);
        reservePool.deposit(depositAmount_);
        vm.stopPrank();

        if(withdrawAmount_ == 0){
            // Expected revert
            vm.expectRevert("ZERO_WITHDRAW");
            // Revert if withdrawing zero
            vm.prank(deployer);
            reservePool.withdraw(withdrawAmount_);
        } else {
            // Withdraw event emitted
            vm.expectEmit(true, true, true, true, address(reservePool));
            emit Withdraw(deployer, withdrawAmount_);

            // Withdraw
            vm.prank(deployer);
            reservePool.withdraw(withdrawAmount_);

            // Withdraws AVAX successfully from the reserve pool
            assertEq(reservePool.totalReserves(), depositAmount_ - withdrawAmount_);
            assertEq(wAvaxToken.balanceOf(address(reservePool)), depositAmount_ - withdrawAmount_);
        }
    }

    function test_fuzz_Withdraw_withStrategies() public{

    }
}