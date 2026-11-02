// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20Metadata} from "../market/Interfaces.sol";
import {FairPrice} from "./FairPrice.sol";
import {IFairPrice} from "./IFairPrice.sol";
import {ITwapPool} from "./ITwapPool.sol";
import {MulDiv} from "./MulDiv.sol";
import {SqrtTick} from "./SqrtTick.sol";

/// @title TwapFairPrice
/// @notice Fee-free v3 TWAP of the pinned WHSK/USDT pool, in the same units as `AproFairPrice`.
contract TwapFairPrice is IFairPrice {
    uint8 public constant decimals = FairPrice.DECIMALS;

    uint256 public immutable maxStaleness;
    uint32 public immutable twapWindow;
    ITwapPool public immutable pool;
    address public immutable whsk;
    address public immutable usdt;
    uint256 public immutable whskUnit;
    uint256 public immutable scaleToFair;

    constructor(
        address pool_,
        address factory_,
        address whsk_,
        address usdt_,
        uint24 fee_,
        uint32 twapWindow_,
        uint256 maxStaleness_
    ) {
        require(pool_ != address(0) && factory_ != address(0), "pool");
        require(whsk_ != address(0) && usdt_ != address(0) && whsk_ != usdt_, "token");
        require(twapWindow_ != 0 && maxStaleness_ != 0, "window");

        ITwapPool v3 = ITwapPool(pool_);
        require(v3.factory() == factory_, "factory");
        require(v3.fee() == fee_, "fee");
        require(v3.token0() == whsk_ && v3.token1() == usdt_, "pair");

        uint8 whskDecimals = IERC20Metadata(whsk_).decimals();
        uint8 usdtDecimals = IERC20Metadata(usdt_).decimals();
        require(whskDecimals == 18, "whsk decimals");
        require(usdtDecimals <= FairPrice.DECIMALS, "usdt decimals");

        pool = v3;
        whsk = whsk_;
        usdt = usdt_;
        twapWindow = twapWindow_;
        maxStaleness = maxStaleness_;
        whskUnit = 10 ** whskDecimals;
        scaleToFair = 10 ** (FairPrice.DECIMALS - usdtDecimals);
    }

    /// @inheritdoc IFairPrice
    function latestPrice() external view returns (uint256 answer, uint256 updatedAt) {
        (,, uint16 index, uint16 cardinality,,,) = pool.slot0();
        if (cardinality == 0) revert FairPrice.InvalidPrice();

        (uint32 observationTime,,, bool initialized) = pool.observations(index);
        if (!initialized) revert FairPrice.InvalidPrice();
        updatedAt = _unix(observationTime);
        FairPrice.requireFresh(updatedAt, maxStaleness);

        int24 tick = _consult(updatedAt);
        uint256 rawUsdt = _quote(SqrtTick.sqrtPriceX96(tick), whskUnit);
        answer = rawUsdt * scaleToFair;
        if (answer == 0) revert FairPrice.InvalidPrice();
    }

    function _consult(uint256 updatedAt) internal view returns (int24 tick) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapWindow;
        secondsAgos[1] = 0;

        try pool.observe(secondsAgos) returns (int56[] memory tickCumulatives, uint160[] memory) {
            int56 delta = tickCumulatives[1] - tickCumulatives[0];
            int56 period = int56(uint56(twapWindow));
            tick = int24(delta / period);
            if (delta < 0 && delta % period != 0) tick -= 1;
        } catch (bytes memory reason) {
            if (keccak256(reason) == keccak256(abi.encodeWithSignature("Error(string)", "OLD"))) {
                revert FairPrice.StalePrice(updatedAt, block.timestamp);
            }
            assembly {
                revert(add(reason, 32), mload(reason))
            }
        }
    }

    /// @dev Pool observation times are uint32. Reconstruct the unix time from the current block.
    function _unix(uint32 observationTime) internal view returns (uint256) {
        uint32 elapsed = uint32(block.timestamp) - observationTime;
        return block.timestamp - elapsed;
    }

    /// @dev USDT raw units for `baseAmount` of WHSK. Token0 is WHSK and token1 is USDT, so the
    ///      sqrt price is already token1/token0.
    function _quote(uint160 sqrtPriceX96, uint256 baseAmount) internal pure returns (uint256) {
        if (sqrtPriceX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtPriceX96) * sqrtPriceX96;
            return MulDiv.mulDiv(ratioX192, baseAmount, 1 << 192);
        }
        uint256 ratioX128 = MulDiv.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
        return MulDiv.mulDiv(ratioX128, baseAmount, 1 << 128);
    }
}
