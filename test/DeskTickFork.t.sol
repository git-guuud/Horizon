// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {DeskFill} from "../src/fill/DeskFill.sol";
import {IUniswapV3Pool} from "../src/market/Interfaces.sol";
import {MarketPin} from "../src/market/MarketPin.sol";
import {Seeds} from "../src/market/Seeds.sol";
import {DeskPolicy} from "../src/policy/DeskPolicy.sol";
import {AproFairPrice} from "../src/price/AproFairPrice.sol";
import {FairPrice} from "../src/price/FairPrice.sol";
import {FallbackFairPrice} from "../src/price/FallbackFairPrice.sol";
import {SqrtTick} from "../src/price/SqrtTick.sol";
import {TwapFairPrice} from "../src/price/TwapFairPrice.sol";
import {DeskQuote} from "../src/quote/DeskQuote.sol";
import {RangeMath} from "../src/quote/RangeMath.sol";
import {DeskTick} from "../src/tick/DeskTick.sol";
import {DeskVault} from "../src/vault/DeskVault.sol";

interface IWHSK {
    function deposit() external payable;
}

interface IPayToken {
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

/// @notice Fork of chain 177. The tick runs here and is not broadcast.
contract DeskTickForkTest is Test {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WIDTH = 100;
    uint256 internal constant FLOOR = 30;
    uint256 internal constant BAND = 100;
    uint256 internal constant CAP = 1_000_000 ether;
    uint256 internal constant SLIPPAGE = 100;

    uint256 internal traderKey = 0xC0FFEE;
    address internal owner = makeAddr("owner");
    address internal operator = makeAddr("operator");
    address internal trader;

    AproFairPrice internal apro;
    TwapFairPrice internal twap;
    FallbackFairPrice internal fair;
    DeskVault internal vault;
    DeskPolicy internal policy;
    DeskQuote internal quote;
    DeskFill internal desk;
    DeskTick internal deskTick;

    address internal pool;
    address internal whsk;
    address internal usdt;

    function setUp() public {
        vm.createSelectFork("hashkey");
        trader = vm.addr(traderKey);
        MarketPin.Snapshot memory snap = new MarketPin().read();
        pool = snap.pool.pool;
        whsk = snap.whsk.token;
        usdt = snap.usdt.token;

        apro = new AproFairPrice(Seeds.APRO_HSK_USD, Seeds.APRO_USDT_USD, FairPrice.MAX_STALENESS);
        twap = new TwapFairPrice(
            pool, snap.factory, whsk, usdt, snap.pool.fee, FairPrice.TWAP_WINDOW, FairPrice.MAX_STALENESS
        );
        fair = new FallbackFairPrice(address(apro), address(twap));
        vault = new DeskVault(owner, operator, whsk, usdt);
        policy = new DeskPolicy(owner, operator, address(fair), whsk, usdt, BAND, FLOOR, CAP, CAP, 1_000_000e6);
        quote = new DeskQuote(address(vault), address(policy), address(fair), snap.positionManager, pool);
        desk = new DeskFill(
            address(vault), address(policy), pool, Seeds.HSKSWAP_SWAP_ROUTER_02, Seeds.HSKSWAP_QUOTER_V2, SLIPPAGE
        );
        deskTick = new DeskTick(address(quote), address(desk), address(fair));

        vm.startPrank(owner);
        vault.setQuoter(address(quote));
        vault.setFiller(address(desk));
        policy.setQuote(address(quote));
        vm.stopPrank();
        _fund(100 ether, 100e6);
    }

    function test_fork_tickRecenterWhenFairLeaves() public {
        uint256 opened = _mint();
        (int24 lower0, int24 upper0) = _ticks(opened);
        _moveFairPrice(lower0);
        (uint256 moved,) = twap.latestPrice();
        int24 fairTick = RangeMath.tickAtFairPrice(moved);
        assertTrue(RangeMath.place(fairTick, quote.tickLower(), quote.tickUpper()) != RangeMath.Place.Inside);

        _handToTick();
        vm.recordLogs();
        deskTick.tick(false, _blank(), "", "", bytes32(0));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (uint256 id, int24 lower1, int24 upper1, bytes32 reasonHash) = _recenter(logs);
        assertEq(id, quote.positionId());
        assertTrue(id != opened);
        int24 spacing = quote.tickSpacing();
        (int24 expectLower, int24 expectUpper) =
            RangeMath.quote(moved, quote.widthBps(), 0, FLOOR, 0, 0, CAP, CAP, spacing);
        assertEq(lower1, expectLower);
        assertEq(upper1, expectUpper);
        assertTrue(lower1 != lower0 || upper1 != upper0);
        (int24 liveLower, int24 liveUpper) = _ticks(id);
        assertEq(liveLower, lower1);
        assertEq(liveUpper, upper1);
        assertEq(reasonHash, keccak256(bytes(deskTick.REASON())));
        assertTrue(RangeMath.place(RangeMath.tickAtFairPrice(moved), lower1, upper1) == RangeMath.Place.Inside);
    }

    function test_fork_tickLeavesPositionWhenFairStays() public {
        uint256 opened = _mint();
        (uint256 price,) = twap.latestPrice();
        assertTrue(
            RangeMath.place(RangeMath.tickAtFairPrice(price), quote.tickLower(), quote.tickUpper())
                == RangeMath.Place.Inside
        );

        _handToTick();
        deskTick.tick(false, _blank(), "", "", bytes32(0));
        assertEq(quote.positionId(), opened);
    }

    /// @dev A signed intent is submitted only when asked. A size the pool can fill still reverts,
    ///      and the nonce stays unused.
    function test_fork_tickSubmitsFillOnlyWithIntent_poolGateHolds() public {
        uint256 opened = _mint();
        // Idle WHSK after the mint is dust. A one-WHSK balance keeps the inventory leg above zero
        // so the pool gate is what reverts.
        _fund(1 ether, 0);
        _handToTick();

        (uint256 mid,) = twap.latestPrice();
        uint256 price = mid * (BPS + FLOOR) / BPS;
        DeskFill.Intent memory intent = _intent(desk.BUY_WHSK(), 1 ether, price, 4);
        bytes memory signature = _sign(intent);
        string memory reason = "pool can fill";
        bytes32 reasonHash = keccak256(bytes(reason));

        deskTick.tick(false, intent, signature, reason, reasonHash);
        assertEq(quote.positionId(), opened);
        assertFalse(desk.usedNonce(trader, 4));

        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.POOL_CAN_FILL()));
        deskTick.tick(true, intent, signature, reason, reasonHash);
        assertEq(quote.positionId(), opened);
        assertFalse(desk.usedNonce(trader, 4));

