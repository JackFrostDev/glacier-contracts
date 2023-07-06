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

contract ReservePoolUnitTests is Fixture {

    address public constant aaveV3Address = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address public constant rewardsController = 0x929EC64c34a17401F460460D4B9390518E5B473e;

    uint256 public constant TEN_AVAX = 10 * 10**18;

    AaveV3Strategy public aaveStrategyImplementation;

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
        aaveStrategyImplementation = new AaveV3Strategy();
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

    function test_addStrategy() public {
        _deployStrategy();

        // Add new strategy
        vm.prank(deployer);      
        reservePool.addStrategy(aaveStrategyImplementation, 100, _getAaveParamaters());

        (GReservePool.Strategy memory strategy, address implementationAave) = reservePool.getStrategy(1);
        uint256 totalWeight = reservePool._totalWeight();

        // Strategy exists in list        
        assertEq(implementationAave, address(aaveStrategyImplementation));
        // Strategy count increases
        assertEq(reservePool._strategyCount(), 2);
        // Strategy weight calculates correctly
        assertEq(strategy.weight, 100);
        assertEq(totalWeight, 200);
    }

    function test_clearStrategies() public {
        _deployStrategy();

        // Add new strategy
        vm.prank(deployer);
        reservePool.addStrategy(aaveStrategyImplementation, 100,_getAaveParamaters());

        // Clear strategies
        vm.prank(deployer);
        reservePool.clearStrategies();

        // Clear strategies correctly resets
        assertEq(reservePool._strategyCount(), 1);
    }

    function test_revert_tooManyStrategies() public {
        _deployStrategy();

        uint256 maxStrategies = reservePool._maxStrategies();
        uint256 count = maxStrategies + 5;

        // Add multiple strategies
        for(uint256 i = 1; i < count; i++) {
            if(i >= maxStrategies) {
                // Expected revert
                vm.expectRevert("TOO_MANY_STRATEGIES");
                // Strategy cant exceed max strategies
                vm.prank(deployer);
                reservePool.addStrategy(aaveStrategyImplementation, 100,_getAaveParamaters());
            } else {
                // Add strategy
                vm.prank(deployer);
                reservePool.addStrategy(aaveStrategyImplementation, 100,_getAaveParamaters());
            }
        }
    }

    /****************************** Deposit ****************************************/

    // Logic

    function test_deposit() public {
        vm.startPrank(deployer);
        // Approve
        wAvaxToken.approve(address(reservePool), TEN_AVAX);
        
        // Deposit event emitted
        vm.expectEmit(true, true, true, true, address(reservePool));
        emit Deposit(deployer, TEN_AVAX);
        
        // Deposit 
        reservePool.deposit(TEN_AVAX);
        vm.stopPrank();

        // Deposits AVAX successfully into the reserve pool
        assertEq(reservePool.totalReserves(), TEN_AVAX);
        assertEq(wAvaxToken.balanceOf(address(reservePool)), TEN_AVAX);
    }

    function test_Deposit_withStrategies() public {
        _deployStrategy();

        vm.startPrank(deployer);
        // Add new strategy
        address newStrategy = reservePool.addStrategy(aaveStrategyImplementation, 100,_getAaveParamaters());
        // Approve
        wAvaxToken.approve(address(reservePool), TEN_AVAX);
        // Deposit
        reservePool.deposit(TEN_AVAX);
        vm.stopPrank();

        // Deposits AVAX successfully into the reserve pool with strategies
        assertEq(reservePool.totalReserves(), TEN_AVAX);
        
        // strategy contract holds the AVAX yield bearing token 
        (uint256 totalCollateralBase,,,,,) = IPool(aaveV3Address).getUserAccountData(newStrategy);
        assertGt(totalCollateralBase, 0); 
        assertGt(wAvaxToken.balanceOf(address(reservePool)), 0);
    }

    // Validation

    function test_revert_Deposit_IncorrectRole() public{
        // Expected revert
        vm.expectRevert("INCORRECT_ROLE");
        // Revert if called by a non-approved wallet
        vm.prank(alice);
        reservePool.deposit(TEN_AVAX);
    }

    function test_revert_ZeroDeposit() public{
        // Expected revert
        vm.expectRevert("ZERO_DEPOSIT");
        // Revert if depositing zero
        vm.prank(deployer);
        reservePool.deposit(0);
    }

    function test_revert_NoApproval() public{
        
        vm.startPrank(deployer);
        // Approve 0
        wAvaxToken.approve(address(reservePool), 0);
        // Expected revert
        vm.expectRevert();
        // Revert if depositing without approval
        reservePool.deposit(TEN_AVAX);
        vm.stopPrank();
    }

    function test_revert_Caller_Not_ReservePool() public{
        _deployStrategy();

        vm.startPrank(deployer);
        // Add new strategy
        AaveV3Strategy aaveStrategy = AaveV3Strategy(reservePool.addStrategy(aaveStrategyImplementation, 100,_getAaveParamaters()));

        vm.expectRevert("CALLER_NOT_RESERVE_POOL");
        aaveStrategy.deposit(TEN_AVAX);
        
        vm.expectRevert("CALLER_NOT_RESERVE_POOL");
        aaveStrategy.withdraw(TEN_AVAX);
        vm.stopPrank();
    }

    /****************************** Withdrawals ****************************************/

    // Logic

    function test_Withdraw() public{
        // Deposit
        vm.startPrank(deployer);
        wAvaxToken.approve(address(reservePool), TEN_AVAX);
        reservePool.deposit(TEN_AVAX);
        vm.stopPrank();

        // Withdraw event emitted
        vm.expectEmit(true, true, true, true, address(reservePool));
        emit Withdraw(deployer, TEN_AVAX);

        // Withdraw
        vm.prank(deployer);
        reservePool.withdraw(TEN_AVAX);

        // Withdraws AVAX successfully from the reserve pool
        assertEq(reservePool.totalReserves(), 0);
        assertEq(wAvaxToken.balanceOf(address(reservePool)), 0);
    }

    function test_WithdrawAll() public{
        // Deposit
        vm.startPrank(deployer);
        wAvaxToken.approve(address(reservePool), TEN_AVAX *3);
        reservePool.deposit(TEN_AVAX);
        reservePool.deposit(TEN_AVAX);
        reservePool.deposit(TEN_AVAX);
        vm.stopPrank();

        // Withdraw all
        vm.prank(deployer);
        reservePool.withdrawAll();

        // Withdraws all AVAX successfully from the reserve pool
        assertEq(reservePool.totalReserves(), 0);
        assertEq(wAvaxToken.balanceOf(address(reservePool)), 0);
    }

    function test_Withdraw_withStrategies() public{
        _deployStrategy();

        // Deposit with strategy
        vm.startPrank(deployer);
        reservePool.addStrategy(aaveStrategyImplementation, 100,_getAaveParamaters());
        wAvaxToken.approve(address(reservePool), TEN_AVAX);
        reservePool.deposit(TEN_AVAX);
        vm.stopPrank();   

        // Withdraw
        vm.prank(deployer);
        //reservePool.withdraw(TEN_AVAX);
    }

    // Validation

    function test_revert_Withdraw_IncorrectRole() public{
        // Expected revert
        vm.expectRevert("INCORRECT_ROLE");
        // Revert if called by a non-approved wallet
        vm.prank(alice);
        reservePool.withdraw(TEN_AVAX);
    }

    function test_revert_ZeroWithdraw() public{
        // Expected revert
        vm.expectRevert("ZERO_WITHDRAW");
        // Revert if withdrawing zero
        vm.prank(deployer);
        reservePool.withdraw(0);
    }

    function test_revert_NoReserves() public{
        // Expected revert
        vm.expectRevert("NO_RESERVES");
        // Revert if no reserves
        vm.prank(deployer);
        reservePool.withdrawAll();
    }
}