// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AproFairPrice} from "../src/price/AproFairPrice.sol";
import {FairPrice} from "../src/price/FairPrice.sol";
import {MulDiv} from "../src/price/MulDiv.sol";
import {SqrtTick} from "../src/price/SqrtTick.sol";
import {TwapFairPrice} from "../src/price/TwapFairPrice.sol";
import {MockAproFeed} from "./mocks/MockAproFeed.sol";
import {MockToken} from "./mocks/MockToken.sol";
import {MockV3Pool} from "./mocks/MockV3Pool.sol";

contract FairPriceTest is Test {
    uint256 internal constant HEARTBEAT = 1 hours;
    uint32 internal constant WINDOW = 30 minutes;
    uint256 internal constant NOW = 1_700_000_000;

    int256 internal constant HSK_USD = 8_734_450;
    int256 internal constant USDT_USD = 99_890_500;
    uint256 internal constant CROSS = 8_744_024;

    MockToken internal whsk;
    MockToken internal usdt;
    MockAproFeed internal hskFeed;
    MockAproFeed internal usdtFeed;
    MockV3Pool internal pool;
    AproFairPrice internal apro;
    TwapFairPrice internal twap;

    function setUp() public {
        vm.warp(NOW);
        whsk = new MockToken("WHSK", 18);
        usdt = new MockToken("USDT", 6);
        hskFeed = new MockAproFeed(8);
        usdtFeed = new MockAproFeed(8);
        pool = new MockV3Pool(address(whsk), address(usdt), 3000);
        apro = new AproFairPrice(address(hskFeed), address(usdtFeed), HEARTBEAT);
        twap = new TwapFairPrice(address(pool), pool.factory(), address(whsk), address(usdt), 3000, WINDOW, HEARTBEAT);
    }

    function test_decimals_matchOnBothAdapters() public view {
        assertEq(apro.decimals(), 8);
        assertEq(twap.decimals(), 8);
        assertEq(apro.decimals(), twap.decimals());
        assertEq(apro.maxStaleness(), twap.maxStaleness());
    }

    function test_apro_freshPrice() public {
        _feeds(HSK_USD, NOW, USDT_USD, NOW);
        (uint256 answer, uint256 updatedAt) = apro.latestPrice();
        assertEq(answer, CROSS);
        assertEq(updatedAt, NOW);
    }

    function test_apro_freshAtExactHeartbeat() public {
        _feeds(HSK_USD, NOW, USDT_USD, NOW - HEARTBEAT);
        (uint256 answer, uint256 updatedAt) = apro.latestPrice();
        assertEq(answer, CROSS);
        assertEq(updatedAt, NOW - HEARTBEAT);
    }

    function test_apro_stalePrice() public {
        uint256 staleAt = NOW - HEARTBEAT - 1;
        _feeds(HSK_USD, NOW, USDT_USD, staleAt);
        vm.expectRevert(abi.encodeWithSignature("StalePrice(uint256,uint256)", staleAt, NOW));
        apro.latestPrice();
    }

    function test_apro_invalidWhenAnswerIsZero() public {
        _feeds(0, NOW, USDT_USD, NOW);
        vm.expectRevert(FairPrice.InvalidPrice.selector);
        apro.latestPrice();
    }

    function test_apro_invalidWhenRoundIsIncomplete() public {
        hskFeed.setRound(2, HSK_USD, NOW, 1);
        usdtFeed.setRound(1, USDT_USD, NOW, 1);
        vm.expectRevert(FairPrice.InvalidPrice.selector);
        apro.latestPrice();
    }

    function test_mockApro_deniedFeedBubblesNoAccess() public {
        hskFeed.setDeny(true);
        vm.expectRevert(bytes("No access"));
        apro.latestPrice();
    }

    function test_twap_freshPriceAtTickZero() public {
        _flat(0, NOW);
        (uint256 answer, uint256 updatedAt) = twap.latestPrice();
        assertEq(answer, 100e18);
        assertEq(updatedAt, NOW);
    }

    function test_twap_freshPriceAtPinnedTick() public {
        _flat(-300697, NOW);
        (uint256 answer, uint256 updatedAt) = twap.latestPrice();
        assertEq(answer, 8_740_700);
        assertEq(updatedAt, NOW);
    }

    function test_twap_roundsNegativeMeanTowardNegativeInfinity() public {
        pool.setObservation(uint32(NOW), 0, -541_254_601);
        (uint256 answer,) = twap.latestPrice();
        assertEq(answer, 8_739_800);
    }

    function test_twap_freshAtExactHeartbeat() public {
        _flat(-300697, NOW - HEARTBEAT);
        (uint256 answer, uint256 updatedAt) = twap.latestPrice();
        assertEq(answer, 8_740_700);
        assertEq(updatedAt, NOW - HEARTBEAT);
    }

    function test_twap_stalePrice() public {
        uint256 staleAt = NOW - HEARTBEAT - 1;
        _flat(-300697, staleAt);
        vm.expectRevert(abi.encodeWithSignature("StalePrice(uint256,uint256)", staleAt, NOW));
        twap.latestPrice();
    }

    function test_twap_staleWhenObserveIsOld() public {
        _flat(-300697, NOW);
        pool.setRevertReason("OLD");
        vm.expectRevert(abi.encodeWithSignature("StalePrice(uint256,uint256)", NOW, NOW));
        twap.latestPrice();
    }

    function test_twap_bubblesUnknownPoolRevert() public {
        _flat(-300697, NOW);
        pool.setRevertReason("LOCKED");
        vm.expectRevert(bytes("LOCKED"));
        twap.latestPrice();
    }

    function test_sqrtPrice_tickZeroAndPinnedTick() public pure {
        assertEq(SqrtTick.sqrtPriceX96(0), uint160(1) << 96);
        assertEq(SqrtTick.sqrtPriceX96(-300697), 23_423_600_284_292_666_011_778);
    }

    function test_mulDiv_fullWidthProduct() public pure {
        assertEq(MulDiv.mulDiv(7, 3, 2), 10);
        assertEq(MulDiv.mulDiv(type(uint256).max, type(uint256).max, type(uint256).max), type(uint256).max);
    }

    function _feeds(int256 hsk, uint256 hskAt, int256 usdtAnswer, uint256 usdtAt) internal {
        hskFeed.setRound(1, hsk, hskAt, 1);
        usdtFeed.setRound(1, usdtAnswer, usdtAt, 1);
    }

    function _flat(int24 tick, uint256 observedAt) internal {
        pool.setObservation(uint32(observedAt), 0, int56(tick) * int56(uint56(WINDOW)));
    }
}
