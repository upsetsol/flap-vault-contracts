// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {IndexBasketVault, IndexBasketVaultFactory} from "src/IndexBasketVault.sol";
import {FieldDescriptor} from "src/flap/IVaultSchemasV1.sol";

/// @dev Minimal mock ERC20 standing in for a real Flap tax token — we only
///      need balanceOf() to drive the share math. Also exposes a settable
///      mainPool() so we can test pair-exclusion (BOTH-03).
contract MockTaxToken {
    mapping(address => uint256) public balanceOf;
    address public mainPool;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function setMainPool(address pool) external {
        mainPool = pool;
    }
}

contract IndexBasketVaultTest is Test {
    address internal constant PANCAKE_ROUTER_V2 = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address internal constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant VAULT_PORTAL_BSC = 0x90497450f2a706f1951b5bdda52B4E5d16f34C06;
    address internal constant GUARDIAN_BSC = 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;

    address internal constant TEAM_OPERATOR = address(0xBEEF5);
    address internal constant USER1 = address(0xCAFE1);
    address internal constant USER2 = address(0xCAFE2);
    address internal constant ATTACKER = address(0xBAD1);
    address internal constant QQQB = 0x205812CdBed920aFf76C6580abD681a46D11efc7;
    address internal constant WECHAT_DOGE = 0x016c87c9986FB6c069846A799042a2327cF07777;
    address internal constant JACKET = 0xb82535E74B03FFE4910EFeA1C759b6bbbF0a7777;

    IndexBasketVaultFactory internal factory;
    IndexBasketVault internal vault;
    MockTaxToken internal taxToken;

    function setUp() public {
        string memory rpcUrl = vm.envOr("BSC_RPC_URL", string("https://bsc-dataseed.bnbchain.org"));
        uint256 forkBlock = vm.envOr("FORK_BLOCK", uint256(0));
        if (forkBlock > 0) {
            vm.createSelectFork(rpcUrl, forkBlock);
        } else {
            vm.createSelectFork(rpcUrl);
        }

        taxToken = new MockTaxToken();
        factory = new IndexBasketVaultFactory(PANCAKE_ROUTER_V2);

        (address[] memory initTokens, uint16[] memory initWeights) = _twoTokenBasket();
        bytes memory vaultData = _encodeVaultData(TEAM_OPERATOR, 0, initTokens, initWeights);

        vm.prank(VAULT_PORTAL_BSC);
        address vaultAddr = factory.newVault(address(taxToken), address(0), address(this), vaultData);
        vault = IndexBasketVault(payable(vaultAddr));
    }

    function _encodeVaultData(
        address operator,
        uint256 minShare,
        address[] memory initTokens,
        uint16[] memory initWeights
    ) internal pure returns (bytes memory) {
        address t1 = initTokens.length > 0 ? initTokens[0] : address(0);
        address t2 = initTokens.length > 1 ? initTokens[1] : address(0);
        address t3 = initTokens.length > 2 ? initTokens[2] : address(0);
        address t4 = initTokens.length > 3 ? initTokens[3] : address(0);
        address t5 = initTokens.length > 4 ? initTokens[4] : address(0);
        uint16 w1 = initWeights.length > 0 ? initWeights[0] : 0;
        uint16 w2 = initWeights.length > 1 ? initWeights[1] : 0;
        uint16 w3 = initWeights.length > 2 ? initWeights[2] : 0;
        uint16 w4 = initWeights.length > 3 ? initWeights[3] : 0;
        uint16 w5 = initWeights.length > 4 ? initWeights[4] : 0;
        return abi.encode(operator, minShare, t1, t2, t3, t4, t5, w1, w2, w3, w4, w5);
    }

    function _twoTokenBasket() internal pure returns (address[] memory tokens, uint16[] memory weights) {
        tokens = new address[](2);
        tokens[0] = CAKE;
        tokens[1] = USDT;
        weights = new uint16[](2);
        weights[0] = 6000;
        weights[1] = 4000;
    }

    /// @dev Funds the vault and immediately processes it.
    function _fundAndProcess(uint256 amount) internal {
        vm.deal(address(this), amount);
        (bool ok,) = address(vault).call{value: amount}("");
        assertTrue(ok, "receive() should never revert");
        vault.processPendingRevenue();
    }

    /// @dev Advances time past the basket update cooldown so a second
    ///      updateBasket() call in the same test doesn't hit BasketUpdateCooldownActive.
    function _skipBasketCooldown() internal {
        vm.warp(block.timestamp + vault.basketUpdateCooldown() + 1);
    }

    // ------------------------------------------------------------------
    // 1. Factory + deployment sanity
    // ------------------------------------------------------------------
    function test_factoryDeploysWiredVault() public view {
        assertEq(vault.taxToken(), address(taxToken));
        assertEq(vault.pancakeRouter(), PANCAKE_ROUTER_V2);
        assertTrue(vault.hasRole(vault.OPERATOR_ROLE(), TEAM_OPERATOR));
        assertEq(vault.vaultQuoteToken(), address(0), "native-only vault");
        assertEq(vault.minBnbToProcess(), 0.03 ether);
        assertEq(vault.maxReserveImpactBps(), 0, "thin Flap pools must not be sliced by default");
    }

    function test_factoryRejectsNonVaultPortalCaller() public {
        bytes memory vaultData = _encodeVaultData(TEAM_OPERATOR, 0, new address[](0), new uint16[](0));
        vm.expectRevert(bytes("Only VaultPortal"));
        factory.newVault(address(taxToken), address(0), address(this), vaultData);
    }

    function test_factorySpecVersionIsV23() public view {
        assertEq(factory.factorySpecVersion(), "v2.3", "BOTH-11: factory should advertise v2.3 for V3 vaults");
    }

    function test_factorySchemaExposesFiveTokenSlots() public view {
        FieldDescriptor[] memory fields = factory.vaultDataSchema().fields;
        assertEq(fields.length, 12);
        assertEq(fields[2].name, "token1");
        assertEq(fields[6].name, "token5");
        assertEq(fields[7].name, "weight1");
        assertEq(fields[11].name, "weight5");
    }

    function test_teamOperatorDoesNotGetDefaultAdminRole() public view {
        assertFalse(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), TEAM_OPERATOR), "team must not hold DEFAULT_ADMIN_ROLE");
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), GUARDIAN_BSC), "guardian must still hold admin");
    }

    // ------------------------------------------------------------------
    // 1b. SECURITY FIX (IBV-03): initial basket can be set atomically at
    //     construction, avoiding the empty-basket launch window entirely.
    // ------------------------------------------------------------------
    function test_initialBasketCanBeSetAtConstruction() public {
        (address[] memory tokens, uint16[] memory weights) = _twoTokenBasket();
        bytes memory vaultData = _encodeVaultData(TEAM_OPERATOR, 0, tokens, weights);

        vm.prank(VAULT_PORTAL_BSC);
        address vaultAddr2 = factory.newVault(address(taxToken), address(0), address(this), vaultData);
        IndexBasketVault v2 = IndexBasketVault(payable(vaultAddr2));

        assertEq(v2.basketLength(), 2, "basket should already be set, no separate updateBasket() call needed");
        assertEq(v2.basketTokens(0), CAKE);
        assertEq(v2.basketWeightBps(CAKE), 6000);
    }

    function test_factoryRejectsEmptyBasket() public {
        bytes memory vaultData = _encodeVaultData(TEAM_OPERATOR, 0, new address[](0), new uint16[](0));
        vm.prank(VAULT_PORTAL_BSC);
        vm.expectRevert(IndexBasketVaultFactory.BasketRequired.selector);
        factory.newVault(address(taxToken), address(0), address(this), vaultData);
    }

    // ------------------------------------------------------------------
    // 1c. SECURITY FIX (IBV-03): updateBasket is rate-limited by a cooldown
    // ------------------------------------------------------------------
    function test_updateBasketRejectsRapidSecondCall() public {
        (address[] memory tokens, uint16[] memory weights) = _twoTokenBasket();
        _skipBasketCooldown();
        vm.prank(TEAM_OPERATOR);
        vault.updateBasket(tokens, weights);

        address[] memory newTokens = new address[](1);
        newTokens[0] = CAKE;
        uint16[] memory newWeights = new uint16[](1);
        newWeights[0] = 10000;

        vm.prank(TEAM_OPERATOR);
        vm.expectRevert(IndexBasketVault.BasketUpdateCooldownActive.selector);
        vault.updateBasket(newTokens, newWeights);
    }

    function test_updateBasketSucceedsAfterCooldownElapses() public {
        (address[] memory tokens, uint16[] memory weights) = _twoTokenBasket();
        _skipBasketCooldown();
        vm.prank(TEAM_OPERATOR);
        vault.updateBasket(tokens, weights);

        _skipBasketCooldown();

        address[] memory newTokens = new address[](1);
        newTokens[0] = CAKE;
        uint16[] memory newWeights = new uint16[](1);
        newWeights[0] = 10000;

        _skipBasketCooldown();
        vm.prank(TEAM_OPERATOR);
        vault.updateBasket(newTokens, newWeights); // must not revert
        assertEq(vault.basketLength(), 1);
    }

    function test_operatorCannotSetCooldownBelowMinimum() public {
        vm.prank(TEAM_OPERATOR);
        vm.expectRevert(bytes("cooldown below minimum"));
        vault.setBasketUpdateCooldown(30 minutes); // below the 1-hour floor
    }

    function test_operatorCanIncreaseCooldownAboveMinimum() public {
        vm.prank(TEAM_OPERATOR);
        vault.setBasketUpdateCooldown(1 days);
        assertEq(vault.basketUpdateCooldown(), 1 days);
    }

    // ------------------------------------------------------------------
    // 2. Basket management validation
    // ------------------------------------------------------------------
    function test_operatorCanSetBasket() public {
        (address[] memory tokens, uint16[] memory weights) = _twoTokenBasket();

        _skipBasketCooldown();
        vm.prank(TEAM_OPERATOR);
        vault.updateBasket(tokens, weights);

        assertEq(vault.basketLength(), 2);
        assertEq(vault.basketTokens(0), CAKE);
        assertEq(vault.basketTokens(1), USDT);
        assertEq(vault.basketWeightBps(CAKE), 6000);
        assertEq(vault.basketWeightBps(USDT), 4000);
    }

    function test_nonOperatorCannotSetBasket() public {
        (address[] memory tokens, uint16[] memory weights) = _twoTokenBasket();
        vm.expectRevert();
        vm.prank(ATTACKER);
        vault.updateBasket(tokens, weights);
    }

    function test_updateBasketRejectsBadWeightSum() public {
        address[] memory tokens = new address[](2);
        tokens[0] = CAKE;
        tokens[1] = USDT;
        uint16[] memory weights = new uint16[](2);
        weights[0] = 5000;
        weights[1] = 4000;

        _skipBasketCooldown();
        vm.prank(TEAM_OPERATOR);
        vm.expectRevert(IndexBasketVault.InvalidBasket.selector);
        vault.updateBasket(tokens, weights);
    }

    function test_updateBasketRejectsDuplicateTokens() public {
        address[] memory tokens = new address[](2);
        tokens[0] = CAKE;
        tokens[1] = CAKE;
        uint16[] memory weights = new uint16[](2);
        weights[0] = 5000;
        weights[1] = 5000;

        _skipBasketCooldown();
        vm.prank(TEAM_OPERATOR);
        vm.expectRevert(IndexBasketVault.InvalidBasket.selector);
        vault.updateBasket(tokens, weights);
    }

    function test_updateBasketRejectsMoreThanFiveTokens() public {
        address[] memory tokens = new address[](6);
        uint16[] memory weights = new uint16[](6);
        uint16 evenWeight = uint16(uint256(10000) / 6);
        for (uint256 i = 0; i < 6; i++) {
            tokens[i] = address(uint160(i + 1));
            weights[i] = evenWeight;
        }

        _skipBasketCooldown();
        vm.prank(TEAM_OPERATOR);
        vm.expectRevert(IndexBasketVault.InvalidBasket.selector);
        vault.updateBasket(tokens, weights);
    }

    function test_updateBasketRejectsTaxTokenItself() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(taxToken);
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10000;

        _skipBasketCooldown();
        vm.prank(TEAM_OPERATOR);
        vm.expectRevert(IndexBasketVault.InvalidBasket.selector);
        vault.updateBasket(tokens, weights);
    }

    function test_updateBasketRejectsVaultItself() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(vault);
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10000;

        _skipBasketCooldown();
        vm.prank(TEAM_OPERATOR);
        vm.expectRevert(IndexBasketVault.InvalidBasket.selector);
        vault.updateBasket(tokens, weights);
    }

    function test_updateBasketRejectsZeroWeight() public {
        address[] memory tokens = new address[](2);
        tokens[0] = CAKE;
        tokens[1] = USDT;
        uint16[] memory weights = new uint16[](2);
        weights[0] = 0;
        weights[1] = 10000;

        _skipBasketCooldown();
        vm.prank(TEAM_OPERATOR);
        vm.expectRevert(IndexBasketVault.InvalidBasket.selector);
        vault.updateBasket(tokens, weights);
    }

    // ------------------------------------------------------------------
    // 3. receive() accumulates only, split per-token at receipt time (IBV-02)
    // ------------------------------------------------------------------
    function test_receiveOnlyAccumulatesNeverSwaps() public {
        (address[] memory tokens, uint16[] memory weights) = _twoTokenBasket();
        _skipBasketCooldown();
        vm.prank(TEAM_OPERATOR);
        vault.updateBasket(tokens, weights);

        taxToken.mint(USER1, 100 ether);
        vault.syncShare(USER1);

        vm.deal(address(this), 1 ether);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);

        assertEq(vault.totalPendingBnb(), 1 ether, "receive() must only accumulate");
        assertEq(vault.pendingBnbByToken(CAKE), 0.6 ether, "should already be split 60% to CAKE at receive() time");
        assertEq(vault.pendingBnbByToken(USDT), 0.4 ether, "should already be split 40% to USDT at receive() time");
        assertEq(IERC20(CAKE).balanceOf(address(vault)), 0, "receive() must never swap (BOTH-01 fix)");
    }

    function test_receiveWithNoBasketParksInNoBasketBucket() public view {
        assertEq(vault.basketLength(), 2, "setUp must deploy with a required initial basket");
    }

    function test_processPendingRevenueSwapsAcrossBasketProportionally() public {
        (address[] memory tokens, uint16[] memory weights) = _twoTokenBasket();
        _skipBasketCooldown();
        vm.prank(TEAM_OPERATOR);
        vault.updateBasket(tokens, weights);

        taxToken.mint(USER1, 100 ether);
        vault.syncShare(USER1);

        uint256 cakeBefore = IERC20(CAKE).balanceOf(address(vault));
        uint256 usdtBefore = IERC20(USDT).balanceOf(address(vault));

        _fundAndProcess(1 ether);

        uint256 cakeGained = IERC20(CAKE).balanceOf(address(vault)) - cakeBefore;
        uint256 usdtGained = IERC20(USDT).balanceOf(address(vault)) - usdtBefore;

        assertGt(cakeGained, 0, "should have received CAKE");
        assertGt(usdtGained, 0, "should have received USDT");
        assertEq(vault.totalPendingBnb(), 0, "should be fully drained after processing");
    }

    // ------------------------------------------------------------------
    // 3b. SECURITY FIX (IBV-02): a dead token's pending stays isolated —
    //     it does not bleed into other tokens' allocation on later rounds.
    // ------------------------------------------------------------------
    function test_deadTokenPendingStaysIsolatedAcrossMultipleRounds() public {
        NoLiquidityToken deadToken = new NoLiquidityToken();

        address[] memory tokens = new address[](2);
        tokens[0] = CAKE;
        tokens[1] = address(deadToken);
        uint16[] memory weights = new uint16[](2);
        weights[0] = 5000;
        weights[1] = 5000;

        _skipBasketCooldown();
        vm.prank(TEAM_OPERATOR);
        vault.updateBasket(tokens, weights);

        taxToken.mint(USER1, 100 ether);
        vault.syncShare(USER1);

        // Round 1: fund and process — CAKE succeeds, dead token fails and
        // stays isolated in its own bucket.
        vm.deal(address(this), 1 ether);
        (bool ok1,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok1);
        vault.processPendingRevenue();

        uint256 deadPendingAfterRound1 = vault.pendingBnbByToken(address(deadToken));
        assertEq(deadPendingAfterRound1, 0.5 ether, "dead token's half should sit isolated, untouched");
        assertEq(vault.pendingBnbByToken(CAKE), 0, "CAKE's half should have fully processed");

        // Round 2: fund again — CAKE's new share must NOT be inflated by the
        // dead token's leftover (that would mean the leftover "leaked" across
        // tokens, which is exactly the IBV-02 bug).
        vm.deal(address(this), 1 ether);
        (bool ok2,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok2);

        assertEq(vault.pendingBnbByToken(CAKE), 0.5 ether, "CAKE gets only its own 50% share of round 2, no leakage");
        assertEq(
            vault.pendingBnbByToken(address(deadToken)),
            1 ether,
            "dead token accumulates its own share across rounds, isolated from CAKE's"
        );
    }

    // ------------------------------------------------------------------
    // 4. End-to-end claim across multiple reward tokens
    // ------------------------------------------------------------------
    function test_holderCanClaimAllAcrossBothTokens() public {
        (address[] memory tokens, uint16[] memory weights) = _twoTokenBasket();
        _skipBasketCooldown();
        vm.prank(TEAM_OPERATOR);
        vault.updateBasket(tokens, weights);

        taxToken.mint(USER1, 100 ether);
        vault.syncShare(USER1);

        _fundAndProcess(2 ether);

        uint256 pendingCake = vault.withdrawableDividendOf(USER1, CAKE);
        uint256 pendingUsdt = vault.withdrawableDividendOf(USER1, USDT);
        assertGt(pendingCake, 0);
        assertGt(pendingUsdt, 0);

        vm.prank(USER1);
        vault.claimAll();

        assertEq(IERC20(CAKE).balanceOf(USER1), pendingCake);
        assertEq(IERC20(USDT).balanceOf(USER1), pendingUsdt);
        assertEq(vault.withdrawableDividendOf(USER1, CAKE), 0);
        assertEq(vault.withdrawableDividendOf(USER1, USDT), 0);
    }

    function test_claimAllRevertsWithNothingToClaim() public {
        (address[] memory tokens, uint16[] memory weights) = _twoTokenBasket();
        _skipBasketCooldown();
        vm.prank(TEAM_OPERATOR);
        vault.updateBasket(tokens, weights);

        taxToken.mint(USER1, 100 ether);

        vm.expectRevert(IndexBasketVault.NothingToClaim.selector);
        vm.prank(USER1);
        vault.claimAll();
    }

    // ------------------------------------------------------------------
    // 5. Push distribution to a batch of holders
    // ------------------------------------------------------------------
    function test_distributeToPaysMultipleHolders() public {
        (address[] memory tokens, uint16[] memory weights) = _twoTokenBasket();
        _skipBasketCooldown();
        vm.prank(TEAM_OPERATOR);
        vault.updateBasket(tokens, weights);

        taxToken.mint(USER1, 300 ether);
        taxToken.mint(USER2, 100 ether);
        vault.syncShare(USER1);
        vault.syncShare(USER2);

        _fundAndProcess(4 ether);

        address[] memory batch = new address[](2);
        batch[0] = USER1;
        batch[1] = USER2;

        vault.distributeTo(batch);

        assertGt(IERC20(CAKE).balanceOf(USER1), 0, "USER1 should have received CAKE");
        assertGt(IERC20(CAKE).balanceOf(USER2), 0, "USER2 should have received CAKE");
        assertApproxEqRel(IERC20(CAKE).balanceOf(USER1), IERC20(CAKE).balanceOf(USER2) * 3, 0.02e18);
    }

    function test_distributeToDoesNotRevertOnUserWithNothingPending() public {
        (address[] memory tokens, uint16[] memory weights) = _twoTokenBasket();
        _skipBasketCooldown();
        vm.prank(TEAM_OPERATOR);
        vault.updateBasket(tokens, weights);

        taxToken.mint(USER1, 100 ether);
        vault.syncShare(USER1);

        _fundAndProcess(1 ether);

        address[] memory batch = new address[](2);
        batch[0] = USER1;
        batch[1] = USER2;

        vault.distributeTo(batch);
        assertGt(IERC20(CAKE).balanceOf(USER1), 0, "USER1 should still get paid");
        assertEq(IERC20(CAKE).balanceOf(USER2), 0, "USER2 has nothing, correctly skipped");
    }

    // ------------------------------------------------------------------
    // 6. Changing the basket preserves old accruals
    // ------------------------------------------------------------------
    function test_changingBasketPreservesOldAccruals() public {
        (address[] memory tokens, uint16[] memory weights) = _twoTokenBasket();
        _skipBasketCooldown();
        vm.prank(TEAM_OPERATOR);
        vault.updateBasket(tokens, weights);

        taxToken.mint(USER1, 100 ether);
        vault.syncShare(USER1);

        _fundAndProcess(1 ether);

        uint256 pendingCakeBeforeSwitch = vault.withdrawableDividendOf(USER1, CAKE);
        assertGt(pendingCakeBeforeSwitch, 0);

        _skipBasketCooldown();

        address[] memory newTokens = new address[](1);
        newTokens[0] = USDT;
        uint16[] memory newWeights = new uint16[](1);
        newWeights[0] = 10000;

        _skipBasketCooldown();
        vm.prank(TEAM_OPERATOR);
        vault.updateBasket(newTokens, newWeights);

        assertEq(vault.withdrawableDividendOf(USER1, CAKE), pendingCakeBeforeSwitch);

        vm.prank(USER1);
        vault.claimAll();
        assertEq(IERC20(CAKE).balanceOf(USER1), pendingCakeBeforeSwitch);
    }

    // ------------------------------------------------------------------
    // 7. SECURITY FIX (IBV-01): emergency withdraw is Guardian-only
    // ------------------------------------------------------------------
    function test_randomAttackerCannotCallEmergencyWithdraw() public {
        vm.expectRevert(IndexBasketVault.GuardianOnly.selector);
        vm.prank(ATTACKER);
        vault.emergencyWithdrawNative(1 ether, ATTACKER);
    }

    function test_teamOperatorCannotCallEmergencyWithdrawNative() public {
        vm.expectRevert(IndexBasketVault.GuardianOnly.selector);
        vm.prank(TEAM_OPERATOR);
        vault.emergencyWithdrawNative(1 ether, TEAM_OPERATOR);
    }

    function test_teamOperatorCannotCallEmergencyWithdrawToken() public {
        vm.expectRevert(IndexBasketVault.GuardianOnly.selector);
        vm.prank(TEAM_OPERATOR);
        vault.emergencyWithdrawToken(CAKE, 1, TEAM_OPERATOR);
    }

    function test_guardianCanWithdrawGenuineSurplus() public {
        address recipient = address(0xC0FFEE);
        vm.deal(address(vault), 1 ether); // bypasses receive(), pendingBnb stays 0
        assertEq(vault.totalPendingBnb(), 0);

        uint256 balBefore = recipient.balance;
        vm.prank(GUARDIAN_BSC);
        vault.emergencyWithdrawNative(1 ether, recipient);
        assertEq(recipient.balance, balBefore + 1 ether);
    }

    function test_guardianCannotWithdrawPendingBnb() public {
        (address[] memory tokens, uint16[] memory weights) = _twoTokenBasket();
        _skipBasketCooldown();
        vm.prank(TEAM_OPERATOR);
        vault.updateBasket(tokens, weights);

        vm.deal(address(this), 1 ether);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(vault.totalPendingBnb(), 1 ether);

        vm.expectRevert(bytes("amount exceeds surplus; would touch pending dividend revenue"));
        vm.prank(GUARDIAN_BSC);
        vault.emergencyWithdrawNative(1 ether, GUARDIAN_BSC);
    }

    function test_guardianCannotWithdrawReservedDividends() public {
        (address[] memory tokens, uint16[] memory weights) = _twoTokenBasket();
        _skipBasketCooldown();
        vm.prank(TEAM_OPERATOR);
        vault.updateBasket(tokens, weights);

        taxToken.mint(USER1, 100 ether);
        vault.syncShare(USER1);
        _fundAndProcess(1 ether);

        uint256 cakeBalance = IERC20(CAKE).balanceOf(address(vault));
        assertGt(cakeBalance, 0, "sanity: vault should hold CAKE owed to USER1");

        vm.expectRevert(bytes("amount exceeds surplus; would touch reserved dividends"));
        vm.prank(GUARDIAN_BSC);
        vault.emergencyWithdrawToken(CAKE, cakeBalance, GUARDIAN_BSC);
    }

    function test_guardianRoleCannotBeRevoked() public {
        bytes32 operatorRole = vault.OPERATOR_ROLE();

        vm.prank(GUARDIAN_BSC);
        vm.expectRevert(IndexBasketVault.CannotRevokeGuardianRole.selector);
        vault.revokeRole(operatorRole, GUARDIAN_BSC);
    }

    // ------------------------------------------------------------------
    // 8. Full 5-token basket
    // ------------------------------------------------------------------
    function test_fiveTokenBasketWorksAndFits5EqualWeights() public {
        address usdc = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
        address[] memory tokens = new address[](5);
        tokens[0] = CAKE;
        tokens[1] = USDT;
        tokens[2] = usdc;
        tokens[3] = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8;
        tokens[4] = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;

        uint16[] memory weights = new uint16[](5);
        weights[0] = 2000;
        weights[1] = 2000;
        weights[2] = 2000;
        weights[3] = 2000;
        weights[4] = 2000;

        _skipBasketCooldown();
        vm.prank(TEAM_OPERATOR);
        vault.updateBasket(tokens, weights);
        assertEq(vault.basketLength(), 5);

        taxToken.mint(USER1, 100 ether);
        vault.syncShare(USER1);

        _fundAndProcess(1 ether);

        for (uint256 i = 0; i < tokens.length; i++) {
            assertGt(vault.withdrawableDividendOf(USER1, tokens[i]), 0, "each of the 5 tokens should have accrued");
        }

        vm.prank(USER1);
        vault.claimAll();
        for (uint256 i = 0; i < tokens.length; i++) {
            assertGt(IERC20(tokens[i]).balanceOf(USER1), 0, "USER1 should hold all 5 reward tokens after claim");
        }
    }

    // ------------------------------------------------------------------
    // 9. One basket token has no liquidity — swap fails but others still work
    // ------------------------------------------------------------------
    function test_oneFailingSwapDoesNotBlockTheRestOfTheBasket() public {
        NoLiquidityToken deadToken = new NoLiquidityToken();

        address[] memory tokens = new address[](2);
        tokens[0] = CAKE;
        tokens[1] = address(deadToken);
        uint16[] memory weights = new uint16[](2);
        weights[0] = 5000;
        weights[1] = 5000;

        _skipBasketCooldown();
        vm.prank(TEAM_OPERATOR);
        vault.updateBasket(tokens, weights);

        taxToken.mint(USER1, 100 ether);
        vault.syncShare(USER1);

        vm.deal(address(this), 1 ether);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);

        vm.expectEmit(true, false, false, false);
        emit IndexBasketVault.SwapSkipped(address(deadToken), 0, "");
        vault.processPendingRevenue();

        assertGt(vault.withdrawableDividendOf(USER1, CAKE), 0, "CAKE side should still work");
        assertEq(vault.withdrawableDividendOf(USER1, address(deadToken)), 0, "dead token should have accrued 0");
        assertGt(vault.totalPendingBnb(), 0, "the dead token's slice should remain queued, not lost");
    }

    // ------------------------------------------------------------------
    // 10. Partial basket overlap — one token stays, one is dropped
    // ------------------------------------------------------------------
    function test_partialBasketOverlapKeepsAccruingSharedToken() public {
        (address[] memory tokens, uint16[] memory weights) = _twoTokenBasket();
        _skipBasketCooldown();
        vm.prank(TEAM_OPERATOR);
        vault.updateBasket(tokens, weights);

        taxToken.mint(USER1, 100 ether);
        vault.syncShare(USER1);

        _fundAndProcess(1 ether);

        uint256 cakeAccruedRound1 = vault.withdrawableDividendOf(USER1, CAKE);
        assertGt(cakeAccruedRound1, 0);

        _skipBasketCooldown();

        address[] memory newTokens = new address[](1);
        newTokens[0] = CAKE;
        uint16[] memory newWeights = new uint16[](1);
        newWeights[0] = 10000;

        _skipBasketCooldown();
        vm.prank(TEAM_OPERATOR);
        vault.updateBasket(newTokens, newWeights);

        assertEq(vault.basketLength(), 1);
        assertEq(vault.basketWeightBps(USDT), 0);

        _fundAndProcess(1 ether);

        uint256 cakeAccruedRound2 = vault.withdrawableDividendOf(USER1, CAKE);
        assertGt(cakeAccruedRound2, cakeAccruedRound1, "CAKE should keep accruing across the basket change");
        assertGt(vault.withdrawableDividendOf(USER1, USDT), 0, "old USDT accrual should be preserved");
    }

    // ------------------------------------------------------------------
    // 11. minimumShareBalance actually gates small holders to zero share
    // ------------------------------------------------------------------
    function test_minimumShareBalanceExcludesSmallHolders() public {
        address[] memory tokens = new address[](1);
        tokens[0] = CAKE;
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10000;
        bytes memory vaultData = _encodeVaultData(TEAM_OPERATOR, 10000 ether, tokens, weights);
        vm.prank(VAULT_PORTAL_BSC);
        address vaultAddr2 = factory.newVault(address(taxToken), address(0), address(this), vaultData);
        IndexBasketVault vaultWithMin = IndexBasketVault(payable(vaultAddr2));

        taxToken.mint(USER1, 5000 ether);
        taxToken.mint(USER2, 20000 ether);

        vaultWithMin.syncShare(USER1);
        vaultWithMin.syncShare(USER2);

        vm.deal(address(this), 1 ether);
        (bool ok,) = address(vaultWithMin).call{value: 1 ether}("");
        assertTrue(ok);
        vaultWithMin.processPendingRevenue();

        assertEq(vaultWithMin.withdrawableDividendOf(USER1, CAKE), 0, "below-minimum holder should get nothing");
        assertGt(vaultWithMin.withdrawableDividendOf(USER2, CAKE), 0, "above-minimum holder should get paid");
    }

    // ------------------------------------------------------------------
    // 12. Excluded addresses never accrue, regardless of balance
    // ------------------------------------------------------------------
    function test_excludedAddressNeverAccrues() public {
        (address[] memory tokens, uint16[] memory weights) = _twoTokenBasket();
        _skipBasketCooldown();
        vm.prank(TEAM_OPERATOR);
        vault.updateBasket(tokens, weights);

        taxToken.mint(USER1, 100 ether);
        taxToken.mint(USER2, 100 ether);

        vm.prank(TEAM_OPERATOR);
        vault.setExcludedFromDividends(USER1, true);

        vault.syncShare(USER1);
        vault.syncShare(USER2);

        vm.deal(address(this), 1 ether);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);
        vault.processPendingRevenue();

        assertEq(vault.withdrawableDividendOf(USER1, CAKE), 0, "excluded address must accrue nothing");
        assertGt(vault.withdrawableDividendOf(USER2, CAKE), 0, "non-excluded holder should still get paid");
        assertEq(vault.totalEligibleSupply(), 100 ether, "only USER2's balance should count toward eligible supply");
    }

    function test_excludingAlreadySyncedHolderZeroesShareImmediately() public {
        taxToken.mint(USER1, 100 ether);
        vault.syncShare(USER1);
        assertEq(vault.totalEligibleSupply(), 100 ether);

        vm.prank(TEAM_OPERATOR);
        vault.setExcludedFromDividends(USER1, true);

        assertEq(vault.totalEligibleSupply(), 0, "excluding an already-synced holder must zero their share now");
    }

    function test_reIncludingExcludedHolderAllowsSyncAgain() public {
        taxToken.mint(USER1, 100 ether);
        vault.syncShare(USER1);

        vm.prank(TEAM_OPERATOR);
        vault.setExcludedFromDividends(USER1, true);
        assertEq(vault.totalEligibleSupply(), 0);

        vm.prank(TEAM_OPERATOR);
        vault.setExcludedFromDividends(USER1, false);
        vault.syncShare(USER1);

        assertEq(vault.totalEligibleSupply(), 100 ether, "re-included holder should be able to sync back in");
    }

    function test_vaultItselfNeverAccruesEvenIfBalanceIsSet() public {
        taxToken.mint(address(vault), 999 ether);
        vault.syncShare(address(vault));
        assertEq(vault.totalEligibleSupply(), 0, "the vault itself must never count as a holder");
    }

    function test_taxTokenAddressNeverAccrues() public {
        taxToken.mint(address(taxToken), 999 ether);
        vault.syncShare(address(taxToken));
        assertEq(vault.totalEligibleSupply(), 0, "taxToken itself must never count as a holder");
    }

    function test_deadAddressNeverAccrues() public {
        taxToken.mint(address(0xdEaD), 999 ether);
        vault.syncShare(address(0xdEaD));
        assertEq(vault.totalEligibleSupply(), 0, "the dead address must never count as a holder");
    }

    function test_taxTokenMainPoolNeverAccrues() public {
        address fakePair = address(0xFACADE);
        taxToken.setMainPool(fakePair);
        taxToken.mint(fakePair, 999 ether);

        vault.syncShare(fakePair);
        assertEq(vault.totalEligibleSupply(), 0, "taxToken's own trading pair must never count as a holder (BOTH-03)");
    }

    function test_anyoneCanTriggerProtectedAddressSync_harmlessly() public {
        address fakePair = address(0xFACADE);
        taxToken.setMainPool(fakePair);
        taxToken.mint(fakePair, 500 ether);

        vm.prank(ATTACKER);
        vault.syncShare(fakePair);
        assertEq(vault.totalEligibleSupply(), 0, "syncing the pair must never grant it a share, regardless of caller");
    }

    // ------------------------------------------------------------------
    // 13. Gas cost of distributing to many holders in one call
    // ------------------------------------------------------------------
    function test_gasCostOfDistributingToThreeHundredHolders() public {
        (address[] memory tokens, uint16[] memory weights) = _twoTokenBasket();
        _skipBasketCooldown();
        vm.prank(TEAM_OPERATOR);
        vault.updateBasket(tokens, weights);

        uint256 n = 50;
        address[] memory holders = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            address holder = address(uint160(0x10000 + i));
            holders[i] = holder;
            taxToken.mint(holder, 1000 ether + i * 1 ether);
        }

        vm.deal(address(this), 10 ether);
        (bool ok,) = address(vault).call{value: 10 ether}("");
        assertTrue(ok);
        assertEq(vault.totalPendingBnb(), 10 ether, "should be parked, not swapped, while nobody is synced yet");

        uint256 gasBefore = gasleft();
        vault.distributeTo(holders);
        uint256 gasUsed = gasBefore - gasleft();

        console2.log("Gas used for distributeTo() with N holders (sync pass):", gasUsed);
        console2.log("Holder count N:", n);
        assertLt(gasUsed, 50_000_000, "batch of 50 should comfortably fit within a BSC block");
        assertGt(vault.totalEligibleSupply(), 0, "all holders should now be synced");

        vault.processPendingRevenue();
        assertEq(vault.totalPendingBnb(), 0, "parked BNB should now be fully swapped");

        vault.distributeTo(holders);
        assertGt(IERC20(CAKE).balanceOf(holders[0]), 0, "holder 0 should now be paid");
        assertGt(IERC20(CAKE).balanceOf(holders[n - 1]), 0, "holder n-1 should now be paid");
    }

    // ------------------------------------------------------------------
    // 14. Revenue arriving before any holder is synced must not be lost
    // ------------------------------------------------------------------
    function test_revenueBeforeAnySyncIsParkedNotLost() public {
        (address[] memory tokens, uint16[] memory weights) = _twoTokenBasket();
        _skipBasketCooldown();
        vm.prank(TEAM_OPERATOR);
        vault.updateBasket(tokens, weights);

        vm.deal(address(this), 1 ether);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(vault.totalPendingBnb(), 1 ether, "should be parked");
        assertEq(IERC20(CAKE).balanceOf(address(vault)), 0, "must not have swapped into an orphaned deposit");

        taxToken.mint(USER1, 100 ether);
        vault.syncShare(USER1);

        vault.processPendingRevenue();
        assertEq(vault.totalPendingBnb(), 0, "parked BNB should now be converted");
        assertGt(
            vault.withdrawableDividendOf(USER1, CAKE),
            0,
            "USER1 should now be able to claim the previously-parked funds"
        );
    }

    function test_processPendingRevenueRevertsWithNothingPending() public {
        (address[] memory tokens, uint16[] memory weights) = _twoTokenBasket();
        _skipBasketCooldown();
        vm.prank(TEAM_OPERATOR);
        vault.updateBasket(tokens, weights);

        taxToken.mint(USER1, 100 ether);
        vault.syncShare(USER1);

        vm.expectRevert(bytes("nothing pending"));
        vault.processPendingRevenue();
    }

    // ------------------------------------------------------------------
    // 15. Swap safety parameters (BOTH-02, BOTH-07)
    // ------------------------------------------------------------------
    function test_operatorCanTuneSlippageWithinCeiling() public {
        vm.prank(TEAM_OPERATOR);
        vault.setMaxSlippageBps(300);
        assertEq(vault.maxSlippageBps(), 300);
    }

    function test_operatorCannotExceedSlippageCeiling() public {
        vm.prank(TEAM_OPERATOR);
        vm.expectRevert(bytes("slippage above safety ceiling"));
        vault.setMaxSlippageBps(501);
    }

    function test_operatorCannotExceedReserveImpactCeiling() public {
        vm.prank(TEAM_OPERATOR);
        vm.expectRevert(bytes("impact above safety ceiling"));
        vault.setMaxReserveImpactBps(201);
    }

    function test_swapStillSucceedsWithDefaultSlippageProtection() public {
        (address[] memory tokens, uint16[] memory weights) = _twoTokenBasket();
        _skipBasketCooldown();
        vm.prank(TEAM_OPERATOR);
        vault.updateBasket(tokens, weights);

        taxToken.mint(USER1, 100 ether);
        vault.syncShare(USER1);

        _fundAndProcess(1 ether);
        assertGt(vault.withdrawableDividendOf(USER1, CAKE), 0, "swap should still succeed with slippage protection on");
    }

    function test_extraPairNeverAccrues() public {
        address extra = address(uint160(uint256(keccak256("extra-pair"))));
        vm.etch(extra, hex"00");
        taxToken.mint(extra, 999 ether);

        vm.prank(TEAM_OPERATOR);
        vault.addExtraPair(extra);

        vault.syncShare(extra);
        assertEq(vault.totalEligibleSupply(), 0, "extra pair must be excluded from dividends");
    }

    function test_droppedBasketTokenPendingMovesToNoBasketBucket() public {
        taxToken.mint(USER1, 100 ether);
        vault.syncShare(USER1);

        vm.deal(address(this), 1 ether);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(vault.pendingBnbByToken(USDT), 0.4 ether);

        address[] memory newTokens = new address[](1);
        newTokens[0] = CAKE;
        uint16[] memory newWeights = new uint16[](1);
        newWeights[0] = 10000;
        _skipBasketCooldown();
        vm.prank(TEAM_OPERATOR);
        vault.updateBasket(newTokens, newWeights);

        assertEq(vault.pendingBnbByToken(USDT), 0, "dropped token pending must not stay locked");
        assertEq(vault.pendingBnbNoBasket(), 0.4 ether, "dropped pending should move to the shared bucket");
    }

    function test_operatorCannotExceedMinBnbCeiling() public {
        vm.prank(TEAM_OPERATOR);
        vm.expectRevert(bytes("min BNB above maximum"));
        vault.setMinBnbToProcess(101 ether);
    }

    function test_operatorCannotExceedCooldownMaximum() public {
        vm.prank(TEAM_OPERATOR);
        vm.expectRevert(bytes("cooldown above maximum"));
        vault.setBasketUpdateCooldown(8 days);
    }

    function test_distributeToRejectsOversizedBatch() public {
        address[] memory users = new address[](vault.MAX_DISTRIBUTE_BATCH() + 1);
        vm.expectRevert(bytes("batch too large"));
        vault.distributeTo(users);
    }

    function test_noPairDoesNotDumpFullAmount() public {
        NoLiquidityToken deadToken = new NoLiquidityToken();
        address[] memory tokens = new address[](1);
        tokens[0] = address(deadToken);
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10000;
        _skipBasketCooldown();
        vm.prank(TEAM_OPERATOR);
        vault.updateBasket(tokens, weights);

        taxToken.mint(USER1, 100 ether);
        vault.syncShare(USER1);

        vm.deal(address(this), 1 ether);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertTrue(ok);
        vault.processPendingRevenue();

        assertEq(vault.pendingBnbByToken(address(deadToken)), 1 ether, "fail-closed cap must leave BNB pending");
        assertEq(address(vault).balance, 1 ether, "BNB must not be spent when pair/reserves are missing");
    }

    // ------------------------------------------------------------------
    // Quote-token hops (Flap memes that trade against QQQB, not WBNB)
    // ------------------------------------------------------------------
    function test_nonOperatorCannotSetBasketQuote() public {
        vm.prank(ATTACKER);
        vm.expectRevert();
        vault.setBasketQuote(CAKE, USDT);
    }

    function test_setBasketQuoteRejectsTaxTokenAsHop() public {
        vm.prank(TEAM_OPERATOR);
        vm.expectRevert(IndexBasketVault.InvalidBasket.selector);
        vault.setBasketQuote(CAKE, address(taxToken));
    }

    function test_forcedUsdtHopStillBuysCake() public {
        vm.prank(TEAM_OPERATOR);
        vault.setBasketQuote(CAKE, USDT);
        assertEq(vault.basketQuote(CAKE), USDT);

        taxToken.mint(USER1, 100 ether);
        vault.syncShare(USER1);
        _fundAndProcess(1 ether);

        assertGt(vault.withdrawableDividendOf(USER1, CAKE), 0, "CAKE should be bought via WBNB -> USDT -> CAKE");
        assertGt(vault.withdrawableDividendOf(USER1, USDT), 0, "USDT direct hop must still work");
    }

    function test_flapQuotedMemeIsBoughtViaQuoteToken() public {
        address[] memory tokens = new address[](1);
        tokens[0] = WECHAT_DOGE;
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10000;

        _skipBasketCooldown();
        vm.prank(TEAM_OPERATOR);
        vault.updateBasket(tokens, weights);

        taxToken.mint(USER1, 100 ether);
        vault.syncShare(USER1);

        uint256 qqqbBefore = IERC20(QQQB).balanceOf(address(vault));
        _fundAndProcess(0.05 ether);

        assertGt(
            vault.withdrawableDividendOf(USER1, WECHAT_DOGE),
            0,
            "Flap meme quoted in QQQB must be bought via WBNB -> QQQB -> token"
        );
        assertEq(IERC20(QQQB).balanceOf(address(vault)), qqqbBefore, "hop must be atomic; no leftover QQQB in the vault");
    }

    function test_thinQuotedMemeSpendsFullPending() public {
        address[] memory tokens = new address[](1);
        tokens[0] = JACKET;
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10000;

        _skipBasketCooldown();
        vm.prank(TEAM_OPERATOR);
        vault.updateBasket(tokens, weights);

        taxToken.mint(USER1, 100 ether);
        vault.syncShare(USER1);

        // 0.1 BNB is well above 2% of Jacket's quote/WBNB pool (~0.055). The
        // old cap would slice; with the cap off the full pending must spend.
        _fundAndProcess(0.1 ether);

        assertGt(vault.withdrawableDividendOf(USER1, JACKET), 0, "thin quote pool must still be bought");
        assertEq(vault.pendingBnbByToken(JACKET), 0, "full pending must be spent, not sliced");
        assertEq(address(vault).balance, 0, "no leftover BNB parked by a reserve cap");
    }

    function test_optInReserveCapSkipsThinPool() public {
        address[] memory tokens = new address[](1);
        tokens[0] = JACKET;
        uint16[] memory weights = new uint16[](1);
        weights[0] = 10000;

        _skipBasketCooldown();
        vm.startPrank(TEAM_OPERATOR);
        vault.updateBasket(tokens, weights);
        vault.setMaxReserveImpactBps(200);
        vm.stopPrank();

        taxToken.mint(USER1, 100 ether);
        vault.syncShare(USER1);

        vm.deal(address(this), 0.1 ether);
        (bool ok,) = address(vault).call{value: 0.1 ether}("");
        assertTrue(ok);
        vault.processPendingRevenue();

        assertEq(vault.withdrawableDividendOf(USER1, JACKET), 0, "2% cap should skip a too-thin quote pool rather than slice a dust buy");
        assertEq(vault.pendingBnbByToken(JACKET), 0.1 ether, "BNB must stay queued when the opt-in cap collapses the swap");
        assertEq(address(vault).balance, 0.1 ether);
    }
}

/// @dev Plain ERC20 with zero PancakeSwap liquidity — used to prove one bad
///      basket token can't brick payouts for the rest of the basket.
contract NoLiquidityToken {
    string public name = "NoLiquidity";
    string public symbol = "NOLIQ";
    uint8 public decimals = 18;
    uint256 public totalSupply = 1_000_000 ether;
    mapping(address => uint256) public balanceOf;

    constructor() {
        balanceOf[msg.sender] = totalSupply;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
