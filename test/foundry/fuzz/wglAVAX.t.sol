// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { console } from "@forge-std/console.sol";

import { Fixture } from "../Fixture.t.sol";

contract WglAVAXFuzzTests is Fixture {
    function setUp() public override {
        super.setUp();
    }

    mapping(address => uint256) public userBalance;

    bool firstDepositer = true;

    function test_fuzz_wrap_unwrap(address[] memory users_, uint256[] calldata wrapAmounts_, uint256[] calldata unwrapAmounts_) public {
        uint256 numWrappers_ = users_.length < wrapAmounts_.length ? users_.length : wrapAmounts_.length;
        uint256 numUsers_ = numWrappers_ < unwrapAmounts_.length ? numWrappers_ : unwrapAmounts_.length;
        vm.assume(numUsers_ < 3);
        vm.assume(numUsers_ > 0);

        // Wrap
        for (uint256 i_ = 0; i_ < numUsers_; i_++) {
            uint256 wrapAmount_ = wrapAmounts_[i_];

            // user might be an existing contract so it's best to use random addresses
            users_[i_] = address(uint160(uint256(keccak256(abi.encodePacked(users_[i_])))));
            vm.label(users_[i_], string(abi.encodePacked("user", vm.toString(i_))));
            
            // limit wrap amount of user to prevent overflow
            wrapAmount_ = bound(wrapAmount_, 0, type(uint256).max - userBalance[users_[i_]]);
            
            // limit wrap amount of glAVAXToken to prevent overflow
            wrapAmount_ = bound(wrapAmount_, 0, type(uint256).max - address(glAVAXToken).balance);

            // limit wrap amount of wAVAX to prevent overflow
            wrapAmount_ = bound(wrapAmount_, 0, type(uint256).max - address(wAvaxToken).balance);

            _wrap(users_[i_], wrapAmount_);
            userBalance[users_[i_]] += wrapAmount_;
        }

        // Unwrap
        for (uint256 i_ = 0; i_ < numUsers_; i_++) {
            _unwrap(users_[i_], unwrapAmounts_[i_]);
        }
    }

    function _wrap(address user_, uint256 amount_) internal {
        vm.deal(user_, amount_);

        uint256 initialUserGlAVAXTokenBalance_ = glAVAXToken.balanceOf(user_);
        uint256 initialUserWglAVAXTokenBalance_ = wglAVAXToken.balanceOf(user_);
        uint256 initialWrapperGlAVAXTokenBalance_ = glAVAXToken.balanceOf(address(wglAVAXToken));
        uint256 initialWglAVAXTotalSupply_ = wglAVAXToken.totalSupply();

        vm.startPrank(user_);

        uint256 shares = glAVAXToken._totalShares();
        uint256 minimum = glAVAXToken.MINIMUM_LIQUIDITY();
        // deposit
        if (amount_ == 0) {
            vm.expectRevert("ZERO_DEPOSIT");
            glAVAXToken.deposit{value: amount_}(0);
        } 
        else if(shares == 0 && amount_ <= minimum){
            vm.expectRevert("INSUFFICIENT_DEPOSIT");
            glAVAXToken.deposit{value: amount_}(0);
        }
        else {           
            glAVAXToken.deposit{value: amount_}(0);
            uint256 total = initialUserGlAVAXTokenBalance_ + amount_;
            if(firstDepositer){
                total -= minimum;        
            }
            assertEq(glAVAXToken.balanceOf(user_), total);
        }

        // approve
        if (user_ == address(0)) {
            vm.expectRevert("ERC20: approve from the zero address");
        }
        glAVAXToken.approve(address(wglAVAXToken), amount_);        

        // wrap
        if (amount_ == 0) {
            vm.expectRevert("ZERO_DEPOSIT");
            wglAVAXToken.wrap(amount_);
        }
        else if(shares == 0 && amount_ <= minimum){
            vm.expectRevert("INSUFFICIENT_DEPOSIT");
            glAVAXToken.deposit{value: amount_}(0);
        }
        else {
            uint256 wrapAmount = amount_;
            if(firstDepositer){
                wrapAmount -= minimum;                
                firstDepositer = false;
            } 
            uint256 wglAvaxAmount = wglAVAXToken.wrap(wrapAmount);
            assertEq(wglAvaxAmount, wrapAmount);
            assertEq(wglAVAXToken.balanceOf(user_), initialUserWglAVAXTokenBalance_ + wrapAmount);
            assertEq(glAVAXToken.balanceOf(address(wglAVAXToken)), initialWrapperGlAVAXTokenBalance_ + wrapAmount);
            assertEq(wglAVAXToken.totalSupply(), initialWglAVAXTotalSupply_ + wrapAmount);
        }

        vm.stopPrank();
    }

    function _unwrap(address user_, uint256 amount_) internal {
        uint256 initialUserGlAVAXTokenBalance_ = glAVAXToken.balanceOf(user_);
        uint256 initialUserWglAVAXTokenBalance_ = wglAVAXToken.balanceOf(user_);
        uint256 initialWrapperGlAVAXTokenBalance_ = glAVAXToken.balanceOf(address(wglAVAXToken));
        uint256 initialWglAVAXTotalSupply_ = wglAVAXToken.totalSupply();

        vm.prank(user_);
        if (amount_ == 0) {
            vm.expectRevert("ZERO_WITHDRAW");
            wglAVAXToken.unwrap(amount_);
        }
        else if (amount_ > initialUserWglAVAXTokenBalance_) {
            vm.expectRevert("ERC20: burn amount exceeds balance");
            wglAVAXToken.unwrap(amount_);
        } 
        else {
            uint256 wglAvaxAmount_ = wglAVAXToken.unwrap(amount_);
            assertEq(wglAvaxAmount_, amount_);
            assertEq(wglAVAXToken.balanceOf(user_), initialUserWglAVAXTokenBalance_ - amount_);
            assertEq(glAVAXToken.balanceOf(address(wglAVAXToken)), initialWrapperGlAVAXTokenBalance_ - amount_);
            assertEq(glAVAXToken.balanceOf(user_), initialUserGlAVAXTokenBalance_ + amount_);
            assertEq(wglAVAXToken.totalSupply(), initialWglAVAXTotalSupply_ - amount_);
        }
    }
}