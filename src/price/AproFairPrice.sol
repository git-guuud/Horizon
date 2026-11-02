// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IAproFeed} from "../market/Interfaces.sol";
import {FairPrice} from "./FairPrice.sol";
import {IFairPrice} from "./IFairPrice.sol";

/// @title AproFairPrice
/// @notice USDT per 1 WHSK from APRO HSK/USD and USDT/USD.
///         A contract caller is denied on HashKey mainnet. That revert is not caught.
contract AproFairPrice is IFairPrice {
    uint8 public constant decimals = FairPrice.DECIMALS;

    uint256 public immutable maxStaleness;
    IAproFeed public immutable hskUsd;
    IAproFeed public immutable usdtUsd;

    constructor(address hskUsd_, address usdtUsd_, uint256 maxStaleness_) {
        require(hskUsd_ != address(0) && usdtUsd_ != address(0) && hskUsd_ != usdtUsd_, "feed");
        require(maxStaleness_ != 0, "staleness");
        hskUsd = IAproFeed(hskUsd_);
        usdtUsd = IAproFeed(usdtUsd_);
        maxStaleness = maxStaleness_;
        require(hskUsd.decimals() == FairPrice.DECIMALS && usdtUsd.decimals() == FairPrice.DECIMALS, "feed decimals");
    }

    /// @inheritdoc IFairPrice
    function latestPrice() external view returns (uint256 answer, uint256 updatedAt) {
        (uint256 hsk, uint256 hskUpdated) = _read(hskUsd);
        (uint256 usdt, uint256 usdtUpdated) = _read(usdtUsd);
        updatedAt = hskUpdated < usdtUpdated ? hskUpdated : usdtUpdated;
        FairPrice.requireFresh(updatedAt, maxStaleness);
        answer = (hsk * (10 ** FairPrice.DECIMALS)) / usdt;
        if (answer == 0) revert FairPrice.InvalidPrice();
    }

    function _read(IAproFeed feed) internal view returns (uint256 answer, uint256 updatedAt) {
        (uint80 roundId, int256 raw,, uint256 updated, uint80 answeredInRound) = feed.latestRoundData();
        if (raw <= 0 || answeredInRound < roundId) revert FairPrice.InvalidPrice();
        return (uint256(raw), updated);
    }
}
