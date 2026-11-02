// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeskFill} from "../src/fill/DeskFill.sol";
import {DeskPolicy} from "../src/policy/DeskPolicy.sol";
import {DeskVault} from "../src/vault/DeskVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockFairPrice} from "./mocks/MockFairPrice.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

/// @notice MockERC20, MockFairPrice, and MockV3Pool stand in for WHSK, USDT, APRO, and the HSKSwap pool.
///         The router and the quoter are unset. A short inventory cannot be routed.
///         The pool is a mock, so these fills do not quote HSKSwap.
contract DeskFillTest is Test {
    uint256 internal constant FAIR = 1e8;
    uint256 internal constant BAND = 100;
    uint256 internal constant FLOOR = 30;
    uint256 internal constant WHSK_CAP = 100 ether;
    uint256 internal constant USDT_CAP = 2_000e6;
    uint256 internal constant BPS = 10_000;

    uint256 internal ownerKey = 0xA11CE;
    uint256 internal operatorKey = 0xB0B;
    uint256 internal traderKey = 0xC0FFEE;
    uint256 internal otherKey = 0xD00D;

    address internal owner;
    address internal operator;
    address internal trader;

    MockERC20 internal whsk;
    MockERC20 internal usdt;
    MockFairPrice internal fair;
    MockV3Pool internal pool;
    DeskVault internal vault;
    DeskPolicy internal policy;
    DeskFill internal desk;

    function setUp() public {
        owner = vm.addr(ownerKey);
        operator = vm.addr(operatorKey);
        trader = vm.addr(traderKey);

        whsk = new MockERC20("WHSK", 18);
        usdt = new MockERC20("USDT", 6);
        fair = new MockFairPrice();
        fair.setAnswer(FAIR);
        pool = new MockV3Pool(address(whsk), address(usdt), 3000);

        vault = new DeskVault(owner, operator, address(whsk), address(usdt));
        policy = new DeskPolicy(
            owner, operator, address(fair), address(whsk), address(usdt), BAND, FLOOR, WHSK_CAP, USDT_CAP, 1_000e6
        );
        desk = new DeskFill(address(vault), address(policy), address(pool), address(0), address(0), 0);

        vm.prank(owner);
        vault.setFiller(address(desk));
    }

    function test_fullFillFromInventory() public {
        uint256 size = 1 ether;
        uint256 price = _ask();
        uint256 paid = _usdt(size, price);
        whsk.mint(address(vault), 10 ether);
        usdt.mint(trader, paid);
        vm.prank(trader);
        usdt.approve(address(vault), paid);

        DeskFill.Intent memory intent = _intent(desk.BUY_WHSK(), size, price, 1);
        bytes32 reasonHash = keccak256("inventory fill");
        bytes memory signature = _sign(traderKey, desk.intentDigest(intent));

        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.NOT_OPERATOR()));
        desk.fill(intent, signature, "inventory fill", reasonHash);

        vm.expectEmit(true, false, false, true);
        emit DeskFill.Filled(trader, 1, desk.BUY_WHSK(), size, FAIR, FLOOR, 9 ether, paid, reasonHash, 0);
        vm.prank(operator);
        desk.fill(intent, signature, "inventory fill", reasonHash);

        assertEq(whsk.balanceOf(trader), size);
        assertEq(whsk.balanceOf(address(vault)), 9 ether);
        assertEq(usdt.balanceOf(address(vault)), paid);
        assertEq(usdt.balanceOf(trader), 0);
        assertTrue(desk.usedNonce(trader, 1));

        vm.prank(operator);
        vm.expectRevert(DeskVault.NotOwner.selector);
        vault.withdraw(address(whsk), 1 ether, operator);
        assertEq(whsk.balanceOf(address(vault)), 9 ether);
    }

    function test_expiredIntentReverts() public {
        DeskFill.Intent memory intent = _intent(desk.BUY_WHSK(), 1 ether, _ask(), 2);
        intent.expiry = block.timestamp - 1;
        bytes memory signature = _sign(traderKey, desk.intentDigest(intent));

        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.EXPIRED()));
        vm.prank(operator);
        desk.fill(intent, signature, "inventory fill", keccak256("inventory fill"));
        assertFalse(desk.usedNonce(trader, 2));
    }

    function test_replayedNonceReverts() public {
        uint256 size = 1 ether;
        uint256 paid = _usdt(size, _ask());
        whsk.mint(address(vault), 10 ether);
        usdt.mint(trader, paid * 2);
        vm.prank(trader);
        usdt.approve(address(vault), paid * 2);

        DeskFill.Intent memory intent = _intent(desk.BUY_WHSK(), size, _ask(), 3);
        bytes memory signature = _sign(traderKey, desk.intentDigest(intent));

        vm.prank(operator);
        desk.fill(intent, signature, "inventory fill", keccak256("inventory fill"));

        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.BAD_NONCE()));
        vm.prank(operator);
        desk.fill(intent, signature, "inventory fill", keccak256("inventory fill"));

        assertEq(whsk.balanceOf(trader), size);
        assertEq(usdt.balanceOf(address(vault)), paid);
    }

    function test_wrongSignerReverts() public {
        DeskFill.Intent memory intent = _intent(desk.BUY_WHSK(), 1 ether, _ask(), 4);
        bytes memory signature = _sign(otherKey, desk.intentDigest(intent));

        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.BAD_SIGNATURE()));
        vm.prank(operator);
        desk.fill(intent, signature, "inventory fill", keccak256("inventory fill"));
        assertFalse(desk.usedNonce(trader, 4));
        assertEq(whsk.balanceOf(trader), 0);
    }

    function test_sizeAboveInventoryCapReverts() public {
        uint256 size = WHSK_CAP + 1;
        uint256 bid = _bid();
        uint256 payout = _usdt(size, bid);
        usdt.mint(address(vault), payout);
        whsk.mint(trader, size);
        vm.prank(trader);
        whsk.approve(address(vault), size);

        DeskFill.Intent memory intent = _intent(desk.SELL_WHSK(), size, bid, 5);
        bytes memory signature = _sign(traderKey, desk.intentDigest(intent));

        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.INVENTORY_CAP()));
        vm.prank(operator);
        desk.fill(intent, signature, "inventory fill", keccak256("inventory fill"));

        assertEq(whsk.balanceOf(address(vault)), 0);
        assertEq(usdt.balanceOf(address(vault)), payout);
        assertEq(whsk.balanceOf(trader), size);
        assertFalse(desk.usedNonce(trader, 5));
    }

    function test_limitThroughSpreadFloorReverts() public {
        uint256 size = 1 ether;
        whsk.mint(address(vault), size);
        DeskFill.Intent memory intent = _intent(desk.BUY_WHSK(), size, _ask() - 1, 6);
        bytes memory signature = _sign(traderKey, desk.intentDigest(intent));

        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.BELOW_SPREAD()));
        vm.prank(operator);
        desk.fill(intent, signature, "inventory fill", keccak256("inventory fill"));

        assertEq(whsk.balanceOf(address(vault)), size);
        assertEq(whsk.balanceOf(trader), 0);
        assertFalse(desk.usedNonce(trader, 6));
    }

    function test_shortInventoryWithoutRouterReverts() public {
        whsk.mint(address(vault), 0.4 ether);
        DeskFill.Intent memory intent = _intent(desk.BUY_WHSK(), 1 ether, _ask(), 8);
        bytes memory signature = _sign(traderKey, desk.intentDigest(intent));

        vm.expectRevert(DeskFill.ShortInventory.selector);
        vm.prank(operator);
        desk.fill(intent, signature, "inventory fill", keccak256("inventory fill"));
        assertEq(whsk.balanceOf(address(vault)), 0.4 ether);
        assertFalse(desk.usedNonce(trader, 8));
    }

    function test_fillOverCapDoesNotConsumeNonce() public {
        assertEq(policy.FILL_CAP(), keccak256("FILL_CAP"));
        uint256 size = 1 ether;
        uint256 price = _ask();
        uint256 paid = _usdt(size, price);
        whsk.mint(address(vault), size);
        usdt.mint(trader, paid);
        vm.prank(trader);
        usdt.approve(address(vault), paid);

        vm.prank(owner);
        policy.setFillCap(paid - 1);

        DeskFill.Intent memory intent = _intent(desk.BUY_WHSK(), size, price, 11);
        bytes memory signature = _sign(traderKey, desk.intentDigest(intent));

        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.FILL_CAP()));
        vm.prank(operator);
        desk.fill(intent, signature, "over the cap", keccak256("over the cap"));

        assertFalse(desk.usedNonce(trader, 11));
        assertEq(whsk.balanceOf(address(vault)), size);
        assertEq(usdt.balanceOf(address(vault)), 0);
        assertEq(whsk.balanceOf(trader), 0);
    }

    function test_reasonHashMismatchReverts() public {
        assertEq(desk.REASON_MISMATCH(), keccak256("REASON_MISMATCH"));

        uint256 size = 1 ether;
        whsk.mint(address(vault), size);
        DeskFill.Intent memory intent = _intent(desk.BUY_WHSK(), size, _ask(), 7);
        bytes memory signature = _sign(traderKey, desk.intentDigest(intent));

        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, desk.REASON_MISMATCH()));
        vm.prank(operator);
        desk.fill(intent, signature, "inventory fill", keccak256("other reason"));

        assertEq(whsk.balanceOf(address(vault)), size);
        assertFalse(desk.usedNonce(trader, 7));
    }

    function _intent(uint8 side, uint256 size, uint256 limit, uint256 nonce)
        internal
        view
        returns (DeskFill.Intent memory)
    {
        return DeskFill.Intent({
            pair: address(pool),
            side: side,
            size: size,
            limit: limit,
            expiry: block.timestamp + 1 hours,
            nonce: nonce,
            trader: trader
        });
    }

    function _ask() internal pure returns (uint256) {
        return FAIR * (BPS + FLOOR) / BPS;
    }

    function _bid() internal pure returns (uint256) {
        return FAIR * (BPS - FLOOR) / BPS;
    }

    function _usdt(uint256 size, uint256 price) internal pure returns (uint256) {
        return size * price / 1e20;
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }
}
