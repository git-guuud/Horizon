// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MulDiv} from "../price/MulDiv.sol";

/// @title CloseValue
/// @notice Values a close in USDT raw. The fair mid is 8-decimal USDT per 1 WHSK.
///         WHSK has 18 decimals and USDT has 6, so one WHSK is worth `fairMid / 10^20` USDT.
///         Fees are what collect returns beyond the decreased principal.
///         Spread captured is the value of those fees.
///         Holding delta is the value of the principal after the close minus the value of the inventory before it.
library CloseValue {
    /// @dev 18 + 8 - 6.
    uint256 internal constant FAIR_TO_USDT = 10 ** 20;

    struct Snap {
        uint256 whskBefore;
        uint256 usdtBefore;
        uint256 principal0;
        uint256 principal1;
        uint256 fee0;
        uint256 fee1;
    }

    /// @notice USDT raw value of `whskAmount` and `usdtAmount` at `fairMid`.
    function value(uint256 whskAmount, uint256 usdtAmount, uint256 fairMid) internal pure returns (uint256) {
        return MulDiv.mulDiv(whskAmount, fairMid, FAIR_TO_USDT) + usdtAmount;
    }

    /// @notice Collect minus decreased principal. A short collect, from core rounding, is zero fees.
    function splitFees(uint256 collected0, uint256 collected1, uint256 principal0, uint256 principal1)
        internal
        pure
        returns (uint256 fee0, uint256 fee1)
    {
        fee0 = collected0 > principal0 ? collected0 - principal0 : 0;
        fee1 = collected1 > principal1 ? collected1 - principal1 : 0;
    }

    function spreadCaptured(uint256 fee0, uint256 fee1, uint256 fairMid) internal pure returns (uint256) {
        return value(fee0, fee1, fairMid);
    }

    function holdingDelta(
        uint256 whskBefore,
        uint256 usdtBefore,
        uint256 principalWhsk,
        uint256 principalUsdt,
        uint256 fairMid
    ) internal pure returns (int256) {
        return int256(value(principalWhsk, principalUsdt, fairMid)) - int256(value(whskBefore, usdtBefore, fairMid));
    }
}
