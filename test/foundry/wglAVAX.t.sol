// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;


import { console } from "@forge-std/console.sol";

import { Fixture } from "./Fixture.t.sol";
import { wglAVAX } from "contracts/protocol/GlacialAVAX/wglAVAX.sol";

contract WglAVAXUnitTests is Fixture {

    function setUp() public override {
        super.setUp();
    }

    function testSetUp() public {
        assertEq(wglAVAXToken.name(), "Wrapped Glacial AVAX");
        assertEq(wglAVAXToken.symbol(), "wglAVAX");
        assertEq(wglAVAXToken.decimals(), 18);
        assertEq(address(wglAVAXToken.glAVAX()), address(glAVAXToken));
    }

    /****************************** Wrap ****************************************/ 

    function testWrap_revertIfZeroAmount() public {
        vm.expectRevert("ZERO_DEPOSIT");
        wglAVAXToken.wrap(0);
    }

    function testWrap_revertIfToZeroAddress() public {
        deal(address(0), 1 ether);
        vm.prank(address(0));

        vm.expectRevert("ERC20: mint to the zero address");
        wglAVAXToken.wrap(1 ether);
    }

    function testWrap_ok() public {
        _wrap(alice, 10 ether);
        _wrap(bob, 5 ether);
    }

    /****************************** Unwrap ****************************************/ 

    function testUnwrap_revertIfZeroAmount() public {
        vm.expectRevert("ZERO_WITHDRAW");
        wglAVAXToken.unwrap(0);
    }

    function testUnwrap_revertIfAmountBiggerThanBalance() public {
        _wrap(alice, 10 ether);

        vm.expectRevert("ERC20: burn amount exceeds balance");
        wglAVAXToken.unwrap(20 ether);
    }

    function testUnwrap_revertIfToZeroAddress() public {
        vm.expectRevert("ERC20: burn from the zero address");

        vm.prank(address(0));
        wglAVAXToken.unwrap(20 ether);
    }

    function testUnwrap_ok() public {
        // we block this minimun liquidity on first deposit
        uint256 minLiquidity = glAVAXToken.MINIMUM_LIQUIDITY();

        _wrap(alice, 10 ether);
        _wrap(bob, 5 ether);
        _unwrap(alice, 10 ether - minLiquidity);
        _unwrap(bob, 5 ether);
    }


    function _wrap(address user_, uint256 amount_) internal {
        vm.deal(user_, amount_);

        uint256 initialUserGlAVAXTokenBalance_ = glAVAXToken.balanceOf(user_);
        uint256 initialUserWglAVAXTokenBalance_ = wglAVAXToken.balanceOf(user_);
        uint256 initialWrapperGlAVAXTokenBalance_ = glAVAXToken.balanceOf(address(wglAVAXToken));
        uint256 initialWglAVAXTotalSupply_ = wglAVAXToken.totalSupply();

        uint256 amountAvailable = amount_;
        if(glAVAXToken._totalShares() == 0){
            // we block this minimun liquidity on first deposit
            amountAvailable -= glAVAXToken.MINIMUM_LIQUIDITY();
        }

        vm.startPrank(user_);

        glAVAXToken.deposit{value: amount_}(0);
        assertEq(glAVAXToken.balanceOf(user_), initialUserGlAVAXTokenBalance_ + amountAvailable);

        glAVAXToken.approve(address(wglAVAXToken), amountAvailable);
        uint256 wglAvaxAmount = wglAVAXToken.wrap(amountAvailable);
        assertEq(wglAvaxAmount, amountAvailable);
        assertEq(wglAVAXToken.balanceOf(user_), initialUserWglAVAXTokenBalance_ + amountAvailable);
        assertEq(glAVAXToken.balanceOf(address(wglAVAXToken)), initialWrapperGlAVAXTokenBalance_ + amountAvailable);
        assertEq(wglAVAXToken.totalSupply(), initialWglAVAXTotalSupply_ + amountAvailable);

        vm.stopPrank();
    }

    function _unwrap(address user_, uint256 amount_) internal {
        uint256 initialUserGlAVAXTokenBalance_ = glAVAXToken.balanceOf(user_);
        uint256 initialUserWglAVAXTokenBalance_ = wglAVAXToken.balanceOf(user_);
        uint256 initialWrapperGlAVAXTokenBalance_ = glAVAXToken.balanceOf(address(wglAVAXToken));
        uint256 initialWglAVAXTotalSupply_ = wglAVAXToken.totalSupply();

        vm.prank(user_);
        uint256 wglAvaxAmount = wglAVAXToken.unwrap(amount_);

        assertEq(wglAvaxAmount, amount_);
        assertEq(wglAVAXToken.balanceOf(user_), initialUserWglAVAXTokenBalance_ - amount_);
        assertEq(glAVAXToken.balanceOf(address(wglAVAXToken)), initialWrapperGlAVAXTokenBalance_ - amount_);
        assertEq(glAVAXToken.balanceOf(user_), initialUserGlAVAXTokenBalance_ + amount_);
        assertEq(wglAVAXToken.totalSupply(), initialWglAVAXTotalSupply_ - amount_);
    }

    /****************************** ERC20 ****************************************/ 

    // transfer

    function testTransfer_revertIfAmountBiggerThanBalance() public {
        _wrap(alice, 10 ether);

        vm.expectRevert("ERC20: transfer amount exceeds balance");
        vm.prank(alice);
        wglAVAXToken.transfer(bob, 11 ether);
    }

    function testTransfer_revertIfFromIsZeroAddress() public {
        deal(address(wglAVAXToken), address(0), 10 ether);

        vm.expectRevert("ERC20: transfer from the zero address");
        vm.prank(address(0));
        wglAVAXToken.transfer(bob, 10 ether);
    }

    function testTransfer_revertIfToIsZeroAddress() public {
        _wrap(alice, 10 ether);

        vm.expectRevert("ERC20: transfer to the zero address");
        vm.prank(alice);
        wglAVAXToken.transfer(address(0), 10 ether);
    }

    function testTransfer_ok() public {
        _wrap(alice, 10 ether);

        // we block this minimun liquidity on first deposit
        uint256 minLiquidity = glAVAXToken.MINIMUM_LIQUIDITY();

        vm.prank(alice);
        wglAVAXToken.transfer(bob, 6 ether);
        assertEq(wglAVAXToken.balanceOf(alice), 4 ether - minLiquidity);
        assertEq(wglAVAXToken.balanceOf(bob), 6 ether);
        assertEq(wglAVAXToken.totalSupply(), 10 ether - minLiquidity);
    }

    // approve

    function testApprove_revertIfOwnerIsZeroAddress() public {
        vm.expectRevert("ERC20: approve from the zero address");
        vm.prank(address(0));
        wglAVAXToken.approve(bob, 6 ether);
    }

    function testApprove_revertIfSpenderIsZeroAddress() public {
        vm.expectRevert("ERC20: approve to the zero address");
        vm.prank(alice);
        wglAVAXToken.approve(address(0), 6 ether);
    }

    function testApprove_ok() public {
        _approve(alice, bob, 6 ether);
    }

    // transferFrom

    function testTransferFrom_ok() public {
        _wrap(alice, 10 ether);

        _approve(alice, bob, 6 ether);

        // we block this minimun liquidity on first deposit
        uint256 minLiquidity = glAVAXToken.MINIMUM_LIQUIDITY();

        vm.prank(bob);
        wglAVAXToken.transferFrom(alice, bob, 6 ether);
        assertEq(wglAVAXToken.balanceOf(alice), 4 ether - minLiquidity);
        assertEq(wglAVAXToken.balanceOf(bob), 6 ether);
        assertEq(wglAVAXToken.totalSupply(), 10 ether - minLiquidity);
    }

    // increaseAllowance

    function testIncreaseAllowance_revertIfOwnerIsZeroAddress() public {
        vm.expectRevert("ERC20: approve from the zero address");
        vm.prank(address(0));
        wglAVAXToken.increaseAllowance(bob, 6 ether);
    }

    function testIncreaseAllowance_revertIfSpenderIsZeroAddress() public {
        vm.expectRevert("ERC20: approve to the zero address");
        vm.prank(alice);
        wglAVAXToken.increaseAllowance(address(0), 6 ether);
    }

    function testIncreaseAllowance_ok() public {
        vm.prank(alice);
        wglAVAXToken.increaseAllowance(bob, 6 ether);
        assertEq(wglAVAXToken.allowance(alice, bob), 6 ether);
    }

    // decreaseAllowance

    function testDecreaseAllowance_revertIfOwnerIsZeroAddress() public {
        _manualApprove(address(wglAVAXToken), address(0), bob, 6 ether);

        vm.expectRevert("ERC20: approve from the zero address");
        vm.prank(address(0));
        wglAVAXToken.decreaseAllowance(bob, 6 ether);
    }

    function testDecreaseAllowance_revertIfSpenderIsZeroAddress() public {
        _manualApprove(address(wglAVAXToken), bob, address(0), 6 ether);

        vm.expectRevert("ERC20: approve to the zero address");
        vm.prank(bob);
        wglAVAXToken.decreaseAllowance(address(0), 6 ether);
    }

    function testDecreaseAllowance_revertIfBelowZero() public {
        _approve(alice, bob, 6 ether);

        vm.prank(alice);
        vm.expectRevert("ERC20: decreased allowance below zero");
        wglAVAXToken.decreaseAllowance(bob, 10 ether);
    }

    function testDecreaseAllowance_ok() public {
        _approve(alice, bob, 6 ether);

        vm.prank(alice);
        wglAVAXToken.decreaseAllowance(bob, 6 ether);
        assertEq(wglAVAXToken.allowance(alice, bob), 0);
    }

    function _approve(address owner_, address spender_, uint256 amount_) internal {
        vm.prank(owner_);
        wglAVAXToken.approve(spender_, amount_);
        assertEq(wglAVAXToken.allowance(owner_, spender_), amount_);
    }

    function _manualApprove(address token_, address owner_, address spender_, uint256 amount_) internal {
        // approve by setting storage slot manually
        vm.record();
        (bool success, ) = token_.call(abi.encodeWithSignature("allowance(address,address)", owner_, spender_));
        require(success);
        (bytes32[] memory reads_, ) = vm.accesses(address(wglAVAXToken));
        vm.store(address(wglAVAXToken), reads_[reads_.length - 1], bytes32(uint256(amount_)));
    }
}
