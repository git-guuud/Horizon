// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DeskPolicy} from "../policy/DeskPolicy.sol";
import {MulDiv} from "../price/MulDiv.sol";
import {SqrtTick} from "../price/SqrtTick.sol";

/// @title RangeMath
/// @notice Pure tick range for a WHSK/USDT quote. No pool calls.
///         Width is the distance, in bps, from the skewed center to each edge.
///         It must be at least the policy spread floor.
///         A positive skew lifts the center, so the position holds more WHSK.
///         A negative skew drops it, so the position holds more USDT.
///         Skew toward an asset already at its cap reverts with the T4 inventory code.
library RangeMath {
    uint256 internal constant BPS = 10_000;

    /// @dev Fair price is 8-decimal USDT per 1 WHSK. Raw token1/token0 = fair / 10^20
    ///      because WHSK has 18 decimals and USDT has 6.
    uint256 internal constant FAIR_TO_RATIO = 10 ** 20;

    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = 887272;

    enum Place {
        Below,
        Inside,
        Above
    }

    error BadWidth();
    error BadSkew();
    error BadSpacing();

    /// @notice Ticks for a concentrated range. Both ends are multiples of `tickSpacing`.
    /// @param fairPrice USDT per 1 WHSK at 8 decimals.
    /// @param widthBps Distance from the skewed center to each edge. Must be at least `spreadFloor`.
    /// @param skewBps Signed shift of the center, in bps of the fair price. Positive holds more WHSK.
    /// @param whskInventory Balance the quote would leave in WHSK.
    /// @param usdtInventory Balance the quote would leave in USDT.
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
    ) public pure returns (int24 tickLower, int24 tickUpper) {
        if (tickSpacing <= 0) revert BadSpacing();
        if (widthBps < spreadFloor) revert DeskPolicy.Policy(keccak256("BELOW_SPREAD"));
        if (widthBps >= BPS) revert BadWidth();
        if (whskInventory > whskCap || usdtInventory > usdtCap) revert DeskPolicy.Policy(keccak256("INVENTORY_CAP"));
        if (skewBps > 0 && whskInventory >= whskCap) revert DeskPolicy.Policy(keccak256("INVENTORY_CAP"));
        if (skewBps < 0 && usdtInventory >= usdtCap) revert DeskPolicy.Policy(keccak256("INVENTORY_CAP"));

        uint256 mid = center(fairPrice, skewBps);
        uint256 lowerPrice = MulDiv.mulDiv(mid, BPS - widthBps, BPS);
        uint256 upperPrice = MulDiv.mulDiv(mid, BPS + widthBps, BPS);
        if (lowerPrice == 0) revert BadWidth();

        tickLower = _floor(tickAtFairPrice(lowerPrice), tickSpacing);
        tickUpper = _ceil(tickAtFairPrice(upperPrice), tickSpacing);
        if (tickLower < MIN_TICK || tickUpper > MAX_TICK) revert SqrtTick.TickOutOfRange();
        if (tickUpper <= tickLower) {
            if (tickLower > MAX_TICK - tickSpacing) revert SqrtTick.TickOutOfRange();
            tickUpper = tickLower + tickSpacing;
        }
    }

    /// @notice Greatest tick whose sqrt price is still at or below `fairPrice`.
    function tickAtFairPrice(uint256 fairPrice) internal pure returns (int24 tick) {
        uint160 sqrtPrice = _sqrtPriceX96(fairPrice);
        if (sqrtPrice < SqrtTick.sqrtPriceX96(MIN_TICK) || sqrtPrice >= SqrtTick.sqrtPriceX96(MAX_TICK)) {
            revert SqrtTick.TickOutOfRange();
        }

        int24 low = MIN_TICK;
        int24 high = MAX_TICK;
        while (low < high) {
            int24 mid = int24(int256(low) + (int256(high) - int256(low) + 1) / 2);
            if (SqrtTick.sqrtPriceX96(mid) <= sqrtPrice) low = mid;
            else high = mid - 1;
        }
        return low;
    }

    /// @notice Where `tick` sits relative to a half-open range `[tickLower, tickUpper)`.
    function place(int24 tick, int24 tickLower, int24 tickUpper) internal pure returns (Place) {
        if (tick < tickLower) return Place.Below;
        if (tick >= tickUpper) return Place.Above;
        return Place.Inside;
    }

    /// @notice Fair price shifted by `skewBps`. This is the mid the quote posts.
    function center(uint256 fairPrice, int256 skewBps) public pure returns (uint256) {
        if (skewBps <= -int256(BPS)) revert BadSkew();
        return MulDiv.mulDiv(fairPrice, uint256(int256(BPS) + skewBps), BPS);
    }

    function _sqrtPriceX96(uint256 fairPrice) private pure returns (uint160) {
        if (fairPrice == 0) revert DeskPolicy.Policy(keccak256("INVALID_PRICE"));
        uint256 ratioX192 = MulDiv.mulDiv(fairPrice, uint256(1) << 192, FAIR_TO_RATIO);
        uint256 root = _sqrt(ratioX192);
        if (root > type(uint160).max) revert SqrtTick.TickOutOfRange();
        return uint160(root);
    }

    function _floor(int24 tick, int24 spacing) private pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) compressed -= 1;
        return compressed * spacing;
    }

    function _ceil(int24 tick, int24 spacing) private pure returns (int24) {
        int24 compressed = tick / spacing;
        if (tick > 0 && tick % spacing != 0) compressed += 1;
        return compressed * spacing;
    }

    /// @dev Floor of the square root. Newton's method after a power-of-two guess.
    function _sqrt(uint256 x) private pure returns (uint256 result) {
        if (x == 0) return 0;
        uint256 xAux = x;
        result = 1;
        if (xAux >= 0x100000000000000000000000000000000) {
            xAux >>= 128;
            result <<= 64;
        }
        if (xAux >= 0x10000000000000000) {
            xAux >>= 64;
            result <<= 32;
        }
        if (xAux >= 0x100000000) {
            xAux >>= 32;
            result <<= 16;
        }
        if (xAux >= 0x10000) {
            xAux >>= 16;
            result <<= 8;
        }
        if (xAux >= 0x100) {
            xAux >>= 8;
            result <<= 4;
        }
        if (xAux >= 0x10) {
            xAux >>= 4;
            result <<= 2;
        }
        if (xAux >= 0x8) result <<= 1;

        unchecked {
            result = (result + x / result) >> 1;
            result = (result + x / result) >> 1;
            result = (result + x / result) >> 1;
            result = (result + x / result) >> 1;
            result = (result + x / result) >> 1;
            result = (result + x / result) >> 1;
            result = (result + x / result) >> 1;
            uint256 rounded = x / result;
            return result >= rounded ? rounded : result;
        }
    }
}
