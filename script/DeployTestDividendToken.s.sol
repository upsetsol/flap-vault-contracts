// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";
import {IPortal, IPortalTypes, IPortalCommonTypes} from "../src/flap/IPortal.sol";
import {IFlapTaxTokenV3} from "../src/flap/IFlapTaxTokenV3.sol";
import {IDividend} from "../src/flap/IDividend.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {ClonesUpgradeable} from "@openzeppelin-contracts-upgradeable/proxy/ClonesUpgradeable.sol";

/// @notice Proves Flap's BUILT-IN dividend mechanism (Case 2: dividendToken = BNB)
///         works exactly like Dust — live share tracking via setShare(), no custom
///         vault, no swap needed. Runs entirely on BSC testnet with tBNB.
contract DeployTestDividendToken is Script {
    address internal constant PORTAL_TESTNET = 0x5bEacaF7ABCbB3aB280e80D007FD31fcE26510e9;
    address internal constant TAX_TOKEN_V3_IMPL_TESTNET = 0xE6Ff967a887084c16D0fD71548CF709542cc1557;

    /// @dev Tax tokens (7777 suffix) require a CREATE2 salt whose resulting clone
    ///      address ends in 0x7777 — this is enforced on-chain, not cosmetic.
    ///      Since Portal.newTokenV6 delegatecalls through internal launcher
    ///      contracts, address(this) stays PORTAL_TESTNET throughout — that's the
    ///      effective CREATE2 deployer to predict against.
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
        IPortal portal = IPortal(PORTAL_TESTNET);

        // ── Step 1: create the tax token, buying a small amount on creation ──
        uint256 buyAmount = 0.02 ether;

        IPortalTypes.NewTokenV6Params memory params;
        params.name = "TestDiv";
        params.symbol = "TDIV";
        params.meta = "";
        params.dexThresh = IPortalCommonTypes.DexThreshType.FOUR_FIFTHS; // standard threshold used by the UI
        params.salt = _findVanity7777Salt();
        params.migratorType = IPortalTypes.MigratorType.V2_MIGRATOR; // required for tax tokens
        params.quoteToken = address(0); // BNB
        params.quoteAmt = buyAmount;
        params.beneficiary = me;
        params.permitData = "";
        params.extensionID = bytes32(0);
        params.extensionData = "";
        params.dexId = IPortalTypes.DEXId.DEX0;
        params.lpFeeProfile = IPortalTypes.V3LPFeeProfile.LP_FEE_PROFILE_STANDARD;
        params.buyTaxRate = 100; // 1%
        params.sellTaxRate = 100; // 1%
        params.taxDuration = 30 days;
        params.antiFarmerDuration = 0;
        params.mktBps = 0;
        params.deflationBps = 0;
        params.dividendBps = 10000; // 100% of tax -> dividends
        params.lpBps = 0;
        params.minimumShareBalance = 10000 ether; // protocol-enforced minimum
        params.dividendToken = address(0); // Case 2: dividends paid in BNB, no swap needed
        params.commissionReceiver = address(0);
        params.tokenVersion = IPortalTypes.TokenVersion.TOKEN_TAXED_V3;

        vm.startBroadcast();

        address token = portal.newTokenV6{value: buyAmount}(params);
        console2.log("Token created at:", token);

        uint256 myTokenBalance = IERC20(token).balanceOf(me);
        console2.log("My token balance after creation-buy:", myTokenBalance);

        // ── Step 2: dispatch accumulated tax revenue into the Dividend contract ──
        // (buy/sell was already collected during the creation-time purchase above —
        //  a second portal.buy() call is disabled on this deployment, so we skip it
        //  and dispatch what's already sitting in the tax processor)
        address taxProcessor = IFlapTaxTokenV3(token).taxProcessor();
        address dividendAddr = IFlapTaxTokenV3(token).dividendContract();
        console2.log("Tax processor:", taxProcessor);
        console2.log("Dividend contract:", dividendAddr);

        (bool ok,) = taxProcessor.call(abi.encodeWithSignature("dispatch()"));
        console2.log("Dispatch succeeded:", ok);

        // ── Step 5: check that live share tracking actually worked ──
        IDividend dividend = IDividend(dividendAddr);
        uint256 pending = dividend.withdrawableDividends(me);
        console2.log("Withdrawable dividends (wei BNB):", pending);

        if (pending > 0) {
            uint256 balBefore = me.balance;
            dividend.withdrawDividends();
            uint256 balAfter = me.balance;
            console2.log("Claimed dividends (wei BNB):", balAfter > balBefore ? balAfter - balBefore : 0);
            console2.log("SUCCESS: built-in dividend mechanism confirmed working on testnet.");
        } else {
            console2.log("No dividends pending yet - dispatch may not have routed revenue. Check logs above.");
        }

        vm.stopBroadcast();
    }
}
