// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { Test } from "@forge-std/Test.sol";
import { console } from "@forge-std/console.sol";
import { GlacierAddressBook } from "contracts/GlacierAddressBook.sol";

import { Fixture } from "test/foundry/Fixture.t.sol";

contract GlAVAXFuzzTests is Fixture {

    uint256 public constant TEN_AVAX = 10 * 10**18;
    uint256 public constant ONE_HUNDRED_AVAX = 100 * 10**18;
    uint256 public constant ONE_THOUSAND_AVAX = 1000 * 10**18;

    bool firstDepositer = true;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Withdrawal(address indexed src, uint wad);
    event Deposit(address indexed user, uint256 avaxAmount, uint64 referralCode);
    event Withdraw(address indexed user, uint256 avaxAmount);

    function setUp() public override {
        super.setUp();
    }

    /****************************** Deposit ****************************************/

    function test_fuzz_Deposit_Withdraw(address[] memory users_, uint256[] calldata depositsAmount_, uint256[] calldata withdrawalsAmount_, uint64 referralCode_) public {
        
        uint256 numDeposits = users_.length < depositsAmount_.length ? users_.length : depositsAmount_.length;
        uint256 numWithdraws = numDeposits < withdrawalsAmount_.length ? numDeposits : withdrawalsAmount_.length;
        vm.assume(numWithdraws < 3);
        vm.assume(numWithdraws > 0);

        // Make several deposits
        for(uint256 i_ = 0; i_ < numWithdraws; i_++) {
            
            // addresses smaller than 10 are precompiles and user should not be contract that does not implement receive
            users_[i_] = address(uint160(uint256(keccak256(abi.encodePacked(users_[i_])))));
            vm.label(users_[i_], string(abi.encodePacked("user", vm.toString(i_))));

            uint256 amount = depositsAmount_[i_];
            // Limit amount to deposit
            amount = bound(amount, 0, ONE_THOUSAND_AVAX);

            // Give user enougth to deposit
            deal(users_[i_], amount);

            // Deposit
            _deposit(users_[i_], amount, referralCode_);
        }

        // Make several withdrawals
        for(uint256 i_ = 0; i_ < numWithdraws; i_++) {
            
            uint256 amount = withdrawalsAmount_[i_];
            address user = users_[i_];

            // Withdraw
            _withdraw(user, amount);
        }
    }

    function _deposit(address user_, uint256 amount_, uint64 referralCode_) internal {
        // Deposit AVAX
        vm.startPrank(user_);

        uint256 shares = glAVAXToken._totalShares();
        uint256 minimum = glAVAXToken.MINIMUM_LIQUIDITY();

        if (user_ == address(proxyAdmin)) {
            // Revert if address same as proxyAdmin
            vm.expectRevert("TransparentUpgradeableProxy: admin cannot fallback to proxy target");
            glAVAXToken.deposit{value: amount_ }(referralCode_);
        } else if(amount_ == 0){
            // Revert if trying to deposit zero
            vm.expectRevert("ZERO_DEPOSIT");
            glAVAXToken.deposit{ value: amount_ }(referralCode_);
        } else if (user_ == address(0)) {
            // Revert if address 0
            vm.expectRevert("ERC20: mint to the zero address");
            glAVAXToken.deposit{value: amount_ }(referralCode_);
        } else if(shares == 0 && amount_ <= minimum){
            vm.expectRevert("INSUFFICIENT_DEPOSIT");
            glAVAXToken.deposit{value: amount_}(referralCode_);
        }        
        else {
            uint256 balanceBefore = wAvaxToken.balanceOf(address(glAVAXToken));

            vm.expectEmit(true, false, false, true, address(glAVAXToken));
            emit Deposit(user_, amount_, referralCode_);

            // Deposit
            glAVAXToken.deposit{ value: amount_ }(referralCode_);

            uint256 balanceAfter = wAvaxToken.balanceOf(address(glAVAXToken));

            uint256 availableAmount = amount_;
            if(firstDepositer){
                availableAmount -= minimum;   
                firstDepositer = false;     
            }

            // User receives the correct amount of glAVAX token
            assertEq((balanceAfter - balanceBefore), amount_);
            assertEq(glAVAXToken.balanceOf(user_), availableAmount);
        }
        vm.stopPrank();
    }

    function _withdraw(address user_, uint256 amount_) internal {
        uint256 initialUserGlAVAXTokenBalance_ = glAVAXToken.balanceOf(user_);

        // Withdraw AVAX
        vm.startPrank(user_);
        if (user_ == address(proxyAdmin)) {
            // Revert if address same as proxyAdmin
            vm.expectRevert("TransparentUpgradeableProxy: admin cannot fallback to proxy target");
            glAVAXToken.withdraw(amount_);
        } else if(amount_ == 0) {
            // Revert if trying to withdraw zero
            vm.expectRevert("ZERO_WITHDRAW");
            glAVAXToken.withdraw(amount_);
        } else if (amount_ > initialUserGlAVAXTokenBalance_) {
            // Revert if trying to withdraw with no glAVAX balance
            vm.expectRevert("INSUFFICIENT_BALANCE");
            glAVAXToken.withdraw(amount_);
        } else if (user_ == address(0)) {
            // Revert if address 0
            vm.expectRevert("ERC20: mint to the zero address");
            glAVAXToken.withdraw(amount_);
        } else {
            uint256 balanceBefore = user_.balance;

            vm.expectEmit(true, true, false, true, address(wAvaxToken));
            emit Withdrawal(address(glAVAXToken), amount_);
            vm.expectEmit(true, true, true, true, address(glAVAXToken));
            emit Transfer(user_, address(0), amount_);
            vm.expectEmit(true, true, false, true, address(glAVAXToken));
            emit Withdraw(user_, amount_);

            // Withdraw
            glAVAXToken.withdraw(amount_);


            uint256 balanceAfter = user_.balance;

            // User receives correct amount of AVAX
            assertGt((balanceAfter - balanceBefore), 0);     
        }
        vm.stopPrank();
    }
}
