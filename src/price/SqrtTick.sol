// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title SqrtTick
/// @notice `sqrt(1.0001^tick) * 2^96` for a v3 tick. Factors are the published Q128.128
///         multipliers for each bit of the absolute tick.
library SqrtTick {
    error TickOutOfRange();

    int24 internal constant MAX_TICK = 887272;

    function sqrtPriceX96(int24 tick) internal pure returns (uint160) {
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        if (absTick > uint256(int256(MAX_TICK))) revert TickOutOfRange();

        uint256 ratio = _ratio(absTick);
        if (tick > 0) ratio = type(uint256).max / ratio;

        uint256 shifted = ratio >> 32;
        if (ratio % (1 << 32) != 0) shifted += 1;
        return uint160(shifted);
    }

    function _ratio(uint256 absTick) private pure returns (uint256 ratio) {
        ratio = (absTick & 0x1) == 0 ? (1 << 128) : 0xfffcb933bd6fad37aa2d162d1a594001;
        ratio = _apply(ratio, absTick, 0x2, 0xfff97272373d413259a46990580e213a);
        ratio = _apply(ratio, absTick, 0x4, 0xfff2e50f5f656932ef12357cf3c7fdcc);
        ratio = _apply(ratio, absTick, 0x8, 0xffe5caca7e10e4e61c3624eaa0941cd0);
        ratio = _apply(ratio, absTick, 0x10, 0xffcb9843d60f6159c9db58835c926644);
        ratio = _apply(ratio, absTick, 0x20, 0xff973b41fa98c081472e6896dfb254c0);
        ratio = _apply(ratio, absTick, 0x40, 0xff2ea16466c96a3843ec78b326b52861);
        ratio = _apply(ratio, absTick, 0x80, 0xfe5dee046a99a2a811c461f1969c3053);
        ratio = _apply(ratio, absTick, 0x100, 0xfcbe86c7900a88aedcffc83b479aa3a4);
        ratio = _apply(ratio, absTick, 0x200, 0xf987a7253ac413176f2b074cf7815e54);
        ratio = _apply(ratio, absTick, 0x400, 0xf3392b0822b70005940c7a398e4b70f3);
        ratio = _apply(ratio, absTick, 0x800, 0xe7159475a2c29b7443b29c7fa6e889d9);
        ratio = _apply(ratio, absTick, 0x1000, 0xd097f3bdfd2022b8845ad8f792aa5825);
        ratio = _apply(ratio, absTick, 0x2000, 0xa9f746462d870fdf8a65dc1f90e061e5);
        ratio = _apply(ratio, absTick, 0x4000, 0x70d869a156d2a1b890bb3df62baf32f7);
        ratio = _apply(ratio, absTick, 0x8000, 0x31be135f97d08fd981231505542fcfa6);
        ratio = _apply(ratio, absTick, 0x10000, 0x9aa508b5b7a84e1c677de54f3e99bc9);
        ratio = _apply(ratio, absTick, 0x20000, 0x5d6af8dedb81196699c329225ee604);
        ratio = _apply(ratio, absTick, 0x40000, 0x2216e584f5fa1ea926041bedfe98);
        ratio = _apply(ratio, absTick, 0x80000, 0x48a170391f7dc42444e8fa2);
    }

    function _apply(uint256 ratio, uint256 absTick, uint256 bit, uint256 factor) private pure returns (uint256) {
        if (absTick & bit == 0) return ratio;
        return (ratio * factor) >> 128;
    }
}
