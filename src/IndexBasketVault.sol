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
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
    function getAmountsIn(uint256 amountOut, address[] calldata path) external view returns (uint256[] memory amounts);
}

interface IPancakeFactoryMinimal {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IPancakePairMinimal {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface ITaxTokenMainPool {
    function mainPool() external view returns (address);
}

interface IFlapQuotedToken {
    function quoteToken() external view returns (address);
}

/// @title IndexBasketVault
/// @notice "Meme index" vault: converts incoming tax revenue (BNB) into a
///         manually-curated basket of up to 5 tokens (weighted), and pays
///         holders of `taxToken` dividends in ALL basket tokens simultaneously,
///         proportional to their balance. Basket composition is set by the
///         team (OPERATOR_ROLE) — this contract does not attempt on-chain
///         "top runners" discovery or rug-filtering, since that judgment
///         cannot be done reliably on-chain.
/// @dev Native BNB in, basket tokens out. `receive()` only queues BNB;
///      swaps run in `processPendingRevenue`. Shares update on claim/sync,
///      not on every taxToken transfer. Changing the basket does not
///      liquidate already-bought reward tokens. Pancake V2: WBNB → token
///      when that pair exists, otherwise WBNB → quote → token.
contract IndexBasketVault is VaultBaseV3, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    uint256 private constant MAGNITUDE = 2 ** 128;
    uint256 private constant MAX_BASKET_SIZE = 5;
    uint16 private constant BPS_DENOMINATOR = 10000;
    uint16 private constant MAX_SLIPPAGE_BPS_CEILING = 500; // basket swap only; operator cannot widen MEV window
    uint16 private constant MAX_RESERVE_IMPACT_BPS_CEILING = 200; // opt-in cap; 0 default = do not slice thin pools
    uint256 public constant MIN_BASKET_UPDATE_COOLDOWN = 1 hours;
    uint256 public constant MAX_BASKET_UPDATE_COOLDOWN = 7 days;
    uint256 public constant MAX_MIN_BNB_TO_PROCESS = 100 ether;
    uint8 public constant MAX_EXTRA_PAIRS = 8;
    uint256 public constant MAX_DISTRIBUTE_BATCH = 100;

    address public taxToken;
    address public pancakeRouter;
    uint256 public minimumShareBalance;
    uint256 public totalEligibleSupply;

    /// @notice BNB collected while no basket existed yet — split into
    ///         `pendingBnbByToken` using CURRENT weights the next time
    ///         processPendingRevenue() runs (there's no prior allocation to
    ///         preserve fairness against, since no basket existed when it
    ///         arrived).
    uint256 public pendingBnbNoBasket;
    /// @notice BNB queued per basket token, allocated at receive() time using
    ///         the weights in effect then. Isolated per token so a failed
    ///         swap leftover does not mix into another token's share.
    mapping(address => uint256) public pendingBnbByToken;

    uint256 public minBnbToProcess = 0.03 ether; // per basket slot; skip dust swaps
    uint16 public maxSlippageBps = 500; // 5% default
    uint16 public maxReserveImpactBps = 0; // 0 = no size cap; 5% slippage still applies

    uint256 public lastBasketUpdateTime;
    uint256 public basketUpdateCooldown = MIN_BASKET_UPDATE_COOLDOWN;

    address[] public basketTokens;
    mapping(address => uint16) public basketWeightBps;
    /// @notice Optional hop override per basket token. `address(0)` = auto
    ///         (prefer a WBNB pair, else Flap `quoteToken()` / `mainPool`).
    ///         Set to WBNB to force a direct pair. Any other address is the
    ///         intermediate: BNB → hop → token.
    mapping(address => address) public basketQuote;

    address[] public extraPairs;
    mapping(address => bool) public isExtraPair;

    address[] public allRewardTokens;
    mapping(address => bool) public isKnownRewardToken;

