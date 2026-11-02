// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";
import {DeskPolicy} from "../src/policy/DeskPolicy.sol";
import {CloseValue} from "../src/quote/CloseValue.sol";
import {DeskQuote} from "../src/quote/DeskQuote.sol";
import {INonfungiblePositionManager} from "../src/quote/INonfungiblePositionManager.sol";
import {RangeMath} from "../src/quote/RangeMath.sol";
import {DeskVault} from "../src/vault/DeskVault.sol";
import {MarketPin} from "../src/market/MarketPin.sol";
import {Seeds} from "../src/market/Seeds.sol";
import {IUniswapV3Pool} from "../src/market/Interfaces.sol";
import {AproFairPrice} from "../src/price/AproFairPrice.sol";
import {FairPrice} from "../src/price/FairPrice.sol";
import {FallbackFairPrice} from "../src/price/FallbackFairPrice.sol";
import {SqrtTick} from "../src/price/SqrtTick.sol";
import {TwapFairPrice} from "../src/price/TwapFairPrice.sol";

interface IWHSK {
    function deposit() external payable;
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

interface IPayToken {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @notice Fork of chain 177. The fair-price move is a swap on the pinned pool, then a warp
///         across the TWAP window. The price is not a mock.
contract DeskQuoteForkTest is Test {
    uint256 internal constant WIDTH = 100;
    uint256 internal constant FLOOR = 30;
    uint256 internal constant BAND = 50;
    uint256 internal constant CAP = 1_000_000 ether;
    int256 internal constant OUTSIDE_SKEW = 200;

    address internal owner = makeAddr("owner");
    address internal operator = makeAddr("operator");
    address internal stranger = makeAddr("stranger");

    AproFairPrice internal apro;
    TwapFairPrice internal twap;
    FallbackFairPrice internal fair;
    DeskVault internal vault;
    DeskPolicy internal policy;
    DeskQuote internal quote;

    address internal pool;
    address internal whsk;
    address internal usdt;

    function setUp() public {
        vm.createSelectFork("hashkey");
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

        vm.startPrank(owner);
        vault.setQuoter(address(quote));
        policy.setQuote(address(quote));
        vm.stopPrank();
        _fund(100 ether, 100e6);
    }

    function _setWidth(uint256 width) internal {
        vm.prank(operator);
        quote.widenWidth(width);
    }

    /// @dev APRO denies the desk. Mint and recenter both use the pinned-pool TWAP.
    function test_fork_aproDenied_mintMoveFairRecenterUsesTwap() public {
        vm.expectRevert(bytes("No access"));
        apro.latestPrice();

        bytes32 notOperator = policy.NOT_OPERATOR();
        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, notOperator));
        vm.prank(stranger);
        quote.mint(0, "stranger");

        _setWidth(WIDTH);
        (uint256 before,) = twap.latestPrice();
        vm.prank(operator);
        quote.mint(0, "mint at the twap");
        assertTrue(quote.lastUsedTwap());

        uint256 opened = quote.positionId();
        (int24 lower0, int24 upper0) = _ticks(opened);
        int24 spacing = quote.tickSpacing();
        (int24 expectLower, int24 expectUpper) = RangeMath.quote(before, WIDTH, 0, FLOOR, 0, 0, CAP, CAP, spacing);
        assertEq(lower0, expectLower);
        assertEq(upper0, expectUpper);
        assertEq(lower0 % spacing, 0);
        assertEq(upper0 % spacing, 0);

        vm.prank(operator);
        vm.expectRevert(DeskVault.NotOwner.selector);
        vault.withdraw(whsk, 1, operator);

        _moveFairPrice();
        (uint256 moved,) = twap.latestPrice();
        assertTrue(moved != before);

        string memory reason = "recenter after the fair price moved";
        vm.recordLogs();
        vm.prank(operator);
        quote.recenter(0, reason);

        (
            uint256 id,
            uint256 whskAfter,
            uint256 usdtAfter,
            uint256 mid,
            bytes32 reasonHash,
            int24 lower1,
            int24 upper1,
            bool usedTwap,,
        ) = _recenter(vm.getRecordedLogs());

