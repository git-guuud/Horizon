// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MarketPin} from "../src/market/MarketPin.sol";

/// @notice Reads the WHSK/USDT market on a HashKey mainnet fork and writes `addresses.json`.
contract PinMarket is Script {
    function run() external returns (string memory json) {
        MarketPin pin = new MarketPin();
        MarketPin.Snapshot memory snap = pin.read();
        json = pin.toJson(snap);
        console2.log(json);
        vm.writeFile("addresses.json", json);
    }
}
