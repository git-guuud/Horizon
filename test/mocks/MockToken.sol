// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title MockToken
/// @notice MOCK. Decimals only. Not WHSK or USDT.
contract MockToken {
    string public symbol;
    uint8 public decimals;

    constructor(string memory symbol_, uint8 decimals_) {
        symbol = symbol_;
        decimals = decimals_;
    }
}
