// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {MarketPin} from "../src/market/MarketPin.sol";
import {Seeds} from "../src/market/Seeds.sol";
import {AproFairPrice} from "../src/price/AproFairPrice.sol";
import {FairPrice} from "../src/price/FairPrice.sol";
import {TwapFairPrice} from "../src/price/TwapFairPrice.sol";

contract FairPriceForkTest is Test {
    AproFairPrice internal apro;
    TwapFairPrice internal twap;

    function setUp() public {
        vm.createSelectFork("hashkey");
        MarketPin.Snapshot memory snap = new MarketPin().read();
        apro = new AproFairPrice(Seeds.APRO_HSK_USD, Seeds.APRO_USDT_USD, FairPrice.MAX_STALENESS);
        twap = new TwapFairPrice(
            snap.pool.pool,
            snap.factory,
            snap.whsk.token,
            snap.usdt.token,
            snap.pool.fee,
            FairPrice.TWAP_WINDOW,
            FairPrice.MAX_STALENESS
        );
    }

    /// @dev APRO denies this contract. The pinned-pool TWAP still returns a price.
    function test_fork_aproDenied_twapReturnsPrice() public {
        vm.expectRevert(bytes("No access"));
        apro.latestPrice();

        (uint256 answer, uint256 updatedAt) = twap.latestPrice();
        assertEq(apro.decimals(), 8);
        assertEq(twap.decimals(), apro.decimals());
        assertGt(answer, 5_000_000);
        assertLt(answer, 20_000_000);
        assertLe(block.timestamp - updatedAt, twap.maxStaleness());
        assertEq(twap.twapWindow(), FairPrice.TWAP_WINDOW);

        console2.log("twap USDT per WHSK, 8 decimals", answer);
        console2.log("twap updatedAt", updatedAt);
    }
}
