// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title MockERC20
/// @notice MOCK. Test ERC20 with optional missing or false return data, and an optional fee.
///         Not WHSK or USDT.
contract MockERC20 {
    string public symbol;
    uint8 public decimals;
    bool public returnsBool = true;
    bool public returnsFalse;
    uint256 public fee;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory symbol_, uint8 decimals_) {
        symbol = symbol_;
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function setReturnsBool(bool value) external {
        returnsBool = value;
    }

    function setReturnsFalse(bool value) external {
        returnsFalse = value;
    }

    function setFee(uint256 value) external {
        fee = value;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return _done();
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return _done();
    }

    function _move(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        uint256 cut = fee;
        if (cut > amount) cut = amount;
        balanceOf[to] += amount - cut;
    }

    function _done() internal view returns (bool) {
        if (!returnsBool) {
            assembly {
                return(0, 0)
            }
        }
        return !returnsFalse;
    }
}
