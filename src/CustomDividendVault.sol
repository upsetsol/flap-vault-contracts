// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {VaultBaseV3} from "./flap/VaultBaseV3.sol";
import {VaultFactoryBaseV2} from "./flap/VaultFactoryBaseV2.sol";
import {
    VaultUISchema,
    VaultMethodSchema,
    VaultDataSchema,
    FieldDescriptor,
    ApproveAction
} from "./flap/IVaultSchemasV1.sol";

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
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
    function factory() external pure returns (address);
    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);
}

interface IPancakeFactoryMinimal {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IPancakePairMinimal {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
}

interface ITaxTokenMainPool {
    function mainPool() external view returns (address);
}

/// @title CustomDividendVault
/// @notice Converts incoming tax revenue (native BNB) into a chosen ERC-20
///         dividend token and pays holders of `taxToken` pro-rata.
/// @dev Guardian address is NOT a constructor parameter — it is resolved on
///      every call via `_getGuardian()` from VaultBase, which returns Flap's
///      own security-team address per chain.
/// @dev SECURITY NOTE (post-review, see flap-vault-contracts-security-review.md):
///      Pass 1 fixes (Critical/High): receive()-only-accumulates (BOTH-01,
///      CDV-01), slippage floor + reserve cap + threshold (BOTH-02, BOTH-07),
///      Guardian-only emergency with reserved-balance protection (BOTH-10),
///      hard-excluded protected addresses (BOTH-03, BOTH-04, BOTH-12).
///      Pass 2 fixes (this revision):
///        - BOTH-09: SafeERC20 for all payouts, plus balance-delta
///          measurement so a fee-on-transfer dividend token can no longer
///          create a silent accounting/balance mismatch.
///        - BOTH-11 (partial): now extends `VaultBaseV3`, declares
///          `vaultQuoteToken() == address(0)` (native); factory advertises
///          `factorySpecVersion() == "v2.3"`.
///      IBV-02/IBV-03 don't apply here — this vault has a single, fixed
///      dividendToken set once at construction, not a mutable basket.
contract CustomDividendVault is VaultBaseV3, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    uint256 private constant MAGNITUDE = 2 ** 128;
    uint16 private constant BPS_DENOMINATOR = 10000;
    uint16 private constant MAX_SLIPPAGE_BPS_CEILING = 2000;
    uint16 private constant MAX_RESERVE_IMPACT_BPS_CEILING = 1000;

    address public taxToken;
    address public dividendToken;
    address public pancakeRouter;
    uint256 public minimumShareBalance;
    uint256 public totalEligibleSupply;

    uint256 public pendingBnb;
    uint256 public minBnbToProcess;
    uint16 public maxSlippageBps = 500;
    uint16 public maxReserveImpactBps = 200;

    uint256 private magnifiedDividendPerShare;
    mapping(address => int256) private magnifiedCorrections;
    mapping(address => uint256) private withdrawnDividends;
    mapping(address => uint256) private lastSyncedBalance;
    mapping(address => bool) public excludedFromDividends;

    uint256 public totalDeposited;
    uint256 public totalClaimed;

    bool private initialized;

    event DividendsDeposited(uint256 bnbIn, uint256 dividendTokenOut);
    event DividendClaimed(address indexed user, uint256 amount);
    event ShareSynced(address indexed user, uint256 newShare);
    event SwapFailed(uint256 bnbAmount);
    event SwapSkipped(uint256 bnbAmount, string reason);
    event Excluded(address indexed account, bool excluded);
    event EmergencyWithdraw(address indexed token, uint256 amount, address indexed to);

    error AlreadyInitialized();
    error NothingToClaim();
    error CannotRevokeGuardianRole();
    error GuardianOnly();

    modifier onlyGuardian() {
        if (msg.sender != _getGuardian()) revert GuardianOnly();
        _;
    }

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

