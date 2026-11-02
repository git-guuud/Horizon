// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {
    IERC20Metadata,
    IAproFeed,
    IPeripheryFactory,
    IQuoterV2,
    ISwapRouter02,
    IUniswapV3Factory,
    IUniswapV3Pool
} from "./Interfaces.sol";
import {Seeds} from "./Seeds.sol";

/// @title MarketPin
/// @notice Reads the live WHSK/USDT HSKSwap market and the APRO feeds. The JSON
///         it returns is the only source for `addresses.json`.
contract MarketPin {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal constant QUOTE_AMOUNT_IN = 0.01 ether;

    struct Token {
        address token;
        string symbol;
        uint8 decimals;
    }

    struct Slot0 {
        uint160 sqrtPriceX96;
        int24 tick;
        uint16 observationIndex;
        uint16 observationCardinality;
        uint16 observationCardinalityNext;
        uint8 feeProtocol;
        bool unlocked;
    }

    struct Pool {
        address pool;
        uint24 fee;
        Slot0 slot0;
        uint128 liquidity;
    }

    struct Apro {
        address feed;
        string description;
        uint8 decimals;
        string status;
        uint80 roundId;
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
        uint80 answeredInRound;
        bytes revertData;
        string revertReason;
    }

    struct Snapshot {
        uint256 chainId;
        Token whsk;
        Token usdt;
        address factory;
        address swapRouter02;
        address positionManager;
        address quoterV2;
        Pool pool;
        Apro hskUsd;
        Apro usdtUsd;
        address hyperindexV3Factory;
        address hyperindexPool;
        uint256 quoteAmountOut;
    }

    function read() public returns (Snapshot memory snap) {
        require(block.chainid == Seeds.CHAIN_ID, "chain id");

        snap.chainId = block.chainid;
        snap.whsk = _token(Seeds.WHSK, "WHSK", 18);
        snap.usdt = _token(Seeds.USDT, "USDT", 6);

        ISwapRouter02 router = ISwapRouter02(Seeds.HSKSWAP_SWAP_ROUTER_02);
        snap.swapRouter02 = Seeds.HSKSWAP_SWAP_ROUTER_02;
        snap.factory = router.factory();
        snap.positionManager = router.positionManager();
        snap.quoterV2 = Seeds.HSKSWAP_QUOTER_V2;

        require(snap.factory == Seeds.HSKSWAP_FACTORY, "router factory");
        require(router.WETH9() == Seeds.WHSK, "router WETH9");
        require(snap.positionManager == Seeds.HSKSWAP_POSITION_MANAGER, "router position manager");
        require(IPeripheryFactory(snap.positionManager).factory() == snap.factory, "position manager factory");
        require(IPeripheryFactory(snap.quoterV2).factory() == snap.factory, "quoter factory");

        snap.pool = _deepestPool(snap.factory, snap.whsk.token, snap.usdt.token);
        require(IUniswapV3Pool(snap.pool.pool).factory() == snap.factory, "pool factory");

        snap.hyperindexV3Factory = Seeds.HYPERINDEX_V3_FACTORY;
        snap.hyperindexPool =
            IUniswapV3Factory(snap.hyperindexV3Factory).getPool(snap.whsk.token, snap.usdt.token, snap.pool.fee);
        require(snap.hyperindexV3Factory != snap.factory, "hyperindex factory");
        require(snap.hyperindexPool != snap.pool.pool, "hyperindex pool");

        (snap.quoteAmountOut,,,) = IQuoterV2(snap.quoterV2)
            .quoteExactInputSingle(
                IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: snap.whsk.token,
                tokenOut: snap.usdt.token,
                amountIn: QUOTE_AMOUNT_IN,
                fee: snap.pool.fee,
                sqrtPriceLimitX96: 0
            })
            );
        require(snap.quoteAmountOut > 0, "quoter");

        snap.hskUsd = _apro(Seeds.APRO_HSK_USD, "HSK/USD");
        snap.usdtUsd = _apro(Seeds.APRO_USDT_USD, "USDT/USD");
    }

    function toJson(Snapshot memory snap) public pure returns (string memory) {
        string memory head = string.concat(
            "{\n",
            '  "chainId": ',
            vm.toString(snap.chainId),
            ",\n",
            '  "whsk": ',
            _tokenJson(snap.whsk),
            ",\n",
            '  "usdt": ',
            _tokenJson(snap.usdt),
            ",\n",
            '  "hskswap": {\n',
            '    "factory": "',
            vm.toString(snap.factory),
            '",\n',
            '    "swapRouter02": "',
            vm.toString(snap.swapRouter02),
            '",\n',
            '    "nonfungiblePositionManager": "',
            vm.toString(snap.positionManager),
            '",\n',
            '    "quoterV2": "',
            vm.toString(snap.quoterV2),
            '"\n',
            "  },\n"
        );
        string memory pool = _poolJson(snap.pool);
        string memory apro = string.concat(
            '  "apro": {\n',
            '    "hskUsd": ',
            _aproJson(snap.hskUsd),
            ",\n",
            '    "usdtUsd": ',
            _aproJson(snap.usdtUsd),
            "\n",
            "  },\n"
        );
        string memory tail = string.concat(
            '  "hyperindexV3Factory": "',
            vm.toString(snap.hyperindexV3Factory),
            '",\n',
            '  "hyperindexPool": "',
            vm.toString(snap.hyperindexPool),
            '",\n',
            '  "quoterV2AmountOut": "',
            vm.toString(snap.quoteAmountOut),
            '"\n',
            "}\n"
        );
        return string.concat(head, pool, apro, tail);
    }

    function _poolJson(Pool memory pool) internal pure returns (string memory) {
        string memory slot0 = string.concat(
            '    "slot0": {\n',
            '      "sqrtPriceX96": "',
            vm.toString(pool.slot0.sqrtPriceX96),
            '",\n',
            '      "tick": ',
            vm.toString(pool.slot0.tick),
            ",\n",
            '      "observationIndex": ',
            vm.toString(pool.slot0.observationIndex),
            ",\n"
        );
        string memory slot0Rest = string.concat(
            '      "observationCardinality": ',
            vm.toString(pool.slot0.observationCardinality),
            ",\n",
            '      "observationCardinalityNext": ',
            vm.toString(pool.slot0.observationCardinalityNext),
            ",\n",
            '      "feeProtocol": ',
            vm.toString(pool.slot0.feeProtocol),
            ",\n",
            '      "unlocked": ',
            pool.slot0.unlocked ? "true" : "false",
            "\n",
            "    },\n"
        );
        return string.concat(
            '  "pool": {\n',
            '    "address": "',
            vm.toString(pool.pool),
            '",\n',
            '    "fee": ',
            vm.toString(pool.fee),
            ",\n",
            slot0,
            slot0Rest,
            '    "liquidity": "',
            vm.toString(pool.liquidity),
            '"\n',
            "  },\n"
        );
    }

    function _token(address token, string memory symbol, uint8 decimals) internal view returns (Token memory) {
        Token memory t;
        t.token = token;
        t.symbol = IERC20Metadata(token).symbol();
        t.decimals = IERC20Metadata(token).decimals();
        require(keccak256(bytes(t.symbol)) == keccak256(bytes(symbol)), "symbol");
        require(t.decimals == decimals, "decimals");
        return t;
    }

    function _deepestPool(address factory, address whsk, address usdt) internal view returns (Pool memory best) {
        uint24[4] memory fees = [uint24(100), 500, 3000, 10000];
        uint128 bestLiquidity;
        for (uint256 i = 0; i < fees.length; i++) {
            address pool = IUniswapV3Factory(factory).getPool(whsk, usdt, fees[i]);
            if (pool == address(0)) continue;
            uint128 liquidity = IUniswapV3Pool(pool).liquidity();
            if (liquidity > bestLiquidity) {
                bestLiquidity = liquidity;
                best = _pool(pool);
            }
        }
        require(best.pool != address(0) && best.liquidity > 0, "no pool");
        require(IUniswapV3Pool(best.pool).token0() == whsk && IUniswapV3Pool(best.pool).token1() == usdt, "pool tokens");
    }

    function _pool(address pool) internal view returns (Pool memory p) {
        IUniswapV3Pool v3 = IUniswapV3Pool(pool);
        p.pool = pool;
        p.fee = v3.fee();
        (
            p.slot0.sqrtPriceX96,
            p.slot0.tick,
            p.slot0.observationIndex,
            p.slot0.observationCardinality,
            p.slot0.observationCardinalityNext,
            p.slot0.feeProtocol,
            p.slot0.unlocked
        ) = v3.slot0();
        p.liquidity = v3.liquidity();
    }

    function _apro(address feed, string memory description) internal view returns (Apro memory a) {
        a.feed = feed;
        a.description = IAproFeed(feed).description();
        a.decimals = IAproFeed(feed).decimals();
        require(keccak256(bytes(a.description)) == keccak256(bytes(description)), "apro description");
        require(a.decimals == 8, "apro decimals");
        try IAproFeed(feed).latestRoundData() returns (
            uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound
        ) {
            if (answer > 0 && updatedAt != 0) {
                a.status = "live";
                a.roundId = roundId;
                a.answer = answer;
                a.startedAt = startedAt;
                a.updatedAt = updatedAt;
                a.answeredInRound = answeredInRound;
            } else {
                a.status = "denied";
                a.revertData = bytes("empty answer");
                a.revertReason = "empty answer";
            }
        } catch (bytes memory reason) {
            a.status = "denied";
            a.revertData = reason;
            a.revertReason = _revertReason(reason);
        }
    }

    /// @dev Pulls `Error(string)` out of APRO's revert. Other payloads stay as hex.
    function _revertReason(bytes memory data) internal pure returns (string memory) {
        if (data.length < 68 || bytes4(data) != bytes4(0x08c379a0)) return _toHex(data);
        bytes memory payload = new bytes(data.length - 4);
        for (uint256 i = 0; i < payload.length; i++) {
            payload[i] = data[i + 4];
        }
        return abi.decode(payload, (string));
    }

    function _tokenJson(Token memory t) internal pure returns (string memory) {
        return string.concat(
            '{ "address": "',
            vm.toString(t.token),
            '", "symbol": "',
            t.symbol,
            '", "decimals": ',
            vm.toString(t.decimals),
            " }"
        );
    }

    function _aproJson(Apro memory a) internal pure returns (string memory) {
        bool live = keccak256(bytes(a.status)) == keccak256("live");
        return string.concat(
            "{\n",
            '      "address": "',
            vm.toString(a.feed),
            '",\n',
            '      "description": "',
            a.description,
            '",\n',
            '      "decimals": ',
            vm.toString(a.decimals),
            ",\n",
            '      "status": "',
            a.status,
            '",\n',
            '      "roundId": "',
            vm.toString(a.roundId),
            '",\n',
            '      "answer": "',
            vm.toString(a.answer),
            '",\n',
            '      "startedAt": "',
            vm.toString(a.startedAt),
            '",\n',
            '      "updatedAt": "',
            vm.toString(a.updatedAt),
            '",\n',
            '      "answeredInRound": "',
            vm.toString(a.answeredInRound),
            '",\n',
            '      "revert": ',
            live ? "null" : string.concat('"', a.revertReason, '"'),
            ",\n",
            '      "revertData": ',
            live ? "null" : string.concat('"', _toHex(a.revertData), '"'),
            "\n",
            "    }"
        );
    }

    function _toHex(bytes memory data) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory out = new bytes(2 + data.length * 2);
        out[0] = "0";
        out[1] = "x";
        for (uint256 i = 0; i < data.length; i++) {
            out[2 + i * 2] = alphabet[uint8(data[i] >> 4)];
            out[3 + i * 2] = alphabet[uint8(data[i] & 0x0f)];
        }
        return string(out);
    }
}
