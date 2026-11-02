// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IQuoterV2, ISwapRouter02} from "../market/Interfaces.sol";
import {DeskPolicy} from "../policy/DeskPolicy.sol";
import {DeskVault} from "../vault/DeskVault.sol";
import {FairPrice} from "../price/FairPrice.sol";
import {IFairPrice} from "../price/IFairPrice.sol";
import {MulDiv} from "../price/MulDiv.sol";

interface IFillPool {
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
}

interface IFillToken {
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title DeskFill
/// @notice The operator fills one signed intent from vault inventory.
///         The pool is the pair on the intent.
///         The USDT leg of the intent has to sit at or under the policy fill cap.
///         Before settling, the pinned QuoterV2 is asked whether the pool can do the full size
///         inside the oracle band. The budget is the size times the band edge.
///         If that quote covers the size, the fill reverts and the nonce stays unused.
///         If it does not, inventory is used first, at the fair price plus or minus the spread floor.
///         Any size the vault cannot cover is a residual. That residual is swapped on the HSKSwap
///         router when the worst price stays inside the slippage cap and inside the oracle band.
///         With no router set, a short inventory reverts. The unit tests leave the quoter unset
///         because their pool is a mock and is not the pinned HSKSwap pool.
///         A buy of WHSK pays the taker WHSK and pulls USDT. A sell pays USDT and pulls WHSK.
///         The limit has to clear the spread floor. The balances after the inventory leg have to sit at or under the caps.
///         The fill emits the fair mid, the spread, both inventories after, the reason hash, and the residual size.
///         The operator cannot withdraw. The taker signs the intent. The owner sets this contract as the vault's filler.
contract DeskFill {
    uint256 internal constant BPS = 10_000;
    /// @notice Taker buys WHSK from the desk.
    uint8 public constant BUY_WHSK = 0;
    /// @notice Taker sells WHSK to the desk.
    uint8 public constant SELL_WHSK = 1;

    bytes32 internal constant EIP712_DOMAIN =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant INTENT_TYPEHASH = keccak256(
        "Intent(address pair,uint8 side,uint256 size,uint256 limit,uint256 expiry,uint256 nonce,address trader)"
    );
    bytes32 internal constant NAME_HASH = keccak256("Desk");
    bytes32 internal constant VERSION_HASH = keccak256("1");

    /// @dev keccak256 of the label. A second machine can recompute it from the name alone.
    bytes32 public constant REASON_MISMATCH = keccak256("REASON_MISMATCH");

    struct Intent {
        address pair;
        uint8 side;
        uint256 size;
        uint256 limit;
        uint256 expiry;
        uint256 nonce;
        address trader;
    }

    DeskVault public immutable vault;
    DeskPolicy public immutable policy;
    IFillPool public immutable pool;
    address public immutable whsk;
    address public immutable usdt;
    uint256 public immutable quoteScale;

    mapping(address trader => mapping(uint256 nonce => bool used)) public usedNonce;

    error ZeroAddress();
    error BadMarket();
    error BadPair();
    error BadSide();
    error FillingPaused();
    error ShortInventory();
    error ZeroFill();
    error BadSlippage();

    event Filled(
        address indexed trader,
        uint256 nonce,
        uint8 side,
        uint256 size,
        uint256 mid,
        uint256 spread,
        uint256 whskAfter,
        uint256 usdtAfter,
        bytes32 reasonHash,
        uint256 residual
    );

    ISwapRouter02 public immutable router;
    IQuoterV2 public immutable quoter;
    uint24 public immutable fee;
    uint256 public immutable slippageBps;

    constructor(address vault_, address policy_, address pool_, address router_, address quoter_, uint256 slippageBps_) {
        if (vault_ == address(0) || policy_ == address(0) || pool_ == address(0)) revert ZeroAddress();
        if ((router_ == address(0)) != (quoter_ == address(0))) revert ZeroAddress();
        if (slippageBps_ >= BPS) revert BadSlippage();

        DeskVault vaultBound = DeskVault(vault_);
        DeskPolicy policyBound = DeskPolicy(policy_);
        IFillPool poolBound = IFillPool(pool_);
        address token0 = poolBound.token0();
        address token1 = poolBound.token1();
        if (token0 != vaultBound.whsk() || token1 != vaultBound.usdt()) revert BadMarket();
        if (token0 != policyBound.whsk() || token1 != policyBound.usdt()) revert BadMarket();
        if (address(policyBound.fair()).code.length == 0) revert BadMarket();

        uint256 whskDecimals = IFillToken(token0).decimals();
        uint256 usdtDecimals = IFillToken(token1).decimals();
        uint256 priceDecimals = IFairPrice(address(policyBound.fair())).decimals();
        if (whskDecimals + priceDecimals < usdtDecimals) revert BadMarket();
        router = ISwapRouter02(router_);
        quoter = IQuoterV2(quoter_);
        if (router_ != address(0)) {
            if (router.factory() != poolBound.factory()) revert BadMarket();
            if (router.WETH9() != token0) revert BadMarket();
        }

        vault = vaultBound;
        policy = policyBound;
        pool = poolBound;
        whsk = token0;
        usdt = token1;
        fee = poolBound.fee();
        slippageBps = slippageBps_;
        quoteScale = 10 ** (whskDecimals + priceDecimals - usdtDecimals);
    }

    /// @notice Fill `intent` from inventory. `reasonHash` must be keccak256 of `reason`.
    /// @param intent Signed by `intent.trader`. `size` is WHSK. `limit` is USDT per 1 WHSK at the fair-price decimals.
    ///        A buy limit is the most the taker pays. A sell limit is the least the taker accepts.
    /// @param reason Recorded as keccak256 of its UTF-8 bytes. The hash argument has to match.
    function fill(Intent calldata intent, bytes calldata signature, string calldata reason, bytes32 reasonHash)
        external
    {
        if (msg.sender != policy.operator()) revert DeskPolicy.Policy(policy.NOT_OPERATOR());
        if (vault.paused()) revert FillingPaused();
        if (keccak256(bytes(reason)) != reasonHash) revert DeskPolicy.Policy(REASON_MISMATCH);
        if (intent.pair != address(pool)) revert BadPair();
        if (intent.side != BUY_WHSK && intent.side != SELL_WHSK) revert BadSide();
        if (intent.size == 0) revert ZeroFill();
        if (block.timestamp > intent.expiry) revert DeskPolicy.Policy(policy.EXPIRED());
        _requireTrader(intent, signature);
        if (usedNonce[intent.trader][intent.nonce]) revert DeskPolicy.Policy(policy.BAD_NONCE());

        uint256 floorBps = policy.spreadFloor();
        uint256 mid = _fresh();
        uint256 price = _quotePrice(intent.side, mid, floorBps);
        _requireLimit(intent, price);
        uint256 usdtLeg = MulDiv.mulDiv(intent.size, price, quoteScale);
        if (usdtLeg == 0) revert ZeroFill();
        if (usdtLeg > policy.fillCap()) revert DeskPolicy.Policy(policy.FILL_CAP());

        (uint256 covered, uint256 residual) = _split(intent, price);
        if (residual != 0 && address(router) == address(0)) revert ShortInventory();

        uint256 whskAfter = _balance(whsk);
        uint256 usdtAfter = _balance(usdt);
        address payToken;
        uint256 payAmount;
        address takeToken;
        uint256 takeAmount;
        if (covered != 0) {
            (payToken, payAmount, takeToken, takeAmount) = _coveredLegs(intent.side, covered, price);
            (whskAfter, usdtAfter) = _after(intent.side, payAmount, takeAmount);
        }
        policy.requireBound(price, floorBps, whsk, whskAfter);
        policy.requireBound(price, floorBps, usdt, usdtAfter);
        uint256 worst;
        if (residual != 0) {
            worst = _worst(intent.side, mid, _capBps());
            policy.requireBound(worst, floorBps, whsk, whskAfter);
            policy.requireBound(worst, floorBps, usdt, usdtAfter);
        }
        if (address(quoter) != address(0) && _poolCanFill(intent.side, intent.size, mid)) {
            revert DeskPolicy.Policy(policy.POOL_CAN_FILL());
        }

        usedNonce[intent.trader][intent.nonce] = true;
        if (covered != 0) vault.settle(payToken, payAmount, takeToken, takeAmount, intent.trader);
        if (residual != 0) _route(intent, residual, worst);

        emit Filled(
            intent.trader,
            intent.nonce,
            intent.side,
            intent.size,
            mid,
            floorBps,
            whskAfter,
            usdtAfter,
            reasonHash,
            residual
        );
    }

    function intentDigest(Intent calldata intent) public view returns (bytes32) {
        return _hashTypedData(
            keccak256(
                abi.encode(
                    INTENT_TYPEHASH,
                    intent.pair,
                    intent.side,
                    intent.size,
                    intent.limit,
                    intent.expiry,
                    intent.nonce,
                    intent.trader
                )
            )
        );
    }

    /// @dev Buyers pay the fair price plus the floor. Sellers receive the fair price minus the floor.
    function _quotePrice(uint8 side, uint256 mid, uint256 floorBps) private view returns (uint256) {
        if (side == BUY_WHSK) return MulDiv.mulDiv(mid, BPS + floorBps, BPS);
        if (floorBps >= BPS) revert DeskPolicy.Policy(policy.BELOW_SPREAD());
        uint256 bid = MulDiv.mulDiv(mid, BPS - floorBps, BPS);
        if (bid == 0) revert DeskPolicy.Policy(policy.INVALID_PRICE());
        return bid;
    }

    function _requireLimit(Intent calldata intent, uint256 price) private view {
        if (intent.side == BUY_WHSK) {
            if (intent.limit < price) revert DeskPolicy.Policy(policy.BELOW_SPREAD());
        } else if (intent.limit > price) {
            revert DeskPolicy.Policy(policy.BELOW_SPREAD());
        }
    }

    /// @dev True when the pinned pool can do `size` inside the oracle band.
    ///      A buy is quoted with a USDT budget at the top of the band. A sell is quoted
    ///      for the full WHSK size and has to clear the bottom of the band.
    ///      A quote that reverts cannot fill the size.
    function _poolCanFill(uint8 side, uint256 size, uint256 mid) private returns (bool) {
        uint256 band = policy.bandBps();
        if (side == BUY_WHSK) {
            uint256 high = MulDiv.mulDiv(mid, BPS + band, BPS);
            uint256 budget = MulDiv.mulDiv(size, high, quoteScale);
            if (budget == 0) return false;
            try quoter.quoteExactInputSingle(
                IQuoterV2.QuoteExactInputSingleParams({
                    tokenIn: usdt, tokenOut: whsk, amountIn: budget, fee: fee, sqrtPriceLimitX96: 0
                })
            ) returns (uint256 amountOut, uint160, uint32, uint256) {
                return amountOut >= size;
            } catch {
                return false;
            }
        }
        uint256 low = MulDiv.mulDiv(mid, BPS - band, BPS);
        uint256 minOut = MulDiv.mulDiv(size, low, quoteScale);
        if (low == 0 || minOut == 0) return false;
        try quoter.quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: whsk, tokenOut: usdt, amountIn: size, fee: fee, sqrtPriceLimitX96: 0
            })
        ) returns (uint256 amountOut, uint160, uint32, uint256) {
            return amountOut >= minOut;
        } catch {
            return false;
        }
    }

    /// @dev Inventory covers what the vault can pay. The rest is the residual.
    function _split(Intent calldata intent, uint256 price) private view returns (uint256 covered, uint256 residual) {
        if (intent.side == BUY_WHSK) {
            uint256 have = _balance(whsk);
            covered = have >= intent.size ? intent.size : have;
            return (covered, intent.size - covered);
        }
        uint256 fullQuote = MulDiv.mulDiv(intent.size, price, quoteScale);
        if (fullQuote == 0) revert ZeroFill();
        uint256 usdtBal = _balance(usdt);
        if (usdtBal >= fullQuote) return (intent.size, 0);
        covered = MulDiv.mulDiv(usdtBal, quoteScale, price);
        if (covered > intent.size) covered = intent.size;
        return (covered, intent.size - covered);
    }

    function _coveredLegs(uint8 side, uint256 covered, uint256 price)
        private
        view
        returns (address payToken, uint256 payAmount, address takeToken, uint256 takeAmount)
    {
        uint256 quoted = MulDiv.mulDiv(covered, price, quoteScale);
        if (quoted == 0) revert ZeroFill();
        if (side == BUY_WHSK) return (whsk, covered, usdt, quoted);
        return (usdt, quoted, whsk, covered);
    }

    /// @dev The band binds when it is tighter than the configured slippage cap.
    function _capBps() private view returns (uint256) {
        uint256 band = policy.bandBps();
        return slippageBps < band ? slippageBps : band;
    }

    /// @dev Worst USDT-per-WHSK the residual may print. Buys pay up to this. Sells receive down to this.
    function _worst(uint8 side, uint256 mid, uint256 capBps) private view returns (uint256) {
        if (side == BUY_WHSK) return MulDiv.mulDiv(mid, BPS + capBps, BPS);
        uint256 worst = MulDiv.mulDiv(mid, BPS - capBps, BPS);
        if (worst == 0) revert DeskPolicy.Policy(policy.INVALID_PRICE());
        return worst;
    }

    /// @dev The taker must have approved this contract for the residual token. Unused input is returned.
    function _route(Intent calldata intent, uint256 residual, uint256 worst) private {
        if (intent.side == BUY_WHSK) {
            uint256 maxIn = MulDiv.mulDiv(residual, worst, quoteScale);
            if (maxIn == 0) revert ZeroFill();
            _pull(usdt, intent.trader, maxIn);
            _approve(usdt, address(router), maxIn);
            router.exactOutputSingle(
                ISwapRouter02.ExactOutputSingleParams({
                    tokenIn: usdt,
                    tokenOut: whsk,
                    fee: fee,
                    recipient: intent.trader,
                    amountOut: residual,
                    amountInMaximum: maxIn,
                    sqrtPriceLimitX96: 0
                })
            );
            _approve(usdt, address(router), 0);
            uint256 left = _balanceOf(usdt, address(this));
            if (left != 0) _push(usdt, intent.trader, left);
            return;
        }
        uint256 minOut = MulDiv.mulDiv(residual, worst, quoteScale);
        if (minOut == 0) revert ZeroFill();
        _pull(whsk, intent.trader, residual);
        _approve(whsk, address(router), residual);
        router.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: whsk,
                tokenOut: usdt,
                fee: fee,
                recipient: intent.trader,
                amountIn: residual,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
        _approve(whsk, address(router), 0);
        uint256 unsold = _balanceOf(whsk, address(this));
        if (unsold != 0) _push(whsk, intent.trader, unsold);
    }

    function _pull(address token, address from, uint256 amount) private {
        uint256 beforeBal = _balanceOf(token, address(this));
        _call(token, abi.encodeWithSelector(IFillToken.transferFrom.selector, from, address(this), amount));
        if (_balanceOf(token, address(this)) - beforeBal != amount) revert DeskVault.TransferFailed();
    }

    function _push(address token, address to, uint256 amount) private {
        uint256 beforeBal = _balanceOf(token, address(this));
        _call(token, abi.encodeWithSelector(IFillToken.transfer.selector, to, amount));
        if (beforeBal - _balanceOf(token, address(this)) != amount) revert DeskVault.TransferFailed();
    }

    function _approve(address token, address spender, uint256 amount) private {
        _call(token, abi.encodeWithSelector(IFillToken.approve.selector, spender, 0));
        if (amount != 0) _call(token, abi.encodeWithSelector(IFillToken.approve.selector, spender, amount));
    }

    function _call(address token, bytes memory data) private {
        (bool ok, bytes memory ret) = token.call(data);
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert DeskVault.TransferFailed();
    }

    function _after(uint8 side, uint256 payAmount, uint256 takeAmount)
        private
        view
        returns (uint256 whskAfter, uint256 usdtAfter)
    {
        whskAfter = _balance(whsk);
        usdtAfter = _balance(usdt);
        if (side == BUY_WHSK) {
            whskAfter -= payAmount;
            usdtAfter += takeAmount;
        } else {
            usdtAfter -= payAmount;
            whskAfter += takeAmount;
        }
    }

    function _fresh() private view returns (uint256 answer) {
        try IFairPrice(address(policy.fair())).latestPrice() returns (uint256 price, uint256) {
            return price;
        } catch (bytes memory err) {
            bytes4 sel = _selector(err);
            if (sel == FairPrice.StalePrice.selector) revert DeskPolicy.Policy(policy.STALE());
            if (sel == FairPrice.InvalidPrice.selector) revert DeskPolicy.Policy(policy.INVALID_PRICE());
            _bubble(err);
        }
    }

    function _requireTrader(Intent calldata intent, bytes calldata signature) private view {
        if (intent.trader == address(0) || signature.length != 65) revert DeskPolicy.Policy(policy.BAD_SIGNATURE());
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        if (v != 27 && v != 28) revert DeskPolicy.Policy(policy.BAD_SIGNATURE());
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            revert DeskPolicy.Policy(policy.BAD_SIGNATURE());
        }
        address signer = ecrecover(intentDigest(intent), v, r, s);
        if (signer != intent.trader) revert DeskPolicy.Policy(policy.BAD_SIGNATURE());
    }

    function _hashTypedData(bytes32 structHash) private view returns (bytes32) {
        bytes32 domain = keccak256(abi.encode(EIP712_DOMAIN, NAME_HASH, VERSION_HASH, block.chainid, address(this)));
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _balance(address token) private view returns (uint256) {
        return _balanceOf(token, address(vault));
    }

    function _balanceOf(address token, address account) private view returns (uint256) {
        return IFillToken(token).balanceOf(account);
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
