// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title FairPrice
/// @notice Shared scale and freshness rule for the APRO and TWAP adapters.
library FairPrice {
    /// @dev Both adapters quote at this scale.
    uint8 internal constant DECIMALS = 8;

    /// @dev Desk heartbeat. The fork wires both adapters with this value.
    uint256 internal constant MAX_STALENESS = 1 days;

    /// @dev Window the pinned pool's observations can cover.
    uint32 internal constant TWAP_WINDOW = 30 minutes;

    /// @notice `updatedAt` is older than `maxStaleness`.
    error StalePrice(uint256 updatedAt, uint256 blockTimestamp);

    /// @notice The reading is empty, in the future, incomplete, or rounds to zero.
    error InvalidPrice();

    /// @dev A reading exactly `maxStaleness` seconds old is still fresh.
    function requireFresh(uint256 updatedAt, uint256 maxStaleness) internal view {
        if (updatedAt == 0 || updatedAt > block.timestamp) revert InvalidPrice();
        if (block.timestamp - updatedAt > maxStaleness) revert StalePrice(updatedAt, block.timestamp);
    }
}
