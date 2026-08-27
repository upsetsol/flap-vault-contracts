// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {CustomDividendVault, CustomDividendVaultFactory} from "src/CustomDividendVault.sol";

/// @dev Minimal mock ERC20 standing in for a real Flap tax token. We only
///      need balanceOf() to drive the dividend share math — we are not
///      testing the tax token's own transfer/tax logic here, only that our
///      vault correctly reads balances and pays out accordingly. Also
///      exposes a settable mainPool() to test pair-exclusion (BOTH-03).
contract MockTaxToken {
    mapping(address => uint256) public balanceOf;
    address public mainPool;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function setBalance(address who, uint256 amount) external {
        balanceOf[who] = amount;
    }

    function setMainPool(address pool) external {
        mainPool = pool;
    }
}

contract CustomDividendVaultTest is Test {
    // Real BSC mainnet addresses — this test runs on a mainnet fork so these
    // must be live, liquid contracts.
    address internal constant PANCAKE_ROUTER_V2 = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address internal constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;
    address internal constant VAULT_PORTAL_BSC = 0x90497450f2a706f1951b5bdda52B4E5d16f34C06;
    address internal constant GUARDIAN_BSC = 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;

    address internal constant USER1 = address(0xCAFE1);
    address internal constant USER2 = address(0xCAFE2);
    address internal constant ATTACKER = address(0xBAD1);

    CustomDividendVaultFactory internal factory;
    CustomDividendVault internal vault;
    MockTaxToken internal taxToken;

    function setUp() public {
        string memory rpcUrl = vm.envOr("BSC_RPC_URL", string("https://bsc-dataseed.bnbchain.org"));
        vm.createSelectFork(rpcUrl);

        taxToken = new MockTaxToken();
        factory = new CustomDividendVaultFactory(PANCAKE_ROUTER_V2);

        bytes memory vaultData = abi.encode(CAKE, uint256(0)); // dividendToken = CAKE, no minimum balance

        // Only VaultPortal is allowed to call newVault — prank as it.
        vm.prank(VAULT_PORTAL_BSC);
        address vaultAddr = factory.newVault(address(taxToken), address(0), address(this), vaultData);
        vault = CustomDividendVault(payable(vaultAddr));
    }

    /// @dev Funds the vault and immediately processes it — the standard
    ///      two-step flow now that receive() only accumulates (BOTH-01 fix).
    function _fundAndProcess(uint256 amount) internal {
        vm.deal(address(this), amount);
        (bool ok,) = address(vault).call{value: amount}("");
        assertTrue(ok, "receive() should never revert");
        vault.processPendingRevenue();
    }

    // ------------------------------------------------------------------
    // 1. Factory deploys a correctly wired vault
    // ------------------------------------------------------------------
    function test_factoryDeploysWiredVault() public view {
        assertEq(vault.taxToken(), address(taxToken), "taxToken mismatch");
        assertEq(vault.dividendToken(), CAKE, "dividendToken mismatch");
        assertEq(vault.pancakeRouter(), PANCAKE_ROUTER_V2, "router mismatch");
        assertEq(vault.vaultQuoteToken(), address(0), "native-only vault");
    }

    function test_factorySpecVersionIsV23() public view {
        assertEq(factory.factorySpecVersion(), "v2.3", "BOTH-11: factory should advertise v2.3 for V3 vaults");
    }

    function test_factoryRejectsNonVaultPortalCaller() public {
        bytes memory vaultData = abi.encode(CAKE, uint256(0));
        vm.expectRevert(bytes("Only VaultPortal"));
        factory.newVault(address(taxToken), address(0), address(this), vaultData);
    }

    function test_factoryRejectsNonNativeQuoteToken() public {
        bytes memory vaultData = abi.encode(CAKE, uint256(0));
        vm.prank(VAULT_PORTAL_BSC);
        vm.expectRevert(bytes("Only native BNB quote token supported"));
        factory.newVault(address(taxToken), CAKE, address(this), vaultData);
    }

    // ------------------------------------------------------------------
    // 2. receive() accumulates only; processPendingRevenue() does the swap
    // ------------------------------------------------------------------
    function test_receiveOnlyAccumulatesNeverSwaps() public {
        taxToken.mint(USER1, 100 ether);
        vault.syncShare(USER1);

        vm.deal(address(this), 1 ether);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok, "receive() should accept BNB");

        assertEq(vault.pendingBnb(), 1 ether, "receive() must only accumulate into pendingBnb");
        assertEq(IERC20(CAKE).balanceOf(address(vault)), 0, "receive() must never swap (BOTH-01 fix)");
    }

    function test_processPendingRevenueSwapsBnbIntoDividendToken() public {
        taxToken.mint(USER1, 100 ether);
        vault.syncShare(USER1);

        uint256 vaultCakeBefore = IERC20(CAKE).balanceOf(address(vault));
        _fundAndProcess(1 ether);
        uint256 vaultCakeAfter = IERC20(CAKE).balanceOf(address(vault));

        assertGt(vaultCakeAfter, vaultCakeBefore, "vault should have received CAKE from the swap");
        assertEq(vault.pendingBnb(), 0, "pendingBnb should be drained after processing");
    }

    function test_revenueBeforeAnySyncIsParkedNotLost() public {
        // No syncShare called yet — totalEligibleSupply is 0.
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);

        assertEq(vault.pendingBnb(), 1 ether, "should be parked as pendingBnb");
        assertEq(IERC20(CAKE).balanceOf(address(vault)), 0, "must not swap into an orphaned deposit");

        taxToken.mint(USER1, 100 ether);
        vault.syncShare(USER1);

        vault.processPendingRevenue();
        assertEq(vault.pendingBnb(), 0, "parked BNB should now be converted");
        assertGt(vault.withdrawableDividendOf(USER1), 0, "USER1 should now be able to claim the previously-parked funds");
    }

    function test_processPendingRevenueRevertsWithNothingPending() public {
        taxToken.mint(USER1, 100 ether);
        vault.syncShare(USER1);

        vm.expectRevert(bytes("nothing pending"));
        vault.processPendingRevenue();
    }

    // ------------------------------------------------------------------
    // 3. End-to-end: holder syncs, dividend arrives, holder claims
    // ------------------------------------------------------------------
    function test_holderCanClaimAfterDividendDeposit() public {
        taxToken.mint(USER1, 100 ether);
        vault.syncShare(USER1);

        _fundAndProcess(2 ether);

        uint256 pending = vault.withdrawableDividendOf(USER1);
        assertGt(pending, 0, "USER1 should have pending dividends");

        uint256 balBefore = IERC20(CAKE).balanceOf(USER1);
        vm.prank(USER1);
        vault.claim();
        uint256 balAfter = IERC20(CAKE).balanceOf(USER1);

        assertEq(balAfter - balBefore, pending, "claimed amount should match previewed pending amount");
        assertEq(vault.withdrawableDividendOf(USER1), 0, "pending should be zero after claim");
    }

    function test_claimRevertsWithNothingToClaim() public {
        taxToken.mint(USER1, 100 ether);
        vault.syncShare(USER1);

        vm.expectRevert(CustomDividendVault.NothingToClaim.selector);
        vm.prank(USER1);
        vault.claim();
    }

    function test_doubleClaimWithoutNewDepositReverts() public {
        taxToken.mint(USER1, 100 ether);
        vault.syncShare(USER1);

        _fundAndProcess(1 ether);

        vm.prank(USER1);
        vault.claim();

        vm.expectRevert(CustomDividendVault.NothingToClaim.selector);
        vm.prank(USER1);
        vault.claim();
    }

    // ------------------------------------------------------------------
    // 4. Two holders split dividends proportionally to synced balance
    // ------------------------------------------------------------------
    function test_twoHoldersSplitDividendsProportionally() public {
        taxToken.mint(USER1, 300 ether); // 75% share
        taxToken.mint(USER2, 100 ether); // 25% share
        vault.syncShare(USER1);
        vault.syncShare(USER2);

        _fundAndProcess(4 ether);

        uint256 pending1 = vault.withdrawableDividendOf(USER1);
        uint256 pending2 = vault.withdrawableDividendOf(USER2);

        assertApproxEqRel(pending1, pending2 * 3, 0.01e18, "dividend split should be proportional to balance");
    }

    // ------------------------------------------------------------------
    // 5. SECURITY FIX (IBV-01 pattern applied here too): emergency withdraw
    //    is Guardian-only via an explicit address check, not just role-based
    //    (defense-in-depth — CDV never granted a team role in the first
    //    place, so this closes the gap for consistency rather than an
    //    actual live exploit in this specific vault).
    // ------------------------------------------------------------------
    function test_nonGuardianCannotCallEmergencyWithdraw() public {
        vm.expectRevert(CustomDividendVault.GuardianOnly.selector);
        vm.prank(ATTACKER);
        vault.emergencyWithdrawNative(1 ether, ATTACKER);
    }

    function test_guardianCanWithdrawGenuineSurplus() public {
        // Send to a plain address, not the Guardian multisig itself — that's
        // a real contract on the mainnet fork that rejects bare ETH transfers
        // with no calldata. Guardian is the CALLER here (authorization), the
        // recipient can be anyone the Guardian chooses.
        address recipient = address(0xC0FFEE);
        vm.deal(address(vault), 1 ether); // bypasses receive(), so pendingBnb stays 0
        assertEq(vault.pendingBnb(), 0);

        uint256 balBefore = recipient.balance;
        vm.prank(GUARDIAN_BSC);
        vault.emergencyWithdrawNative(1 ether, recipient);
        assertEq(recipient.balance, balBefore + 1 ether);
    }

    function test_guardianCannotWithdrawPendingBnb() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(vault.pendingBnb(), 1 ether);

        vm.expectRevert(bytes("amount exceeds surplus; would touch pending dividend revenue"));
        vm.prank(GUARDIAN_BSC);
        vault.emergencyWithdrawNative(1 ether, GUARDIAN_BSC);
    }

    function test_guardianCannotWithdrawReservedDividends() public {
        taxToken.mint(USER1, 100 ether);
        vault.syncShare(USER1);
        _fundAndProcess(1 ether);

        uint256 cakeBalance = IERC20(CAKE).balanceOf(address(vault));
        assertGt(cakeBalance, 0, "sanity: vault should hold CAKE owed to USER1");

        vm.expectRevert(bytes("amount exceeds surplus; would touch reserved dividends"));
        vm.prank(GUARDIAN_BSC);
        vault.emergencyWithdrawToken(CAKE, cakeBalance, GUARDIAN_BSC);
    }

    function test_nonGuardianCannotExcludeAddresses() public {
        vm.expectRevert();
        vm.prank(ATTACKER);
        vault.setExcludedFromDividends(USER1, true);
    }

    function test_guardianRoleCannotBeRevoked() public {
        bytes32 operatorRole = vault.OPERATOR_ROLE();

        vm.prank(GUARDIAN_BSC);
        vm.expectRevert(CustomDividendVault.CannotRevokeGuardianRole.selector);
        vault.revokeRole(operatorRole, GUARDIAN_BSC);
    }

    // ------------------------------------------------------------------
    // 6. Excluded addresses never accrue share
    // ------------------------------------------------------------------
    function test_excludedAddressDoesNotAccrueDividends() public {
        taxToken.mint(USER1, 100 ether);
        vm.prank(GUARDIAN_BSC);
        vault.setExcludedFromDividends(USER1, true);

        vault.syncShare(USER1);
        assertEq(vault.totalEligibleSupply(), 0, "excluded address should not count toward eligible supply");
    }

    // ------------------------------------------------------------------
    // 6b. SECURITY FIX (BOTH-04): excluding an ALREADY-synced address
    //     actually zeroes their share immediately.
    // ------------------------------------------------------------------
    function test_excludingAlreadySyncedHolderZeroesShareImmediately() public {
        taxToken.mint(USER1, 100 ether);
        vault.syncShare(USER1);
        assertEq(vault.totalEligibleSupply(), 100 ether);

        vm.prank(GUARDIAN_BSC);
        vault.setExcludedFromDividends(USER1, true);

        assertEq(vault.totalEligibleSupply(), 0, "excluding an already-synced holder must zero their share now");
    }

    // ------------------------------------------------------------------
    // 6c. SECURITY FIX (BOTH-03, BOTH-12): protected addresses can never
    //     accrue a share, even without ever calling setExcludedFromDividends.
    // ------------------------------------------------------------------
    function test_vaultItselfNeverAccrues() public {
        taxToken.mint(address(vault), 999 ether);
        vault.syncShare(address(vault));
        assertEq(vault.totalEligibleSupply(), 0, "the vault itself must never count as a holder");
    }

    function test_taxTokenMainPoolNeverAccrues() public {
        address fakePair = address(0xFACADE);
        taxToken.setMainPool(fakePair);
        taxToken.mint(fakePair, 999 ether);

        vm.prank(ATTACKER); // permissionless sync, even from an attacker, is harmless
        vault.syncShare(fakePair);
        assertEq(vault.totalEligibleSupply(), 0, "taxToken's own trading pair must never count as a holder (BOTH-03)");
    }

    // ------------------------------------------------------------------
    // 7. SECURITY FIX (BOTH-02, BOTH-07): swap safety parameters
    // ------------------------------------------------------------------
    function test_operatorCannotExceedSlippageCeiling() public {
        vm.prank(GUARDIAN_BSC);
        vm.expectRevert(bytes("slippage above safety ceiling"));
        vault.setMaxSlippageBps(2001);
    }

    function test_swapStillSucceedsWithDefaultSlippageProtection() public {
        taxToken.mint(USER1, 100 ether);
        vault.syncShare(USER1);
        _fundAndProcess(1 ether);
        assertGt(vault.withdrawableDividendOf(USER1), 0, "swap should still succeed with slippage protection on");
    }
}
