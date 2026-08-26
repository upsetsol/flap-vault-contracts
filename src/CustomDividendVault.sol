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

/// @title CustomDividendVault
/// @notice Converts incoming tax revenue (native BNB) into a chosen ERC-20
///         dividend token and pays holders of `taxToken` pro-rata.
/// @dev Guardian address is NOT a constructor parameter — it is resolved on
///      every call via `_getGuardian()` from VaultBase, which returns Flap's
///      own security-team address per chain. This matches the mandate in
///      VaultBase.sol: "the Guardian must always retain a backup path to
///      call permissioned functions."
contract CustomDividendVault is VaultBaseV2, AccessControl, ReentrancyGuard {
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    uint256 private constant MAGNITUDE = 2 ** 128;

    address public taxToken;
    address public dividendToken;
    address public pancakeRouter;
    uint256 public minimumShareBalance;
    uint256 public totalEligibleSupply;

    uint256 private magnifiedDividendPerShare;
    mapping(address => int256) private magnifiedCorrections;
    mapping(address => uint256) private withdrawnDividends;
    mapping(address => uint256) private lastSyncedBalance;
    mapping(address => bool) public excludedFromDividends;

    bool private initialized;

    event DividendsDeposited(uint256 bnbIn, uint256 dividendTokenOut);
    event DividendClaimed(address indexed user, uint256 amount);
    event ShareSynced(address indexed user, uint256 newShare);

    error AlreadyInitialized();
    error SwapFailed();
    error NothingToClaim();

    /// @dev Non-upgradeable version: `newVault` deploys one instance per
    ///      token directly (no beacon proxy). Simpler to audit; the
    ///      recommended beacon-proxy pattern is the next step once this
    ///      is battle-tested — see FreeCoinVaultUpgradeable in this repo
    ///      for the beacon-based reference implementation.
    function initializeVault(
        address _taxToken,
        address _dividendToken,
        address _pancakeRouter,
        uint256 _minimumShareBalance
    ) external {
        if (initialized) revert AlreadyInitialized();
        initialized = true;

        taxToken = _taxToken;
        dividendToken = _dividendToken;
        pancakeRouter = _pancakeRouter;
        minimumShareBalance = _minimumShareBalance;

        address guardian = _getGuardian();
        _grantRole(DEFAULT_ADMIN_ROLE, guardian);
        _grantRole(OPERATOR_ROLE, guardian);
    }

    /// @dev MANDATE from VaultBase.sol: Guardian's role must never be
    ///      revocable by anyone but itself.
    function revokeRole(bytes32 role, address account) public override onlyRole(getRoleAdmin(role)) {
        if (account == _getGuardian()) revert CannotRevokeGuardianRole();
        super.revokeRole(role, account);
    }

    error CannotRevokeGuardianRole();

    receive() external payable {
        // If nobody has been synced yet, totalEligibleSupply is 0 — swapping
        // now would permanently orphan the proceeds (no share to attribute
        // them to). Just let the BNB sit here; call processPendingRevenue()
        // once at least one holder has been synced to convert it retroactively.
        if (totalEligibleSupply == 0) return;
        _swapAndDeposit(address(this).balance);
    }

    /// @notice Manually triggers conversion of whatever native BNB is
    ///         currently sitting in the vault into dividendToken, using the
    ///         CURRENT totalEligibleSupply. Exists to unstick funds that
    ///         arrived via receive() while totalEligibleSupply was still 0.
    ///         Permissionless — there's no way to misuse it to redirect
    ///         funds anywhere but the existing dividendToken.
    function processPendingRevenue() external nonReentrant {
        require(totalEligibleSupply > 0, "no eligible holders yet");
        require(address(this).balance > 0, "nothing pending");
        _swapAndDeposit(address(this).balance);
    }

    function _swapAndDeposit(uint256 bnbAmount) internal {
        address[] memory path = new address[](2);
        path[0] = IPancakeRouter(pancakeRouter).WETH();
        path[1] = dividendToken;

        uint256 balBefore = IERC20(dividendToken).balanceOf(address(this));

        try IPancakeRouter(pancakeRouter).swapExactETHForTokensSupportingFeeOnTransferTokens{value: bnbAmount}(
            0, path, address(this), block.timestamp + 300
        ) {
            uint256 received = IERC20(dividendToken).balanceOf(address(this)) - balBefore;
            if (received > 0 && totalEligibleSupply > 0) {
                magnifiedDividendPerShare += (received * MAGNITUDE) / totalEligibleSupply;
                emit DividendsDeposited(bnbAmount, received);
            }
        } catch {
            revert SwapFailed();
        }
    }

    /// @notice Refreshes `user`'s share to their current taxToken balance.
    ///         Anyone may call this for any address; it is safe and permissionless
    ///         because it only ever corrects a holder's own tracked share.
    function syncShare(address user) public {
        if (excludedFromDividends[user]) return;

        uint256 newBalance = IERC20(taxToken).balanceOf(user);
        if (newBalance < minimumShareBalance) newBalance = 0;

        uint256 oldBalance = lastSyncedBalance[user];
        if (newBalance == oldBalance) return;

        if (newBalance > oldBalance) {
            uint256 delta = newBalance - oldBalance;
            magnifiedCorrections[user] -= int256(magnifiedDividendPerShare * delta);
            totalEligibleSupply += delta;
        } else {
            uint256 delta = oldBalance - newBalance;
            magnifiedCorrections[user] += int256(magnifiedDividendPerShare * delta);
            totalEligibleSupply -= delta;
        }

        lastSyncedBalance[user] = newBalance;
        emit ShareSynced(user, newBalance);
    }

    function withdrawableDividendOf(address user) public view returns (uint256) {
        int256 magnified = int256(magnifiedDividendPerShare * lastSyncedBalance[user]) + magnifiedCorrections[user];
        if (magnified < 0) return 0;
        uint256 accumulative = uint256(magnified) / MAGNITUDE;
        if (accumulative < withdrawnDividends[user]) return 0;
        return accumulative - withdrawnDividends[user];
    }

    function claim() external nonReentrant {
        syncShare(msg.sender);

        uint256 owed = withdrawableDividendOf(msg.sender);
        if (owed == 0) revert NothingToClaim();

        withdrawnDividends[msg.sender] += owed;
        bool ok = IERC20(dividendToken).transfer(msg.sender, owed);
        require(ok, "transfer failed");

        emit DividendClaimed(msg.sender, owed);
    }

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

    function description() public pure override returns (string memory) {
        return "Custom dividend vault: converts incoming tax revenue to a chosen ERC-20 and pays holders pro-rata.";
    }

    function vaultUISchema() public pure override returns (VaultUISchema memory schema) {
        schema.vaultType = "CustomDividendVault";
        schema.description = "Pays holders dividends in a chosen ERC-20 token, funded by the token's own buy/sell tax.";

        schema.methods = new VaultMethodSchema[](3);

        schema.methods[0].name = "withdrawableDividendOf";
        schema.methods[0].description = "Returns the pending dividend amount for a given address.";
        schema.methods[0].inputs = new FieldDescriptor[](1);
        schema.methods[0].inputs[0] = FieldDescriptor("user", "address", "Address to check", 0);
        schema.methods[0].outputs = new FieldDescriptor[](1);
        schema.methods[0].outputs[0] = FieldDescriptor("amount", "uint256", "Pending dividend amount", 18);
        schema.methods[0].approvals = new ApproveAction[](0);

        schema.methods[1].name = "claim";
        schema.methods[1].description = "Claims all pending dividends for the caller.";
        schema.methods[1].inputs = new FieldDescriptor[](0);
        schema.methods[1].outputs = new FieldDescriptor[](0);
        schema.methods[1].approvals = new ApproveAction[](0);
        schema.methods[1].isWriteMethod = true;

        schema.methods[2].name = "syncShare";
        schema.methods[2].description = "Refreshes a holder's tracked share to their current token balance.";
        schema.methods[2].inputs = new FieldDescriptor[](1);
        schema.methods[2].inputs[0] = FieldDescriptor("user", "address", "Address to sync", 0);
        schema.methods[2].outputs = new FieldDescriptor[](0);
        schema.methods[2].approvals = new ApproveAction[](0);
        schema.methods[2].isWriteMethod = true;
    }
}

