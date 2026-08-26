// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {VaultBaseV2} from "./flap/VaultBaseV2.sol";
import {VaultFactoryBaseV2} from "./flap/VaultFactoryBaseV2.sol";
import {IVaultFactoryValidationV2} from "./flap/IVaultFactory.sol";
import {
    VaultUISchema,
    VaultMethodSchema,
    VaultDataSchema,
    FieldDescriptor,
    ApproveAction
} from "./flap/IVaultSchemasV1.sol";

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {AccessControl} from "@openzeppelin/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/security/ReentrancyGuard.sol";

interface IPancakeRouter {
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;

    function WETH() external pure returns (address);
}

/// @title IndexBasketVault
/// @notice "Meme index" vault: converts incoming tax revenue (BNB) into a
///         manually-curated basket of up to 5 tokens (weighted), and pays
///         holders of `taxToken` dividends in ALL basket tokens simultaneously,
///         proportional to their balance. Basket composition is set by the
///         team (OPERATOR_ROLE) — this contract does not attempt on-chain
///         "top runners" discovery or rug-filtering, since that judgment
///         cannot be done reliably on-chain.
/// @dev Share sync model matches CustomDividendVault: a holder's share is
///      refreshed to their current taxToken balance at claim() time (or via
///      permissionless syncShare()), not on every transfer — see prior
///      discussion on why custom vaults can't get Dust's live transfer hook.
///      Changing the basket does NOT liquidate previously-acquired reward
///      tokens; past accruals remain claimable in their original denomination.
contract IndexBasketVault is VaultBaseV2, AccessControl, ReentrancyGuard {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    uint256 private constant MAGNITUDE = 2 ** 128;
    uint256 private constant MAX_BASKET_SIZE = 5;
    uint16 private constant BPS_DENOMINATOR = 10000;

    address public taxToken;
    address public pancakeRouter;
    uint256 public minimumShareBalance;
    uint256 public totalEligibleSupply;

    address[] public basketTokens;
    mapping(address => uint16) public basketWeightBps;

    address[] public allRewardTokens;
    mapping(address => bool) public isKnownRewardToken;

    mapping(address => uint256) private magnifiedDividendPerShare; // per reward token
    mapping(address => mapping(address => int256)) private magnifiedCorrections; // token => user => correction
    mapping(address => mapping(address => uint256)) private withdrawnDividends; // token => user => withdrawn
    mapping(address => uint256) private lastSyncedBalance; // user => synced taxToken balance
    mapping(address => bool) public excludedFromDividends;

    bool private initialized;

    event BasketUpdated(address[] tokens, uint16[] weightsBps);
    event DividendsDeposited(address indexed token, uint256 bnbIn, uint256 tokenOut);
    event DividendClaimed(address indexed user, address indexed token, uint256 amount);
    event ShareSynced(address indexed user, uint256 newShare);
    event SwapFailed(address indexed token, uint256 bnbAmount);

    error AlreadyInitialized();
    error InvalidBasket();
    error NothingToClaim();
    error CannotRevokeGuardianRole();

    function initializeVault(address _taxToken, address _pancakeRouter, address _teamOperator, uint256 _minimumShareBalance)
        external
    {
        if (initialized) revert AlreadyInitialized();
        initialized = true;

        taxToken = _taxToken;
        pancakeRouter = _pancakeRouter;
        minimumShareBalance = _minimumShareBalance;

        address guardian = _getGuardian();
        _grantRole(DEFAULT_ADMIN_ROLE, guardian);
        _grantRole(OPERATOR_ROLE, guardian);
        if (_teamOperator != address(0)) {
            _grantRole(DEFAULT_ADMIN_ROLE, _teamOperator);
            _grantRole(OPERATOR_ROLE, _teamOperator);
        }
    }

    function revokeRole(bytes32 role, address account) public override onlyRole(getRoleAdmin(role)) {
        if (account == _getGuardian()) revert CannotRevokeGuardianRole();
        super.revokeRole(role, account);
    }

    // ------------------------------------------------------------------
    // Basket management — team sets which tokens are in the index right now
    // ------------------------------------------------------------------

    /// @notice Replace the current basket. Does not touch previously-acquired
    ///         reward tokens — those stay claimable at their old accrual rate.
    /// @param tokens Up to 5 token addresses, no duplicates, no zero address.
    /// @param weightsBps Matching weights in basis points; must sum to 10000.
    function updateBasket(address[] calldata tokens, uint16[] calldata weightsBps) external onlyRole(OPERATOR_ROLE) {
        if (tokens.length == 0 || tokens.length > MAX_BASKET_SIZE || tokens.length != weightsBps.length) {
            revert InvalidBasket();
        }

        uint16 total;
        for (uint256 i = 0; i < weightsBps.length; i++) {
            total += weightsBps[i];
            if (tokens[i] == address(0)) revert InvalidBasket();
            for (uint256 j = i + 1; j < tokens.length; j++) {
                if (tokens[i] == tokens[j]) revert InvalidBasket();
            }
        }
        if (total != BPS_DENOMINATOR) revert InvalidBasket();

        // clear old weights so a token dropped from the basket stops accruing
        for (uint256 i = 0; i < basketTokens.length; i++) {
            basketWeightBps[basketTokens[i]] = 0;
        }

        delete basketTokens;
        for (uint256 i = 0; i < tokens.length; i++) {
            basketTokens.push(tokens[i]);
            basketWeightBps[tokens[i]] = weightsBps[i];
            _registerRewardToken(tokens[i]);
        }

        emit BasketUpdated(tokens, weightsBps);
    }

    function _registerRewardToken(address token) internal {
        if (!isKnownRewardToken[token]) {
            isKnownRewardToken[token] = true;
            allRewardTokens.push(token);
        }
    }

    function basketLength() external view returns (uint256) {
        return basketTokens.length;
    }

    function rewardTokenCount() external view returns (uint256) {
        return allRewardTokens.length;
    }

    // ------------------------------------------------------------------
    // Receives tax revenue, splits it across the basket by weight, swaps
    // ------------------------------------------------------------------
    receive() external payable {
        // If nobody has been synced yet, totalEligibleSupply is 0 — swapping
        // now would permanently orphan the proceeds (no share to attribute
        // them to). Just let the BNB sit here; call processPendingRevenue()
        // once at least one holder has been synced (e.g. after the first
        // claim or the first distributeTo run) to convert it retroactively.
        if (totalEligibleSupply == 0) return;
        _processBnbBalance();
    }

    /// @notice Manually triggers conversion of whatever native BNB is
    ///         currently sitting in the vault into the basket, using the
    ///         CURRENT totalEligibleSupply. Exists to unstick funds that
    ///         arrived via receive() while totalEligibleSupply was still 0
    ///         (e.g. tax dispatched before the first holder was ever synced).
    ///         Permissionless — anyone can call it, there's no way to misuse
    ///         it to redirect funds anywhere but the existing basket.
    function processPendingRevenue() external nonReentrant {
        require(totalEligibleSupply > 0, "no eligible holders yet");
        require(address(this).balance > 0, "nothing pending");
        _processBnbBalance();
    }

    function _processBnbBalance() internal {
        uint256 balance = address(this).balance;
        if (balance == 0 || basketTokens.length == 0) return;

        for (uint256 i = 0; i < basketTokens.length; i++) {
            address token = basketTokens[i];
            uint256 share = (balance * basketWeightBps[token]) / BPS_DENOMINATOR;
            if (share == 0) continue;
            _swapAndDeposit(token, share);
        }
    }

    function _swapAndDeposit(address token, uint256 bnbAmount) internal {
        address[] memory path = new address[](2);
        path[0] = IPancakeRouter(pancakeRouter).WETH();
        path[1] = token;

        uint256 balBefore = IERC20(token).balanceOf(address(this));

        try IPancakeRouter(pancakeRouter).swapExactETHForTokensSupportingFeeOnTransferTokens{value: bnbAmount}(
            0, path, address(this), block.timestamp + 300
        ) {
            uint256 received = IERC20(token).balanceOf(address(this)) - balBefore;
            if (received > 0 && totalEligibleSupply > 0) {
                magnifiedDividendPerShare[token] += (received * MAGNITUDE) / totalEligibleSupply;
                emit DividendsDeposited(token, bnbAmount, received);
            }
        } catch {
            // Don't let one bad token in the basket brick tax dispatch for the
            // others — funds simply stay as BNB in the vault. Team can retry
            // via emergencyWithdrawNative + manual handling if this persists.
            emit SwapFailed(token, bnbAmount);
        }
    }

    // ------------------------------------------------------------------
    // Share sync — same claim-time model as CustomDividendVault
    // ------------------------------------------------------------------
    function syncShare(address user) public {
        if (excludedFromDividends[user]) return;

        uint256 newBalance = IERC20(taxToken).balanceOf(user);
        if (newBalance < minimumShareBalance) newBalance = 0;

        uint256 oldBalance = lastSyncedBalance[user];
        if (newBalance == oldBalance) return;

        // apply the same balance delta to every reward token's correction ledger
        for (uint256 i = 0; i < allRewardTokens.length; i++) {
            address token = allRewardTokens[i];
            if (newBalance > oldBalance) {
                uint256 delta = newBalance - oldBalance;
                magnifiedCorrections[token][user] -= int256(magnifiedDividendPerShare[token] * delta);
            } else {
                uint256 delta = oldBalance - newBalance;
                magnifiedCorrections[token][user] += int256(magnifiedDividendPerShare[token] * delta);
            }
        }

        if (newBalance > oldBalance) {
            totalEligibleSupply += (newBalance - oldBalance);
        } else {
            totalEligibleSupply -= (oldBalance - newBalance);
        }

        lastSyncedBalance[user] = newBalance;
        emit ShareSynced(user, newBalance);
    }

    function withdrawableDividendOf(address user, address token) public view returns (uint256) {
        int256 magnified =
            int256(magnifiedDividendPerShare[token] * lastSyncedBalance[user]) + magnifiedCorrections[token][user];
        if (magnified < 0) return 0;
        uint256 accumulative = uint256(magnified) / MAGNITUDE;
        if (accumulative < withdrawnDividends[token][user]) return 0;
        return accumulative - withdrawnDividends[token][user];
    }

    /// @notice Claim pending dividends in a single reward token.
    function claimToken(address token) public nonReentrant {
        syncShare(msg.sender);
        uint256 owed = withdrawableDividendOf(msg.sender, token);
        if (owed == 0) revert NothingToClaim();

        withdrawnDividends[token][msg.sender] += owed;
        bool ok = IERC20(token).transfer(msg.sender, owed);
        require(ok, "transfer failed");

        emit DividendClaimed(msg.sender, token, owed);
    }

    /// @notice Claim pending dividends across every reward token ever used,
    ///         including ones no longer in the active basket.
    function claimAll() external nonReentrant {
        if (!_claimAllFor(msg.sender)) revert NothingToClaim();
    }

    /// @notice Permissionless push distribution — pays out every user in the
    ///         list across all reward tokens in one transaction. Anyone can
    ///         call this (team keeper, a bot, or a community member); the
    ///         caller just pays the gas. One user having nothing pending, or
    ///         one reward token failing to transfer to a given address (e.g.
    ///         a blacklist on that specific token), does not block payouts
    ///         to the rest of the batch.
    /// @param users Addresses to push dividends to. Get this list off-chain
    ///        (BscScan holder export, Bitquery, your own indexer) — the
    ///        chain itself has no way to enumerate all taxToken holders.
    function distributeTo(address[] calldata users) external nonReentrant {
        for (uint256 i = 0; i < users.length; i++) {
            try this.pushClaimFor(users[i]) {} catch {}
        }
    }

    /// @dev External wrapper so distributeTo can try/catch per-user failures.
    ///      Not meant to be called directly — use claimAll() or distributeTo().
    function pushClaimFor(address user) external {
        require(msg.sender == address(this), "internal only");
        _claimAllFor(user);
    }

    function _claimAllFor(address user) internal returns (bool claimedAny) {
        syncShare(user);
        for (uint256 i = 0; i < allRewardTokens.length; i++) {
            address token = allRewardTokens[i];
            uint256 owed = withdrawableDividendOf(user, token);
            if (owed == 0) continue;

            withdrawnDividends[token][user] += owed;
            bool ok = IERC20(token).transfer(user, owed);
            require(ok, "transfer failed");
            emit DividendClaimed(user, token, owed);
            claimedAny = true;
        }
    }

    // ------------------------------------------------------------------
    // Guardian-gated admin controls
    // ------------------------------------------------------------------
    function setExcludedFromDividends(address account, bool excluded) external onlyRole(OPERATOR_ROLE) {
        excludedFromDividends[account] = excluded;
    }

    function emergencyWithdrawToken(address token, uint256 amount, address to) external onlyRole(OPERATOR_ROLE) {
        bool ok = IERC20(token).transfer(to, amount);
        require(ok, "transfer failed");
    }

    function emergencyWithdrawNative(uint256 amount, address to) external onlyRole(OPERATOR_ROLE) {
        (bool ok,) = to.call{value: amount}("");
        require(ok, "withdraw failed");
    }

    // ------------------------------------------------------------------
    // VaultBase / VaultBaseV2 required overrides
    // ------------------------------------------------------------------
    function description() public pure override returns (string memory) {
        return "Meme index vault: buys back a team-curated basket of up to 5 tokens with tax revenue and pays holders in all of them.";
    }

    function vaultUISchema() public pure override returns (VaultUISchema memory schema) {
        schema.vaultType = "IndexBasketVault";
        schema.description = "Pays holders dividends across a curated basket of up to 5 tokens, funded by tax revenue.";

        schema.methods = new VaultMethodSchema[](4);

        schema.methods[0].name = "withdrawableDividendOf";
        schema.methods[0].description = "Returns pending dividends for a user in a specific reward token.";
        schema.methods[0].inputs = new FieldDescriptor[](2);
        schema.methods[0].inputs[0] = FieldDescriptor("user", "address", "Address to check", 0);
        schema.methods[0].inputs[1] = FieldDescriptor("token", "address", "Reward token to check", 0);
        schema.methods[0].outputs = new FieldDescriptor[](1);
        schema.methods[0].outputs[0] = FieldDescriptor("amount", "uint256", "Pending amount", 18);
        schema.methods[0].approvals = new ApproveAction[](0);

        schema.methods[1].name = "claimAll";
        schema.methods[1].description = "Claims all pending dividends across every reward token for the caller.";
        schema.methods[1].inputs = new FieldDescriptor[](0);
        schema.methods[1].outputs = new FieldDescriptor[](0);
        schema.methods[1].approvals = new ApproveAction[](0);
        schema.methods[1].isWriteMethod = true;

        schema.methods[2].name = "distributeTo";
        schema.methods[2].description = "Pushes pending dividends to a batch of addresses in one transaction. Anyone can call this, and the caller pays gas.";
        schema.methods[2].inputs = new FieldDescriptor[](1);
        schema.methods[2].inputs[0] = FieldDescriptor("users", "address", "Addresses to distribute to", 0);
        schema.methods[2].isInputArray = true;
        schema.methods[2].outputs = new FieldDescriptor[](0);
        schema.methods[2].approvals = new ApproveAction[](0);
        schema.methods[2].isWriteMethod = true;

        schema.methods[3].name = "syncShare";
        schema.methods[3].description = "Refreshes a holder's tracked share to their current token balance.";
        schema.methods[3].inputs = new FieldDescriptor[](1);
        schema.methods[3].inputs[0] = FieldDescriptor("user", "address", "Address to sync", 0);
        schema.methods[3].outputs = new FieldDescriptor[](0);
        schema.methods[3].approvals = new ApproveAction[](0);
        schema.methods[3].isWriteMethod = true;
    }
}

