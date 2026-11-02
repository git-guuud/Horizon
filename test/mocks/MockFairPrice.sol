// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FairPrice} from "../../src/price/FairPrice.sol";
import {IFairPrice} from "../../src/price/IFairPrice.sol";

/// @title MockFairPrice
/// @notice MOCK. Stand-in for an `IFairPrice` adapter. Not APRO and not the pool TWAP.
contract MockFairPrice is IFairPrice {
    uint8 public constant decimals = FairPrice.DECIMALS;
    uint256 public constant maxStaleness = FairPrice.MAX_STALENESS;

    uint256 public answer = 1e8;
    bool public stale;
    bool public invalid;
    bool public deny;

    function setAnswer(uint256 answer_) external {
        answer = answer_;
    }

    function setStale(bool stale_) external {
        stale = stale_;
    }

    function setInvalid(bool invalid_) external {
        invalid = invalid_;
    }

    function setDeny(bool deny_) external {
        deny = deny_;
    }

    function latestPrice() external view returns (uint256, uint256) {
        if (deny) revert("No access");
        if (stale) revert FairPrice.StalePrice(0, block.timestamp);
        if (invalid || answer == 0) revert FairPrice.InvalidPrice();
        return (answer, block.timestamp);
    }
}
