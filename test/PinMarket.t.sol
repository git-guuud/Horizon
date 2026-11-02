// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {MarketPin} from "../src/market/MarketPin.sol";
import {Seeds} from "../src/market/Seeds.sol";

contract PinMarketTest is Test {
    using stdJson for string;

    MarketPin internal pin;
    MarketPin.Snapshot internal snap;

    function setUp() public {
        vm.createSelectFork("hashkey");
        pin = new MarketPin();
        snap = pin.read();
    }

    function test_forkIsHashKeyMainnet() public view {
        assertEq(block.chainid, Seeds.CHAIN_ID);
        assertEq(snap.chainId, 177);
    }

    function test_tokensMatchChain() public view {
        assertEq(snap.whsk.token, Seeds.WHSK);
        assertEq(snap.whsk.symbol, "WHSK");
        assertEq(snap.whsk.decimals, 18);
        assertEq(snap.usdt.token, Seeds.USDT);
        assertEq(snap.usdt.symbol, "USDT");
        assertEq(snap.usdt.decimals, 6);
    }

    function test_hskswapPeripherySharesTheFactory() public view {
        assertEq(snap.factory, Seeds.HSKSWAP_FACTORY);
        assertEq(snap.swapRouter02, Seeds.HSKSWAP_SWAP_ROUTER_02);
        assertEq(snap.positionManager, Seeds.HSKSWAP_POSITION_MANAGER);
        assertEq(snap.quoterV2, Seeds.HSKSWAP_QUOTER_V2);
        assertTrue(snap.factory != snap.hyperindexV3Factory);
        assertTrue(snap.pool.pool != snap.hyperindexPool);
    }

    function test_poolIsTheDeepestWHSKUSDTPool() public view {
        assertGt(snap.pool.liquidity, 0);
        assertGt(snap.pool.slot0.sqrtPriceX96, 0);
        assertTrue(snap.pool.slot0.unlocked);
        assertGt(snap.quoteAmountOut, 0);
    }

    function test_aproIsLiveOrDenied() public view {
        _assertApro(snap.hskUsd, "HSK/USD");
        _assertApro(snap.usdtUsd, "USDT/USD");
    }

    function test_addressesJsonMatchesTheFork() public view {
        string memory raw = vm.readFile("addresses.json");
        assertEq(raw.readUint(".chainId"), snap.chainId);
        assertEq(raw.readAddress(".whsk.address"), snap.whsk.token);
        assertEq(raw.readString(".whsk.symbol"), snap.whsk.symbol);
        assertEq(raw.readUint(".whsk.decimals"), snap.whsk.decimals);
        assertEq(raw.readAddress(".usdt.address"), snap.usdt.token);
        assertEq(raw.readString(".usdt.symbol"), snap.usdt.symbol);
        assertEq(raw.readUint(".usdt.decimals"), snap.usdt.decimals);
        assertEq(raw.readAddress(".hskswap.factory"), snap.factory);
        assertEq(raw.readAddress(".hskswap.swapRouter02"), snap.swapRouter02);
        assertEq(raw.readAddress(".hskswap.nonfungiblePositionManager"), snap.positionManager);
        assertEq(raw.readAddress(".hskswap.quoterV2"), snap.quoterV2);
        assertEq(raw.readAddress(".pool.address"), snap.pool.pool);
        assertEq(raw.readUint(".pool.fee"), snap.pool.fee);
        assertEq(raw.readAddress(".hyperindexV3Factory"), snap.hyperindexV3Factory);
        assertEq(raw.readAddress(".hyperindexPool"), snap.hyperindexPool);
        _assertAproJson(raw, ".apro.hskUsd", snap.hskUsd);
        _assertAproJson(raw, ".apro.usdtUsd", snap.usdtUsd);
        assertGt(bytes(raw.readString(".pool.liquidity")).length, 0);
        assertGt(bytes(raw.readString(".pool.slot0.sqrtPriceX96")).length, 0);
    }

    function _assertAproJson(string memory raw, string memory key, MarketPin.Apro memory a) internal pure {
        assertEq(raw.readString(string.concat(key, ".status")), a.status);
        assertEq(raw.readString(string.concat(key, ".description")), a.description);
        assertEq(raw.readAddress(string.concat(key, ".address")), a.feed);
        if (keccak256(bytes(a.status)) == keccak256("denied")) {
            assertEq(raw.readString(string.concat(key, ".revert")), a.revertReason);
        }
    }

    function _assertApro(MarketPin.Apro memory a, string memory description) internal pure {
        assertEq(a.description, description);
        assertEq(a.decimals, 8);
        assertTrue(keccak256(bytes(a.status)) == keccak256("live") || keccak256(bytes(a.status)) == keccak256("denied"));
        if (keccak256(bytes(a.status)) == keccak256("live")) {
            assertGt(a.answer, 0);
            assertGt(a.updatedAt, 0);
        } else {
            assertGt(a.revertData.length, 0);
        }
    }
}
