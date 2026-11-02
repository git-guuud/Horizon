// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FairPrice} from "./FairPrice.sol";
import {IFairPrice} from "./IFairPrice.sol";

/// @title FallbackFairPrice
/// @notice Tries the primary adapter, then the secondary. On HashKey mainnet the primary
///         is APRO, which reverts `No access` for a contract caller. That failure is caught
///         and the secondary, the pool TWAP, is the price. A revert from the secondary is not caught.
contract FallbackFairPrice is IFairPrice {
    uint8 public constant decimals = FairPrice.DECIMALS;

    uint256 public immutable maxStaleness;
    IFairPrice public immutable primary;
    IFairPrice public immutable secondary;

    constructor(address primary_, address secondary_) {
        require(primary_ != address(0) && secondary_ != address(0) && primary_ != secondary_, "feed");
        primary = IFairPrice(primary_);
        secondary = IFairPrice(secondary_);
        require(primary.decimals() == FairPrice.DECIMALS && secondary.decimals() == FairPrice.DECIMALS, "decimals");
        maxStaleness = primary.maxStaleness();
        require(maxStaleness != 0 && secondary.maxStaleness() != 0, "staleness");
    }

    /// @inheritdoc IFairPrice
    function latestPrice() external view returns (uint256 answer, uint256 updatedAt) {
        (answer, updatedAt,) = _load();
    }

    /// @notice The price, and whether the primary read failed and the secondary was used.
    function read() external view returns (uint256 answer, uint256 updatedAt, bool usedSecondary) {
        return _load();
    }

    function _load() internal view returns (uint256 answer, uint256 updatedAt, bool usedSecondary) {
        try primary.latestPrice() returns (uint256 primaryAnswer, uint256 primaryUpdated) {
            return (primaryAnswer, primaryUpdated, false);
        } catch {
            (answer, updatedAt) = secondary.latestPrice();
            usedSecondary = true;
        }
    }
}
