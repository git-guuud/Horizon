// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FairPrice} from "../price/FairPrice.sol";
import {IFairPrice} from "../price/IFairPrice.sol";

/// @title DeskPolicy
/// @notice Bounds a quote and a fill share. No HSKSwap calls.
///         The operator may only make a limit stricter: a wider spread, a lower inventory cap,
///         a narrower band, or a lower fill cap.
///         Loosening the spread floor, raising an inventory cap, widening the band, or raising the fill cap
///         needs the owner's EIP-712 signature.
///         Anyone may halt on a stale fair price. The halt stays until the owner resumes.
contract DeskPolicy {
    uint256 internal constant BPS = 10_000;
    bytes32 internal constant EIP712_DOMAIN =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant TIGHTEN_SPREAD_TYPEHASH =
        keccak256("TightenSpread(uint256 newFloor,uint256 nonce,uint256 deadline)");
    bytes32 internal constant RAISE_CAP_TYPEHASH =
        keccak256("RaiseCap(address token,uint256 newCap,uint256 nonce,uint256 deadline)");
    bytes32 internal constant WIDEN_BAND_TYPEHASH =
        keccak256("WidenBand(uint256 newBand,uint256 nonce,uint256 deadline)");
    bytes32 internal constant TIGHTEN_WIDTH_TYPEHASH =
        keccak256("TightenWidth(uint256 newWidth,uint256 nonce,uint256 deadline)");
    bytes32 internal constant RAISE_FILL_CAP_TYPEHASH =
        keccak256("RaiseFillCap(uint256 newCap,uint256 nonce,uint256 deadline)");
    bytes32 internal constant NAME_HASH = keccak256("Desk");
    bytes32 internal constant VERSION_HASH = keccak256("1");

    /// @dev keccak256 of the label. A second machine can recompute the code from the name alone.
    bytes32 public constant OUTSIDE_BAND = keccak256("OUTSIDE_BAND");
    bytes32 public constant BELOW_SPREAD = keccak256("BELOW_SPREAD");
    bytes32 public constant INVENTORY_CAP = keccak256("INVENTORY_CAP");
    bytes32 public constant STALE = keccak256("STALE");
    bytes32 public constant INVALID_PRICE = keccak256("INVALID_PRICE");
    bytes32 public constant HALTED = keccak256("HALTED");
    bytes32 public constant NOT_STALE = keccak256("NOT_STALE");
    bytes32 public constant ALREADY_HALTED = keccak256("ALREADY_HALTED");
    bytes32 public constant NOT_HALTED = keccak256("NOT_HALTED");
    bytes32 public constant NOT_OWNER = keccak256("NOT_OWNER");
    bytes32 public constant NOT_OPERATOR = keccak256("NOT_OPERATOR");
    bytes32 public constant BAD_SIGNATURE = keccak256("BAD_SIGNATURE");
    bytes32 public constant BAD_NONCE = keccak256("BAD_NONCE");
    bytes32 public constant EXPIRED = keccak256("EXPIRED");
    bytes32 public constant NOT_WIDER = keccak256("NOT_WIDER");
    bytes32 public constant NOT_TIGHTER = keccak256("NOT_TIGHTER");
    bytes32 public constant NOT_LOWER = keccak256("NOT_LOWER");
    bytes32 public constant NOT_HIGHER = keccak256("NOT_HIGHER");
    bytes32 public constant NOT_INVENTORY = keccak256("NOT_INVENTORY");
    bytes32 public constant ZERO_ADDRESS = keccak256("ZERO_ADDRESS");
    bytes32 public constant BAD_BAND = keccak256("BAD_BAND");
    bytes32 public constant FILL_CAP = keccak256("FILL_CAP");
    bytes32 public constant POOL_CAN_FILL = keccak256("POOL_CAN_FILL");

    address public owner;
    address public operator;
    IFairPrice public immutable fair;
    address public immutable whsk;
    address public immutable usdt;

    /// @notice A price may sit this many bps either side of the fair price.
    uint256 public bandBps;
    uint256 public spreadFloor;
    mapping(address token => uint256 cap) public inventoryCap;
    /// @notice Largest USDT leg, in raw units, a fill may take.
    uint256 public fillCap;
    bool public halted;
    uint256 public nonce;
    /// @notice DeskQuote. Only that contract may consume a tighten-width signature.
    address public quote;

    error Policy(bytes32 reason);

    event SpreadFloorUpdated(uint256 floor);
    event InventoryCapUpdated(address indexed token, uint256 cap);
    event FillCapUpdated(uint256 cap);
    event BandUpdated(uint256 bandBps);
    event Halted(address indexed by);
    event Resumed(address indexed by);
    event OperatorUpdated(address indexed operator);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event QuoteSet(address indexed quote);

    constructor(
        address owner_,
        address operator_,
        address fair_,
        address whsk_,
        address usdt_,
        uint256 bandBps_,
        uint256 spreadFloor_,
        uint256 whskCap_,
        uint256 usdtCap_,
        uint256 fillCap_
    ) {
        if (
            owner_ == address(0) || operator_ == address(0) || fair_ == address(0) || whsk_ == address(0)
                || usdt_ == address(0)
        ) {
            revert Policy(ZERO_ADDRESS);
        }
        if (whsk_ == usdt_) revert Policy(NOT_INVENTORY);
        if (fair_.code.length == 0) revert Policy(INVALID_PRICE);
        if (bandBps_ >= BPS) revert Policy(BAD_BAND);

        owner = owner_;
        operator = operator_;
        fair = IFairPrice(fair_);
        whsk = whsk_;
        usdt = usdt_;
        bandBps = bandBps_;
        spreadFloor = spreadFloor_;
        inventoryCap[whsk_] = whskCap_;
        inventoryCap[usdt_] = usdtCap_;
        fillCap = fillCap_;

        emit OwnershipTransferred(address(0), owner_);
        emit OperatorUpdated(operator_);
        emit BandUpdated(bandBps_);
        emit SpreadFloorUpdated(spreadFloor_);
        emit InventoryCapUpdated(whsk_, whskCap_);
        emit InventoryCapUpdated(usdt_, usdtCap_);
        emit FillCapUpdated(fillCap_);
    }

    /// @notice Shared gate for a quote and a fill.
    /// @param price USDT per 1 WHSK at the fair-price decimals. Must sit inside the band around a fresh fair price.
    /// @param spreadBps Quoted spread. Must be at least the floor.
    /// @param token WHSK or USDT.
    /// @param inventory Balance of `token` the action would leave. The caller passes the vault balance. This function does not read tokens.
    function requireBound(uint256 price, uint256 spreadBps, address token, uint256 inventory) external view {
        if (halted) revert Policy(HALTED);
        uint256 fairPrice = _freshPrice();
        (uint256 low, uint256 high) = _band(fairPrice);
        if (price < low || price > high) revert Policy(OUTSIDE_BAND);
        if (spreadBps < spreadFloor) revert Policy(BELOW_SPREAD);
        _checkInventory(token);
        if (inventory > inventoryCap[token]) revert Policy(INVENTORY_CAP);
    }

    /// @notice The owner sets the floor, including a tighter one.
    function setSpreadFloor(uint256 newFloor) external onlyOwner {
        spreadFloor = newFloor;
        emit SpreadFloorUpdated(newFloor);
    }

    /// @notice The operator may only raise the floor.
    function widenSpreadFloor(uint256 newFloor) external onlyOperator {
        if (newFloor <= spreadFloor) revert Policy(NOT_WIDER);
        spreadFloor = newFloor;
        emit SpreadFloorUpdated(newFloor);
    }

    /// @notice Lower the floor. The owner must have signed this exact floor, nonce, and deadline.
    function tightenSpreadFloor(uint256 newFloor, uint256 deadline, bytes calldata signature) external {
        if (newFloor >= spreadFloor) revert Policy(NOT_TIGHTER);
        _consume(tightenSpreadDigest(newFloor, nonce, deadline), deadline, signature);
        spreadFloor = newFloor;
        emit SpreadFloorUpdated(newFloor);
    }

    /// @notice The owner sets either inventory cap, including a higher one.
    function setInventoryCap(address token, uint256 newCap) external onlyOwner {
        _checkInventory(token);
        inventoryCap[token] = newCap;
        emit InventoryCapUpdated(token, newCap);
    }

    /// @notice The operator may only lower a cap.
    function lowerInventoryCap(address token, uint256 newCap) external onlyOperator {
        _checkInventory(token);
        if (newCap >= inventoryCap[token]) revert Policy(NOT_LOWER);
        inventoryCap[token] = newCap;
        emit InventoryCapUpdated(token, newCap);
    }

    /// @notice Raise a cap. The owner must have signed this exact token, cap, nonce, and deadline.
    function raiseInventoryCap(address token, uint256 newCap, uint256 deadline, bytes calldata signature) external {
        _checkInventory(token);
        if (newCap <= inventoryCap[token]) revert Policy(NOT_HIGHER);
        _consume(raiseCapDigest(token, newCap, nonce, deadline), deadline, signature);
        inventoryCap[token] = newCap;
        emit InventoryCapUpdated(token, newCap);
    }

    /// @notice The owner sets the fill cap, including a higher one.
    function setFillCap(uint256 newCap) external onlyOwner {
        fillCap = newCap;
        emit FillCapUpdated(newCap);
    }

    /// @notice The operator may only lower the fill cap.
    function lowerFillCap(uint256 newCap) external onlyOperator {
        if (newCap >= fillCap) revert Policy(NOT_LOWER);
        fillCap = newCap;
        emit FillCapUpdated(newCap);
    }

    /// @notice Raise the fill cap. The owner must have signed this exact cap, nonce, and deadline.
    function raiseFillCap(uint256 newCap, uint256 deadline, bytes calldata signature) external {
        if (newCap <= fillCap) revert Policy(NOT_HIGHER);
        _consume(raiseFillCapDigest(newCap, nonce, deadline), deadline, signature);
        fillCap = newCap;
        emit FillCapUpdated(newCap);
    }

    function setBand(uint256 bandBps_) external onlyOwner {
        if (bandBps_ >= BPS) revert Policy(BAD_BAND);
        bandBps = bandBps_;
        emit BandUpdated(bandBps_);
    }

    /// @notice The operator may only narrow the band. A narrower band pulls sooner.
    function narrowBand(uint256 newBand) external onlyOperator {
        if (newBand >= bandBps) revert Policy(NOT_LOWER);
        bandBps = newBand;
        emit BandUpdated(newBand);
    }

    /// @notice Widen the band. The owner must have signed this exact band, nonce, and deadline.
    function widenBand(uint256 newBand, uint256 deadline, bytes calldata signature) external {
        if (newBand <= bandBps) revert Policy(NOT_HIGHER);
        if (newBand >= BPS) revert Policy(BAD_BAND);
        _consume(widenBandDigest(newBand, nonce, deadline), deadline, signature);
        bandBps = newBand;
        emit BandUpdated(newBand);
    }

    /// @notice Anyone may halt, and only when the fair price is stale. A fresh feed reverts.
    function halt() external {
        if (halted) revert Policy(ALREADY_HALTED);
        try fair.latestPrice() returns (uint256, uint256) {
            revert Policy(NOT_STALE);
        } catch (bytes memory err) {
            bytes4 sel = _selector(err);
            if (sel == FairPrice.InvalidPrice.selector) revert Policy(INVALID_PRICE);
            if (sel != FairPrice.StalePrice.selector) _bubble(err);
        }
        halted = true;
        emit Halted(msg.sender);
    }

    /// @notice The halt stays until the owner resumes, including after the feed is fresh again.
    function resume() external onlyOwner {
        if (!halted) revert Policy(NOT_HALTED);
        halted = false;
        emit Resumed(msg.sender);
    }

    function setOperator(address operator_) external onlyOwner {
        if (operator_ == address(0)) revert Policy(ZERO_ADDRESS);
        operator = operator_;
        emit OperatorUpdated(operator_);
    }

    function transferOwnership(address owner_) external onlyOwner {
        if (owner_ == address(0)) revert Policy(ZERO_ADDRESS);
        emit OwnershipTransferred(owner, owner_);
        owner = owner_;
    }

    /// @notice The owner names the quote contract that may consume a posted-width signature.
    function setQuote(address quote_) external onlyOwner {
        if (quote_ == address(0)) revert Policy(ZERO_ADDRESS);
        quote = quote_;
        emit QuoteSet(quote_);
    }

    /// @notice Burn the owner's nonce for a tighter posted width. DeskQuote calls this after its own floor check.
    function consumeTightenWidth(uint256 newWidth, uint256 deadline, bytes calldata signature) external {
        if (msg.sender != quote) revert Policy(NOT_OPERATOR);
        _consume(tightenWidthDigest(newWidth, nonce, deadline), deadline, signature);
    }

    function tightenSpreadDigest(uint256 newFloor, uint256 nonce_, uint256 deadline) public view returns (bytes32) {
        return _hashTypedData(keccak256(abi.encode(TIGHTEN_SPREAD_TYPEHASH, newFloor, nonce_, deadline)));
    }

    function raiseCapDigest(address token, uint256 newCap, uint256 nonce_, uint256 deadline)
        public
        view
        returns (bytes32)
    {
        return _hashTypedData(keccak256(abi.encode(RAISE_CAP_TYPEHASH, token, newCap, nonce_, deadline)));
    }

    function widenBandDigest(uint256 newBand, uint256 nonce_, uint256 deadline) public view returns (bytes32) {
        return _hashTypedData(keccak256(abi.encode(WIDEN_BAND_TYPEHASH, newBand, nonce_, deadline)));
    }

    function tightenWidthDigest(uint256 newWidth, uint256 nonce_, uint256 deadline) public view returns (bytes32) {
        return _hashTypedData(keccak256(abi.encode(TIGHTEN_WIDTH_TYPEHASH, newWidth, nonce_, deadline)));
    }

    function raiseFillCapDigest(uint256 newCap, uint256 nonce_, uint256 deadline) public view returns (bytes32) {
        return _hashTypedData(keccak256(abi.encode(RAISE_FILL_CAP_TYPEHASH, newCap, nonce_, deadline)));
    }

    function _freshPrice() internal view returns (uint256 answer) {
        try fair.latestPrice() returns (uint256 price, uint256) {
            return price;
        } catch (bytes memory err) {
            if (_selector(err) == FairPrice.StalePrice.selector) revert Policy(STALE);
            if (_selector(err) == FairPrice.InvalidPrice.selector) revert Policy(INVALID_PRICE);
            _bubble(err);
        }
    }

    function _band(uint256 fairPrice) internal view returns (uint256 low, uint256 high) {
        low = fairPrice * (BPS - bandBps) / BPS;
        high = fairPrice * (BPS + bandBps) / BPS;
    }

    function _consume(bytes32 digest, uint256 deadline, bytes calldata signature) internal {
        if (block.timestamp > deadline) revert Policy(EXPIRED);
        _requireOwnerSignature(digest, signature);
        nonce += 1;
    }

    function _requireOwnerSignature(bytes32 digest, bytes calldata signature) internal view {
        if (signature.length != 65) revert Policy(BAD_SIGNATURE);
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        if (v != 27 && v != 28) revert Policy(BAD_SIGNATURE);
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            revert Policy(BAD_SIGNATURE);
        }
        address signer = ecrecover(digest, v, r, s);
        if (signer != owner) revert Policy(BAD_SIGNATURE);
    }

    function _hashTypedData(bytes32 structHash) internal view returns (bytes32) {
        bytes32 domain = keccak256(abi.encode(EIP712_DOMAIN, NAME_HASH, VERSION_HASH, block.chainid, address(this)));
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _checkInventory(address token) internal view {
        if (token != whsk && token != usdt) revert Policy(NOT_INVENTORY);
    }

    function _selector(bytes memory err) internal pure returns (bytes4 sel) {
        if (err.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            sel := mload(add(err, 32))
        }
    }

    function _bubble(bytes memory err) internal pure {
        assembly ("memory-safe") {
            revert(add(err, 32), mload(err))
        }
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Policy(NOT_OWNER);
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert Policy(NOT_OPERATOR);
        _;
    }
}
