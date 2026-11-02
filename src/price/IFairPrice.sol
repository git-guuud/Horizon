// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IFairPrice
/// @notice USDT per 1 WHSK. Both adapters use the same decimals and the same stale rule.
interface IFairPrice {
    /// @notice Shared scale. 8 matches the APRO feeds.
    function decimals() external view returns (uint8);

    /// @notice A reading older than this many seconds is stale.
    function maxStaleness() external view returns (uint256);

    /// @notice Fee-free USDT per 1 WHSK, scaled by `decimals()`.
    /// @dev Reverts `StalePrice(uint256,uint256)` when the reading is older than `maxStaleness`.
    ///      Reverts `InvalidPrice()` when the reading is empty, in the future, or rounds to zero.
    ///      An APRO access denial bubbles through unchanged.
    function latestPrice() external view returns (uint256 answer, uint256 updatedAt);
}
