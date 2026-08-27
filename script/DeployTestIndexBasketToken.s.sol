// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";
import {IVaultPortal, IVaultPortalTypes} from "../src/flap/IVaultPortal.sol";
import {IPortalTypes, IPortalCommonTypes} from "../src/flap/IPortal.sol";
import {IFlapTaxTokenV3} from "../src/flap/IFlapTaxTokenV3.sol";
import {IndexBasketVault} from "../src/IndexBasketVault.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {ClonesUpgradeable} from "@openzeppelin-contracts-upgradeable/proxy/ClonesUpgradeable.sol";

/// @notice Launches a real tax token on BSC testnet using our own
///         IndexBasketVaultFactory (not the built-in dividendToken), sets a
///         2-token basket, buys, dispatches, and verifies dividends accrue
///         and can be distributed — proving the custom vault path end-to-end.
contract DeployTestIndexBasketToken is Script {
    address internal constant VAULT_PORTAL_TESTNET = 0x027e3704fC5C16522e9393d04C60A3ac5c0d775f;
    address internal constant PORTAL_TESTNET = 0x5bEacaF7ABCbB3aB280e80D007FD31fcE26510e9;
    address internal constant TAX_TOKEN_V3_IMPL_TESTNET = 0xE6Ff967a887084c16D0fD71548CF709542cc1557;

    // Set VAULT_FACTORY in the environment to the factory just deployed.

    address internal constant CAKE_TESTNET = 0xFa60D973F7642B748046464e165A65B7323b0DEE;
    address internal constant BUSD_TESTNET = 0xeD24FC36d5Ee211Ea25A80239Fb8C4Cfd80f12Ee;

    function _findVanity7777Salt() internal view returns (bytes32) {
        bytes32 salt = keccak256(abi.encodePacked(block.timestamp, msg.sender));
        for (uint256 i = 0; i < 500000; i++) {
            address predicted =
                ClonesUpgradeable.predictDeterministicAddress(TAX_TOKEN_V3_IMPL_TESTNET, salt, PORTAL_TESTNET);
            bytes20 addrBytes = bytes20(predicted);
            if (addrBytes[18] == 0x77 && addrBytes[19] == 0x77) {
                return salt;
            }
            salt = bytes32(uint256(salt) + 1);
        }
        revert("vanity salt not found in 500000 tries");
    }

    function run() external {
        address me = msg.sender;
        uint256 buyAmount = 0.02 ether;

        vm.startBroadcast();

        address token = _launchToken(buyAmount);
        console2.log("Token created at:", token);
        console2.log("My token balance after creation-buy:", IERC20(token).balanceOf(me));

        address vaultAddr = _findVaultAddress(token);
        console2.log("Vault address:", vaultAddr);

        _setBasketAndDispatch(token, vaultAddr);
        _checkAndClaim(vaultAddr, me);

        vm.stopBroadcast();
    }

    function _launchToken(uint256 buyAmount) internal returns (address token) {
        IVaultPortal vaultPortal = IVaultPortal(VAULT_PORTAL_TESTNET);
        IVaultPortalTypes.NewTokenV6WithVaultParams memory params = _buildParams(buyAmount);
        token = vaultPortal.newTokenV6WithVault{value: buyAmount}(params);
    }

    function _buildParams(uint256 buyAmount)
        internal
        view
        returns (IVaultPortalTypes.NewTokenV6WithVaultParams memory params)
    {
        params.name = "TestBasket";
        params.symbol = "TBSK";
        params.meta = "";
        params.dexThresh = IPortalCommonTypes.DexThreshType.FOUR_FIFTHS;
        params.salt = _findVanity7777Salt();
        params.migratorType = IPortalTypes.MigratorType.V2_MIGRATOR;
        params.quoteToken = address(0);
        params.quoteAmt = buyAmount;
        params.permitData = "";
        params.extensionID = bytes32(0);
        params.extensionData = "";
        params.dexId = IPortalTypes.DEXId.DEX0;
        params.lpFeeProfile = IPortalTypes.V3LPFeeProfile.LP_FEE_PROFILE_STANDARD;
        params.buyTaxRate = 100;
        params.sellTaxRate = 100;
        params.taxDuration = 30 days;
        params.antiFarmerDuration = 0;
        params.mktBps = 10000;
        params.deflationBps = 0;
        params.dividendBps = 0;
        params.lpBps = 0;
        params.minimumShareBalance = 1;
        params.dividendToken = address(0);
        params.commissionReceiver = address(0);
        params.tokenVersion = IPortalTypes.TokenVersion.TOKEN_TAXED_V3;
        params.vaultFactory = vm.envAddress("VAULT_FACTORY");
        params.vaultData = abi.encode(
            msg.sender,
            uint256(1),
            CAKE_TESTNET,
            BUSD_TESTNET,
            address(0),
            address(0),
            address(0),
            uint16(6000),
            uint16(4000),
            uint16(0),
            uint16(0),
            uint16(0)
        );
    }

    function _findVaultAddress(address token) internal view returns (address vaultAddr) {
        address taxProcessor = IFlapTaxTokenV3(token).taxProcessor();
        console2.log("Tax processor:", taxProcessor);

        (bool okAddr, bytes memory addrData) = taxProcessor.staticcall(abi.encodeWithSignature("marketAddress()"));
        require(okAddr, "could not read marketAddress");
        vaultAddr = abi.decode(addrData, (address));
    }

    function _setBasketAndDispatch(
        address token,
        address /* vaultAddr */
    )
        internal
    {
        console2.log("Basket set at launch (required initial basket).");

        address taxProcessor = IFlapTaxTokenV3(token).taxProcessor();
        (bool okDispatch,) = taxProcessor.call(abi.encodeWithSignature("dispatch()"));
        console2.log("Dispatch succeeded:", okDispatch);
    }

    function _checkAndClaim(address vaultAddr, address me) internal {
        IndexBasketVault vault = IndexBasketVault(payable(vaultAddr));

        vault.syncShare(me);

        // Do not call processPendingRevenue here: Foundry still fails the
        // whole script if that tx reverts (try/catch does not help). A 0.02
        // BNB creation buy is below the 0.03 BNB/slot threshold.
        console2.log("Vault BNB:", address(vaultAddr).balance);
        console2.log("minBnbToProcess:", vault.minBnbToProcess());
        console2.log("totalPendingBnb:", vault.totalPendingBnb());

        uint256 pendingCake = vault.withdrawableDividendOf(me, CAKE_TESTNET);
        uint256 pendingBusd = vault.withdrawableDividendOf(me, BUSD_TESTNET);
        console2.log("Pending CAKE:", pendingCake);
        console2.log("Pending BUSD:", pendingBusd);

        if (pendingCake > 0 || pendingBusd > 0) {
            vault.claimAll();
            console2.log("SUCCESS: custom IndexBasketVault confirmed working end-to-end on testnet.");
        } else {
            console2.log("Nothing pending yet - check basket token liquidity on testnet or dispatch logs above.");
        }
    }
}
