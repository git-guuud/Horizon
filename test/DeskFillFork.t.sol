// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {DeskFill} from "../src/fill/DeskFill.sol";
import {DeskPolicy} from "../src/policy/DeskPolicy.sol";
import {DeskVault} from "../src/vault/DeskVault.sol";
import {IQuoterV2, ISwapRouter02} from "../src/market/Interfaces.sol";
import {ITwapPool} from "../src/price/ITwapPool.sol";
import {MarketPin} from "../src/market/MarketPin.sol";
import {Seeds} from "../src/market/Seeds.sol";
import {AproFairPrice} from "../src/price/AproFairPrice.sol";
import {FairPrice} from "../src/price/FairPrice.sol";
import {FallbackFairPrice} from "../src/price/FallbackFairPrice.sol";
import {SqrtTick} from "../src/price/SqrtTick.sol";
import {TwapFairPrice} from "../src/price/TwapFairPrice.sol";

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

/// @notice Fork of chain 177. Fills use the live pool, the live router, and the TWAP.
///         APRO denies the contract. No fill amount is mocked.
contract DeskFillForkTest is Test {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant BAND = 100;
    uint256 internal constant FLOOR = 30;
    uint256 internal constant SLIPPAGE = 100;
    uint256 internal constant CAP = 1_000_000 ether;
    uint256 internal constant SIZE = 100_000 ether;

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
    DeskFill internal desk;

    address internal pool;
    address internal whsk;
    address internal usdt;
    uint24 internal fee;

    function setUp() public {
        vm.createSelectFork("hashkey");
        trader = vm.addr(traderKey);
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
        desk = new DeskFill(
            address(vault), address(policy), pool, Seeds.HSKSWAP_SWAP_ROUTER_02, Seeds.HSKSWAP_QUOTER_V2, SLIPPAGE
        );

        vm.prank(owner);
        vault.setFiller(address(desk));
    }

    /// @dev The size cannot be bought from the pinned pool inside the oracle band.
    function test_fork_nakedPoolFailsInsideBand() public {
        (uint256 mid,) = twap.latestPrice();
        uint256 budget = SIZE * mid * (BPS + BAND) / BPS / 1e20;
        (uint256 whskOut,,,) = IQuoterV2(Seeds.HSKSWAP_QUOTER_V2)
            .quoteExactInputSingle(
                IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: usdt, tokenOut: whsk, amountIn: budget, fee: fee, sqrtPriceLimitX96: 0
            })
            );

        console2.log("intent size, WHSK wei", SIZE);
        console2.log("band budget, USDT raw", budget);
        console2.log("quoted WHSK out", whskOut);
        assertLt(whskOut, SIZE);

        deal(usdt, address(this), 20_000e6);
        _approve(usdt, Seeds.HSKSWAP_SWAP_ROUTER_02, 20_000e6);
        vm.expectRevert(bytes("Too much requested"));
        ISwapRouter02(Seeds.HSKSWAP_SWAP_ROUTER_02)
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
            );
    }

    /// @dev The same size fills from vault inventory at the oracle. Balances are the vault's tokens.
    function test_fork_inventoryFillAtOracle() public {
        vm.expectRevert(bytes("No access"));
        apro.latestPrice();

        (uint256 mid,) = twap.latestPrice();
        uint256 price = mid * (BPS + FLOOR) / BPS;
        uint256 paid = SIZE * price / 1e20;
        _fund(SIZE, 0);
        deal(usdt, trader, paid);
        vm.prank(trader);
        _approve(usdt, address(vault), paid);

        DeskFill.Intent memory intent = _intent(desk.BUY_WHSK(), SIZE, price, 1);
        bytes memory signature = _sign(intent);
        bytes32 reasonHash = keccak256("fill at the oracle");

        vm.expectEmit(true, false, false, true);
        emit DeskFill.Filled(trader, 1, desk.BUY_WHSK(), SIZE, mid, FLOOR, 0, paid, reasonHash, 0);
        vm.prank(operator);
        desk.fill(intent, signature, "fill at the oracle", reasonHash);

        assertEq(IPayToken(whsk).balanceOf(address(vault)), 0);
        assertEq(IPayToken(usdt).balanceOf(address(vault)), paid);
        assertEq(IPayToken(whsk).balanceOf(trader), SIZE);
        assertEq(IPayToken(usdt).balanceOf(trader), 0);

        vm.prank(operator);
        vm.expectRevert(DeskVault.NotOwner.selector);
        vault.withdraw(whsk, 1, operator);

        console2.log("feed", "TWAP, APRO denied");
        console2.log("fair, 8 decimals", mid);
        console2.log("usdt paid", paid);
    }

    function test_fork_outsideBandReverts() public {
        _fund(1 ether, 0);
        (uint256 mid,) = twap.latestPrice();
        uint256 price = mid * (BPS + FLOOR) / BPS;
        DeskFill.Intent memory intent = _intent(desk.BUY_WHSK(), 1 ether, price, 2);
        bytes memory signature = _sign(intent);

        vm.prank(owner);
        policy.setBand(FLOOR - 1);

        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.OUTSIDE_BAND()));
        vm.prank(operator);
        desk.fill(intent, signature, "outside the band", keccak256("outside the band"));

        assertEq(IPayToken(whsk).balanceOf(address(vault)), 1 ether);
        assertEq(IPayToken(usdt).balanceOf(address(vault)), 0);
        assertFalse(desk.usedNonce(trader, 2));
    }

    function test_fork_stalePriceRevertsAndHaltSticks() public {
        _fund(SIZE, 0);
        (uint256 mid,) = twap.latestPrice();
        uint256 size = SIZE;
        DeskFill.Intent memory intent = _intent(desk.BUY_WHSK(), size, mid * 2, 3);
        bytes memory signature = _sign(intent);

        vm.warp(block.timestamp + FairPrice.MAX_STALENESS + 1);
        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.STALE()));
        vm.prank(operator);
        desk.fill(intent, signature, "stale", keccak256("stale"));

        vm.prank(stranger);
        policy.halt();
        assertTrue(policy.halted());

        _pokePool();
        (uint256 fresh,) = twap.latestPrice();
        uint256 price = fresh * (BPS + FLOOR) / BPS;
        uint256 paid = size * price / 1e20;
        assertLe(price, mid * 2);

        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.HALTED()));
        vm.prank(operator);
        desk.fill(intent, signature, "stale", keccak256("stale"));

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.NOT_OWNER()));
        policy.resume();
        assertTrue(policy.halted());

        vm.prank(owner);
        policy.resume();
        assertFalse(policy.halted());

        deal(usdt, trader, paid);
        vm.prank(trader);
        _approve(usdt, address(vault), paid);
        vm.prank(operator);
        desk.fill(intent, signature, "stale", keccak256("stale"));

        assertEq(IPayToken(whsk).balanceOf(address(vault)), 0);
        assertEq(IPayToken(usdt).balanceOf(address(vault)), paid);
        assertEq(IPayToken(whsk).balanceOf(trader), size);
        assertFalse(policy.halted());
    }

    /// @dev The pool cannot fill 100,000 WHSK inside the band. One WHSK of that size is bought
    ///      on the live router. The rest comes from the vault.
    function test_fork_residualRoutesInsideSlippageCap() public {
        uint256 residual = 1 ether;
        uint256 size = SIZE;
        uint256 covered = size - residual;
        _fund(covered, 0);

        (uint256 mid,) = twap.latestPrice();
        uint256 price = mid * (BPS + FLOOR) / BPS;
        uint256 paid = covered * price / 1e20;
        uint256 worst = mid * (BPS + SLIPPAGE) / BPS;
        uint256 maxIn = residual * worst / 1e20;

        deal(usdt, trader, paid + maxIn);
        vm.startPrank(trader);
        _approve(usdt, address(vault), paid);
        _approve(usdt, address(desk), maxIn);
        vm.stopPrank();

        DeskFill.Intent memory intent = _intent(desk.BUY_WHSK(), size, price, 4);
        bytes memory signature = _sign(intent);
        uint256 traderBefore = IPayToken(usdt).balanceOf(trader);
        vm.prank(operator);
        desk.fill(intent, signature, "residual", keccak256("residual"));

        uint256 spent = traderBefore - IPayToken(usdt).balanceOf(trader) - paid;
        assertEq(IPayToken(whsk).balanceOf(address(vault)), 0);
        assertEq(IPayToken(usdt).balanceOf(address(vault)), paid);
        assertEq(IPayToken(whsk).balanceOf(trader), size);
        assertGt(spent, 0);
        assertLe(spent, maxIn);
        assertEq(IPayToken(usdt).balanceOf(address(desk)), 0);

        console2.log("residual WHSK", residual);
        console2.log("router USDT in", spent);
        console2.log("slippage cap, USDT raw", maxIn);
    }

    /// @dev A size the pinned pool can fill inside the band never settles.
    function test_fork_poolCanFillReverts() public {
        assertEq(policy.POOL_CAN_FILL(), keccak256("POOL_CAN_FILL"));
        uint256 size = 1 ether;
        _fund(size, 0);
        (uint256 mid,) = twap.latestPrice();
        uint256 price = mid * (BPS + FLOOR) / BPS;
        uint256 paid = size * price / 1e20;
        deal(usdt, trader, paid);
        vm.prank(trader);
        _approve(usdt, address(vault), paid);

        DeskFill.Intent memory intent = _intent(desk.BUY_WHSK(), size, price, 8);
        bytes memory signature = _sign(intent);
        uint256 whskBefore = IPayToken(whsk).balanceOf(address(vault));
        uint256 usdtBefore = IPayToken(usdt).balanceOf(address(vault));

        vm.expectRevert(abi.encodeWithSelector(DeskPolicy.Policy.selector, policy.POOL_CAN_FILL()));
        vm.prank(operator);
        desk.fill(intent, signature, "pool can fill", keccak256("pool can fill"));

        assertEq(IPayToken(whsk).balanceOf(address(vault)), whskBefore);
        assertEq(IPayToken(usdt).balanceOf(address(vault)), usdtBefore);
        assertEq(IPayToken(whsk).balanceOf(trader), 0);
        assertFalse(desk.usedNonce(trader, 8));
    }

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
        IWHSK(whsk).deposit{value: whskAmount}();
        IPayToken(whsk).transfer(owner, whskAmount);
        if (usdtAmount != 0) deal(usdt, owner, usdtAmount);

        vm.startPrank(owner);
        _approve(whsk, address(vault), whskAmount);
        if (usdtAmount != 0) {
            _approve(usdt, address(vault), usdtAmount);
            vault.deposit(usdt, usdtAmount);
        }
        vault.deposit(whsk, whskAmount);
        vm.stopPrank();
    }

    /// @dev Sell enough WHSK to cross a tick. This pool records an observation when the tick moves.
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
}
