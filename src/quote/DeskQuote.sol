// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DeskPolicy} from "../policy/DeskPolicy.sol";
import {DeskVault} from "../vault/DeskVault.sol";
import {FairPrice} from "../price/FairPrice.sol";
import {FallbackFairPrice} from "../price/FallbackFairPrice.sol";
import {CloseValue} from "./CloseValue.sol";
import {INonfungiblePositionManager} from "./INonfungiblePositionManager.sol";
import {RangeMath} from "./RangeMath.sol";

interface IQuotePool {
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function tickSpacing() external view returns (int24);
}

interface IQuoteToken {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @title DeskQuote
/// @notice The operator mints one concentrated position on a pinned v3 pool and recenters it
///         when the fair price moves. The quoted mid is the fair price shifted by the skew.
///         That mid has to sit inside the oracle band. The posted width is stored here.
///         Mint and recenter use that width. It has to clear the spread floor.
///         The operator may widen it. A tighter width needs the owner's signature on the policy,
///         and it still cannot go under the floor.
///         APRO is the primary read. A failed APRO read, including `No access`, uses the TWAP.
///         Recenter emits the vault balances after, the fair mid, keccak256 of the reason string,
///         the spread captured on the close, and the holding delta of that close.
///         The position is held here. The operator cannot send it, and cannot withdraw the vault.
///         Mint spends the vault balances. It does not set a surplus minimum. The band is the price check.
contract DeskQuote {
    uint128 internal constant MAX_COLLECT = type(uint128).max;

    DeskVault public immutable vault;
    DeskPolicy public immutable policy;
    FallbackFairPrice public immutable fair;
    INonfungiblePositionManager public immutable npm;
    IQuotePool public immutable pool;
    address public immutable whsk;
    address public immutable usdt;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;

    uint256 public constant BPS = 10_000;

    uint256 public positionId;
    int24 public tickLower;
    int24 public tickUpper;
    uint256 public mid;
    bool public lastUsedTwap;
    /// @notice Distance from the skewed mid to each edge, in bps. Mint and recenter read this.
    uint256 public widthBps;

    error ZeroAddress();
    error BadMarket();
    error QuotingPaused();
    error PositionOpen();
    error NoPosition();
    error NoInventory();
    error NoLiquidity();

    event Minted(
        uint256 indexed positionId,
        uint256 whskAfter,
        uint256 usdtAfter,
        uint256 mid,
        bytes32 reasonHash,
        int24 tickLower,
        int24 tickUpper,
        bool usedTwap
    );

    event Recentered(
        uint256 indexed positionId,
        uint256 whskAfter,
        uint256 usdtAfter,
        uint256 mid,
        bytes32 reasonHash,
        int24 tickLower,
        int24 tickUpper,
        bool usedTwap,
        uint256 spreadCaptured,
        int256 holdingDelta
    );

    event WidthUpdated(uint256 widthBps);

    constructor(address vault_, address policy_, address fair_, address npm_, address pool_) {
        if (
            vault_ == address(0) || policy_ == address(0) || fair_ == address(0) || npm_ == address(0)
                || pool_ == address(0)
        ) {
            revert ZeroAddress();
        }

        DeskVault vaultBound = DeskVault(vault_);
        DeskPolicy policyBound = DeskPolicy(policy_);
        IQuotePool poolBound = IQuotePool(pool_);
        address token0 = poolBound.token0();
        address token1 = poolBound.token1();
        if (token0 != vaultBound.whsk() || token1 != vaultBound.usdt()) revert BadMarket();
        if (token0 != policyBound.whsk() || token1 != policyBound.usdt()) revert BadMarket();
        if (address(policyBound.fair()) != fair_) revert BadMarket();
        if (INonfungiblePositionManager(npm_).factory() != poolBound.factory()) revert BadMarket();
        int24 spacing = poolBound.tickSpacing();
        if (spacing <= 0) revert BadMarket();

        vault = vaultBound;
        policy = policyBound;
        fair = FallbackFairPrice(fair_);
        npm = INonfungiblePositionManager(npm_);
        pool = poolBound;
        whsk = token0;
        usdt = token1;
        fee = poolBound.fee();
        tickSpacing = spacing;
        widthBps = policyBound.spreadFloor();
        emit WidthUpdated(widthBps);
    }

    /// @notice The operator may only widen the posted range.
    function widenWidth(uint256 newWidth) external {
        if (msg.sender != policy.operator()) revert DeskPolicy.Policy(policy.NOT_OPERATOR());
        _checkWidth(newWidth);
        if (newWidth <= widthBps) revert DeskPolicy.Policy(policy.NOT_WIDER());
        widthBps = newWidth;
        emit WidthUpdated(newWidth);
    }

    /// @notice A tighter posted width. The owner must have signed it. A width under the floor reverts.
    /// @dev The floor is checked before the signature, so a width under the floor does not burn the nonce.
    function tightenWidth(uint256 newWidth, uint256 deadline, bytes calldata signature) external {
        _checkWidth(newWidth);
        if (newWidth >= widthBps) revert DeskPolicy.Policy(policy.NOT_TIGHTER());
        policy.consumeTightenWidth(newWidth, deadline, signature);
        widthBps = newWidth;
        emit WidthUpdated(newWidth);
    }

    /// @notice Mint the desk's position around the current fair price, at the stored width.
    /// @param skewBps Signed shift of the mid, in bps. A shift outside the oracle band reverts.
    /// @param reason Recorded as keccak256 of its UTF-8 bytes.
    function mint(int256 skewBps, string calldata reason) external returns (uint256 mintedId) {
        _enter();
        if (positionId != 0) revert PositionOpen();
        _quoteAt(skewBps);
        mintedId = _open();
        positionId = mintedId;
        _emitMinted(mintedId, reason);
    }

    /// @notice Close the position and mint a new one at the stored width. A bound failure rolls the close back.
    /// @dev `mid` in the event is the fair price, before the skew. The band is applied to the skewed center.
    ///      Spread and holding are valued at that same mid, in USDT raw.
    function recenter(int256 skewBps, string calldata reason) external returns (uint256 mintedId) {
        _enter();
        if (positionId == 0) revert NoPosition();
        CloseValue.Snap memory snap = _close();
        _quoteAt(skewBps);
        mintedId = _open();
        positionId = mintedId;
        uint256 spread = CloseValue.spreadCaptured(snap.fee0, snap.fee1, mid);
        int256 holding = CloseValue.holdingDelta(
            snap.whskBefore, snap.usdtBefore, snap.whskBefore + snap.principal0, snap.usdtBefore + snap.principal1, mid
        );
        _emitRecentered(mintedId, reason, spread, holding);
    }

    function _quoteAt(int256 skewBps) private {
        (uint256 price, bool usedTwap) = _fair();
        mid = price;
        lastUsedTwap = usedTwap;
        _bound(RangeMath.center(price, skewBps), widthBps);
        (tickLower, tickUpper) = _ticks(price, widthBps, skewBps);
    }

    function _checkWidth(uint256 newWidth) private view {
        if (newWidth < policy.spreadFloor()) revert DeskPolicy.Policy(policy.BELOW_SPREAD());
        if (newWidth >= BPS) revert RangeMath.BadWidth();
    }

    function _ticks(uint256 price, uint256 width, int256 skewBps) private view returns (int24 lower, int24 upper) {
        uint256 floorBps = policy.spreadFloor();
        uint256 whskBal = _balance(whsk);
        uint256 usdtBal = _balance(usdt);
        uint256 whskCap = policy.inventoryCap(whsk);
        uint256 usdtCap = policy.inventoryCap(usdt);
        return RangeMath.quote(price, width, skewBps, floorBps, whskBal, usdtBal, whskCap, usdtCap, tickSpacing);
    }

    function _bound(uint256 skewed, uint256 width) private view {
        policy.requireBound(skewed, width, whsk, _balance(whsk));
        policy.requireBound(skewed, width, usdt, _balance(usdt));
    }

    function _fair() private view returns (uint256 price, bool usedTwap) {
        try fair.read() returns (uint256 answer, uint256, bool usedSecondary) {
            return (answer, usedSecondary);
        } catch (bytes memory err) {
            bytes4 sel = _selector(err);
            if (sel == FairPrice.StalePrice.selector) revert DeskPolicy.Policy(policy.STALE());
            if (sel == FairPrice.InvalidPrice.selector) revert DeskPolicy.Policy(policy.INVALID_PRICE());
            _bubble(err);
        }
    }

    function _open() private returns (uint256 mintedId) {
        uint256 amount0 = _draw(whsk);
        uint256 amount1 = _draw(usdt);
        if (amount0 == 0 && amount1 == 0) revert NoInventory();
        _approve(whsk, address(npm), amount0);
        _approve(usdt, address(npm), amount1);
        mintedId = _npmMint(amount0, amount1);
        _approve(whsk, address(npm), 0);
        _approve(usdt, address(npm), 0);
        _restore(whsk);
        _restore(usdt);
    }

    function _npmMint(uint256 amount0, uint256 amount1) private returns (uint256 mintedId) {
        uint128 liquidity;
        (mintedId, liquidity,,) = npm.mint(
            INonfungiblePositionManager.MintParams({
                token0: whsk,
                token1: usdt,
                fee: fee,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
        if (liquidity == 0) revert NoLiquidity();
    }

    /// @dev Sends the position's tokens back to the vault before the new range is checked.
    ///      Fees are the collect return beyond the decreased principal. The snap's before-balances
    ///      are the vault, and the principal after the close is those balances plus that principal.
    function _close() private returns (CloseValue.Snap memory snap) {
        snap.whskBefore = _balance(whsk);
        snap.usdtBefore = _balance(usdt);
        uint256 id = positionId;
        (snap.principal0, snap.principal1) = _decrease(id);
        (uint256 collected0, uint256 collected1) = _collect(id);
        (snap.fee0, snap.fee1) = CloseValue.splitFees(collected0, collected1, snap.principal0, snap.principal1);
        npm.burn(id);
        positionId = 0;
        _restore(whsk);
        _restore(usdt);
    }

    function _decrease(uint256 id) private returns (uint256 amount0, uint256 amount1) {
        uint128 liquidity = _liquidity(id);
        if (liquidity == 0) return (0, 0);
        return npm.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: id, liquidity: liquidity, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
            })
        );
    }

    function _collect(uint256 id) private returns (uint256 amount0, uint256 amount1) {
        return npm.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: id, recipient: address(this), amount0Max: MAX_COLLECT, amount1Max: MAX_COLLECT
            })
        );
    }

    function _emitMinted(uint256 mintedId, string calldata reason) private {
        emit Minted(
            mintedId, _balance(whsk), _balance(usdt), mid, keccak256(bytes(reason)), tickLower, tickUpper, lastUsedTwap
        );
    }

    function _emitRecentered(uint256 mintedId, string calldata reason, uint256 spread, int256 holding) private {
        emit Recentered(
            mintedId,
            _balance(whsk),
            _balance(usdt),
            mid,
            keccak256(bytes(reason)),
            tickLower,
            tickUpper,
            lastUsedTwap,
            spread,
            holding
        );
    }

    function _draw(address token) private returns (uint256 amount) {
        amount = _balance(token);
        if (amount != 0) vault.draw(token, amount);
    }

    function _restore(address token) private {
        uint256 bal = IQuoteToken(token).balanceOf(address(this));
        if (bal == 0) return;
        _approve(token, address(vault), bal);
        vault.restore(token, bal);
    }

    function _approve(address token, address spender, uint256 amount) private {
        _call(token, abi.encodeCall(IQuoteToken.approve, (spender, 0)));
        if (amount != 0) _call(token, abi.encodeCall(IQuoteToken.approve, (spender, amount)));
    }

    function _balance(address token) private view returns (uint256) {
        return IQuoteToken(token).balanceOf(address(vault));
    }

    function _liquidity(uint256 id) private view returns (uint128 liquidity) {
        (,,,,,,, liquidity,,,,) = npm.positions(id);
    }

    function _enter() private view {
        if (msg.sender != policy.operator()) revert DeskPolicy.Policy(policy.NOT_OPERATOR());
        if (vault.paused()) revert QuotingPaused();
    }

    function _call(address token, bytes memory data) private {
        (bool ok, bytes memory ret) = token.call(data);
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert DeskVault.TransferFailed();
    }

    function _selector(bytes memory err) private pure returns (bytes4 sel) {
        if (err.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            sel := mload(add(err, 32))
        }
    }

    function _bubble(bytes memory err) private pure {
        assembly ("memory-safe") {
            revert(add(err, 32), mload(err))
        }
    }
}
