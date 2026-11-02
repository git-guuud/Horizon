// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FairPrice} from "../src/price/FairPrice.sol";
import {FallbackFairPrice} from "../src/price/FallbackFairPrice.sol";
import {MockFairPrice} from "./mocks/MockFairPrice.sol";

contract FallbackFairPriceTest is Test {
    MockFairPrice internal primary;
    MockFairPrice internal secondary;
    FallbackFairPrice internal fair;

    function setUp() public {
        primary = new MockFairPrice();
        secondary = new MockFairPrice();
        fair = new FallbackFairPrice(address(primary), address(secondary));
    }

    function test_mock_primaryFresh_skipsSecondary() public {
        primary.setAnswer(3e8);
        secondary.setAnswer(4e8);

        (uint256 answer, uint256 updatedAt, bool usedSecondary) = fair.read();
        assertEq(answer, 3e8);
        assertEq(updatedAt, block.timestamp);
        assertFalse(usedSecondary);

        (uint256 latest,) = fair.latestPrice();
        assertEq(latest, 3e8);
        assertEq(fair.decimals(), FairPrice.DECIMALS);
    }

    /// @dev MOCK primary. A denied or stale primary read uses the secondary adapter.
    function test_mock_primaryDeniedOrStale_usesSecondary() public {
        secondary.setAnswer(2e8);

        primary.setDeny(true);
        (uint256 answer,, bool usedSecondary) = fair.read();
        assertEq(answer, 2e8);
        assertTrue(usedSecondary);

        primary.setDeny(false);
        primary.setStale(true);
        (answer,, usedSecondary) = fair.read();
        assertEq(answer, 2e8);
        assertTrue(usedSecondary);

        secondary.setDeny(true);
        vm.expectRevert(bytes("No access"));
        fair.read();
    }
}
