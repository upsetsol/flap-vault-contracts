// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";
import {IndexBasketVaultFactory} from "../src/IndexBasketVault.sol";

/// @notice Deploys IndexBasketVaultFactory. Must compile with via-IR:
///         FOUNDRY_VIA_IR=true FOUNDRY_OPTIMIZER_RUNS=1
///
/// Testnet: PANCAKE_ROUTER=0x9Ac64Cc6e4415144C455BD8E4837Fea55603e5c3
/// Mainnet: PANCAKE_ROUTER=0x10ED43C718714eb63d5aA57B78B54704E256024E
contract DeployIndexBasketVaultFactory is Script {
    function run() external {
        address router = vm.envAddress("PANCAKE_ROUTER");
        vm.startBroadcast();
        IndexBasketVaultFactory factory = new IndexBasketVaultFactory(router);
        console2.log("IndexBasketVaultFactory:", address(factory));
        console2.log("router:", router);
        console2.log("spec:", factory.factorySpecVersion());
        vm.stopBroadcast();
    }
}