    function revokeRole(bytes32 role, address account) public override onlyRole(getRoleAdmin(role)) {
        if (account == _getGuardian()) revert CannotRevokeGuardianRole();
        super.revokeRole(role, account);
    }

    /// @notice Native-only vault: always accounts revenue in BNB.
    function vaultQuoteToken() public pure override returns (address) {
        return address(0);
    }

    // ------------------------------------------------------------------
    // Swap safety parameters
    // ------------------------------------------------------------------
    function setMaxSlippageBps(uint16 bps) external onlyRole(OPERATOR_ROLE) {
        require(bps <= MAX_SLIPPAGE_BPS_CEILING, "slippage above safety ceiling");
        maxSlippageBps = bps;
    }

    function setMaxReserveImpactBps(uint16 bps) external onlyRole(OPERATOR_ROLE) {
        require(bps <= MAX_RESERVE_IMPACT_BPS_CEILING, "impact above safety ceiling");
        maxReserveImpactBps = bps;
    }

    function setMinBnbToProcess(uint256 amount) external onlyRole(OPERATOR_ROLE) {
        minBnbToProcess = amount;
    }

    // ------------------------------------------------------------------
    // Receives tax revenue — accumulates ONLY, never swaps here (BOTH-01)
    // ------------------------------------------------------------------
    receive() external payable nonReentrant {
        pendingBnb += msg.value;
    }

    function processPendingRevenue() external nonReentrant {
        require(totalEligibleSupply > 0, "no eligible holders yet");
        require(pendingBnb > 0, "nothing pending");
        require(pendingBnb >= minBnbToProcess, "below processing threshold");

        uint256 amountToProcess = pendingBnb;
        pendingBnb = 0;

        uint256 processed = _swapAndDeposit(amountToProcess);
        uint256 leftover = amountToProcess - processed;
        if (leftover > 0) {
            pendingBnb += leftover;
        }
    }

    function _swapAndDeposit(uint256 bnbAmount) internal returns (uint256 processed) {
        address weth = IPancakeRouter(pancakeRouter).WETH();

        uint256 cappedAmount = _capAgainstReserves(weth, bnbAmount);
        if (cappedAmount == 0) {
            emit SwapSkipped(bnbAmount, "capped to zero (no/low liquidity)");
            return 0;
        }

        address[] memory path = new address[](2);
        path[0] = weth;
        path[1] = dividendToken;

        uint256 minOut;
        try IPancakeRouter(pancakeRouter).getAmountsOut(cappedAmount, path) returns (uint256[] memory amounts) {
            uint256 expectedOut = amounts[amounts.length - 1];
            minOut = (expectedOut * (BPS_DENOMINATOR - maxSlippageBps)) / BPS_DENOMINATOR;
        } catch {
            emit SwapFailed(cappedAmount);
            return 0;
        }

        uint256 balBefore = IERC20(dividendToken).balanceOf(address(this));

        try IPancakeRouter(pancakeRouter).swapExactETHForTokensSupportingFeeOnTransferTokens{value: cappedAmount}(
            minOut, path, address(this), block.timestamp + 300
        ) {
            uint256 received = IERC20(dividendToken).balanceOf(address(this)) - balBefore;
            if (received > 0 && totalEligibleSupply > 0) {
                magnifiedDividendPerShare += (received * MAGNITUDE) / totalEligibleSupply;
                totalDeposited += received;
                emit DividendsDeposited(cappedAmount, received);
            }
            processed = cappedAmount;
        } catch {
            emit SwapFailed(cappedAmount);
            processed = 0;
        }
    }

