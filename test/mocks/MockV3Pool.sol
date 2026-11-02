// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ITwapPool} from "../../src/price/ITwapPool.sol";

/// @title MockV3Pool
/// @notice MOCK. Programmable observations. Not the HSKSwap pool.
contract MockV3Pool is ITwapPool {
    address public factory;
    address public token0;
    address public token1;
    uint24 public fee;
    uint16 public observationCardinality = 2;

    uint32 public observationTime;
    int56 public cumulativeAgo;
    int56 public cumulativeNow;
    string public revertReason;

    constructor(address token0_, address token1_, uint24 fee_) {
        factory = address(this);
        token0 = token0_;
        token1 = token1_;
        fee = fee_;
    }

    function setObservation(uint32 observationTime_, int56 cumulativeAgo_, int56 cumulativeNow_) external {
        observationTime = observationTime_;
        cumulativeAgo = cumulativeAgo_;
        cumulativeNow = cumulativeNow_;
    }

    function setRevertReason(string calldata reason) external {
        revertReason = reason;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (0, 0, 0, observationCardinality, observationCardinality, 0, true);
    }

    function observations(uint256) external view returns (uint32, int56, uint160, bool) {
        return (observationTime, cumulativeNow, 0, true);
    }

    function observe(uint32[] calldata)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        if (bytes(revertReason).length != 0) revert(revertReason);
        tickCumulatives = new int56[](2);
        tickCumulatives[0] = cumulativeAgo;
        tickCumulatives[1] = cumulativeNow;
        secondsPerLiquidityCumulativeX128s = new uint160[](2);
    }
}
