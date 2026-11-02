// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeskVault} from "../src/vault/DeskVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract DeskVaultTest is Test {
    address internal owner = makeAddr("owner");
    address internal operator = makeAddr("operator");
    address internal next = makeAddr("next");
    address internal recipient = makeAddr("recipient");

    MockERC20 internal whsk;
    MockERC20 internal usdt;
    DeskVault internal vault;

    function setUp() public {
        whsk = new MockERC20("WHSK", 18);
        usdt = new MockERC20("USDT", 6);
        vault = new DeskVault(owner, operator, address(whsk), address(usdt));
    }

    function test_ownerDepositsAndWithdraws() public {
        whsk.mint(owner, 1 ether);
        usdt.mint(owner, 2_000e6);

        vm.startPrank(owner);
        whsk.approve(address(vault), type(uint256).max);
        usdt.approve(address(vault), type(uint256).max);

        vm.expectEmit(true, true, false, true);
        emit DeskVault.Deposited(owner, address(whsk), 1 ether);
        vault.deposit(address(whsk), 1 ether);

        vm.expectEmit(true, true, false, true);
        emit DeskVault.Deposited(owner, address(usdt), 2_000e6);
        vault.deposit(address(usdt), 2_000e6);

        vm.expectEmit(true, true, false, true);
        emit DeskVault.Withdrawn(recipient, address(usdt), 500e6);
        vault.withdraw(address(usdt), 500e6, recipient);
        vm.stopPrank();

        assertEq(whsk.balanceOf(address(vault)), 1 ether);
        assertEq(usdt.balanceOf(address(vault)), 1_500e6);
        assertEq(usdt.balanceOf(recipient), 500e6);
        assertEq(whsk.balanceOf(owner), 0);
    }

    function test_operatorWithdrawReverts() public {
        whsk.mint(address(vault), 1 ether);
        usdt.mint(address(vault), 1);

        vm.startPrank(operator);
        vm.expectRevert(DeskVault.NotOwner.selector);
        vault.withdraw(address(whsk), 1 ether, operator);
        vm.expectRevert(DeskVault.NotOwner.selector);
        vault.withdraw(address(usdt), 1, operator);
        vm.stopPrank();

        assertEq(whsk.balanceOf(address(vault)), 1 ether);
        assertEq(usdt.balanceOf(operator), 0);
    }

    function test_leakedOperatorKeyCannotPauseOrChangeOwner() public {
        vm.startPrank(operator);
        vm.expectRevert(DeskVault.NotOwner.selector);
        vault.pause();
        vm.expectRevert(DeskVault.NotOwner.selector);
        vault.unpause();
        vm.expectRevert(DeskVault.NotOwner.selector);
        vault.setOperator(operator);
        vm.expectRevert(DeskVault.NotOwner.selector);
        vault.setQuoter(operator);
        vm.expectRevert(DeskVault.NotOwner.selector);
        vault.setFiller(operator);
        vm.expectRevert(DeskVault.NotOwner.selector);
        vault.transferOwnership(operator);
        vm.expectRevert(DeskVault.NotOwner.selector);
        vault.deposit(address(whsk), 1);
        vm.stopPrank();

        assertEq(vault.owner(), owner);
        assertEq(vault.operator(), operator);
        assertFalse(vault.paused());
    }

    function test_strangerCannotMoveInventory() public {
        whsk.mint(address(vault), 10);
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(DeskVault.NotOwner.selector);
        vault.withdraw(address(whsk), 10, stranger);
        vm.prank(stranger);
        vm.expectRevert(DeskVault.NotQuoter.selector);
        vault.draw(address(whsk), 10);
        vm.prank(stranger);
        vm.expectRevert(DeskVault.NotFiller.selector);
        vault.settle(address(whsk), 10, address(usdt), 1, stranger);
        assertEq(whsk.balanceOf(address(vault)), 10);
    }

    function test_quoterDrawsAndRestores_operatorCannot() public {
        whsk.mint(address(vault), 10 ether);
        address quoter = makeAddr("quoter");

        vm.prank(operator);
        vm.expectRevert(DeskVault.NotQuoter.selector);
        vault.draw(address(whsk), 1 ether);

        vm.prank(owner);
        vm.expectRevert(DeskVault.ZeroAddress.selector);
        vault.setQuoter(address(0));

        vm.expectEmit(true, false, false, true);
        emit DeskVault.QuoterUpdated(quoter);
        vm.prank(owner);
        vault.setQuoter(quoter);
        assertEq(vault.quoter(), quoter);

        vm.expectEmit(true, true, false, true);
        emit DeskVault.Drawn(quoter, address(whsk), 4 ether);
        vm.prank(quoter);
        vault.draw(address(whsk), 4 ether);
        assertEq(whsk.balanceOf(quoter), 4 ether);
        assertEq(whsk.balanceOf(address(vault)), 6 ether);

        vm.prank(quoter);
        whsk.approve(address(vault), 4 ether);
        vm.expectEmit(true, true, false, true);
        emit DeskVault.Restored(quoter, address(whsk), 4 ether);
        vm.prank(quoter);
        vault.restore(address(whsk), 4 ether);

        assertEq(whsk.balanceOf(address(vault)), 10 ether);
        assertEq(whsk.balanceOf(quoter), 0);

        vm.prank(operator);
        vm.expectRevert(DeskVault.NotOwner.selector);
        vault.withdraw(address(whsk), 1 ether, operator);
        assertEq(whsk.balanceOf(address(vault)), 10 ether);
    }

    function test_fillerSettles_operatorCannot() public {
        address filler = makeAddr("filler");
        address taker = makeAddr("taker");
        whsk.mint(address(vault), 5 ether);
        usdt.mint(taker, 1_000e6);

        vm.prank(operator);
        vm.expectRevert(DeskVault.NotFiller.selector);
        vault.settle(address(whsk), 1 ether, address(usdt), 1_000e6, taker);

        vm.prank(owner);
        vm.expectRevert(DeskVault.ZeroAddress.selector);
        vault.setFiller(address(0));

        vm.expectEmit(true, false, false, true);
        emit DeskVault.FillerUpdated(filler);
        vm.prank(owner);
        vault.setFiller(filler);

        vm.prank(taker);
        usdt.approve(address(vault), 1_000e6);

        vm.expectEmit(true, true, false, true);
        emit DeskVault.Settled(filler, taker, address(whsk), 1 ether, address(usdt), 1_000e6);
        vm.prank(filler);
        vault.settle(address(whsk), 1 ether, address(usdt), 1_000e6, taker);

        assertEq(whsk.balanceOf(taker), 1 ether);
        assertEq(whsk.balanceOf(address(vault)), 4 ether);
        assertEq(usdt.balanceOf(address(vault)), 1_000e6);
        assertEq(usdt.balanceOf(taker), 0);

        vm.prank(operator);
        vm.expectRevert(DeskVault.NotOwner.selector);
        vault.withdraw(address(whsk), 1 ether, operator);
        assertEq(whsk.balanceOf(address(vault)), 4 ether);
    }

    function test_ownerWithdrawsWhilePaused() public {
        usdt.mint(address(vault), 42);
        vm.startPrank(owner);
        vault.pause();
        vault.withdraw(address(usdt), 42, owner);
        vm.stopPrank();
        assertTrue(vault.paused());
        assertEq(usdt.balanceOf(owner), 42);
        assertEq(usdt.balanceOf(address(vault)), 0);
    }

    function test_ownerRotatesOperatorAndOldKeyStillCannotWithdraw() public {
        whsk.mint(address(vault), 7);
        address rotated = makeAddr("rotated");
        vm.prank(owner);
        vault.setOperator(rotated);
        assertEq(vault.operator(), rotated);

        vm.prank(operator);
        vm.expectRevert(DeskVault.NotOwner.selector);
        vault.withdraw(address(whsk), 7, operator);
        vm.prank(rotated);
        vm.expectRevert(DeskVault.NotOwner.selector);
        vault.withdraw(address(whsk), 7, rotated);
        assertEq(whsk.balanceOf(address(vault)), 7);
    }

    function test_newOwnerWithdrawsAndPreviousOwnerCannot() public {
        whsk.mint(address(vault), 9);
        vm.prank(owner);
        vault.transferOwnership(next);

        vm.prank(owner);
        vm.expectRevert(DeskVault.NotOwner.selector);
        vault.withdraw(address(whsk), 9, owner);

        vm.prank(next);
        vault.withdraw(address(whsk), 9, next);
        assertEq(whsk.balanceOf(next), 9);
        assertEq(vault.owner(), next);
    }

    function test_pauseOnlyFlipsOnce() public {
        vm.startPrank(owner);
        vault.pause();
        vm.expectRevert(DeskVault.PauseUnchanged.selector);
        vault.pause();
        vault.unpause();
        vm.expectRevert(DeskVault.PauseUnchanged.selector);
        vault.unpause();
        vm.stopPrank();
        assertFalse(vault.paused());
    }

    function test_depositRejectsWrongTokenZeroAmountAndShortReceipt() public {
        MockERC20 other = new MockERC20("OTHER", 18);
        other.mint(owner, 5);

        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(DeskVault.NotInventory.selector, address(other)));
        vault.deposit(address(other), 5);

        vm.expectRevert(DeskVault.ZeroAmount.selector);
        vault.deposit(address(whsk), 0);

        whsk.mint(owner, 5);
        whsk.approve(address(vault), 5);
        whsk.setFee(1);
        vm.expectRevert(DeskVault.TransferFailed.selector);
        vault.deposit(address(whsk), 5);
        vm.stopPrank();

        assertEq(whsk.balanceOf(address(vault)), 0);
        assertEq(whsk.balanceOf(owner), 5);
    }

    function test_withdrawRejectsZeroAndOverBalance() public {
        whsk.mint(address(vault), 4);
        vm.startPrank(owner);
        vm.expectRevert(DeskVault.ZeroAmount.selector);
        vault.withdraw(address(whsk), 0, owner);
        vm.expectRevert(DeskVault.ZeroAddress.selector);
        vault.withdraw(address(whsk), 1, address(0));
        vm.expectRevert(DeskVault.TransferFailed.selector);
        vault.withdraw(address(whsk), 5, owner);
        vm.stopPrank();
        assertEq(whsk.balanceOf(address(vault)), 4);
    }

    function test_falseReturnAndMissingReturnData() public {
        whsk.mint(owner, 3);
        vm.startPrank(owner);
        whsk.approve(address(vault), type(uint256).max);

        whsk.setReturnsFalse(true);
        vm.expectRevert(DeskVault.TransferFailed.selector);
        vault.deposit(address(whsk), 3);

        whsk.setReturnsFalse(false);
        whsk.setReturnsBool(false);
        vault.deposit(address(whsk), 3);
        vault.withdraw(address(whsk), 3, recipient);
        vm.stopPrank();

        assertEq(whsk.balanceOf(address(vault)), 0);
        assertEq(whsk.balanceOf(recipient), 3);
    }

    function test_constructorRejectsZeroAndDuplicateToken() public {
        vm.expectRevert(DeskVault.ZeroAddress.selector);
        new DeskVault(address(0), operator, address(whsk), address(usdt));
        vm.expectRevert(DeskVault.ZeroAddress.selector);
        new DeskVault(owner, address(0), address(whsk), address(usdt));
        vm.expectRevert(DeskVault.ZeroAddress.selector);
        new DeskVault(owner, operator, address(0), address(usdt));
        vm.expectRevert(DeskVault.SameToken.selector);
        new DeskVault(owner, operator, address(whsk), address(whsk));
    }

    /// @dev Owner, pause, operator, and both balances are the vault state. Withdrawal still pays the owner.
    function testFuzz_ownerWithdrawsInAnyVaultState(
        uint96 whskBal,
        uint96 usdtBal,
        bool pauseFirst,
        address operator_,
        address nextOwner,
        address to,
        bool takeWhsk,
        uint256 amountSeed
    ) public {
        vm.assume(operator_ != address(0) && operator_ != owner);
        vm.assume(nextOwner != address(0) && nextOwner != operator_);
        vm.assume(to != address(0) && to != address(vault) && to != address(whsk) && to != address(usdt));

        whsk.mint(address(vault), whskBal);
        usdt.mint(address(vault), usdtBal);

        vm.startPrank(owner);
        vault.setOperator(operator_);
        if (pauseFirst) vault.pause();
        if (nextOwner != owner) vault.transferOwnership(nextOwner);
        vm.stopPrank();

        MockERC20 token = takeWhsk ? whsk : usdt;
        uint256 bal = token.balanceOf(address(vault));
        address currentOwner = nextOwner == owner ? owner : nextOwner;

        vm.prank(operator_);
        vm.expectRevert(DeskVault.NotOwner.selector);
        vault.withdraw(address(token), bal == 0 ? 1 : bal, operator_);
        vm.prank(operator_);
        vm.expectRevert(DeskVault.NotQuoter.selector);
        vault.draw(address(token), 1);
        vm.prank(operator_);
        vm.expectRevert(DeskVault.NotFiller.selector);
        vault.settle(address(whsk), 1, address(usdt), 1, to);

        if (bal == 0) return;

        uint256 amount = (amountSeed % bal) + 1;
        uint256 toBefore = token.balanceOf(to);
        vm.prank(currentOwner);
        vault.withdraw(address(token), amount, to);

        assertEq(token.balanceOf(address(vault)), bal - amount);
        assertEq(token.balanceOf(to), toBefore + amount);
        assertEq(vault.paused(), pauseFirst);
        assertEq(vault.operator(), operator_);
        assertEq(vault.owner(), currentOwner);
    }
}
