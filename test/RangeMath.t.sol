// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeskPolicy} from "../src/policy/DeskPolicy.sol";
import {MulDiv} from "../src/price/MulDiv.sol";
import {RangeMath} from "../src/quote/RangeMath.sol";
import {SqrtTick} from "../src/price/SqrtTick.sol";

contract RangeHarness {
    function quote(
        uint256 fairPrice,
        uint256 widthBps,
        int256 skewBps,
        uint256 spreadFloor,
        uint256 whskInventory,
        uint256 usdtInventory,
        uint256 whskCap,
        uint256 usdtCap,
        int24 tickSpacing
    ) external pure returns (int24, int24) {
        return RangeMath.quote(
            fairPrice, widthBps, skewBps, spreadFloor, whskInventory, usdtInventory, whskCap, usdtCap, tickSpacing
        );
    }
}

contract RangeMathTest is Test {
    int24 internal constant PINNED = -300697;
    int24 internal constant SPACING = 60;
    uint256 internal constant WIDTH = 100;
    uint256 internal constant FLOOR = 30;
    uint256 internal constant CAP = 100 ether;

    uint256 internal fair;
    RangeHarness internal harness;

    function setUp() public {
        uint160 sqrtPrice = SqrtTick.sqrtPriceX96(PINNED);
        uint256 ratioX192 = uint256(sqrtPrice) * sqrtPrice;
        fair = MulDiv.mulDiv(ratioX192, RangeMath.FAIR_TO_RATIO, uint256(1) << 192);
        harness = new RangeHarness();
    }

    function test_inRange() public view {
        // The fair price is the pinned tick rounded down to 8 decimals, so the
        // greatest tick at or below that price is the pinned tick or the one just under it.
        int24 tick = RangeMath.tickAtFairPrice(fair);
        assertTrue(tick == PINNED || tick == PINNED - 1);

        (int24 lower, int24 upper) = _quote(0, 0, 0);
        assertTrue(RangeMath.place(PINNED, lower, upper) == RangeMath.Place.Inside);
        assertLt(lower, PINNED);
        assertLt(PINNED, upper);
        assertEq(lower % SPACING, 0);
        assertEq(upper % SPACING, 0);
        // 100 bps is about 100 ticks each side, plus less than one spacing of alignment.
        assertLt(upper - lower, 400);
    }

    function test_belowRange() public view {
        (int24 lower, int24 upper) = _quote(2_000, 0, 0);
        assertTrue(RangeMath.place(PINNED, lower, upper) == RangeMath.Place.Below);
        assertLt(PINNED, lower);
        assertLt(lower, upper);
    }

    function test_aboveRange() public view {
        (int24 lower, int24 upper) = _quote(-2_000, 0, 0);
        assertTrue(RangeMath.place(PINNED, lower, upper) == RangeMath.Place.Above);
        assertGe(PINNED, upper);
        assertLt(lower, upper);
    }

    function test_skewThatWouldBreachInventoryCap() public {
        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, keccak256("INVENTORY_CAP")));
        harness.quote(fair, WIDTH, 1, FLOOR, CAP, 0, CAP, CAP, SPACING);

        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, keccak256("INVENTORY_CAP")));
        harness.quote(fair, WIDTH, -1, FLOOR, 0, CAP, CAP, CAP, SPACING);

        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, keccak256("INVENTORY_CAP")));
        harness.quote(fair, WIDTH, 0, FLOOR, CAP + 1, 0, CAP, CAP, SPACING);

        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, keccak256("INVENTORY_CAP")));
        harness.quote(fair, WIDTH, 0, FLOOR, 0, CAP + 1, CAP, CAP, SPACING);

        (int24 lower, int24 upper) = _quote(0, CAP, CAP);
        assertTrue(RangeMath.place(PINNED, lower, upper) == RangeMath.Place.Inside);

        (lower, upper) = _quote(1, CAP - 1, CAP);
        assertLt(lower, upper);
        (lower, upper) = _quote(-1, CAP, CAP - 1);
        assertLt(lower, upper);
    }

    function test_widthBelowSpreadFloor() public {
        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, keccak256("BELOW_SPREAD")));
        harness.quote(fair, FLOOR - 1, 0, FLOOR, 0, 0, CAP, CAP, SPACING);

        (int24 lower, int24 upper) = RangeMath.quote(fair, FLOOR, 0, FLOOR, 0, 0, CAP, CAP, SPACING);
        assertTrue(RangeMath.place(PINNED, lower, upper) == RangeMath.Place.Inside);
    }

    function _quote(int256 skewBps, uint256 whsk, uint256 usdt) internal view returns (int24, int24) {
        return RangeMath.quote(fair, WIDTH, skewBps, FLOOR, whsk, usdt, CAP, CAP, SPACING);
    }
}
