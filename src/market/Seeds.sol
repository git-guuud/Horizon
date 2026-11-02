// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Seeds
/// @notice Entry points the pin script calls. Every recorded value is read back
///         from chain. `addresses.json` is written by the script and is not an input.
library Seeds {
    /// @dev Official WHSK. https://docs.hskchain.net/docs/Build-on-HashKey-Chain/Token-Contracts
    address internal constant WHSK = 0xB210D2120d57b758EE163cFfb43e73728c471Cf1;
    /// @dev Official USDT (OptimismMintableERC20) on HashKey mainnet.
    address internal constant USDT = 0xF1B50eD67A9e2CC94Ad3c477779E2d4cBfFf9029;

    /// @dev HSKSwap (app.hskswap.com) HashKey mainnet v3 core factory.
    ///      Not the HyperInDex factory below.
    address internal constant HSKSWAP_FACTORY = 0x972cA9D1662F5e029cD18327D29026532E84c742;
    /// @dev HSKSwap SwapRouter02. `positionManager()` links it to the position manager.
    address internal constant HSKSWAP_SWAP_ROUTER_02 = 0x2c16f75b95Cf1390c328aB70e2CEE7f4b80bD8F3;
    /// @dev HSKSwap NonfungiblePositionManager.
    address internal constant HSKSWAP_POSITION_MANAGER = 0xDF0A9b833Db0E4CeEa103A4408f3B68e7FC0cad5;
    /// @dev HSKSwap QuoterV2.
    address internal constant HSKSWAP_QUOTER_V2 = 0x603f70466fDdbE3F238220B9a74FFF419a2BbFDD;

    /// @dev APRO HSK/USD on HashKey mainnet.
    address internal constant APRO_HSK_USD = 0x86CE42c1b714149Dc3A7b17169EF67b5F78A224b;
    /// @dev APRO USDT/USD on HashKey mainnet.
    address internal constant APRO_USDT_USD = 0x823d7f90f7A3498DB6595886b6B5dC95E6B0B7f3;

    /// @dev HyperInDex v3 factory. Used only to prove the pinned factory is a different contract.
    address internal constant HYPERINDEX_V3_FACTORY = 0x7858546Cda514455514f248C90670994964795C3;

    uint256 internal constant CHAIN_ID = 177;
}