/// @title CustomDividendVaultFactory
/// @notice Deployed once. VaultPortal calls `newVault` for every new token
///         launch that selects this factory.
contract CustomDividendVaultFactory is VaultFactoryBaseV2 {
    address public immutable pancakeRouter;

    constructor(address _pancakeRouter) {
        pancakeRouter = _pancakeRouter;
    }

    /// @dev IMPORTANT (per IVaultFactory.sol): `taxToken` is a PREDICTED
    ///      address — the actual token contract does not exist yet when
    ///      this runs. Do not call any function on `taxToken` here.
    ///      vaultData = abi.encode(address dividendToken, uint256 minimumShareBalance)
    function newVault(address taxToken, address quoteToken, address, /* creator */ bytes calldata vaultData)
        external
        override
        returns (address vault)
    {
        require(msg.sender == _getVaultPortal(), "Only VaultPortal");
        require(quoteToken == address(0), "Only native BNB quote token supported");

        (address dividendToken, uint256 minimumShareBalance) = abi.decode(vaultData, (address, uint256));

        CustomDividendVault v = new CustomDividendVault();
        v.initializeVault(taxToken, dividendToken, pancakeRouter, minimumShareBalance);
        vault = address(v);
    }

    function isQuoteTokenSupported(address quoteToken) external pure override returns (bool supported) {
        supported = quoteToken == address(0);
    }

    function vaultDataSchema() public pure override returns (VaultDataSchema memory schema) {
        schema.description =
            "Creates a vault that pays holders dividends in any ERC-20 token, funded automatically by the token's tax revenue.";
        schema.fields = new FieldDescriptor[](2);
        schema.fields[0] = FieldDescriptor("dividendToken", "address", "ERC-20 token holders will receive as dividends", 0);
        schema.fields[1] = FieldDescriptor("minimumShareBalance", "uint256", "Minimum token balance to be eligible for dividends", 18);
        schema.isArray = false;
    }
}
