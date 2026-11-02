// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeskPolicy} from "../src/policy/DeskPolicy.sol";
import {MockFairPrice} from "./mocks/MockFairPrice.sol";

contract DeskPolicyTest is Test {
    uint256 internal constant FAIR = 1e8;
    uint256 internal constant BAND = 100;
    uint256 internal constant FLOOR = 30;
    uint256 internal constant WHSK_CAP = 100 ether;
    uint256 internal constant USDT_CAP = 2_000e6;

    uint256 internal ownerKey = 0xA11CE;
    uint256 internal operatorKey = 0xB0B;
    address internal owner;
    address internal operator;
    address internal stranger = makeAddr("stranger");

    MockFairPrice internal fair;
    DeskPolicy internal policy;
    address internal whsk = makeAddr("whsk");
    address internal usdt = makeAddr("usdt");

    function setUp() public {
        owner = vm.addr(ownerKey);
        operator = vm.addr(operatorKey);
        fair = new MockFairPrice();
        fair.setAnswer(FAIR);
        policy = new DeskPolicy(owner, operator, address(fair), whsk, usdt, BAND, FLOOR, WHSK_CAP, USDT_CAP, 1_000e6);
    }

    function test_noQuoteOrFillOutsideBand() public {
        uint256 low = FAIR * 9_900 / 10_000;
        uint256 high = FAIR * 10_100 / 10_000;

        policy.requireBound(FAIR, FLOOR, whsk, WHSK_CAP);
        policy.requireBound(low, FLOOR, usdt, USDT_CAP);
        policy.requireBound(high, FLOOR, whsk, 0);

        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.OUTSIDE_BAND()));
        policy.requireBound(low - 1, FLOOR, whsk, 0);

        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.OUTSIDE_BAND()));
        policy.requireBound(high + 1, FLOOR, usdt, 0);
    }

    function test_operatorMayWidenSpreadFloor() public {
        vm.prank(operator);
        policy.widenSpreadFloor(50);
        assertEq(policy.spreadFloor(), 50);

        policy.requireBound(FAIR, 50, whsk, 0);
        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.BELOW_SPREAD()));
        policy.requireBound(FAIR, 49, whsk, 0);

        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.NOT_WIDER()));
        vm.prank(operator);
        policy.widenSpreadFloor(50);

        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.NOT_WIDER()));
        vm.prank(operator);
        policy.widenSpreadFloor(40);

        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.NOT_OWNER()));
        vm.prank(operator);
        policy.setSpreadFloor(10);

        vm.prank(owner);
        policy.setSpreadFloor(30);
        assertEq(policy.spreadFloor(), 30);
    }

    function test_inventoryAboveCapReverts() public {
        policy.requireBound(FAIR, FLOOR, whsk, WHSK_CAP);
        policy.requireBound(FAIR, FLOOR, usdt, USDT_CAP);

        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.INVENTORY_CAP()));
        policy.requireBound(FAIR, FLOOR, whsk, WHSK_CAP + 1);

        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.INVENTORY_CAP()));
        policy.requireBound(FAIR, FLOOR, usdt, USDT_CAP + 1);

        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.NOT_INVENTORY()));
        policy.requireBound(FAIR, FLOOR, stranger, 0);

        vm.prank(operator);
        policy.lowerInventoryCap(whsk, 10 ether);
        assertEq(policy.inventoryCap(whsk), 10 ether);

        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.INVENTORY_CAP()));
        policy.requireBound(FAIR, FLOOR, whsk, 10 ether + 1);

        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.NOT_LOWER()));
        vm.prank(operator);
        policy.lowerInventoryCap(whsk, 10 ether);

        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.NOT_LOWER()));
        vm.prank(operator);
        policy.lowerInventoryCap(usdt, USDT_CAP + 1);
    }

    function test_tightenAndRaiseCapNeedOwnerSignature() public {
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory tighten = _sign(ownerKey, policy.tightenSpreadDigest(20, policy.nonce(), deadline));
        vm.prank(operator);
        policy.tightenSpreadFloor(20, deadline, tighten);
        assertEq(policy.spreadFloor(), 20);
        assertEq(policy.nonce(), 1);

        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.BAD_SIGNATURE()));
        policy.tightenSpreadFloor(10, deadline, tighten);

        bytes memory raised = _sign(ownerKey, policy.raiseCapDigest(usdt, USDT_CAP + 500e6, policy.nonce(), deadline));
        vm.prank(operator);
        policy.raiseInventoryCap(usdt, USDT_CAP + 500e6, deadline, raised);
        assertEq(policy.inventoryCap(usdt), USDT_CAP + 500e6);

        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.BAD_SIGNATURE()));
        vm.prank(operator);
        policy.tightenSpreadFloor(10, deadline, "");

        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.BAD_SIGNATURE()));
        vm.prank(operator);
        policy.raiseInventoryCap(whsk, WHSK_CAP + 1, deadline, "");

        uint256 expired = block.timestamp - 1;
        bytes memory late = _sign(ownerKey, policy.tightenSpreadDigest(10, policy.nonce(), expired));
        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.EXPIRED()));
        policy.tightenSpreadFloor(10, expired, late);
        assertEq(policy.spreadFloor(), 20);
    }

    function test_operatorSignatureCannotLoosen() public {
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonceBefore = policy.nonce();

        bytes memory tighten = _sign(operatorKey, policy.tightenSpreadDigest(10, nonceBefore, deadline));
        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.BAD_SIGNATURE()));
        vm.prank(operator);
        policy.tightenSpreadFloor(10, deadline, tighten);
        assertEq(policy.spreadFloor(), FLOOR);

        bytes memory raised = _sign(operatorKey, policy.raiseCapDigest(whsk, WHSK_CAP * 2, nonceBefore, deadline));
        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.BAD_SIGNATURE()));
        vm.prank(operator);
        policy.raiseInventoryCap(whsk, WHSK_CAP * 2, deadline, raised);
        assertEq(policy.inventoryCap(whsk), WHSK_CAP);
        assertEq(policy.nonce(), nonceBefore);
    }

    function test_anyoneHaltsWhenStaleOnlyOwnerResumes() public {
        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.NOT_STALE()));
        vm.prank(stranger);
        policy.halt();
        assertFalse(policy.halted());

        fair.setStale(true);
        vm.prank(stranger);
        policy.halt();
        assertTrue(policy.halted());

        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.HALTED()));
        policy.requireBound(FAIR, FLOOR, whsk, 0);

        fair.setStale(false);
        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.HALTED()));
        policy.requireBound(FAIR, FLOOR, whsk, 0);

        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.NOT_OWNER()));
        vm.prank(operator);
        policy.resume();
        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.NOT_OWNER()));
        vm.prank(stranger);
        policy.resume();

        vm.prank(owner);
        policy.resume();
        assertFalse(policy.halted());
        policy.requireBound(FAIR, FLOOR, whsk, 0);

        fair.setStale(true);
        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.STALE()));
        policy.requireBound(FAIR, FLOOR, whsk, 0);

        fair.setStale(false);
        fair.setInvalid(true);
        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.INVALID_PRICE()));
        policy.halt();
        assertFalse(policy.halted());

        fair.setInvalid(false);
        fair.setDeny(true);
        vm.expectRevert(bytes("No access"));
        policy.halt();
        assertFalse(policy.halted());
    }

    function test_operatorCannotLoosenTheBandOrReplaceKeys() public {
        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.NOT_OWNER()));
        vm.prank(operator);
        policy.setBand(BAND + 50);

        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.NOT_OWNER()));
        vm.prank(operator);
        policy.setOperator(operator);

        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.NOT_OWNER()));
        vm.prank(operator);
        policy.transferOwnership(operator);

        vm.prank(owner);
        policy.setBand(50);
        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.OUTSIDE_BAND()));
        policy.requireBound(FAIR * 9_900 / 10_000, FLOOR, whsk, 0);

        address next = makeAddr("next");
        vm.prank(owner);
        policy.setOperator(next);
        assertEq(policy.operator(), next);
        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.NOT_OPERATOR()));
        vm.prank(operator);
        policy.widenSpreadFloor(FLOOR + 1);
    }

    function test_operatorMayNarrowBandAndOwnerSignatureWidensIt() public {
        vm.prank(operator);
        policy.narrowBand(50);
        assertEq(policy.bandBps(), 50);

        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.OUTSIDE_BAND()));
        policy.requireBound(FAIR * 9_900 / 10_000, FLOOR, whsk, 0);

        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.NOT_LOWER()));
        vm.prank(operator);
        policy.narrowBand(50);

        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.NOT_OWNER()));
        vm.prank(operator);
        policy.setBand(BAND);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory widened = _sign(ownerKey, policy.widenBandDigest(80, policy.nonce(), deadline));
        vm.prank(operator);
        policy.widenBand(80, deadline, widened);
        assertEq(policy.bandBps(), 80);
        assertEq(policy.nonce(), 1);

        bytes memory fromOperator = _sign(operatorKey, policy.widenBandDigest(120, policy.nonce(), deadline));
        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.BAD_SIGNATURE()));
        vm.prank(operator);
        policy.widenBand(120, deadline, fromOperator);
        assertEq(policy.bandBps(), 80);

        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.NOT_HIGHER()));
        policy.widenBand(80, deadline, widened);

        bytes memory tooWide = _sign(ownerKey, policy.widenBandDigest(10_000, policy.nonce(), deadline));
        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.BAD_BAND()));
        policy.widenBand(10_000, deadline, tooWide);
        assertEq(policy.bandBps(), 80);
    }

    function test_operatorCannotRaiseFillCapOwnerSignatureCan() public {
        assertEq(policy.FILL_CAP(), keccak256("FILL_CAP"));
        assertEq(policy.fillCap(), 1_000e6);

        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.NOT_LOWER()));
        vm.prank(operator);
        policy.lowerFillCap(1_000e6);

        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.NOT_LOWER()));
        vm.prank(operator);
        policy.lowerFillCap(1_500e6);

        uint256 deadline = block.timestamp + 1 hours;
        bytes memory fromOperator =
            _sign(operatorKey, policy.raiseFillCapDigest(1_500e6, policy.nonce(), deadline));
        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.BAD_SIGNATURE()));
        vm.prank(operator);
        policy.raiseFillCap(1_500e6, deadline, fromOperator);
        assertEq(policy.fillCap(), 1_000e6);
        assertEq(policy.nonce(), 0);

        bytes memory raised = _sign(ownerKey, policy.raiseFillCapDigest(1_500e6, policy.nonce(), deadline));
        vm.prank(operator);
        policy.raiseFillCap(1_500e6, deadline, raised);
        assertEq(policy.fillCap(), 1_500e6);
        assertEq(policy.nonce(), 1);
    }

    function test_revertsCarryStableReasonCode() public {
        assertEq(policy.OUTSIDE_BAND(), keccak256("OUTSIDE_BAND"));
        assertEq(policy.BELOW_SPREAD(), keccak256("BELOW_SPREAD"));
        assertEq(policy.INVENTORY_CAP(), keccak256("INVENTORY_CAP"));
        assertEq(policy.STALE(), keccak256("STALE"));
        assertEq(policy.HALTED(), keccak256("HALTED"));

        uint256 high = FAIR * 10_100 / 10_000;
        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, keccak256("OUTSIDE_BAND")));
        policy.requireBound(high + 1, FLOOR, whsk, 0);

        fair.setStale(true);
        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, keccak256("STALE")));
        policy.requireBound(FAIR, FLOOR, whsk, 0);
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }
}
