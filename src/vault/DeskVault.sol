// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IInventoryToken {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title DeskVault
/// @notice Holds WHSK and USDT. The owner deposits and withdraws.
///         The operator cannot withdraw, pause, unpause, replace the operator, change the owner, draw, or settle.
///         The owner may name a quoter. The quoter draws inventory to itself and restores it.
///         That draw is not a withdrawal: the recipient is the quoter, never a chosen address.
///         The owner may name a filler. The filler pays a taker from inventory and pulls the other asset from that taker.
///         That settle is not a withdrawal: both legs are the inventory pair, and the taker is the fill's counterparty.
///         Pause does not freeze a withdrawal. Inventory is the token balance.
contract DeskVault {
    address public owner;
    address public operator;
    address public quoter;
    address public filler;
    address public immutable whsk;
    address public immutable usdt;
    bool public paused;

    error NotOwner();
    error NotQuoter();
    error NotFiller();
    error ZeroAddress();
    error SameToken();
    error NotInventory(address token);
    error ZeroAmount();
    error TransferFailed();
    error PauseUnchanged();

    event Deposited(address indexed from, address indexed token, uint256 amount);
    event Withdrawn(address indexed to, address indexed token, uint256 amount);
    event Drawn(address indexed quoter, address indexed token, uint256 amount);
    event Restored(address indexed quoter, address indexed token, uint256 amount);
    event Settled(
        address indexed filler,
        address indexed taker,
        address payToken,
        uint256 payAmount,
        address takeToken,
        uint256 takeAmount
    );
    event Paused(bool paused);
    event OperatorUpdated(address indexed operator);
    event QuoterUpdated(address indexed quoter);
    event FillerUpdated(address indexed filler);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    constructor(address owner_, address operator_, address whsk_, address usdt_) {
        if (owner_ == address(0) || operator_ == address(0) || whsk_ == address(0) || usdt_ == address(0)) {
            revert ZeroAddress();
        }
        if (whsk_ == usdt_) revert SameToken();
        owner = owner_;
        operator = operator_;
        whsk = whsk_;
        usdt = usdt_;
        emit OwnershipTransferred(address(0), owner_);
        emit OperatorUpdated(operator_);
    }

    /// @notice Pull `amount` of WHSK or USDT from the owner. The vault must receive that exact amount.
    function deposit(address token, uint256 amount) external onlyOwner {
        _checkInventory(token);
        if (amount == 0) revert ZeroAmount();
        _pull(token, msg.sender, amount);
        emit Deposited(msg.sender, token, amount);
    }

    /// @notice Send `amount` of WHSK or USDT to `to`. Allowed while paused. The operator cannot call this.
    function withdraw(address token, uint256 amount, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        _checkInventory(token);
        if (amount == 0) revert ZeroAmount();
        _push(token, to, amount);
        emit Withdrawn(to, token, amount);
    }

    function pause() external onlyOwner {
        if (paused) revert PauseUnchanged();
        paused = true;
        emit Paused(true);
    }

    function unpause() external onlyOwner {
        if (!paused) revert PauseUnchanged();
        paused = false;
        emit Paused(false);
    }

    /// @notice The owner names the contract that may draw inventory out to a position and put it back.
    function setQuoter(address quoter_) external onlyOwner {
        if (quoter_ == address(0)) revert ZeroAddress();
        quoter = quoter_;
        emit QuoterUpdated(quoter_);
    }

    /// @notice Move `amount` of inventory to the quoter. The recipient is the quoter itself.
    function draw(address token, uint256 amount) external {
        if (msg.sender != quoter) revert NotQuoter();
        _checkInventory(token);
        if (amount == 0) revert ZeroAmount();
        _push(token, msg.sender, amount);
        emit Drawn(msg.sender, token, amount);
    }

    /// @notice Pull `amount` back from the quoter. The quoter must have approved the vault.
    function restore(address token, uint256 amount) external {
        if (msg.sender != quoter) revert NotQuoter();
        _checkInventory(token);
        if (amount == 0) revert ZeroAmount();
        _pull(token, msg.sender, amount);
        emit Restored(msg.sender, token, amount);
    }

    /// @notice The owner names the contract that may settle an inventory fill.
    function setFiller(address filler_) external onlyOwner {
        if (filler_ == address(0)) revert ZeroAddress();
        filler = filler_;
        emit FillerUpdated(filler_);
    }

    /// @notice Pay `taker` `payAmount` of inventory and pull `takeAmount` of the other inventory asset from them.
    ///         The taker must have approved this vault. The operator cannot call this.
    function settle(address payToken, uint256 payAmount, address takeToken, uint256 takeAmount, address taker)
        external
    {
        if (msg.sender != filler) revert NotFiller();
        if (taker == address(0)) revert ZeroAddress();
        _checkInventory(payToken);
        _checkInventory(takeToken);
        if (payToken == takeToken) revert SameToken();
        if (payAmount == 0 || takeAmount == 0) revert ZeroAmount();
        _push(payToken, taker, payAmount);
        _pull(takeToken, taker, takeAmount);
        emit Settled(msg.sender, taker, payToken, payAmount, takeToken, takeAmount);
    }

    function setOperator(address operator_) external onlyOwner {
        if (operator_ == address(0)) revert ZeroAddress();
        operator = operator_;
        emit OperatorUpdated(operator_);
    }

    function transferOwnership(address owner_) external onlyOwner {
        if (owner_ == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, owner_);
        owner = owner_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function _checkInventory(address token) internal view {
        if (token != whsk && token != usdt) revert NotInventory(token);
    }

    function _pull(address token, address from, uint256 amount) private {
        uint256 beforeBal = _balance(token);
        _call(token, abi.encodeCall(IInventoryToken.transferFrom, (from, address(this), amount)));
        if (_balance(token) - beforeBal != amount) revert TransferFailed();
    }

    function _push(address token, address to, uint256 amount) private {
        uint256 beforeBal = _balance(token);
        _call(token, abi.encodeCall(IInventoryToken.transfer, (to, amount)));
        if (beforeBal - _balance(token) != amount) revert TransferFailed();
    }

    function _balance(address token) private view returns (uint256) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeCall(IInventoryToken.balanceOf, (address(this))));
        if (!ok || data.length < 32) revert TransferFailed();
        return abi.decode(data, (uint256));
    }

    /// @dev Accepts a bare success and a returned `true`. A returned `false` or a revert fails.
    function _call(address token, bytes memory data) private {
        (bool ok, bytes memory ret) = token.call(data);
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }
}