        vm.prank(address(deskTick));
        vm.expectRevert(DeskVault.NotOwner.selector);
        vault.withdraw(whsk, 1, address(deskTick));
    }

    function _mint() internal returns (uint256 id) {
        vm.prank(operator);
        quote.widenWidth(WIDTH);
        vm.prank(operator);
        quote.mint(0, "mint");
        return quote.positionId();
    }

    function _handToTick() internal {
        vm.startPrank(owner);
        policy.setOperator(address(deskTick));
        vault.setOperator(address(deskTick));
        vm.stopPrank();
    }

    function _blank() internal pure returns (DeskFill.Intent memory intent) {}

    function _intent(uint8 side, uint256 size, uint256 limit, uint256 nonce)
        internal
        view
        returns (DeskFill.Intent memory)
    {
        return DeskFill.Intent({
            pair: pool,
            side: side,
            size: size,
            limit: limit,
            expiry: block.timestamp + 7 days,
            nonce: nonce,
            trader: trader
        });
    }

    function _sign(DeskFill.Intent memory intent) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(traderKey, desk.intentDigest(intent));
        return abi.encodePacked(r, s, v);
    }

    function _fund(uint256 whskAmount, uint256 usdtAmount) internal {
        vm.deal(address(this), whskAmount);
        if (whskAmount != 0) {
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

    function _moveFairPrice(int24 tickLower) internal {
        int24 target = tickLower - quote.tickSpacing();
        (uint160 sqrtPrice,,,,,,) = IUniswapV3Pool(pool).slot0();
        uint160 limit = SqrtTick.sqrtPriceX96(target);
        assertLt(limit, sqrtPrice);

        uint256 budget = 2_000_000 ether;
        vm.deal(address(this), budget);
        IWHSK(whsk).deposit{value: budget}();
        IMovePool(pool).swap(address(this), true, int256(budget), limit, "");

        (, int24 moved,,,,,) = IUniswapV3Pool(pool).slot0();
        assertLt(moved, tickLower);
        vm.warp(block.timestamp + FairPrice.TWAP_WINDOW);
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        require(msg.sender == pool, "callback");
        if (amount0Delta > 0) _pay(whsk, uint256(amount0Delta));
        if (amount1Delta > 0) _pay(usdt, uint256(amount1Delta));
    }

    function _ticks(uint256 id) internal view returns (int24 tickLower, int24 tickUpper) {
        (,,,,, tickLower, tickUpper,,,,,) = quote.npm().positions(id);
    }

    function _recenter(Vm.Log[] memory logs)
        internal
        view
        returns (uint256 id, int24 lower, int24 upper, bytes32 reasonHash)
    {
        bytes32 topic = keccak256("Recentered(uint256,uint256,uint256,uint256,bytes32,int24,int24,bool,uint256,int256)");
        for (uint256 i = logs.length; i > 0; --i) {
            Vm.Log memory entry = logs[i - 1];
            if (entry.emitter != address(quote) || entry.topics[0] != topic) continue;
            id = uint256(entry.topics[1]);
            uint256 whskAfter;
            uint256 usdtAfter;
            uint256 mid;
            bool usedTwap;
            uint256 spread;
            int256 holding;
            (whskAfter, usdtAfter, mid, reasonHash, lower, upper, usedTwap, spread, holding) =
                abi.decode(entry.data, (uint256, uint256, uint256, bytes32, int24, int24, bool, uint256, int256));
            return (id, lower, upper, reasonHash);
        }
        revert("missing Recentered");
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
}

/// @notice The compiled tick carries no vault withdraw selector and no withdraw text.
contract DeskTickModuleTest is Test {
    function test_tickBytecodeHasNoWithdraw() public view {
        bytes memory code = vm.getCode("DeskTick.sol:DeskTick");
        assertGt(code.length, 0);
        assertFalse(_contains(code, abi.encodePacked(DeskVault.withdraw.selector)));
        assertFalse(_contains(code, bytes("withdraw")));
    }

    function _contains(bytes memory haystack, bytes memory needle) internal pure returns (bool) {
        if (needle.length == 0 || haystack.length < needle.length) return false;
        uint256 last = haystack.length - needle.length;
        for (uint256 i = 0; i <= last; i++) {
            bool found = true;
            for (uint256 j = 0; j < needle.length; j++) {
                if (haystack[i + j] != needle[j]) {
                    found = false;
                    break;
                }
            }
            if (found) return true;
        }
        return false;
    }
}
