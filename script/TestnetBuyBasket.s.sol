// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IndexBasketVault} from "../src/IndexBasketVault.sol";

/// @notice Testnet-only: fund the live vault above the 0.03 BNB/slot floor and buy the basket.
///         VAULT must be set to the vault created by DeployTestIndexBasketToken.
contract TestnetBuyBasket is Script {
    address internal constant CAKE_TESTNET = 0xFa60D973F7642B748046464e165A65B7323b0DEE;
    address internal constant BUSD_TESTNET = 0xeD24FC36d5Ee211Ea25A80239Fb8C4Cfd80f12Ee;

    function run() external {
        address vaultAddr = vm.envAddress("VAULT");
        IndexBasketVault vault = IndexBasketVault(payable(vaultAddr));
        address me = msg.sender;

        vm.startBroadcast();

        (bool ok,) = payable(vaultAddr).call{value: 0.1 ether}("");
        require(ok, "send to vault failed");
        console2.log("Vault BNB after send:", address(vault).balance);

        vault.syncShare(me);
        vault.processPendingRevenue();

        uint256 cake = vault.withdrawableDividendOf(me, CAKE_TESTNET);
        uint256 busd = vault.withdrawableDividendOf(me, BUSD_TESTNET);
        console2.log("Pending CAKE:", cake);
        console2.log("Pending BUSD:", busd);

        if (cake > 0 || busd > 0) {
            vault.claimAll();
            console2.log("Claimed. CAKE wallet:", IERC20(CAKE_TESTNET).balanceOf(me));
            console2.log("Claimed. BUSD wallet:", IERC20(BUSD_TESTNET).balanceOf(me));
        } else {
            console2.log("Still nothing to claim - swap likely skipped (liquidity/slippage).");
        }

        vm.stopBroadcast();
    }
}