/// @title IndexBasketVaultFactory
contract IndexBasketVaultFactory is VaultFactoryBaseV2 {
    address public immutable pancakeRouter;

    constructor(address _pancakeRouter) {
        pancakeRouter = _pancakeRouter;
    }

    /// @dev vaultData = abi.encode(address teamOperator, uint256 minimumShareBalance)
    ///      Initial basket is empty — team calls updateBasket() right after launch.
    function newVault(address taxToken, address quoteToken, address, /* creator */ bytes calldata vaultData)
        external
        override
        returns (address vault)
    {
        require(msg.sender == _getVaultPortal(), "Only VaultPortal");
        require(quoteToken == address(0), "Only native BNB quote token supported");

        (address teamOperator, uint256 minimumShareBalance) = abi.decode(vaultData, (address, uint256));

        IndexBasketVault v = new IndexBasketVault();
        v.initializeVault(taxToken, pancakeRouter, teamOperator, minimumShareBalance);
        vault = address(v);
    }

    function isQuoteTokenSupported(address quoteToken) external pure override returns (bool supported) {
        supported = quoteToken == address(0);
    }

    function vaultDataSchema() public pure override returns (VaultDataSchema memory schema) {
        schema.description =
            "Creates an index-basket vault: pays holders dividends in a team-curated basket of up to 5 tokens.";
        schema.fields = new FieldDescriptor[](2);
        schema.fields[0] = FieldDescriptor("teamOperator", "address", "Address allowed to update the basket", 0);
        schema.fields[1] = FieldDescriptor("minimumShareBalance", "uint256", "Minimum token balance to be eligible for dividends", 18);
        schema.isArray = false;
    }
}
