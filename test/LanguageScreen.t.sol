// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {DeskFill} from "../src/fill/DeskFill.sol";
import {IQuoterV2, ISwapRouter02, IUniswapV3Pool} from "../src/market/Interfaces.sol";
import {MarketPin} from "../src/market/MarketPin.sol";
import {Seeds} from "../src/market/Seeds.sol";
import {DeskPolicy} from "../src/policy/DeskPolicy.sol";
import {AproFairPrice} from "../src/price/AproFairPrice.sol";
import {FairPrice} from "../src/price/FairPrice.sol";
import {FallbackFairPrice} from "../src/price/FallbackFairPrice.sol";
import {ITwapPool} from "../src/price/ITwapPool.sol";
import {SqrtTick} from "../src/price/SqrtTick.sol";
import {TwapFairPrice} from "../src/price/TwapFairPrice.sol";
import {DeskQuote} from "../src/quote/DeskQuote.sol";
import {DeskVault} from "../src/vault/DeskVault.sol";

interface IWHSK {
    function deposit() external payable;
}

interface IPayToken {
    function decimals() external view returns (uint8);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IMovePool {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

/// @notice Fork of chain 177. The parser builds calldata. eth_call surfaces the reason.
///         Nothing here is broadcast. The screen file is the same run.
contract LanguageScreenTest is Test {
    using stdJson for string;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant BAND = 100;
    uint256 internal constant FLOOR = 30;
    uint256 internal constant WIDTH = 100;
    uint256 internal constant SLIPPAGE = 100;
    uint256 internal constant CAP = 1_000_000 ether;
    uint256 internal constant SIZE = 100_000 ether;
    uint256 internal constant PROBE = 1_000e6;
    uint256 internal constant COMMAND_NONCE = 9;
    string internal constant BAD_SIG =
        "0x1111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111";

    uint256 internal traderKey = 0xC0FFEE;
    address internal owner = makeAddr("owner");
    address internal operator = makeAddr("operator");
    address internal stranger = makeAddr("stranger");
    address internal trader;

    AproFairPrice internal apro;
    TwapFairPrice internal twap;
    FallbackFairPrice internal fair;
    DeskVault internal vault;
    DeskPolicy internal policy;
    DeskQuote internal quote;
    DeskFill internal desk;

    address internal pool;
    address internal whsk;
    address internal usdt;
    uint24 internal fee;
    uint256 internal expiry;
    uint256 internal deadline;

    uint256 internal mid;
    uint256 internal updatedAt;
    bool internal usedTwap;
    string internal aproRevert;

    uint256 internal liquidityBefore;
    uint256 internal liquidityAfter;
    uint256 internal depthBefore;
    uint256 internal depthAfter;
    int24 internal poolTick;
    int24 internal tickLower;
    int24 internal tickUpper;
    uint256 internal positionId;

    uint256 internal whskBefore;
    uint256 internal usdtBefore;
    uint256 internal whskCap;
    uint256 internal usdtCap;
    uint256 internal paid;
    uint256 internal whskAfter;
    uint256 internal usdtAfter;
    uint256 internal budget;
    uint256 internal quotedOut;
    string internal routerRevert;

    bytes32 internal badSigReason;
    bytes32 internal fillPreflightReason;
    bytes32 internal outsideReason;
    bytes32 internal staleReason;
    bytes32 internal haltedReason;
    uint256 internal freshMid;
    bool internal ownerResumed;

    string internal out;
    string internal scratch;

    function setUp() public {
        vm.createSelectFork("hashkey");
        trader = vm.addr(traderKey);
        expiry = block.timestamp + 7 days;
        deadline = block.timestamp + 1 hours;

        MarketPin.Snapshot memory snap = new MarketPin().read();
        pool = snap.pool.pool;
        whsk = snap.whsk.token;
        usdt = snap.usdt.token;
        fee = snap.pool.fee;

        apro = new AproFairPrice(Seeds.APRO_HSK_USD, Seeds.APRO_USDT_USD, FairPrice.MAX_STALENESS);
        twap = new TwapFairPrice(pool, snap.factory, whsk, usdt, fee, FairPrice.TWAP_WINDOW, FairPrice.MAX_STALENESS);
        fair = new FallbackFairPrice(address(apro), address(twap));
        vault = new DeskVault(owner, operator, whsk, usdt);
        policy = new DeskPolicy(owner, operator, address(fair), whsk, usdt, BAND, FLOOR, CAP, CAP, 1_000_000e6);
        quote = new DeskQuote(address(vault), address(policy), address(fair), snap.positionManager, pool);
        desk = new DeskFill(
            address(vault), address(policy), pool, Seeds.HSKSWAP_SWAP_ROUTER_02, Seeds.HSKSWAP_QUOTER_V2, SLIPPAGE
        );

        vm.startPrank(owner);
        vault.setQuoter(address(quote));
        vault.setFiller(address(desk));
        policy.setQuote(address(quote));
        vm.stopPrank();
        vm.prank(operator);
        quote.widenWidth(WIDTH);
    }

    function test_fork_languageDryRunAndScreen() public {
        (mid, updatedAt, usedTwap) = fair.read();
        assertTrue(usedTwap);
        _aproDenied();
        _language();
        _withdrawBlocked();
        _nakedPool();
        _mintAndFund();
        _fillInventory();
        _outsideBand();
        _staleHalt();
        _write();
    }

    function _language() internal {
        _refuseUnknown();
        _preflightBadSignature();
        _preflightFillCap();
        _preflightOutsideFill();
    }

    function _refuseUnknown() internal {
        string memory unknown = _agent(_request("withdraw 1 WHSK", "null", "null"));
        assertFalse(unknown.readBool(".ok"));
        assertEq(unknown.readString(".code"), "UNKNOWN");

        string memory refused = _agent(_request("quote 10 bps", "null", "null"));
        assertFalse(refused.readBool(".ok"));
        assertEq(refused.readString(".code"), "NEEDS_OWNER");
        assertEq(refused.readString(".fn"), "tightenWidth");
    }

    function _preflightBadSignature() internal {
        string memory bad = _agent(_request("quote 40 bps", string.concat("\"", BAD_SIG, "\""), "null"));
        assertTrue(bad.readBool(".ok"));
        assertEq(bad.readString(".fn"), "tightenWidth");
        assertEq(bad.readString(".to"), vm.toString(address(quote)));
        uint256 widthBefore = quote.widthBps();
        uint256 floorBefore = policy.spreadFloor();
        vm.prank(operator);
        (bool ok, bytes memory ret) = address(quote).call(bad.readBytes(".calldata"));
        assertFalse(ok);
        badSigReason = _policyReason(ret);
        assertEq(badSigReason, policy.BAD_SIGNATURE());
        assertEq(quote.widthBps(), widthBefore);
        assertEq(policy.spreadFloor(), floorBefore);
        console2.log("preflight reason BAD_SIGNATURE");
    }

    function _preflightFillCap() internal {
        uint256 before = policy.fillCap();
        string memory planned = _agent(_request("fill intents up to 500 USDT", "null", "null"));
        assertTrue(planned.readBool(".ok"));
        assertEq(planned.readString(".fn"), "lowerFillCap");
        assertEq(planned.readString(".to"), vm.toString(address(policy)));
        assertTrue(_has(planned, "\"intent\":null"));
        vm.prank(operator);
        (bool lowered,) = address(policy).call(planned.readBytes(".calldata"));
        assertTrue(lowered);
        assertEq(policy.fillCap(), 500e6);

        string memory higher = _agent(_request("fill intents up to 2000000 USDT", "null", "null"));
        assertFalse(higher.readBool(".ok"));
        assertEq(higher.readString(".code"), "NEEDS_OWNER");
        assertEq(higher.readString(".fn"), "raiseFillCap");
        assertEq(policy.fillCap(), 500e6);

        vm.prank(owner);
        policy.setFillCap(before);
        assertEq(policy.fillCap(), before);
    }

    function _preflightOutsideFill() internal {
        uint256 price = mid * (BPS + FLOOR) / BPS;
        DeskFill.Intent memory intent = _buy(1 ether, price, COMMAND_NONCE);
        bytes memory signature = _sign(intent);
        vm.prank(owner);
        policy.setBand(FLOOR - 1);
        vm.prank(operator);
        (bool filled, bytes memory fillRet) = address(desk)
            .call(abi.encodeCall(DeskFill.fill, (intent, signature, "outside the band", keccak256("outside the band"))));
        assertFalse(filled);
        fillPreflightReason = _policyReason(fillRet);
        assertEq(fillPreflightReason, policy.OUTSIDE_BAND());
        assertFalse(desk.usedNonce(trader, intent.nonce));
        vm.prank(owner);
        policy.setBand(BAND);
        assertEq(policy.bandBps(), BAND);
        console2.log("preflight reason OUTSIDE_BAND");
    }

    function _withdrawBlocked() internal {
        vm.prank(operator);
        vm.expectRevert(DeskVault.NotOwner.selector);
        vault.withdraw(whsk, 1, operator);
    }

    function _nakedPool() internal {
        budget = SIZE * mid * (BPS + BAND) / BPS / 1e20;
        assertGt(budget, 0);
        (quotedOut,,,) = IQuoterV2(Seeds.HSKSWAP_QUOTER_V2)
            .quoteExactInputSingle(
                IQuoterV2.QuoteExactInputSingleParams({
                    tokenIn: usdt, tokenOut: whsk, amountIn: budget, fee: fee, sqrtPriceLimitX96: 0
                })
            );
        assertLt(quotedOut, SIZE);

        uint256 purse = 10_000_000e6;
        deal(usdt, address(this), purse);
        _approve(usdt, Seeds.HSKSWAP_SWAP_ROUTER_02, purse);
        try ISwapRouter02(Seeds.HSKSWAP_SWAP_ROUTER_02)
            .exactOutputSingle(
                ISwapRouter02.ExactOutputSingleParams({
                    tokenIn: usdt,
                    tokenOut: whsk,
                    fee: fee,
                    recipient: address(this),
                    amountOut: SIZE,
                    amountInMaximum: budget,
                    sqrtPriceLimitX96: 0
                })
            ) returns (
            uint256
        ) {
            revert("naked pool filled");
        } catch Error(string memory reason) {
            routerRevert = reason;
        }
        assertEq(routerRevert, "Too much requested");
    }

    function _mintAndFund() internal {
        liquidityBefore = IUniswapV3Pool(pool).liquidity();
        (, poolTick,,,,,) = IUniswapV3Pool(pool).slot0();
        depthBefore = _probe(PROBE);
        _fund(100 ether, 100e6);
        vm.prank(operator);
        quote.mint(0, "mint at the twap");
        assertTrue(quote.lastUsedTwap());
        positionId = quote.positionId();
        tickLower = quote.tickLower();
        tickUpper = quote.tickUpper();
        liquidityAfter = IUniswapV3Pool(pool).liquidity();
        depthAfter = _probe(PROBE);

        _fund(SIZE + 2 ether, 0);
        whskBefore = _bal(whsk);
        usdtBefore = _bal(usdt);
        assertGe(whskBefore, SIZE + 1 ether);
        paid = SIZE * (mid * (BPS + FLOOR) / BPS) / 1e20;
        assertGt(paid, 0);
        vm.startPrank(owner);
        policy.setInventoryCap(whsk, whskBefore);
        policy.setInventoryCap(usdt, usdtBefore + paid * 2);
        vm.stopPrank();
        whskCap = policy.inventoryCap(whsk);
        usdtCap = policy.inventoryCap(usdt);
    }

    function _fillInventory() internal {
        uint256 price = mid * (BPS + FLOOR) / BPS;
        deal(usdt, trader, paid);
        vm.prank(trader);
        _approve(usdt, address(vault), paid);
        DeskFill.Intent memory intent = _buy(SIZE, price, 1);
        bytes memory signature = _sign(intent);
        vm.prank(operator);
        desk.fill(intent, signature, "fill at the oracle", keccak256("fill at the oracle"));
        whskAfter = _bal(whsk);
        usdtAfter = _bal(usdt);
        assertEq(whskAfter, whskBefore - SIZE);
        assertEq(usdtAfter, usdtBefore + paid);
        assertEq(IPayToken(whsk).balanceOf(trader), SIZE);
    }

    function _outsideBand() internal {
        uint256 price = mid * (BPS + FLOOR) / BPS;
        DeskFill.Intent memory intent = _buy(1 ether, price, 2);
        bytes memory signature = _sign(intent);
        uint256 whskAt = _bal(whsk);
        uint256 usdtAt = _bal(usdt);
        vm.prank(owner);
        policy.setBand(FLOOR - 1);
        vm.prank(operator);
        (bool ok, bytes memory ret) = address(desk)
            .call(abi.encodeCall(DeskFill.fill, (intent, signature, "outside the band", keccak256("outside the band"))));
        assertFalse(ok);
        outsideReason = _policyReason(ret);
        assertEq(outsideReason, policy.OUTSIDE_BAND());
        assertEq(_bal(whsk), whskAt);
        assertEq(_bal(usdt), usdtAt);
        assertFalse(desk.usedNonce(trader, 2));
        vm.prank(owner);
        policy.setBand(BAND);
    }

    function _staleHalt() internal {
        uint256 limit = mid * 2;
        DeskFill.Intent memory intent = _buy(1 ether, limit, 3);
        bytes memory signature = _sign(intent);

        vm.warp(block.timestamp + FairPrice.MAX_STALENESS + 1);
        vm.prank(operator);
        (bool ok, bytes memory ret) =
            address(desk).call(abi.encodeCall(DeskFill.fill, (intent, signature, "stale", keccak256("stale"))));
        assertFalse(ok);
        staleReason = _policyReason(ret);
        assertEq(staleReason, policy.STALE());

        vm.prank(stranger);
        policy.halt();
        assertTrue(policy.halted());
        _pokePool();
        (freshMid,) = twap.latestPrice();
        assertLe(freshMid * (BPS + FLOOR) / BPS, limit);

        vm.prank(operator);
        (ok, ret) = address(desk).call(abi.encodeCall(DeskFill.fill, (intent, signature, "stale", keccak256("stale"))));
        assertFalse(ok);
        haltedReason = _policyReason(ret);
        assertEq(haltedReason, policy.HALTED());

        vm.prank(operator);
        (ok, ret) = address(policy).call(abi.encodeCall(DeskPolicy.resume, ()));
        assertFalse(ok);
        assertEq(_policyReason(ret), policy.NOT_OWNER());
        assertTrue(policy.halted());

        vm.prank(owner);
        policy.resume();
        assertFalse(policy.halted());
        ownerResumed = true;

        uint256 size = SIZE;
        _fund(size, 0);
        uint256 price = freshMid * (BPS + FLOOR) / BPS;
        uint256 due = size * price / 1e20;
        assertLe(price, limit);
        vm.startPrank(owner);
        policy.setInventoryCap(whsk, _bal(whsk));
        policy.setInventoryCap(usdt, _bal(usdt) + due);
        vm.stopPrank();
        deal(usdt, trader, due);
        vm.prank(trader);
        _approve(usdt, address(vault), due);
        DeskFill.Intent memory again = _buy(size, limit, 4);
        bytes memory againSig = _sign(again);
        vm.prank(operator);
        desk.fill(again, againSig, "after the owner resumed", keccak256("after the owner resumed"));
        assertFalse(policy.halted());
    }

    function _write() internal {
        out = "{\"chainId\":\"177\",\"source\":\"chain 177 fork\",\"broadcast\":false,";
        _writeFeed();
        _writeRange();
        _writeInventory();
        _writeDepth();
        _writePaths();
        _writePreflight();
        _add(string.concat("\"withdraw\":{", _q("error", "NotOwner"), "},"));
        _add(string.concat("\"limits\":", _stateJson(), "}"));
        vm.writeFile("web/demo.json", out);
        assertTrue(_has(out, "OUTSIDE_BAND"));
        assertTrue(_has(out, "STALE"));
        assertTrue(_has(out, "HALTED"));
        assertTrue(_has(out, "BAD_SIGNATURE"));
        assertTrue(_has(out, "NEEDS_OWNER"));
        assertTrue(_has(out, "Too much requested"));
        assertTrue(_has(out, "NotOwner"));
        assertTrue(_has(out, "\"broadcast\":false"));
        string memory demo = vm.readFile("web/demo.json");
        assertEq(vm.parseUint(demo.readString(".limits.maxFillUsdt")), policy.fillCap());
    }

    function _writeFeed() internal {
        _add("\"feed\":{");
        _add(_q("name", "TWAP"));
        _add(",");
        _add(_q("aproRevert", aproRevert));
        _add(",");
        _add(_q("price", vm.toString(mid)));
        _add(",");
        _add(_q("updatedAt", vm.toString(updatedAt)));
        _add("},");
    }

    function _writeRange() internal {
        _add("\"range\":{");
        _add(_q("tickLower", vm.toString(int256(tickLower))));
        _add(",");
        _add(_q("tickUpper", vm.toString(int256(tickUpper))));
        _add(",");
        _add(_q("poolTick", vm.toString(int256(poolTick))));
        _add(",");
        _add(_q("widthBps", vm.toString(WIDTH)));
        _add(",");
        _add(_q("positionId", vm.toString(positionId)));
        _add(",\"usedTwap\":");
        _add(quote.lastUsedTwap() ? "true" : "false");
        _add("},");
    }

    function _writeInventory() internal {
        _add("\"inventory\":{");
        _add(_q("whsk", vm.toString(whskBefore)));
        _add(",");
        _add(_q("usdt", vm.toString(usdtBefore)));
        _add(",");
        _add(_q("whskCap", vm.toString(whskCap)));
        _add(",");
        _add(_q("usdtCap", vm.toString(usdtCap)));
        _add(",");
        _add(_q("whskAfter", vm.toString(whskAfter)));
        _add(",");
        _add(_q("usdtAfter", vm.toString(usdtAfter)));
        _add("},");
    }

    function _writeDepth() internal {
        _add("\"depth\":{");
        _add(_q("probeUsdt", vm.toString(PROBE)));
        _add(",");
        _add(_q("whskOutBefore", vm.toString(depthBefore)));
        _add(",");
        _add(_q("whskOutAfter", vm.toString(depthAfter)));
        _add(",");
        _add(_q("liquidityBefore", vm.toString(liquidityBefore)));
        _add(",");
        _add(_q("liquidityAfter", vm.toString(liquidityAfter)));
        _add("},");
    }

    function _writePaths() internal {
        _add("\"paths\":{\"naked\":{");
        _writeNaked();
        _add("},\"fill\":{");
        _writeFill();
        _add("},\"outside\":{");
        _writeOutside();
        _add("},\"stale\":{");
        _writeStale();
        _add("}},");
    }

    function _writeNaked() internal {
        _add(_q("size", vm.toString(SIZE)));
        _add(",");
        _add(_q("budget", vm.toString(budget)));
        _add(",");
        _add(_q("quotedOut", vm.toString(quotedOut)));
        _add(",");
        _add(_q("routerRevert", routerRevert));
    }

    function _writeFill() internal {
        _add(_q("size", vm.toString(SIZE)));
        _add(",");
        _add(_q("mid", vm.toString(mid)));
        _add(",");
        _add(_q("spread", vm.toString(FLOOR)));
        _add(",");
        _add(_q("paid", vm.toString(paid)));
        _add(",");
        _add(_q("limit", vm.toString(mid * (BPS + FLOOR) / BPS)));
        _add(",");
        _add(_q("whskAfter", vm.toString(whskAfter)));
        _add(",");
        _add(_q("usdtAfter", vm.toString(usdtAfter)));
        _add(",");
        _add(_q("reason", "fill at the oracle"));
        _add(",");
        _add(_q("reasonHash", _hex32(keccak256("fill at the oracle"))));
        _add(",");
        _add(_q("residual", "0"));
    }

    function _writeOutside() internal {
        _add(_q("reason", "OUTSIDE_BAND"));
        _add(",");
        _add(_q("reasonHash", _hex32(outsideReason)));
    }

    function _writeStale() internal {
        _add(_q("staleReason", "STALE"));
        _add(",");
        _add(_q("haltedReason", "HALTED"));
        _add(",");
        _add(_q("staleHash", _hex32(staleReason)));
        _add(",");
        _add(_q("haltedHash", _hex32(haltedReason)));
        _add(",");
        _add(_q("operatorResume", "NOT_OWNER"));
        _add(",\"ownerResumed\":");
        _add(ownerResumed ? "true" : "false");
        _add(",");
        _add(_q("freshMid", vm.toString(freshMid)));
    }

    function _writePreflight() internal {
        _add("\"preflight\":{\"needsOwner\":\"NEEDS_OWNER\",\"badSignature\":{");
        _add(_q("command", "quote 40 bps"));
        _add(",");
        _add(_q("reason", "BAD_SIGNATURE"));
        _add(",");
        _add(_q("reasonHash", _hex32(badSigReason)));
        _add(",\"broadcast\":false},\"outsideFill\":{");
        _add(_q("command", "fill"));
        _add(",");
        _add(_q("reason", "OUTSIDE_BAND"));
        _add(",");
        _add(_q("reasonHash", _hex32(fillPreflightReason)));
        _add(",\"broadcast\":false}},");
    }

    function _aproDenied() internal {
        try apro.latestPrice() returns (uint256, uint256) {
            aproRevert = "unexpected";
        } catch Error(string memory reason) {
            aproRevert = reason;
        } catch {
            aproRevert = "unknown";
        }
        assertEq(aproRevert, "No access");
    }

    function _request(string memory command, string memory ownerSigJson, string memory traderSigJson)
        internal
        returns (string memory)
    {
        string memory state = _stateJson();
        return string.concat(
            "{\"command\":\"", command, "\",\"ownerSignature\":", ownerSigJson, ",\"traderSignature\":", traderSigJson, ",\"state\":", state, "}"
        );
    }

    function _stateJson() internal returns (string memory) {
        scratch = "{";
        _field("spreadFloor", vm.toString(policy.spreadFloor()));
        _field("widthBps", vm.toString(quote.widthBps()));
        _field("bandBps", vm.toString(policy.bandBps()));
        _field("whskCap", vm.toString(policy.inventoryCap(whsk)));
        _field("usdtCap", vm.toString(policy.inventoryCap(usdt)));
        _field("maxFillUsdt", vm.toString(policy.fillCap()));
        _field("fairPrice", vm.toString(mid));
        _field("whsk", vm.toString(whsk));
        _field("usdt", vm.toString(usdt));
        _field("policy", vm.toString(address(policy)));
        _field("quote", vm.toString(address(quote)));
        _field("fill", vm.toString(address(desk)));
        _field("pool", vm.toString(pool));
        _field("trader", vm.toString(trader));
        _field("nonce", vm.toString(COMMAND_NONCE));
        _field("expiry", vm.toString(expiry));
        _field("deadline", vm.toString(deadline));
        _field("quoteScale", vm.toString(desk.quoteScale()));
        _field("whskDecimals", vm.toString(uint256(IPayToken(whsk).decimals())));
        _field("usdtDecimals", vm.toString(uint256(IPayToken(usdt).decimals())));
        _scratch("}");
        return scratch;
    }

    function _field(string memory key, string memory value) internal {
        if (bytes(scratch).length > 1) _scratch(",");
        _scratch(_q(key, value));
    }

    function _scratch(string memory part) internal {
        scratch = string.concat(scratch, part);
    }

    function _agent(string memory request) internal returns (string memory) {
        vm.writeFile("cache/language-request.json", request);
        string[] memory cmd = new string[](3);
        cmd[0] = "node";
        cmd[1] = "agent/cli.mjs";
        cmd[2] = "cache/language-request.json";
        vm.ffi(cmd);
        return vm.readFile("cache/language-response.json");
    }

    function _buy(uint256 size, uint256 limit, uint256 nonce) internal view returns (DeskFill.Intent memory) {
        return DeskFill.Intent({
            pair: pool, side: desk.BUY_WHSK(), size: size, limit: limit, expiry: expiry, nonce: nonce, trader: trader
        });
    }

    function _sign(DeskFill.Intent memory intent) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(traderKey, desk.intentDigest(intent));
        return abi.encodePacked(r, s, v);
    }

    function _fund(uint256 whskAmount, uint256 usdtAmount) internal {
        if (whskAmount != 0) {
            vm.deal(address(this), whskAmount);
            IWHSK(whsk).deposit{value: whskAmount}();
            IPayToken(whsk).transfer(owner, whskAmount);
        }
        if (usdtAmount != 0) deal(usdt, owner, usdtAmount);
        vm.startPrank(owner);
        if (whskAmount != 0) {
            _approve(whsk, address(vault), whskAmount);
            vault.deposit(whsk, whskAmount);
        }
        if (usdtAmount != 0) {
            _approve(usdt, address(vault), usdtAmount);
            vault.deposit(usdt, usdtAmount);
        }
        vm.stopPrank();
    }

    function _probe(uint256 usdtIn) internal returns (uint256 whskOut) {
        (whskOut,,,) = IQuoterV2(Seeds.HSKSWAP_QUOTER_V2)
            .quoteExactInputSingle(
                IQuoterV2.QuoteExactInputSingleParams({
                    tokenIn: usdt, tokenOut: whsk, amountIn: usdtIn, fee: fee, sqrtPriceLimitX96: 0
                })
            );
    }

    function _pokePool() internal {
        vm.deal(address(this), 5_000 ether);
        IWHSK(whsk).deposit{value: 2_000 ether}();
        (, int24 tick,,,,,) = ITwapPool(pool).slot0();
        uint160 limit = SqrtTick.sqrtPriceX96(tick - 60);
        IMovePool(pool).swap(address(this), true, int256(2_000 ether), limit, "");
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        require(msg.sender == pool, "callback");
        if (amount0Delta > 0) _pay(whsk, uint256(amount0Delta));
        if (amount1Delta > 0) _pay(usdt, uint256(amount1Delta));
    }

    function _approve(address token, address spender, uint256 amount) internal {
        (bool ok, bytes memory ret) =
            token.call(abi.encodeWithSelector(bytes4(keccak256("approve(address,uint256)")), spender, amount));
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "approve");
    }

