// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {IndexBasketVault} from "../src/IndexBasketVault.sol";

/// @notice Keeper for IndexBasketVault lazy shares.
///         This cannot see live transfers of a Flap tax token. It only refreshes
///         `syncShare` / optionally `distributeTo` for addresses you supply.
///
/// Usage:
///   1. Export holders (BscScan token holders CSV → JSON array under "holders").
///   2. Copy script/holders.example.json and fill real addresses.
///   3. PRIVATE_KEY and VAULT in env (never commit .env).
///
///   DO_SYNC=true DO_DISTRIBUTE=false DO_PROCESS=true \
///     forge script script/SyncHolders.s.sol:SyncHolders --rpc-url $RPC --broadcast
///
/// Split files larger than IndexBasketVault.MAX_DISTRIBUTE_BATCH() (100).
contract SyncHolders is Script {
    using stdJson for string;

    function run() external {
        IndexBasketVault vault = IndexBasketVault(payable(vm.envAddress("VAULT")));
        uint256 pk = vm.envUint("PRIVATE_KEY");
        string memory path = vm.envOr("HOLDERS_FILE", string("script/holders.example.json"));
        bool doSync = vm.envOr("DO_SYNC", true);
        bool doDistribute = vm.envOr("DO_DISTRIBUTE", false);
        bool doProcess = vm.envOr("DO_PROCESS", false);

        string memory json = vm.readFile(path);
        address[] memory holders = json.readAddressArray(".holders");
        require(holders.length > 0, "no holders in file");
        require(holders.length <= vault.MAX_DISTRIBUTE_BATCH(), "too many holders; split the JSON");

        vm.startBroadcast(pk);

        if (doProcess) {
            try vault.processPendingRevenue() {
                console2.log("processPendingRevenue ok");
            } catch {
                console2.log("processPendingRevenue skipped (nothing pending or no eligible supply)");
            }
        }

        if (doSync) {
            for (uint256 i; i < holders.length; ++i) {
                vault.syncShare(holders[i]);
            }
            console2.log("synced", holders.length);
        }

        if (doDistribute) {
            vault.distributeTo(holders);
            console2.log("distributeTo", holders.length);
        }

        vm.stopBroadcast();
    }
}
