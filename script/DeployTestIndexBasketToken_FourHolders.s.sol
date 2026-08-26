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
/// @notice Same idea but with FOUR real holders at distinct proportions
///         (40% / 30% / 20% / 10%), to verify the vault correctly splits
///         dividends proportionally across more than two different amounts,
///         not just an even 50/50 split.
contract DeployTestIndexBasketTokenFourHolders is Script {
    address internal constant VAULT_PORTAL_TESTNET = 0x027e3704fC5C16522e9393d04C60A3ac5c0d775f;
    address internal constant PORTAL_TESTNET = 0x5bEacaF7ABCbB3aB280e80D007FD31fcE26510e9;
    address internal constant TAX_TOKEN_V3_IMPL_TESTNET = 0xE6Ff967a887084c16D0fD71548CF709542cc1557;

    address internal constant VAULT_FACTORY = 0xaaE5bd958BEa8e086B6a63B67966314EF54EeaBA;

    address internal constant CAKE_TESTNET = 0xFa60D973F7642B748046464e165A65B7323b0DEE;
    address internal constant BUSD_TESTNET = 0xeD24FC36d5Ee211Ea25A80239Fb8C4Cfd80f12Ee;

    // 40% stays with me (deployer). Remaining three holders below.
    address internal constant HOLDER2 = 0x2C5c2b63908fba13C615531062Af93E24b265209; // 30%
    address internal constant HOLDER3 = 0x9BB0DBE25d0151A4a3818c8F262a3C6acf3A064f; // 20%
    address internal constant HOLDER4 = 0x9bE49746f1b7FaB36BA89717971D1C9EEBAF699a; // 10%

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

        address vaultAddr = _findVaultAddress(token);
        console2.log("Vault address:", vaultAddr);

        _splitAndSync(token, vaultAddr, me);
        _setBasketAndDispatch(token, vaultAddr);
        _logPending(vaultAddr, me);
        _distribute(vaultAddr, me);
        _logFinal(me);

        vm.stopBroadcast();
    }

    function _launchToken(uint256 buyAmount) internal returns (address token) {
        IVaultPortal vaultPortal = IVaultPortal(VAULT_PORTAL_TESTNET);
        IVaultPortalTypes.NewTokenV6WithVaultParams memory params = _buildParams(buyAmount);
        token = vaultPortal.newTokenV6WithVault{value: buyAmount}(params);
    }

    function _buildParams(uint256 buyAmount) internal view returns (IVaultPortalTypes.NewTokenV6WithVaultParams memory params) {
        params.name = "TestBasket4";
        params.symbol = "TBSK4";
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
        params.vaultFactory = VAULT_FACTORY;
        params.vaultData = abi.encode(msg.sender, uint256(1));
    }

    function _findVaultAddress(address token) internal view returns (address vaultAddr) {
        address taxProcessor = IFlapTaxTokenV3(token).taxProcessor();
        (bool okAddr, bytes memory addrData) = taxProcessor.staticcall(abi.encodeWithSignature("marketAddress()"));
        require(okAddr, "could not read marketAddress");
        vaultAddr = abi.decode(addrData, (address));
    }

    /// @dev 40% stays with `me`, splits 30/20/10 to the other three, then
    ///      syncs all four BEFORE dispatch so the deposit lands proportional.
    function _splitAndSync(address token, address vaultAddr, address me) internal {
        uint256 tenPercent = IERC20(token).balanceOf(me) / 10;

        IERC20(token).transfer(HOLDER2, tenPercent * 3);
        IERC20(token).transfer(HOLDER3, tenPercent * 2);
        IERC20(token).transfer(HOLDER4, tenPercent * 1);

        IndexBasketVault vault = IndexBasketVault(payable(vaultAddr));
        vault.syncShare(me);
        vault.syncShare(HOLDER2);
        vault.syncShare(HOLDER3);
        vault.syncShare(HOLDER4);
        console2.log("Split 40/30/20/10 and synced all four holders.");
    }

    function _setBasketAndDispatch(address token, address vaultAddr) internal {
        IndexBasketVault vault = IndexBasketVault(payable(vaultAddr));

        address[] memory tokens = new address[](2);
        tokens[0] = CAKE_TESTNET;
        tokens[1] = BUSD_TESTNET;
        uint16[] memory weights = new uint16[](2);
        weights[0] = 6000;
        weights[1] = 4000;

        vault.updateBasket(tokens, weights);
        console2.log("Basket set.");

        address taxProcessor = IFlapTaxTokenV3(token).taxProcessor();
        (bool okDispatch,) = taxProcessor.call(abi.encodeWithSignature("dispatch()"));
        console2.log("Dispatch succeeded:", okDispatch);
    }

    function _logPending(address vaultAddr, address me) internal {
        IndexBasketVault vault = IndexBasketVault(payable(vaultAddr));
        if (address(vaultAddr).balance > 0 && vault.totalEligibleSupply() > 0) {
            vault.processPendingRevenue();
        }
        console2.log("Pending CAKE - me (40%):", vault.withdrawableDividendOf(me, CAKE_TESTNET));
        console2.log("Pending CAKE - H2 (30%):", vault.withdrawableDividendOf(HOLDER2, CAKE_TESTNET));
        console2.log("Pending CAKE - H3 (20%):", vault.withdrawableDividendOf(HOLDER3, CAKE_TESTNET));
        console2.log("Pending CAKE - H4 (10%):", vault.withdrawableDividendOf(HOLDER4, CAKE_TESTNET));
    }

    function _distribute(address vaultAddr, address me) internal {
        IndexBasketVault vault = IndexBasketVault(payable(vaultAddr));
        address[] memory batch = new address[](4);
        batch[0] = me;
        batch[1] = HOLDER2;
        batch[2] = HOLDER3;
        batch[3] = HOLDER4;
        vault.distributeTo(batch);
        console2.log("distributeTo() called for all four holders.");
    }

    function _logFinal(address me) internal view {
        console2.log("Final CAKE - me:", IERC20(CAKE_TESTNET).balanceOf(me));
        console2.log("Final CAKE - H2:", IERC20(CAKE_TESTNET).balanceOf(HOLDER2));
        console2.log("Final CAKE - H3:", IERC20(CAKE_TESTNET).balanceOf(HOLDER3));
        console2.log("Final CAKE - H4:", IERC20(CAKE_TESTNET).balanceOf(HOLDER4));
    }
}