        (int24 nextLower, int24 nextUpper) = RangeMath.quote(moved, WIDTH, 0, FLOOR, 0, 0, CAP, CAP, spacing);
        assertEq(id, quote.positionId());
        assertTrue(id != opened);
        assertEq(lower1, nextLower);
        assertEq(upper1, nextUpper);
        assertTrue(lower1 != lower0);
        assertTrue(upper1 != upper0);
        (int24 liveLower, int24 liveUpper) = _ticks(id);
        assertEq(liveLower, lower1);
        assertEq(liveUpper, upper1);
        assertEq(mid, moved);
        assertEq(reasonHash, keccak256(bytes(reason)));
        assertEq(whskAfter, IPayToken(whsk).balanceOf(address(vault)));
        assertEq(usdtAfter, IPayToken(usdt).balanceOf(address(vault)));
        assertTrue(usedTwap);
        assertTrue(quote.lastUsedTwap());
        assertTrue(RangeMath.place(RangeMath.tickAtFairPrice(moved), lower1, upper1) == RangeMath.Place.Inside);

        console2.log("feed", "TWAP, APRO denied");
        console2.log("fair before, 8 decimals", before);
        console2.log("fair after, 8 decimals", moved);
        console2.log("tick lower", lower1);
        console2.log("tick upper", upper1);
    }