    function _capAgainstReserves(address weth, uint256 bnbAmount) internal view returns (uint256) {
        address factory;
        try IPancakeRouter(pancakeRouter).factory() returns (address f) {
            factory = f;
        } catch {
            return bnbAmount;
        }

        address pair;
        try IPancakeFactoryMinimal(factory).getPair(weth, dividendToken) returns (address p) {
            pair = p;
        } catch {
            return bnbAmount;
        }
        if (pair == address(0)) return bnbAmount;

        try IPancakePairMinimal(pair).getReserves() returns (uint112 r0, uint112 r1, uint32) {
            address token0;
            try IPancakePairMinimal(pair).token0() returns (address t0) {
                token0 = t0;
            } catch {
                return bnbAmount;
            }
            uint256 wethReserve = token0 == weth ? uint256(r0) : uint256(r1);
            uint256 cap = (wethReserve * maxReserveImpactBps) / BPS_DENOMINATOR;
            return bnbAmount > cap ? cap : bnbAmount;
        } catch {
            return bnbAmount;
        }
    }

    // ------------------------------------------------------------------
    // Share sync
    // ------------------------------------------------------------------
    function syncShare(address user) external nonReentrant {
        _syncShare(user);
    }

    function _syncShare(address user) internal {
        if (excludedFromDividends[user] || _isProtectedAddress(user)) {
            _applyShareChange(user, 0);
            return;
        }

        uint256 newBalance = IERC20(taxToken).balanceOf(user);
        if (newBalance < minimumShareBalance) newBalance = 0;
        _applyShareChange(user, newBalance);
    }

    function _isProtectedAddress(address a) internal view returns (bool) {
        if (a == address(this) || a == taxToken || a == address(0) || a == address(0xdEaD)) return true;
        try ITaxTokenMainPool(taxToken).mainPool() returns (address pool) {
            if (pool != address(0) && a == pool) return true;
        } catch {}
        return false;
    }

    function _applyShareChange(address user, uint256 newBalance) internal {
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

    /// @notice SECURITY FIX (BOTH-09): SafeERC20 + balance-delta measurement
    ///         so a fee-on-transfer dividendToken can't create a silent
    ///         accounting/balance mismatch.
    function claim() external nonReentrant {
        _syncShare(msg.sender);

        uint256 owed = withdrawableDividendOf(msg.sender);
        if (owed == 0) revert NothingToClaim();

        uint256 balBefore = IERC20(dividendToken).balanceOf(msg.sender);
        IERC20(dividendToken).safeTransfer(msg.sender, owed);
        uint256 actuallyReceived = IERC20(dividendToken).balanceOf(msg.sender) - balBefore;

        withdrawnDividends[msg.sender] += actuallyReceived;
        totalClaimed += actuallyReceived;

        emit DividendClaimed(msg.sender, actuallyReceived);
    }

    function setExcludedFromDividends(address account, bool excluded) external onlyRole(OPERATOR_ROLE) {
        excludedFromDividends[account] = excluded;
        if (excluded) {
            _applyShareChange(account, 0);
        }
        emit Excluded(account, excluded);
    }

    function emergencyWithdrawToken(address token, uint256 amount, address to) external onlyGuardian {
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 reserved = token == dividendToken && totalDeposited > totalClaimed ? totalDeposited - totalClaimed : 0;
        uint256 available = balance > reserved ? balance - reserved : 0;
        require(amount <= available, "amount exceeds surplus; would touch reserved dividends");

        IERC20(token).safeTransfer(to, amount);
        emit EmergencyWithdraw(token, amount, to);
    }

    function emergencyWithdrawNative(uint256 amount, address to) external onlyGuardian {
        uint256 available = address(this).balance > pendingBnb ? address(this).balance - pendingBnb : 0;
        require(amount <= available, "amount exceeds surplus; would touch pending dividend revenue");

        (bool ok,) = to.call{value: amount}("");
        require(ok, "withdraw failed");
        emit EmergencyWithdraw(address(0), amount, to);
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

    /// @dev vaultData = abi.encode(address dividendToken, uint256 minimumShareBalance)
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

    /// @dev BOTH-11: v2.3 so the VaultPortal applies the V3 validation flow.
    function factorySpecVersion() public pure override returns (string memory) {
        return "v2.3";
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