    mapping(address => uint256) private magnifiedDividendPerShare; // per reward token
    mapping(address => mapping(address => int256)) private magnifiedCorrections; // token => user => correction
    mapping(address => mapping(address => uint256)) private withdrawnDividends; // token => user => withdrawn
    mapping(address => uint256) private lastSyncedBalance; // user => synced taxToken balance
    mapping(address => bool) public excludedFromDividends;

    /// @notice Lifetime accounting per reward token, used to compute how much
    ///         of the vault's balance is "reserved" (owed to holders) and
    ///         therefore off-limits to emergencyWithdrawToken.
    mapping(address => uint256) public totalDeposited;
    mapping(address => uint256) public totalClaimed;

    bool private initialized;

    event BasketUpdated(address[] tokens, uint16[] weightsBps);
    event BasketQuoteSet(address indexed token, address indexed quote);
    event DividendsDeposited(address indexed token, uint256 bnbIn, uint256 tokenOut);
    event DividendClaimed(address indexed user, address indexed token, uint256 amount);
    event ShareSynced(address indexed user, uint256 newShare);
    event SwapFailed(address indexed token, uint256 bnbAmount);
    event SwapSkipped(address indexed token, uint256 bnbAmount, string reason);
    event ExtraPairAdded(address indexed pair);
    event Excluded(address indexed account, bool excluded);
    event EmergencyWithdraw(address indexed token, uint256 amount, address indexed to);
    event Distributed(address indexed user, bool success);
    event ClaimTokenFailed(address indexed user, address indexed token);

    error AlreadyInitialized();
    error InvalidBasket();
    error NothingToClaim();
    error CannotRevokeGuardianRole();
    error GuardianOnly();
    error BasketUpdateCooldownActive();
    error ZeroAddress();
    error PairLimit();
    error PairAlreadySet();
    error NotAContract();

    modifier onlyGuardian() {
        if (msg.sender != _getGuardian()) revert GuardianOnly();
        _;
    }

    /// @param initialTokens Required initial basket. Empty launch is rejected
    ///        so tax BNB cannot sit unallocated and later dump into a
    ///        last-second team-chosen token.
    function initializeVault(
        address _taxToken,
        address _pancakeRouter,
        address _teamOperator,
        uint256 _minimumShareBalance,
        address[] calldata initialTokens,
        uint16[] calldata initialWeights
    ) external {
        if (initialized) revert AlreadyInitialized();
        if (_taxToken == address(0) || _pancakeRouter == address(0)) revert ZeroAddress();
        initialized = true;

        taxToken = _taxToken;
        pancakeRouter = _pancakeRouter;
        minimumShareBalance = _minimumShareBalance;

        address guardian = _getGuardian();
        _grantRole(DEFAULT_ADMIN_ROLE, guardian);
        _grantRole(OPERATOR_ROLE, guardian);
        // Team is operator only. Emergency withdraw is Guardian-gated.
        if (_teamOperator != address(0)) {
            _grantRole(OPERATOR_ROLE, _teamOperator);
        }

        _setBasket(initialTokens, initialWeights);
    }

    function revokeRole(bytes32 role, address account) public override onlyRole(getRoleAdmin(role)) {
        if (account == _getGuardian()) revert CannotRevokeGuardianRole();
        super.revokeRole(role, account);
    }

    /// @notice Native-only vault: this instance always accounts revenue in
    ///         the chain's native gas token (BNB), never an ERC20 quote.
    function vaultQuoteToken() public pure override returns (address) {
        return address(0);
    }

    // ------------------------------------------------------------------
    // Basket management — team sets which tokens are in the index right now
    // ------------------------------------------------------------------

    /// @notice Replace the current basket. Does not touch previously-acquired
    ///         reward tokens — those stay claimable at their old accrual rate.
    ///         Rate-limited by `basketUpdateCooldown`.
    /// @param tokens Up to 5 token addresses, no duplicates, no zero address,
    ///        and none of {taxToken, this vault, the router, WBNB}.
    /// @param weightsBps Matching weights in basis points; must sum to 10000,
    ///        and every individual weight must be > 0.
    function updateBasket(address[] calldata tokens, uint16[] calldata weightsBps) external onlyRole(OPERATOR_ROLE) {
        // forge-lint: disable-next-line(block-timestamp)
        // Validators can nudge block.timestamp by a few seconds; irrelevant
        // against a cooldown measured in hours (MIN_BASKET_UPDATE_COOLDOWN).
        if (block.timestamp < lastBasketUpdateTime + basketUpdateCooldown) revert BasketUpdateCooldownActive();
        _setBasket(tokens, weightsBps);
    }