    function test_fork_recenterOutsideOracleBandReverts() public {
        _setWidth(WIDTH);
        vm.prank(operator);
        quote.mint(0, "mint at the twap");
        uint256 id = quote.positionId();
        (int24 lower, int24 upper) = _ticks(id);

        bytes32 outside = policy.OUTSIDE_BAND();
        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, outside));
        vm.prank(operator);
        quote.recenter(OUTSIDE_SKEW, "outside the oracle band");

        assertEq(quote.positionId(), id);
        (int24 lowerAfter, int24 upperAfter) = _ticks(id);
        assertEq(lowerAfter, lower);
        assertEq(upperAfter, upper);
        (,,,,,,, uint128 liquidity,,,,) = INonfungiblePositionManager(quote.npm()).positions(id);
        assertGt(liquidity, 0);
    }

    /// @dev A swap through the minted range earns fees and changes principal. Both event fields
    ///      are the close valued at the fair mid.
    function test_fork_recenterValuesFeesAgainstHolding() public {
        _fund(1_000 ether, 1_000e6);
        _setWidth(WIDTH);
        vm.prank(operator);
        quote.mint(0, "mint before the cross");
        uint256 opened = quote.positionId();
        (int24 lower0, int24 upper0) = _ticks(opened);

        uint256 whskBefore = IPayToken(whsk).balanceOf(address(vault));
        uint256 usdtBefore = IPayToken(usdt).balanceOf(address(vault));
        _swapThrough(lower0);

        vm.recordLogs();
        vm.prank(operator);
        quote.recenter(0, "recenter after the range was crossed");
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (,,, uint256 mid,, int24 lower1, int24 upper1,, uint256 spread, int256 holding) = _recenter(logs);
        (uint256 principal0, uint256 principal1) = _decreased(logs, opened);
        (uint256 collected0, uint256 collected1) = _collected(logs, opened);
        (uint256 fee0, uint256 fee1) = CloseValue.splitFees(collected0, collected1, principal0, principal1);

        assertGt(spread, 0);
        assertTrue(lower1 != lower0 || upper1 != upper0);
        assertEq(spread, CloseValue.spreadCaptured(fee0, fee1, mid));
        assertEq(
            holding,
            CloseValue.holdingDelta(whskBefore, usdtBefore, whskBefore + principal0, usdtBefore + principal1, mid)
        );
        (uint256 fairNow,) = twap.latestPrice();
        assertEq(mid, fairNow);
    }

    /// @dev The posted width is what mint uses. A width under the floor does not move the position.
    function test_fork_setWidthThenMint_widthUnderFloorLeavesPosition() public {
        _setWidth(WIDTH);
        assertEq(quote.widthBps(), WIDTH);

        (uint256 price,) = twap.latestPrice();
        vm.prank(operator);
        quote.mint(0, "mint at the stored width");

        uint256 id = quote.positionId();
        (int24 lower, int24 upper) = _ticks(id);
        int24 spacing = quote.tickSpacing();
        (int24 expectLower, int24 expectUpper) = RangeMath.quote(price, WIDTH, 0, FLOOR, 0, 0, CAP, CAP, spacing);
        assertEq(lower, expectLower);
        assertEq(upper, expectUpper);

        uint256 nonceBefore = policy.nonce();
        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.BELOW_SPREAD()));
        vm.prank(operator);
        quote.tightenWidth(FLOOR - 1, block.timestamp + 1 days, "");

        assertEq(quote.widthBps(), WIDTH);
        assertEq(quote.positionId(), id);
        assertEq(policy.nonce(), nonceBefore);
        (int24 lowerAfter, int24 upperAfter) = _ticks(id);
        assertEq(lowerAfter, lower);
        assertEq(upperAfter, upper);
        (,,,,,,, uint128 liquidity,,,,) = INonfungiblePositionManager(quote.npm()).positions(id);
        assertGt(liquidity, 0);
    }

    function _fund(uint256 whskAmount, uint256 usdtAmount) internal {
        vm.deal(address(this), whskAmount);
        IWHSK(whsk).deposit{value: whskAmount}();
        IPayToken(whsk).transfer(owner, whskAmount);
        deal(usdt, owner, usdtAmount);

        vm.startPrank(owner);
        _approve(whsk, address(vault), whskAmount);
        _approve(usdt, address(vault), usdtAmount);
        vault.deposit(whsk, whskAmount);
        vault.deposit(usdt, usdtAmount);
        vm.stopPrank();
    }

    /// @dev Sell WHSK into the pinned pool, then age the TWAP window so the fair price follows.
    function _moveFairPrice() internal {
        (uint160 sqrtPrice, int24 tick,,,,,) = IUniswapV3Pool(pool).slot0();
        int24 target = tick - 2_000;
        uint160 limit = SqrtTick.sqrtPriceX96(target);
        assertLt(limit, sqrtPrice);

        uint256 budget = 2_000_000 ether;
        vm.deal(address(this), budget);
        IWHSK(whsk).deposit{value: budget}();
        IMovePool(pool).swap(address(this), true, int256(budget), limit, "");

        (, int24 moved,,,,,) = IUniswapV3Pool(pool).slot0();
        assertLt(moved, tick - 600);
        vm.warp(block.timestamp + FairPrice.TWAP_WINDOW);
    }

    /// @dev Sell WHSK until the pool tick is below the position, then age the TWAP so the fair price follows.
    function _swapThrough(int24 tickLower) internal {
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
        (,,,,, tickLower, tickUpper,,,,,) = INonfungiblePositionManager(quote.npm()).positions(id);
    }

    function _recenter(Vm.Log[] memory logs)
        internal
        view
        returns (
            uint256 id,
            uint256 whskAfter,
            uint256 usdtAfter,
            uint256 mid,
            bytes32 reasonHash,
            int24 tickLower,
            int24 tickUpper,
            bool usedTwap,
            uint256 spreadCaptured,
            int256 holdingDelta
        )
    {
        bytes32 topic = keccak256("Recentered(uint256,uint256,uint256,uint256,bytes32,int24,int24,bool,uint256,int256)");
        for (uint256 i = logs.length; i > 0; --i) {
            Vm.Log memory entry = logs[i - 1];
            if (entry.emitter != address(quote) || entry.topics[0] != topic) continue;
            id = uint256(entry.topics[1]);
            (whskAfter, usdtAfter, mid, reasonHash, tickLower, tickUpper, usedTwap, spreadCaptured, holdingDelta) =
                abi.decode(entry.data, (uint256, uint256, uint256, bytes32, int24, int24, bool, uint256, int256));
            return
                (
                    id,
                    whskAfter,
                    usdtAfter,
                    mid,
                    reasonHash,
                    tickLower,
                    tickUpper,
                    usedTwap,
                    spreadCaptured,
                    holdingDelta
                );
        }
        revert("missing Recentered");
    }

    function _decreased(Vm.Log[] memory logs, uint256 tokenId)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        bytes32 topic = keccak256("DecreaseLiquidity(uint256,uint128,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory entry = logs[i];
            if (entry.emitter != address(quote.npm()) || entry.topics[0] != topic) continue;
            if (uint256(entry.topics[1]) != tokenId) continue;
            uint128 liquidity;
            (liquidity, amount0, amount1) = abi.decode(entry.data, (uint128, uint256, uint256));
            return (amount0, amount1);
        }
        revert("missing DecreaseLiquidity");
    }

    function _collected(Vm.Log[] memory logs, uint256 tokenId)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        bytes32 topic = keccak256("Collect(uint256,address,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory entry = logs[i];
            if (entry.emitter != address(quote.npm()) || entry.topics[0] != topic) continue;
            if (uint256(entry.topics[1]) != tokenId) continue;
            address recipient;
            (recipient, amount0, amount1) = abi.decode(entry.data, (address, uint256, uint256));
            return (amount0, amount1);
        }
        revert("missing Collect");
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
