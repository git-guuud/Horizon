// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IAproFeed} from "../../src/market/Interfaces.sol";

/// @title MockAproFeed
/// @notice MOCK. Stand-in for an APRO aggregator. Not a mainnet feed.
contract MockAproFeed is IAproFeed {
    uint8 public decimals;
    string public description = "MOCK";
    bool public deny;
    uint80 public roundId = 1;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public answeredInRound = 1;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function setRound(uint80 roundId_, int256 answer_, uint256 updatedAt_, uint80 answeredInRound_) external {
        roundId = roundId_;
        answer = answer_;
        updatedAt = updatedAt_;
        answeredInRound = answeredInRound_;
    }

    function setDeny(bool deny_) external {
        deny = deny_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (deny) revert("No access");
        return (roundId, answer, updatedAt, updatedAt, answeredInRound);
    }
}