    function setBasketUpdateCooldown(uint256 cooldown) external onlyRole(OPERATOR_ROLE) {
        require(cooldown >= MIN_BASKET_UPDATE_COOLDOWN, "cooldown below minimum");
        require(cooldown <= MAX_BASKET_UPDATE_COOLDOWN, "cooldown above maximum");
        basketUpdateCooldown = cooldown;
    }

    function _setBasket(address[] calldata tokens, uint16[] calldata weightsBps) internal {
        if (tokens.length == 0 || tokens.length > MAX_BASKET_SIZE || tokens.length != weightsBps.length) {
            revert InvalidBasket();
        }

        address weth = IPancakeRouter(pancakeRouter).WETH();

        uint16 total;
        for (uint256 i = 0; i < weightsBps.length; i++) {
            if (weightsBps[i] == 0) revert InvalidBasket();
            total += weightsBps[i];
            if (
                tokens[i] == address(0) || tokens[i] == taxToken || tokens[i] == address(this)
                    || tokens[i] == pancakeRouter || tokens[i] == weth
            ) revert InvalidBasket();
            for (uint256 j = i + 1; j < tokens.length; j++) {
                if (tokens[i] == tokens[j]) revert InvalidBasket();
            }
        }
        if (total != BPS_DENOMINATOR) revert InvalidBasket();

        for (uint256 i = 0; i < basketTokens.length; i++) {
            address oldToken = basketTokens[i];
            bool stillInBasket;
            for (uint256 j = 0; j < tokens.length; j++) {
                if (tokens[j] == oldToken) {
                    stillInBasket = true;
                    break;
                }
            }
            if (!stillInBasket) {
                uint256 leftover = pendingBnbByToken[oldToken];
                if (leftover > 0) {
                    pendingBnbNoBasket += leftover;
                    pendingBnbByToken[oldToken] = 0;
                }
            }
            basketWeightBps[oldToken] = 0;
        }

        delete basketTokens;
        for (uint256 i = 0; i < tokens.length; i++) {
            basketTokens.push(tokens[i]);
            basketWeightBps[tokens[i]] = weightsBps[i];
            _registerRewardToken(tokens[i]);
        }

        lastBasketUpdateTime = block.timestamp;
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

    /// @notice Sum of all BNB queued for swapping — the pre-basket bucket
    ///         plus every basket-token-specific bucket. Convenience view for
    ///         keepers/UIs; the per-token detail is in `pendingBnbByToken`.
    function totalPendingBnb() external view returns (uint256 total) {
        total = pendingBnbNoBasket;
        for (uint256 i = 0; i < allRewardTokens.length; i++) {
            total += pendingBnbByToken[allRewardTokens[i]];
        }
    }

    // ------------------------------------------------------------------
    // Swap safety parameters — operator-tunable within hard-coded ceilings
    // ------------------------------------------------------------------
    function extraPairCount() external view returns (uint256) {
        return extraPairs.length;
    }

    /// @notice Permanently exclude an extra DEX pair from dividends. Cannot be
    ///         removed — same one-way model as Flap's own mainPool exclusion.
    function addExtraPair(address pair_) external onlyRole(OPERATOR_ROLE) {
        if (pair_ == address(0)) revert ZeroAddress();
        if (pair_.code.length == 0) revert NotAContract();
        if (isExtraPair[pair_]) revert PairAlreadySet();
        if (extraPairs.length >= MAX_EXTRA_PAIRS) revert PairLimit();
        isExtraPair[pair_] = true;
        extraPairs.push(pair_);
        if (lastSyncedBalance[pair_] > 0) {
            _applyShareChange(pair_, 0);
        }
        emit ExtraPairAdded(pair_);
    }

    function setMaxSlippageBps(uint16 bps) external onlyRole(OPERATOR_ROLE) {
        require(bps <= MAX_SLIPPAGE_BPS_CEILING, "slippage above safety ceiling");
        maxSlippageBps = bps;
    }

    /// @notice Cap each swap to `bps` of the pair's WBNB (and hop-quote) reserve.
    ///         `0` disables the cap so thin Flap pools are bought in full.
    ///         Ceiling remains 2% — this cannot be used to widen a dump window
    ///         beyond the old safety rail; it can only turn slicing off.
    function setMaxReserveImpactBps(uint16 bps) external onlyRole(OPERATOR_ROLE) {
        require(bps <= MAX_RESERVE_IMPACT_BPS_CEILING, "impact above safety ceiling");
        maxReserveImpactBps = bps;
    }

    function setMinBnbToProcess(uint256 amount) external onlyRole(OPERATOR_ROLE) {
        require(amount <= MAX_MIN_BNB_TO_PROCESS, "min BNB above maximum");
        minBnbToProcess = amount;
    }

    /// @notice Set or clear the Pancake hop used to buy `token`. Does not
    ///         change basket membership. `quote == address(0)` restores auto
    ///         routing; `quote == WBNB` forces a direct WBNB pair.
    function setBasketQuote(address token, address quote) external onlyRole(OPERATOR_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        address weth = IPancakeRouter(pancakeRouter).WETH();
        if (quote != address(0) && quote != weth) {
            if (
                quote == token || quote == address(this) || quote == taxToken || quote == pancakeRouter
                    || quote.code.length == 0
            ) revert InvalidBasket();
        }
        basketQuote[token] = quote;
        emit BasketQuoteSet(token, quote);
    }

    // ------------------------------------------------------------------
    // Tax BNB: queue only. No swaps here — keep receive() cheap for Flap.
    // ------------------------------------------------------------------
    receive() external payable nonReentrant {
        if (basketTokens.length == 0) {
            pendingBnbNoBasket += msg.value;
            return;
        }

        uint256 allocated;
        for (uint256 i = 0; i < basketTokens.length; i++) {
            address token = basketTokens[i];
            uint256 share = (msg.value * basketWeightBps[token]) / BPS_DENOMINATOR;
            pendingBnbByToken[token] += share;
            allocated += share;
        }
        // Rounding dust (division truncation) — negligible, kept so no wei
        // is ever silently lost.
        if (msg.value > allocated) {
            pendingBnbNoBasket += (msg.value - allocated);
        }
    }

    /// @notice Manually triggers conversion of whatever native BNB is queued
    ///         into the basket, using CURRENT totalEligibleSupply. This is
    ///         the only place swaps happen. Permissionless — anyone (a
    ///         keeper bot, the team, a holder) can call it; the caller just
    ///         pays gas.
    function processPendingRevenue() external nonReentrant {
        require(totalEligibleSupply > 0, "no eligible holders yet");
        require(basketTokens.length > 0, "no basket set");

        // Carry forward any pre-basket accumulation using CURRENT weights.
        if (pendingBnbNoBasket > 0) {
            uint256 carry = pendingBnbNoBasket;
            pendingBnbNoBasket = 0;
            uint256 allocated;
            for (uint256 i = 0; i < basketTokens.length; i++) {
                address token = basketTokens[i];
                uint256 share = (carry * basketWeightBps[token]) / BPS_DENOMINATOR;
                pendingBnbByToken[token] += share;
                allocated += share;
            }
            if (carry > allocated) {
                pendingBnbNoBasket += (carry - allocated);
            }
        }

        bool processedAny;
        for (uint256 i = 0; i < basketTokens.length; i++) {
            address token = basketTokens[i];
            uint256 amount = pendingBnbByToken[token];
            if (amount == 0 || amount < minBnbToProcess) continue;

            pendingBnbByToken[token] = 0;
            uint256 processed = _swapAndDeposit(token, amount);
            uint256 leftover = amount - processed;
            if (leftover > 0) {
                // Leftover stays on this token's queue, not re-split.
                pendingBnbByToken[token] += leftover;
            }
            processedAny = true;
        }

        require(processedAny, "nothing pending");
    }

    function _swapAndDeposit(address token, uint256 bnbAmount) internal returns (uint256 processed) {
        address weth = IPancakeRouter(pancakeRouter).WETH();
        (address[] memory path, uint256 cappedAmount) = _buildPathAndCap(token, weth, bnbAmount);
        if (cappedAmount == 0 || path.length < 2) {
            emit SwapSkipped(token, bnbAmount, "capped to zero (no/low liquidity)");
            return 0;
        }

        uint256 minOut;
        try IPancakeRouter(pancakeRouter).getAmountsOut(cappedAmount, path) returns (uint256[] memory amounts) {
            uint256 expectedOut = amounts[amounts.length - 1];
            minOut = (expectedOut * (BPS_DENOMINATOR - maxSlippageBps)) / BPS_DENOMINATOR;
        } catch {
            emit SwapFailed(token, cappedAmount);
            return 0;
        }

        uint256 balBefore = IERC20(token).balanceOf(address(this));

        try IPancakeRouter(pancakeRouter).swapExactETHForTokensSupportingFeeOnTransferTokens{value: cappedAmount}(
            minOut, path, address(this), block.timestamp + 300
        ) {
            uint256 received = IERC20(token).balanceOf(address(this)) - balBefore;
            if (received > 0 && totalEligibleSupply > 0) {
                magnifiedDividendPerShare[token] += (received * MAGNITUDE) / totalEligibleSupply;
                totalDeposited[token] += received;
                emit DividendsDeposited(token, cappedAmount, received);
            }
            processed = cappedAmount;
        } catch {
            emit SwapFailed(token, cappedAmount);
            processed = 0;
        }
    }

    /// @dev Direct path `[WBNB, token]` when that pair has reserves; otherwise
    ///      `[WBNB, hop, token]` for Flap memes quoted in QQQB (or another ERC20).
    function _buildPathAndCap(address token, address weth, uint256 bnbAmount)
        internal
        view
        returns (address[] memory path, uint256 capped)
    {
        address factory;
        try IPancakeRouter(pancakeRouter).factory() returns (address f) {
            factory = f;
        } catch {
            return (path, 0);
        }

        address hop = _resolveHop(token, weth, factory);
        if (hop == address(0)) {
            path = new address[](2);
            path[0] = weth;
            path[1] = token;
            capped = _capBnbByWethReserve(factory, weth, token, bnbAmount);
            return (path, capped);
        }

        path = new address[](3);
        path[0] = weth;
        path[1] = hop;
        path[2] = token;
        capped = _capBnbByWethReserve(factory, weth, hop, bnbAmount);
        if (capped == 0) return (path, 0);
        capped = _capBnbByHopReserve(factory, weth, hop, token, capped);
    }

    /// @dev `address(0)` means buy on the WBNB pair. Non-zero is the intermediate.
    function _resolveHop(address token, address weth, address factory) internal view returns (address hop) {
        address overrideQuote = basketQuote[token];
        if (overrideQuote != address(0)) {
            return overrideQuote == weth ? address(0) : overrideQuote;
        }

        if (_tokenReserve(_getPair(factory, weth, token), weth) > 0) {
            return address(0);
        }

        hop = _inferQuote(token);
        if (hop == address(0) || hop == weth || hop == token || hop == taxToken || hop == address(this)) {
            return address(0);
        }
    }

    function _inferQuote(address token) internal view returns (address quote) {
        try IFlapQuotedToken(token).quoteToken() returns (address q) {
            if (q != address(0) && q != token) return q;
        } catch {}

        try ITaxTokenMainPool(token).mainPool() returns (address pool) {
            if (pool == address(0) || pool.code.length == 0) return address(0);
            try IPancakePairMinimal(pool).token0() returns (address t0) {
                try IPancakePairMinimal(pool).token1() returns (address t1) {
                    if (t0 == token) return t1;
                    if (t1 == token) return t0;
                } catch {}
            } catch {}
        } catch {}
    }

    function _capBnbByWethReserve(address factory, address weth, address other, uint256 bnbAmount)
        internal
        view
        returns (uint256)
    {
        uint256 wethReserve = _tokenReserve(_getPair(factory, weth, other), weth);
        if (wethReserve == 0) return 0;
        if (maxReserveImpactBps == 0) return bnbAmount;
        uint256 cap = (wethReserve * maxReserveImpactBps) / BPS_DENOMINATOR;
        return bnbAmount > cap ? cap : bnbAmount;
    }

    /// @dev When `maxReserveImpactBps > 0`, also bound the second hop to that
    ///      fraction of the quote sitting in the meme pair. `0` skips slicing.
    function _capBnbByHopReserve(address factory, address weth, address hop, address token, uint256 bnbAmount)
        internal
        view
        returns (uint256)
    {
        uint256 hopReserve = _tokenReserve(_getPair(factory, hop, token), hop);
        if (hopReserve == 0) return 0;
        if (maxReserveImpactBps == 0) return bnbAmount;
        uint256 maxHop = (hopReserve * maxReserveImpactBps) / BPS_DENOMINATOR;
        if (maxHop == 0) return 0;

        address[] memory p = new address[](2);
        p[0] = weth;
        p[1] = hop;
        try IPancakeRouter(pancakeRouter).getAmountsIn(maxHop, p) returns (uint256[] memory amounts) {
            uint256 need = amounts[0];
            return need < bnbAmount ? need : bnbAmount;
        } catch {
            return 0;
        }
    }

    function _getPair(address factory, address a, address b) internal view returns (address pair) {
        try IPancakeFactoryMinimal(factory).getPair(a, b) returns (address p) {
            pair = p;
        } catch {
            pair = address(0);
        }
    }

    function _tokenReserve(address pair, address token) internal view returns (uint256) {
        if (pair == address(0) || token == address(0)) return 0;
        try IPancakePairMinimal(pair).getReserves() returns (uint112 r0, uint112 r1, uint32) {
            try IPancakePairMinimal(pair).token0() returns (address t0) {
                if (t0 == token) return uint256(r0);
                try IPancakePairMinimal(pair).token1() returns (address t1) {
                    if (t1 == token) return uint256(r1);
                } catch {}
            } catch {}
        } catch {}
        return 0;
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
        if (isExtraPair[a]) return true;
        try ITaxTokenMainPool(taxToken).mainPool() returns (address pool) {
            if (pool != address(0) && a == pool) return true;
        } catch {}
        return false;
    }

    function _applyShareChange(address user, uint256 newBalance) internal {
        uint256 oldBalance = lastSyncedBalance[user];
        if (newBalance == oldBalance) return;

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
    ///         Uses SafeERC20 and credits the amount actually received.
    function claimToken(address token) public nonReentrant {
        _syncShare(msg.sender);
        uint256 owed = withdrawableDividendOf(msg.sender, token);
        if (owed == 0) revert NothingToClaim();

        uint256 balBefore = IERC20(token).balanceOf(msg.sender);
        IERC20(token).safeTransfer(msg.sender, owed);
        uint256 actuallyReceived = IERC20(token).balanceOf(msg.sender) - balBefore;
        if (actuallyReceived == 0) revert NothingToClaim();

        withdrawnDividends[token][msg.sender] += actuallyReceived;
        totalClaimed[token] += actuallyReceived;

        emit DividendClaimed(msg.sender, token, actuallyReceived);
    }

    function claimAll() external nonReentrant {
        if (!_claimAllFor(msg.sender)) revert NothingToClaim();
    }

    /// @notice Permissionless push distribution. See claimToken's NatSpec for
    ///         the SafeERC20 / fee-on-transfer handling that also applies here.
    /// @param users Addresses to push dividends to. Get this list off-chain —
    ///        the chain has no way to enumerate all taxToken holders. Passing
    ///        a protected address (pair/dead/vault/taxToken) is harmless.
    function distributeTo(address[] calldata users) external nonReentrant {
        require(users.length <= MAX_DISTRIBUTE_BATCH, "batch too large");
        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            if (_isProtectedAddress(user) || excludedFromDividends[user]) {
                emit Distributed(user, false);
                continue;
            }
            try this.pushClaimFor(user) {
                emit Distributed(user, true);
            } catch {
                emit Distributed(user, false);
            }
        }
    }

    function pushClaimFor(address user) external {
        require(msg.sender == address(this), "internal only");
        _claimAllFor(user);
    }

    function pushClaimToken(address user, address token) external {
        require(msg.sender == address(this), "internal only");
        _payoutToken(user, token);
    }

    function _claimAllFor(address user) internal returns (bool claimedAny) {
        _syncShare(user);
        for (uint256 i = 0; i < allRewardTokens.length; i++) {
            address token = allRewardTokens[i];
            uint256 owed = withdrawableDividendOf(user, token);
            if (owed == 0) continue;
            try this.pushClaimToken(user, token) {
                claimedAny = true;
            } catch {
                emit ClaimTokenFailed(user, token);
            }
        }
    }

    function _payoutToken(address user, address token) internal {
        uint256 owed = withdrawableDividendOf(user, token);
        if (owed == 0) revert NothingToClaim();

        uint256 balBefore = IERC20(token).balanceOf(user);
        IERC20(token).safeTransfer(user, owed);
        uint256 actuallyReceived = IERC20(token).balanceOf(user) - balBefore;
        if (actuallyReceived == 0) revert NothingToClaim();

        withdrawnDividends[token][user] += actuallyReceived;
        totalClaimed[token] += actuallyReceived;
        emit DividendClaimed(user, token, actuallyReceived);
    }

    // ------------------------------------------------------------------
    // Admin controls
    // ------------------------------------------------------------------
    function setExcludedFromDividends(address account, bool excluded) external onlyRole(OPERATOR_ROLE) {
        excludedFromDividends[account] = excluded;
        if (excluded) {
            _applyShareChange(account, 0);
        }
        emit Excluded(account, excluded);
    }

    function emergencyWithdrawToken(address token, uint256 amount, address to) external onlyGuardian {
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 reserved = totalDeposited[token] > totalClaimed[token] ? totalDeposited[token] - totalClaimed[token] : 0;
        uint256 available = balance > reserved ? balance - reserved : 0;
        require(amount <= available, "amount exceeds surplus; would touch reserved dividends");

        IERC20(token).safeTransfer(to, amount);
        emit EmergencyWithdraw(token, amount, to);
    }

    function emergencyWithdrawNative(uint256 amount, address to) external onlyGuardian {
        uint256 pending = pendingBnbNoBasket;
        for (uint256 i = 0; i < allRewardTokens.length; i++) {
            pending += pendingBnbByToken[allRewardTokens[i]];
        }
        uint256 available = address(this).balance > pending ? address(this).balance - pending : 0;
        require(amount <= available, "amount exceeds surplus; would touch pending dividend revenue");

        (bool ok,) = to.call{value: amount}("");
        require(ok, "withdraw failed");
        emit EmergencyWithdraw(address(0), amount, to);
    }

    // ------------------------------------------------------------------
    // VaultBase / VaultBaseV2 / VaultBaseV3 required overrides
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
        schema.methods[2].description =
            "Pushes pending dividends to a batch of addresses in one transaction. Anyone can call this, and the caller pays gas.";
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

    error WeightWithoutToken();
    error TokenWithoutWeight();
    error BasketRequired();

    constructor(address _pancakeRouter) {
        require(_pancakeRouter != address(0), "router required");
        require(IPancakeRouter(_pancakeRouter).WETH() != address(0), "router WETH missing");
        pancakeRouter = _pancakeRouter;
    }

    /// @dev vaultData = abi.encode(
    ///        address teamOperator, uint256 minimumShareBalance,
    ///        address token1, address token2, address token3, address token4, address token5,
    ///        uint16 weight1, uint16 weight2, uint16 weight3, uint16 weight4, uint16 weight5
    ///      ). Unused slots are address(0) + weight 0. Used weights must sum to 10000.
    ///      Five separate scalar fields so Flap.sh can render them (it cannot
    ///      render nested address[] inside a tuple).
    function newVault(
        address taxToken,
        address quoteToken,
        address,
        /* creator */
        bytes calldata vaultData
    )
        external
        override
        returns (address vault)
    {
        require(msg.sender == _getVaultPortal(), "Only VaultPortal");
        require(quoteToken == address(0), "Only native BNB quote token supported");

        (address teamOperator, uint256 minShare, address[] memory tokens, uint16[] memory weights) =
            _decodeAndPackBasket(vaultData);

        IndexBasketVault v = new IndexBasketVault();
        v.initializeVault(taxToken, pancakeRouter, teamOperator, minShare, tokens, weights);
        vault = address(v);
    }

    /// @dev Flap.sh cannot render nested arrays in vaultData. Slots are five
    ///      scalar token/weight pairs; unused = (address(0), 0).
    function _decodeAndPackBasket(bytes calldata vaultData)
        internal
        pure
        returns (address teamOperator, uint256 minShare, address[] memory tokens, uint16[] memory weights)
    {
        address t1;
        address t2;
        address t3;
        address t4;
        address t5;
        uint16 w1;
        uint16 w2;
        uint16 w3;
        uint16 w4;
        uint16 w5;
        (teamOperator, minShare, t1, t2, t3, t4, t5, w1, w2, w3, w4, w5) = abi.decode(
            vaultData, (address, uint256, address, address, address, address, address, uint16, uint16, uint16, uint16, uint16)
        );

        address[5] memory ts = [t1, t2, t3, t4, t5];
        uint16[5] memory ws = [w1, w2, w3, w4, w5];
        uint256 n;
        for (uint256 i; i < 5; i++) {
            if (ts[i] == address(0)) {
                if (ws[i] != 0) revert WeightWithoutToken();
            } else {
                if (ws[i] == 0) revert TokenWithoutWeight();
                n++;
            }
        }
        if (n == 0) revert BasketRequired();
        tokens = new address[](n);
        weights = new uint16[](n);
        uint256 j;
        for (uint256 i; i < 5; i++) {
            if (ts[i] == address(0)) continue;
            tokens[j] = ts[i];
            weights[j] = ws[i];
            j++;
        }
    }

    function isQuoteTokenSupported(address quoteToken) external pure override returns (bool supported) {
        supported = quoteToken == address(0);
    }

    /// @dev VaultPortal V3 validation; must match `VaultBaseV3`.
    function factorySpecVersion() public pure override returns (string memory) {
        return "v2.3";
    }

    function vaultDataSchema() public pure override returns (VaultDataSchema memory schema) {
        schema.description = "";
        schema.fields = new FieldDescriptor[](12);
        schema.fields[0] = FieldDescriptor("teamOperator", "address", "", 0);
        schema.fields[1] = FieldDescriptor("minimumShareBalance", "uint256", "", 18);
        schema.fields[2] = FieldDescriptor("token1", "address", "", 0);
        schema.fields[3] = FieldDescriptor("token2", "address", "", 0);
        schema.fields[4] = FieldDescriptor("token3", "address", "", 0);
        schema.fields[5] = FieldDescriptor("token4", "address", "", 0);
        schema.fields[6] = FieldDescriptor("token5", "address", "", 0);
        schema.fields[7] = FieldDescriptor("weight1", "uint16", "", 0);
        schema.fields[8] = FieldDescriptor("weight2", "uint16", "", 0);
        schema.fields[9] = FieldDescriptor("weight3", "uint16", "", 0);
        schema.fields[10] = FieldDescriptor("weight4", "uint16", "", 0);
        schema.fields[11] = FieldDescriptor("weight5", "uint16", "", 0);
        schema.isArray = false;
    }
}
