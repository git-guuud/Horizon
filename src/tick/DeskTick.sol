// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DeskFill} from "../fill/DeskFill.sol";
import {FallbackFairPrice} from "../price/FallbackFairPrice.sol";
import {DeskQuote} from "../quote/DeskQuote.sol";
import {RangeMath} from "../quote/RangeMath.sol";

/// @title DeskTick
/// @notice One poke on a fork. It reads the fair price and, when that tick is outside the position,
///         recenters at the stored width. A fill is submitted only when the caller passes an already
///         signed intent. DeskFill still refuses a size the pool can fill inside the band.
///         This contract holds no key and it does not broadcast.
contract DeskTick {
    /// @dev Fixed reason. The recenter event stores keccak256 of these bytes.
    string public constant REASON = "fair tick left the position";

    DeskQuote public immutable quote;
    DeskFill public immutable desk;
    FallbackFairPrice public immutable fair;

    error BadDesk();

    constructor(address quote_, address desk_, address fair_) {
        if (quote_ == address(0) || desk_ == address(0) || fair_ == address(0)) revert BadDesk();
        DeskQuote quoteBound = DeskQuote(quote_);
        DeskFill deskBound = DeskFill(desk_);
        if (address(quoteBound.policy()) != address(deskBound.policy())) revert BadDesk();
        if (address(quoteBound.fair()) != fair_) revert BadDesk();
        if (address(deskBound.policy().fair()) != fair_) revert BadDesk();

        quote = quoteBound;
        desk = deskBound;
        fair = FallbackFairPrice(fair_);
    }

    /// @notice Recenter when the fair tick is outside. Fill only when `submitFill` is set.
    /// @param submitFill The signed intent is ignored when this is false.
    function tick(
        bool submitFill,
        DeskFill.Intent calldata intent,
        bytes calldata signature,
        string calldata fillReason,
        bytes32 fillReasonHash
    ) external {
        (uint256 price,,) = fair.read();
        int24 fairTick = RangeMath.tickAtFairPrice(price);
        if (RangeMath.place(fairTick, quote.tickLower(), quote.tickUpper()) != RangeMath.Place.Inside) {
            quote.recenter(0, REASON);
        }
        if (submitFill) desk.fill(intent, signature, fillReason, fillReasonHash);
    }
}