    function _pay(address token, uint256 amount) internal {
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IPayToken.transfer, (msg.sender, amount)));
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "pay");
    }

    function _bal(address token) internal view returns (uint256) {
        return IPayToken(token).balanceOf(address(vault));
    }

    function _add(string memory part) internal {
        out = string.concat(out, part);
    }

    function _q(string memory key, string memory value) internal pure returns (string memory) {
        return string.concat("\"", key, "\":\"", value, "\"");
    }

    function _policyReason(bytes memory ret) internal pure returns (bytes32 reason) {
        require(ret.length >= 36, "short revert");
        bytes4 sel;
        assembly {
            sel := mload(add(ret, 32))
            reason := mload(add(ret, 36))
        }
        require(sel == DeskPolicy.Policy.selector, "not policy");
    }

    function _errorString(bytes memory ret) internal pure returns (string memory) {
        require(ret.length >= 68, "short error");
        bytes4 sel;
        assembly {
            sel := mload(add(ret, 32))
        }
        require(sel == 0x08c379a0, "not a string");
        bytes memory slice = new bytes(ret.length - 4);
        for (uint256 i = 4; i < ret.length; ++i) {
            slice[i - 4] = ret[i];
        }
        return abi.decode(slice, (string));
    }

    function _hex32(bytes32 data) internal pure returns (string memory) {
        return _hex(abi.encodePacked(data));
    }

    function _hex(bytes memory data) internal pure returns (string memory) {
        bytes16 alphabet = "0123456789abcdef";
        bytes memory text = new bytes(2 + data.length * 2);
        text[0] = "0";
        text[1] = "x";
        for (uint256 i = 0; i < data.length; ++i) {
            text[2 + i * 2] = alphabet[uint8(data[i]) >> 4];
            text[3 + i * 2] = alphabet[uint8(data[i]) & 0x0f];
        }
        return string(text);
    }

    function _has(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || h.length < n.length) return false;
        for (uint256 i = 0; i <= h.length - n.length; ++i) {
            bool same = true;
            for (uint256 j = 0; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    same = false;
                    break;
                }
            }
            if (same) return true;
        }
        return false;
    }
}
