// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CloseValue} from "../src/quote/CloseValue.sol";

/// @notice Fixed balances. No pool and no RPC.
contract CloseValueTest is Test {
    uint256 internal constant FAIR = 8_754_700;

    function test_zeroFees_spreadIsZero() public pure {
        (uint256 fee0, uint256 fee1) = CloseValue.splitFees(5 ether, 7e6, 5 ether, 7e6);
        assertEq(fee0, 0);
        assertEq(fee1, 0);
        assertEq(CloseValue.spreadCaptured(fee0, fee1, FAIR), 0);

        uint256 whskBefore = 10 ether;
        uint256 usdtBefore = 1_000e6;
        uint256 principalWhsk = 1 ether;
        uint256 principalUsdt = 100e6;
        int256 delta = CloseValue.holdingDelta(whskBefore, usdtBefore, principalWhsk, principalUsdt, FAIR);
        int256 expected = int256(CloseValue.value(principalWhsk, principalUsdt, FAIR))
            - int256(CloseValue.value(whskBefore, usdtBefore, FAIR));
        assertEq(delta, expected);
        assertLt(delta, 0);
    }

    function test_fixedBalances_feesAndPrincipalChange() public pure {
        uint256 feeWhsk = 1e17;
        uint256 feeUsdt = 2e6;
        (uint256 fee0, uint256 fee1) = CloseValue.splitFees(5 ether + feeWhsk, 7e6 + feeUsdt, 5 ether, 7e6);
        assertEq(fee0, feeWhsk);
        assertEq(fee1, feeUsdt);
        // 0.1 WHSK at 0.087547 USDT is 8754 raw. The 2 USDT fee is 2_000_000 raw.
        assertEq(CloseValue.value(feeWhsk, 0, FAIR), 8754);
        assertEq(CloseValue.spreadCaptured(fee0, fee1, FAIR), 2_008_754);

        uint256 whskBefore = 10 ether;
        uint256 usdtBefore = 1_000e6;
        uint256 principal0 = 4 ether;
        uint256 principal1 = 200e6;
        int256 delta =
            CloseValue.holdingDelta(whskBefore, usdtBefore, whskBefore + principal0, usdtBefore + principal1, FAIR);
        assertEq(delta, int256(CloseValue.value(principal0, principal1, FAIR)));
        assertGt(delta, 0);
    }

    function test_collectShortOfPrincipal_isZeroFees() public pure {
        (uint256 fee0, uint256 fee1) = CloseValue.splitFees(4, 1, 5, 2);
        assertEq(fee0, 0);
        assertEq(fee1, 0);
    }
}
