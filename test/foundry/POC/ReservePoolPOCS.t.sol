// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "@forge-std/Test.sol";
import {console} from "@forge-std/console.sol";

import {GlacierAddressBook} from "contracts/GlacierAddressBook.sol";
import {AaveV3Strategy} from "contracts/protocol/ReservePool/strategies/AaveV3Strategy.sol";
import {RewardsController} from "@aave/periphery-v3/contracts/rewards/RewardsController.sol";
import {StrategyMock} from "test/foundry/POC/mock/StrategyMock.sol";
import {StrategyMockUnfroze} from "test/foundry/POC/mock/StrategyMockUnfroze.sol";
import {IGReserveStrategy} from "contracts/interfaces/IGReserveStrategy.sol";
import {IRewardsController} from "@aave/periphery-v3/contracts/rewards/interfaces/IRewardsController.sol";
import {IPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";
import {IWAVAX} from "contracts/interfaces/IWAVAX.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

import {Fixture} from "test/foundry/Fixture.t.sol";

contract ReservePoolPOCTests is Fixture {
    address public constant aaveV3Address =
        0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address public constant rewardsController =
        0x929EC64c34a17401F460460D4B9390518E5B473e;

    uint256 public constant TEN_AVAX = 10 * 10 ** 18;
    uint256 public constant FIVE_AVAX = 5 * 10 ** 18;

    AaveV3Strategy public aaveStrategy;
    StrategyMock public strategyMockImplementation;

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);

    function setUp() public override {
        super.setUp();

        vm.prank(deployer);
        reservePool.setManager(deployer);

        deal(deployer, INITIAL_DEPLOYER_AVAX_BALANCE * 10 ** 18);
        deal(alice, INITIAL_ACTOR_AVAX_BALANCE * 10 ** 18);
    }

    function test_POC_FrozenStrategy() public {
        _deployStrategy();
        _deployMockStrategy();

        // Add frozen strategy
        vm.prank(deployer);
        StrategyMock strategyMock = StrategyMock(reservePool.addStrategy(strategyMockImplementation, 100, _getMockParamaters()));

        // Add normal strategy
        vm.prank(deployer);
        reservePool.addStrategy(aaveStrategy, 100, _getAaveParamaters());

        // Deposit in reserve pool
        vm.startPrank(deployer);
        wAvaxToken.approve(address(reservePool), TEN_AVAX);
        reservePool.deposit(TEN_AVAX);
        vm.stopPrank();

        // Strategy freezes
        strategyMock.setFrozen(true);

        // ReservePool: Deposit
        // Depositing will be impossible because frozen strategy will always revert
        vm.startPrank(deployer);
        wAvaxToken.approve(address(reservePool), TEN_AVAX);
        vm.expectRevert("FROZEN_STRATEGY");
        reservePool.deposit(TEN_AVAX);
        vm.stopPrank();

        // ReservePool: Withdraw
        // Withdrawing will be impossible because frozen strategy will always revert
        vm.prank(deployer);
        vm.expectRevert("FROZEN_STRATEGY");
        reservePool.withdraw(TEN_AVAX);

        // ReservePool: WithdrawAll
        // Withdrawing will be impossible because frozen strategy will always revert
        vm.prank(deployer);
        vm.expectRevert("FROZEN_STRATEGY");
        reservePool.withdrawAll();

        // ReservePool: ClearStrategies
        // Clearing strategies will be impossible because there are funds that cant be removed
        vm.prank(deployer);
        vm.expectRevert("ACTIVE_DEPOSITS");
        reservePool.clearStrategies();

        // ReservePool: AddStrategy
        // Adding strategies will be impossible because there are funds that cant be removed
        vm.prank(deployer);
        vm.expectRevert("ACTIVE_DEPOSITS");
        reservePool.addStrategy(aaveStrategy, 100,_getAaveParamaters());

        // Deposit in glAVAX
        vm.prank(alice);
        glAVAXToken.deposit{value: FIVE_AVAX}(0);

        // glAVAX: Rebalance
        // Rebalancing will be impossible if it has to deposit or withdraw from the reserve pool
        vm.prank(deployer);
        vm.expectRevert("FROZEN_STRATEGY");
        glAVAXToken.rebalance();

        vm.startPrank(deployer);
        // deploy contract who doesn't check if frozen
        StrategyMockUnfroze newMock = new StrategyMockUnfroze();
        reservePool.updateStrategy(1, address(strategyMockImplementation), address(newMock), "");
        (,address newImplementation) = reservePool.getStrategy(1);
        assertEq(address(newMock), newImplementation);
        reservePool.deposit(TEN_AVAX);
        vm.stopPrank();
    }

    function test_POC_MissingTotalReservesUpdate_IfAdminWithdrawsDirectly()
        public
    {
        vm.startPrank(deployer);
        _deployMockStrategy();

        // Add strategy
        StrategyMock strategyMock = StrategyMock(reservePool.addStrategy(strategyMockImplementation, 100, _getMockParamaters()));
        vm.stopPrank();
        
        vm.startPrank(address(reservePool));
        // Set deployer as a strategy user to withdraw
        strategyMock.grantRole(strategyMock.STRATEGY_USER(), deployer);
        vm.stopPrank();

        vm.startPrank(deployer);
        // Deposit in reserve pool
        wAvaxToken.approve(address(reservePool), TEN_AVAX);
        reservePool.deposit(TEN_AVAX);

        vm.stopPrank();

        vm.warp(block.timestamp + 100 days); // accrue rewards

        uint256 initialReserves_ = reservePool.totalReserves();

        vm.prank(deployer);
        strategyMock.withdraw(TEN_AVAX / 10);

        assertEq(initialReserves_, reservePool.totalReserves());
    }

    function test_POC_YieldStuck() public {
        vm.startPrank(deployer);

        _deployMockStrategy();

        // Add strategy
        reservePool.addStrategy(strategyMockImplementation, 100, _getMockParamaters());

        // Deposit in reserve pool

        wAvaxToken.approve(address(reservePool), TEN_AVAX);
        reservePool.deposit(TEN_AVAX);

        vm.stopPrank();

        vm.warp(block.timestamp + 100 days); // accrue rewards

        vm.prank(deployer);
        reservePool.withdraw(TEN_AVAX);

        // This is only true because the yield gets stuck in the reserve pool
        // and it is not taken into account for the totalReserves()
        assertGt(wAvaxToken.balanceOf(address(reservePool)), 0);
        assertGt(
            wAvaxToken.balanceOf(address(reservePool)),
            reservePool.totalReserves()
        );
    }

    function test_POC_SendDirectlyToReservePool() public {
        vm.startPrank(deployer);

        _deployMockStrategy();

        // Add strategy
        StrategyMock strategyMock = StrategyMock(reservePool.addStrategy(strategyMockImplementation, 100, _getMockParamaters()));
        vm.stopPrank();

        vm.startPrank(address(reservePool));
        // Set deployer as a strategy user to withdraw
        strategyMock.grantRole(strategyMock.STRATEGY_USER(), deployer);
        vm.stopPrank();

        vm.startPrank(deployer);
        // Deposit in reserve pool
        wAvaxToken.approve(address(reservePool), TEN_AVAX);
        reservePool.deposit(TEN_AVAX);

        vm.warp(block.timestamp + 100 days);

        strategyMock.mockWithdrawTransferDirectly(type(uint256).max);
        assertGt(wAvaxToken.balanceOf(address(reservePool)), TEN_AVAX); // balance increased due to rewards

        vm.stopPrank();
    }

    function test_POC_WrongWeightCalculations() public {
        vm.startPrank(deployer);

        _deployMockStrategy();

        // Add strategies
        reservePool.addStrategy(strategyMockImplementation, 50, _getMockParamaters());
        reservePool.addStrategy(strategyMockImplementation, 50, _getMockParamaters());

        // Deposit
        wAvaxToken.approve(address(reservePool), TEN_AVAX);
        reservePool.deposit(TEN_AVAX);

        // If default strategy weight is 100 and two strategies were added with 50 weight each
        // then at this point the reserve pool should have half of what was deposited.
        // The asserts prove it has more.        
        //assertGt(wAvaxToken.balanceOf(address(reservePool)), TEN_AVAX / 2);
        //assertEq(wAvaxToken.balanceOf(address(reservePool)),TEN_AVAX / 2 + TEN_AVAX / 4);

        // corrected 
        assertEq(wAvaxToken.balanceOf(address(reservePool)), TEN_AVAX / 2);

        // Withdraw
        reservePool.withdraw(TEN_AVAX);

        // It withdraws the full amount which is the wrong one since it does the same as the deposit.
        assertEq(wAvaxToken.balanceOf(address(reservePool)), 0);

        vm.stopPrank();
    }

    function test_POC_RequireBlocksWithdraw() public {
        vm.startPrank(deployer);

        _deployMockStrategy();

        // Add strategy
        StrategyMock strategyMock = StrategyMock(reservePool.addStrategy(strategyMockImplementation, 100, _getMockParamaters()));

        // Deposit in reserve pool
        wAvaxToken.approve(address(reservePool), TEN_AVAX);
        reservePool.deposit(TEN_AVAX);

        vm.stopPrank();

        // Withdraw fails because no yield was accrued and the require fires off.
        vm.prank(address(reservePool));
        vm.expectRevert("INSUFFICIENT_AMOUNT");
        strategyMock.mockWithdrawWithRequire(TEN_AVAX / 4);
    }

    function test_POC_AaveV3StrategyImpl() public {
        vm.startPrank(deployer);

        _deployStrategy();

        // Add strategy
        reservePool.addStrategy(aaveStrategy, 100, _getAaveParamaters());

        uint256 balanceUser = wAvaxToken.balanceOf(deployer);
        // Deposit in reserve pool
        wAvaxToken.approve(address(reservePool), TEN_AVAX);
        reservePool.deposit(TEN_AVAX);
        uint256 spent = balanceUser - wAvaxToken.balanceOf(deployer);
        assertEq(spent,TEN_AVAX);

        // Withdraw fails when getting to the function "claimAllRewardsToSelf()" for receiving the wrong asset.
        //vm.expectRevert();
        // withdraw success with the correction
        reservePool.withdraw(TEN_AVAX);

        // user recover all tokens
        assertEq(balanceUser,wAvaxToken.balanceOf(deployer));

        // address[] memory assets = new address[](1);
        // assets[0] = address(wAvaxToken);

        // // We mock the claimAllRewardsToSelf function so the previous problem doesn't occur.
        // vm.mockCall(
        //     rewardsController,
        //     abi.encodeWithSelector(
        //         IRewardsController.claimAllRewardsToSelf.selector,
        //         assets
        //     ),
        //     abi.encode()
        // );

        // // We try to withdraw again and when getting to the function withdraw of the aave pool it will fail.
        // vm.expectRevert();
        // reservePool.withdraw(TEN_AVAX);

        vm.stopPrank();
    }

    function _getUserCollateralBalance(
        address user_
    ) internal view returns (uint256) {
        (uint256 totalCollateralBase_, , , , , ) = IPool(aaveV3Address)
            .getUserAccountData(user_);
        return totalCollateralBase_;
    }

    function _deployStrategy() internal {
        // Deploy strategies
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

    function _deployMockStrategy() internal{
        strategyMockImplementation = new StrategyMock();
    }

    function _getMockParamaters() internal view returns (bytes memory) {
        return
            abi.encodeWithSelector(
                StrategyMock.initialize.selector,
                address(reservePool),
                address(wAvaxToken),
                aaveV3Address,
                rewardsController
            );
    }
}
