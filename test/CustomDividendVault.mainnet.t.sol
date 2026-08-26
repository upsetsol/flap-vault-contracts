// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {CustomDividendVault, CustomDividendVaultFactory} from "src/CustomDividendVault.sol";

/// @dev Minimal mock ERC20 standing in for a real Flap tax token. We only
///      need balanceOf() to drive the dividend share math — we are not
///      testing the tax token's own transfer/tax logic here, only that our
///      vault correctly reads balances and pays out accordingly.
contract MockTaxToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function setBalance(address who, uint256 amount) external {
        balanceOf[who] = amount;
    }
}

contract CustomDividendVaultTest is Test {
    // Real BSC mainnet addresses — this test runs on a mainnet fork so these
    // must be live, liquid contracts.
    address internal constant PANCAKE_ROUTER_V2 = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address internal constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;
    address internal constant VAULT_PORTAL_BSC = 0x90497450f2a706f1951b5bdda52B4E5d16f34C06;

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

    // ------------------------------------------------------------------
    // 1. Factory deploys a correctly wired vault
    // ------------------------------------------------------------------
    function test_factoryDeploysWiredVault() public view {
        assertEq(vault.taxToken(), address(taxToken), "taxToken mismatch");
        assertEq(vault.dividendToken(), CAKE, "dividendToken mismatch");
        assertEq(vault.pancakeRouter(), PANCAKE_ROUTER_V2, "router mismatch");
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
    // 2. Vault receives BNB and actually swaps it into the dividend token
    // ------------------------------------------------------------------
    function test_receiveSwapsBnbIntoDividendToken() public {
        taxToken.mint(USER1, 100 ether);
        vault.syncShare(USER1);

        uint256 vaultCakeBefore = IERC20(CAKE).balanceOf(address(vault));

        vm.deal(address(this), 1 ether);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok, "receive() should accept BNB");

        uint256 vaultCakeAfter = IERC20(CAKE).balanceOf(address(vault));
        assertGt(vaultCakeAfter, vaultCakeBefore, "vault should have received CAKE from the swap");
    }

    function test_revenueBeforeAnySyncIsParkedNotLost() public {
        // No syncShare called yet — totalEligibleSupply is 0.
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);

        // Correct behavior: BNB is parked, NOT swapped, while nobody is
        // known yet — swapping here would orphan the proceeds permanently
        // (no share to attribute them to). This used to silently swap and
        // lose the funds; caught by a deeper test pass, fixed below.
        assertEq(address(vault).balance, 1 ether, "should be parked as native BNB");
        assertEq(IERC20(CAKE).balanceOf(address(vault)), 0, "must not swap into an orphaned deposit");

        // Now a holder shows up and gets synced.
        taxToken.mint(USER1, 100 ether);
        vault.syncShare(USER1);

        // Unstick the parked funds.
        vault.processPendingRevenue();
        assertEq(address(vault).balance, 0, "parked BNB should now be converted");
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

        vm.deal(address(this), 2 ether);
        (bool ok,) = address(vault).call{value: 2 ether}("");
        assertTrue(ok);

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

        vm.deal(address(this), 1 ether);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);

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

        vm.deal(address(this), 4 ether);
        (bool ok,) = address(vault).call{value: 4 ether}("");
        assertTrue(ok);

        uint256 pending1 = vault.withdrawableDividendOf(USER1);
        uint256 pending2 = vault.withdrawableDividendOf(USER2);

        // USER1 should have roughly 3x USER2's share (within rounding dust).
        assertApproxEqRel(pending1, pending2 * 3, 0.01e18, "dividend split should be proportional to balance");
    }

    // ------------------------------------------------------------------
    // 5. Guardian-gated admin functions
    // ------------------------------------------------------------------
    function test_nonGuardianCannotCallEmergencyWithdraw() public {
        vm.expectRevert();
        vm.prank(ATTACKER);
        vault.emergencyWithdrawNative(1 ether, ATTACKER);
    }

    function test_nonGuardianCannotExcludeAddresses() public {
        vm.expectRevert();
        vm.prank(ATTACKER);
        vault.setExcludedFromDividends(USER1, true);
    }

    function test_guardianRoleCannotBeRevoked() public {
        address guardian = _guardianAddress();
        bytes32 operatorRole = vault.OPERATOR_ROLE(); // read BEFORE pranking — see prank convention note

        vm.prank(guardian);
        vm.expectRevert(CustomDividendVault.CannotRevokeGuardianRole.selector);
        vault.revokeRole(operatorRole, guardian);
    }

    function _guardianAddress() internal pure returns (address) {
        // BNB Chain Guardian, hardcoded in VaultBase.sol — this test runs
        // with vm.chainid defaulting to whatever forge sets for a BSC fork.
        return 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;
    }

    // ------------------------------------------------------------------
    // 6. Excluded addresses never accrue share
    // ------------------------------------------------------------------
    function test_excludedAddressDoesNotAccrueDividends() public {
        address guardian = _guardianAddress();

        taxToken.mint(USER1, 100 ether);
        vm.prank(guardian);
        vault.setExcludedFromDividends(USER1, true);

        vault.syncShare(USER1);
        assertEq(vault.totalEligibleSupply(), 0, "excluded address should not count toward eligible supply");
    }
}
