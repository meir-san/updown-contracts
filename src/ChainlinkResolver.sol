// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {IUpDownSettlement} from "./interfaces/IUpDownSettlement.sol";
import {IVerifierProxy, IFeeManager, FeeManagerAsset, ReportV3} from "./interfaces/IVerifierProxy.sol";

/// @title ChainlinkResolver
/// @notice Reads Chainlink price data and resolves UpDown markets via
///         `UpDownSettlement.resolve`. Resolution is permissionless — anyone
///         can submit a valid Data Streams report and the outcome is
///         deterministic (UP if price > strike, else DOWN; tie => DOWN).
///
///         Price sources after the 2026-05-13 Data Streams swap:
///         - **Strike at create-time** (`getPrice` / `_getLatestPrice`):
///           Chainlink Data Feeds via `AggregatorV3Interface` (legacy
///           push-based aggregator). Strike is a fixed bet anchor and
///           1-hour staleness tolerance is acceptable.
///         - **Settlement at resolve-time** (`resolve`): Chainlink Data
///           Streams via `IVerifierProxy.verify` (pull-based, sub-second
///           freshness). Submitted as a signed `ReportV3` blob fetched
///           off-chain from the Data Streams REST API and verified +
///           paid for on-chain. See `audit-fixes/DATA_STREAMS_INVESTIGATION.md`.
///
///         LINK fee model is Option A from the design pre-discussion
///         (gate-approved 2026-05-13): the resolver holds its own LINK
///         balance, ops tops up via direct transfer, owner clawback via
///         `withdrawLink`. Separate trust boundary from the rebate
///         rebuild's treasury approval pattern (which lives on USDT).
contract ChainlinkResolver is Ownable {
    using SafeERC20 for IERC20;

    // ── Errors ──────────────────────────────────────────────────────────
    error FeedNotConfigured();
    error SequencerDown();
    error SequencerGracePeriod();
    error StalePrice();
    error MarketNotRegistered();
    error MarketNotExpired();
    error AlreadyResolved();
    error TrustedSettlementMismatch();
    error ZeroTrustedSettlement();
    error ZeroAddress();
    /// @notice Streams swap (2026-05-13): caller submitted a report for a
    ///         pair that has no streams feed-id configured. Configure via
    ///         `configureStreamsFeed(pairId, feedId)` before any market
    ///         in that pair can resolve.
    error StreamsFeedNotConfigured();
    /// @notice Streams swap: report's `feedId` does not match the
    ///         `streamsFeedId` registered for the market's pair. Off-chain
    ///         caller fetched a report for the wrong stream — the
    ///         resolver refuses to use it.
    error ReportFeedIdMismatch(bytes32 want, bytes32 have);
    /// @notice Streams swap: report's `expiresAt` is in the past. The
    ///         Verifier Proxy itself would also reject, but we check
    ///         pre-call to fail loudly with a typed error before
    ///         attempting the fee approval.
    error ReportExpired(uint256 expiresAt, uint256 nowTs);
    /// @notice Streams swap: report's `observationsTimestamp` is outside
    ///         the window `[endTime - MAX_REPORT_OBSERVATION_LAG, endTime]`.
    ///         Either too old (DON observed before our market window
    ///         opened — pre-PR-Streams Data Feeds equivalent of
    ///         `updatedAt < endTime - MAX_STALENESS`) or in the future
    ///         (DON observed AFTER the market closed — would reflect a
    ///         post-close price). The resolver refuses to resolve on a
    ///         report observed outside the bracket.
    error ReportObservationOutOfWindow(uint256 endTime, uint256 observationsTimestamp);
    /// @notice Streams-strike (2026-05-16): report's `observationsTimestamp`
    ///         is outside the symmetric ±MAX_STRIKE_REPORT_LAG window
    ///         around the market's `startTime`. Either too old (observed
    ///         before slot boundary by >tolerance) or too far in the
    ///         future (observed after slot boundary by >tolerance). The
    ///         strike anchor is the slot's clock-aligned boundary, so
    ///         observations must be tight around it.
    error ReportObservationOutOfStrikeWindow(uint64 startTime, uint256 observationsTimestamp);
    /// @notice Streams-strike: (pairId, startTime) tuple has already had
    ///         its strike captured. Replay protection — the cycler enforces
    ///         per-slot uniqueness via `pairTfLastCreated`, this is
    ///         defense-in-depth at the Resolver layer so a malformed
    ///         performData (or future external caller) cannot reset the
    ///         strike for an existing slot.
    error StrikeAlreadyCaptured(bytes32 pairId, uint64 startTime);

    // ── Events ──────────────────────────────────────────────────────────
    event FeedConfigured(bytes32 indexed pairId, address feed);
    event MarketRegistered(uint256 indexed marketId, address indexed settlement, bytes32 indexed pairId, int256 strikePrice);
    event MarketResolved(uint256 indexed marketId, uint256 winningOption, int256 settlementPrice, int256 strikePrice);
    event AuthorizedCallerSet(address indexed caller, bool authorized);
    /// @notice Streams swap: emitted on `configureStreamsFeed`. Off-chain
    ///         indexers track per-pair stream-id assignments for ops
    ///         monitoring and the `ChainlinkResolverService` config
    ///         reconciliation.
    event StreamsFeedConfigured(bytes32 indexed pairId, bytes32 feedId);
    /// @notice Streams-strike (2026-05-16): emitted on `captureStrike` —
    ///         records the per-slot strike value derived from a verified
    ///         Streams report. Indexed by `(pairId, startTime)` so off-
    ///         chain consumers can reconstruct the strike of any historic
    ///         slot from chain logs alone. `observationsTimestamp` lets
    ///         consumers audit the report-vs-slot-boundary lag (must be
    ///         within MAX_STRIKE_REPORT_LAG per the validator below).
    event StrikeCaptured(
        bytes32 indexed pairId,
        uint64 indexed startTime,
        int256 strikePrice,
        uint64 observationsTimestamp
    );
    /// @notice Streams swap: emitted on `withdrawLink`. Owner clawback
    ///         + rotation audit trail.
    event LinkWithdrawn(address indexed to, uint256 amount);
    /// @notice PR-16 (P1-18): emitted when the inner `IUpDownSettlement.resolve`
    ///         call reverts. Pre-fix the revert was swallowed silently, so a
    ///         broken settlement contract or a stuck market produced no
    ///         on-chain signal — operators only noticed when off-chain
    ///         reconciliation flagged the missed payout. `reason` carries the
    ///         raw revert bytes for off-chain decoding.
    event ResolveFailed(uint256 indexed marketId, int256 settlementPrice, bytes reason);

    // ── Types ───────────────────────────────────────────────────────────
    struct MarketInfo {
        address settlement;
        bytes32 pairId;
        int256 strikePrice;
        bool resolved;
    }

    // ── Constants ───────────────────────────────────────────────────────
    /// @notice Strike-side (Data Feeds) staleness window. Still 1 hour;
    ///         the strike is a fixed bet anchor and a slightly-stale
    ///         spot reference is acceptable for it (see investigation).
    uint256 public constant MAX_STALENESS = 1 hours;
    /// @notice Streams swap: tolerance on `report.observationsTimestamp`
    ///         vs `market.endTime`. The DON publishes Crypto-stream
    ///         reports at sub-second cadence, so under normal conditions
    ///         the off-chain helper can fetch a report within 1 second
    ///         of `endTime`. The 30-second window absorbs API hiccups
    ///         without ever pricing a market on a stale observation.
    ///         Asymmetric: lower-bounded only — the report must NOT be
    ///         observed AFTER `endTime` (that would price the market on
    ///         a post-close snapshot).
    uint256 public constant MAX_REPORT_OBSERVATION_LAG = 30 seconds;
    /// @notice Streams-strike (2026-05-16): symmetric ±tolerance for
    ///         `report.observationsTimestamp` vs the market's `startTime`.
    ///         Mirrors `MAX_REPORT_OBSERVATION_LAG` (the settlement-side
    ///         tolerance) numerically. Strike is captured AT slot boundary
    ///         not AFTER, so the window is symmetric: observations can be
    ///         either side of startTime by ±30s. This accommodates clock
    ///         drift + DON publish cadence; tight enough to prevent
    ///         meaningful price manipulation since Crypto streams update
    ///         sub-second and a ±30s slice is essentially the same price.
    uint256 public constant MAX_STRIKE_REPORT_LAG = 30 seconds;
    uint256 public constant SEQUENCER_GRACE_PERIOD = 1 hours;
    uint256 public constant OPTION_UP = 1;
    uint256 public constant OPTION_DOWN = 2;

    // ── State ───────────────────────────────────────────────────────────
    AggregatorV3Interface public immutable sequencerFeed;
    address public immutable trustedSettlement;

    /// @notice Streams swap: Chainlink-deployed Verifier Proxy that
    ///         validates DON signatures + collects the per-report LINK
    ///         fee. Immutable — rotation would require a fresh resolver
    ///         deploy (same posture as `trustedSettlement`). The proxy
    ///         is part of Chainlink's protocol infrastructure, not our
    ///         deploy, so we trust the address operationally.
    IVerifierProxy public immutable verifierProxy;

    /// @notice Streams swap: LINK token address on the host chain.
    ///         Resolver holds its own LINK balance and pays the per-verify
    ///         fee from it (Option A funding model). Ops tops up by
    ///         sending LINK directly to this contract; clawback /
    ///         rotation via `withdrawLink`. Immutable for same reason as
    ///         `verifierProxy` — a LINK rotation in the wider Chainlink
    ///         ecosystem is a redeploy event for every consumer.
    IERC20 public immutable linkToken;

    /// @notice Streams swap: per-pair Data Streams feed-id. Separate
    ///         from `priceFeeds` (Data Feeds aggregator addresses,
    ///         used for the strike path). Set by `configureStreamsFeed`.
    mapping(bytes32 => bytes32) public streamsFeedId;

    mapping(bytes32 => address) public priceFeeds;
    mapping(uint256 => MarketInfo) public markets;
    mapping(address => bool) public authorizedCallers;

    /// @notice Streams-strike (2026-05-16): per-(pairId, startTime) record
    ///         of strikes captured from verified Streams reports. The
    ///         AutoCycler reads this in `_createMarket` to pass the strike
    ///         to `settlement.createMarket`, replacing the prior
    ///         `resolver.getPrice(pairId)` Data Feeds read. Indexed by
    ///         `(pairId, startTime)` rather than `marketId` because the
    ///         capture happens BEFORE `settlement.createMarket` mints the
    ///         marketId — the cycler knows the slot boundary at scheduling
    ///         time, the marketId only after creation. The cycler enforces
    ///         per-slot uniqueness via `pairTfLastCreated`, but the
    ///         `strikeCaptured` flag here is defense-in-depth.
    mapping(bytes32 => mapping(uint64 => int256)) public capturedStrike;
    mapping(bytes32 => mapping(uint64 => bool)) public strikeCaptured;

    // ── Constructor ─────────────────────────────────────────────────────
    /// @notice Constructor now takes the Streams Verifier Proxy + LINK
    ///         token addresses alongside the strike-side Data Feeds
    ///         aggregator addresses. The Streams feed-ids are set
    ///         post-deploy via `configureStreamsFeed` — leaving them out
    ///         of the constructor keeps the signature manageable and
    ///         matches Chainlink's recommended deployment pattern
    ///         (configure each stream-id after the contract address is
    ///         known so it can be allow-listed at the DON side first).
    constructor(
        address _owner,
        address _sequencerFeed,
        bytes32 _btcUsdPairId,
        address _btcUsdFeed,
        bytes32 _ethUsdPairId,
        address _ethUsdFeed,
        address _trustedSettlement,
        address _verifierProxy,
        address _linkToken
    ) Ownable(_owner) {
        if (_trustedSettlement == address(0)) revert ZeroTrustedSettlement();
        if (_verifierProxy == address(0) || _linkToken == address(0)) revert ZeroAddress();
        trustedSettlement = _trustedSettlement;
        sequencerFeed = AggregatorV3Interface(_sequencerFeed);
        verifierProxy = IVerifierProxy(_verifierProxy);
        linkToken = IERC20(_linkToken);

        priceFeeds[_btcUsdPairId] = _btcUsdFeed;
        emit FeedConfigured(_btcUsdPairId, _btcUsdFeed);

        if (_ethUsdFeed != address(0)) {
            priceFeeds[_ethUsdPairId] = _ethUsdFeed;
            emit FeedConfigured(_ethUsdPairId, _ethUsdFeed);
        }
    }

    // ── Owner: feed management ──────────────────────────────────────────
    function configureFeed(bytes32 pairId, address feed) external onlyOwner {
        priceFeeds[pairId] = feed;
        emit FeedConfigured(pairId, feed);
    }

    /// @notice Streams swap (2026-05-13): set the Data Streams feed-id
    ///         for a pair. Called once per supported pair after the
    ///         DON has allow-listed this contract for the corresponding
    ///         stream. Markets created for a pair with an unconfigured
    ///         streams feed-id can still be REGISTERED (the registration
    ///         path only consults `priceFeeds` for strike validity) but
    ///         will fail to RESOLVE with `StreamsFeedNotConfigured()`
    ///         until this is set — loud failure mode, not silent.
    function configureStreamsFeed(bytes32 pairId, bytes32 feedId) external onlyOwner {
        streamsFeedId[pairId] = feedId;
        emit StreamsFeedConfigured(pairId, feedId);
    }

    /// @notice Streams swap: owner clawback of LINK held by this contract.
    ///         Used for rotation (migrate funding to a new resolver),
    ///         emergency recovery, or pre-deprecation drainage. NOT a
    ///         day-to-day operational call. Ops topup is a direct
    ///         `LINK.transfer(resolver, amount)` from the funding wallet
    ///         — no on-contract call needed.
    function withdrawLink(uint256 amount) external onlyOwner {
        linkToken.safeTransfer(msg.sender, amount);
        emit LinkWithdrawn(msg.sender, amount);
    }

    function setAuthorizedCaller(address caller, bool authorized) external onlyOwner {
        authorizedCallers[caller] = authorized;
        emit AuthorizedCallerSet(caller, authorized);
    }

    // ── Authorized: market registration ─────────────────────────────────
    function registerMarket(uint256 marketId, address settlement, bytes32 pairId, int256 strikePrice) external {
        require(authorizedCallers[msg.sender] || msg.sender == owner(), "unauthorized");
        if (settlement != trustedSettlement) revert TrustedSettlementMismatch();
        if (priceFeeds[pairId] == address(0)) revert FeedNotConfigured();

        IUpDownSettlement.Market memory sm = IUpDownSettlement(settlement).getMarket(marketId);
        if (sm.startTime == 0 || sm.pairId != pairId || int256(sm.strikePrice) != strikePrice) revert MarketNotRegistered();

        markets[marketId] = MarketInfo({settlement: settlement, pairId: pairId, strikePrice: strikePrice, resolved: false});
        emit MarketRegistered(marketId, settlement, pairId, strikePrice);
    }

    // ── Public: price reading ───────────────────────────────────────────
    /// @notice Returns the latest validated price for a pair.
    ///         Reverts if the sequencer is down, in grace period, or price is stale.
    ///
    /// @dev Streams-strike (2026-05-16): this path is now LEGACY for strike
    ///      capture. The AutoCycler reads strikes via `captureStrike` →
    ///      `capturedStrike[pairId][startTime]` instead. `getPrice` is kept
    ///      for any external read use, but `_createMarket` no longer calls
    ///      it. The underlying `priceFeeds[pairId]` aggregator addresses are
    ///      still configured (constructor + `configureFeed`) so historic
    ///      markets resolve consistently against their captured strike.
    function getPrice(bytes32 pairId) external view returns (int256) {
        _checkSequencer();
        return _getLatestPrice(pairId);
    }

    // ── Public: Streams-strike capture ──────────────────────────────────
    //
    // Streams-strike (2026-05-16). Companion to `resolve()` — same Streams
    // verification machinery, applied at slot-open time instead of slot-
    // close. The motivation: pre-2026-05-16 the resolver consumed
    // AggregatorV3 Data Feeds for strikes (1e8 atomic scale) and Streams
    // for settlement (1e18 atomic scale). Mixed-scale on-chain data
    // cascaded into the frontend's `+644782711328.57%` resolved-market
    // delta bug + an unaudited assumption gap. Captured strikes via
    // Streams unify the scale at 1e18 end-to-end.
    //
    // Caller responsibility:
    //   - Fetch a signed `ReportV3` blob from the Streams REST API near
    //     the slot's `startTime` (sub-second cadence; ±30s window).
    //   - Pass the report + the slot's clock-aligned `startTime` here.
    //   - LINK fee paid by this contract from its own balance (same
    //     funding model as `resolve()`).
    //
    // Replay protection: `(pairId, startTime)` tuple may only be captured
    // once. Cycler-side `pairTfLastCreated` already enforces slot
    // uniqueness; this is defense-in-depth.
    //
    // Permissionless: any caller may submit a valid report for any pair
    // at any startTime — the symmetric ±MAX_STRIKE_REPORT_LAG window and
    // feedId binding bound what a malicious submitter could achieve to
    // "capture the actual price near a real slot boundary," which is
    // exactly the intended behavior.
    function captureStrike(bytes32 pairId, bytes memory signedReport, uint64 startTime)
        external
        returns (int256 strikePrice)
    {
        if (strikeCaptured[pairId][startTime]) revert StrikeAlreadyCaptured(pairId, startTime);

        _checkSequencer();

        bytes32 wantFeedId = streamsFeedId[pairId];
        if (wantFeedId == bytes32(0)) revert StreamsFeedNotConfigured();

        bytes memory parameterPayload = _payVerificationFee(signedReport);
        bytes memory verifierResponse = verifierProxy.verify(signedReport, parameterPayload);
        ReportV3 memory report = abi.decode(verifierResponse, (ReportV3));

        if (report.feedId != wantFeedId) revert ReportFeedIdMismatch(wantFeedId, report.feedId);
        if (uint256(report.expiresAt) < block.timestamp) {
            revert ReportExpired(uint256(report.expiresAt), block.timestamp);
        }

        // Strike window: symmetric ±MAX_STRIKE_REPORT_LAG around startTime.
        // Differs from the settlement-side window which is asymmetric
        // (`endTime - LAG <= obs <= endTime`) because strike is anchored AT
        // slot boundary, settlement is anchored AT-OR-BEFORE close.
        uint256 obs = uint256(report.observationsTimestamp);
        uint256 startTs = uint256(startTime);
        if (obs + MAX_STRIKE_REPORT_LAG < startTs || obs > startTs + MAX_STRIKE_REPORT_LAG) {
            revert ReportObservationOutOfStrikeWindow(startTime, obs);
        }

        strikePrice = int256(report.price);
        strikeCaptured[pairId][startTime] = true;
        capturedStrike[pairId][startTime] = strikePrice;

        emit StrikeCaptured(pairId, startTime, strikePrice, report.observationsTimestamp);
    }

    // ── Public: Data Streams report-bound resolution ─────────────────────
    //
    // 2026-05-13 Data Streams swap (gate 1):
    //
    // Pre-swap (PR-10 / P0-16): the resolver consumed Chainlink Data Feeds
    // via `AggregatorV3Interface.getRoundData(roundId)`, with the off-chain
    // helper computing the canonical round whose `updatedAt <= endTime` and
    // whose `roundId + 1` postdates `endTime`. That model required scanning
    // round history on-chain (two `getRoundData` calls per resolve), suffered
    // a 1h `MAX_STALENESS` cliff that caused the 2026-05-06 shadow-market
    // class (`audit-fixes/AUDIT_FINDING_CHECKUPKEEP_GAS_LEAK.md`), and was
    // structurally limited by Data Feeds' heartbeat-driven publishing.
    //
    // Post-swap: the resolver consumes Chainlink Data Streams. The off-chain
    // `ChainlinkResolverService` fetches a signed `ReportV3` blob from the
    // Streams REST API (`api.dataengine.chain.link/api/v1/reports`) at the
    // market's `endTime` and submits it as `signedReport` calldata. The
    // resolver:
    //
    //   1. Validates market state (registered, not resolved, past endTime).
    //   2. Checks the sequencer (same Arbitrum L2 pattern as before).
    //   3. Looks up the per-pair Streams feed-id from `streamsFeedId`.
    //   4. Pays the LINK fee to the FeeManager (when configured) — Option A
    //      funding model: resolver holds its own LINK balance.
    //   5. Calls `verifierProxy.verify(signedReport, parameterPayload)`. The
    //      proxy validates the DON signature, deducts the fee, and returns
    //      the decoded report.
    //   6. Decodes as `ReportV3`. Validates feedId match, expiresAt, and
    //      that `observationsTimestamp` is within the
    //      `[endTime - MAX_REPORT_OBSERVATION_LAG, endTime]` bracket.
    //   7. Computes winningOption from `report.price` vs `info.strikePrice`.
    //   8. Hands off to `settlement.resolve` under the same try/catch
    //      pattern as before — `ResolveFailed` event preserves the
    //      auditable failure path.
    //
    // Permissionless and deterministic: any caller can submit any signed
    // report, but only a report (a) for the right pair, (b) within the
    // observation window, (c) not expired, and (d) signed by the DON will
    // produce a successful resolve. Different reports observed within the
    // 30s window yield ~identical prices for sub-second Crypto streams, so
    // the determinism property is preserved in practice; the bracket is
    // tight enough to prevent meaningful price manipulation. See
    // `audit-fixes/DATA_STREAMS_INVESTIGATION.md` for the full design
    // rationale.

    function resolve(uint256 marketId, bytes calldata signedReport) external {
        MarketInfo storage info = markets[marketId];
        if (info.settlement == address(0)) revert MarketNotRegistered();
        if (info.resolved) revert AlreadyResolved();

        IUpDownSettlement.Market memory m = IUpDownSettlement(info.settlement).getMarket(marketId);
        if (block.timestamp < uint256(m.endTime)) revert MarketNotExpired();

        _checkSequencer();

        bytes32 wantFeedId = streamsFeedId[info.pairId];
        if (wantFeedId == bytes32(0)) revert StreamsFeedNotConfigured();

        // Pay the LINK fee + verify. The FeeManager is the source of
        // truth for the exact fee amount, the LINK token address, and the
        // RewardManager to approve. When the FeeManager is unset (testnet
        // or subscription-billed mainnets), `parameterPayload` is empty
        // and `verify` proceeds without a fee deduction.
        bytes memory parameterPayload = _payVerificationFee(signedReport);
        bytes memory verifierResponse = verifierProxy.verify(signedReport, parameterPayload);

        // Crypto streams (BTC/USD, ETH/USD) always decode as V3. If we
        // ever add RWA pairs (V8), branch here on a stream-id → schema
        // mapping. Not needed in v1; flagged for v1.1.
        ReportV3 memory report = abi.decode(verifierResponse, (ReportV3));

        if (report.feedId != wantFeedId) revert ReportFeedIdMismatch(wantFeedId, report.feedId);
        if (uint256(report.expiresAt) < block.timestamp) {
            revert ReportExpired(uint256(report.expiresAt), block.timestamp);
        }

        // Observation window: `endTime - LAG <= observationsTimestamp <= endTime`.
        // Upper bound (== endTime) rejects post-close observations that
        // would price the market on a snapshot after it closed. Lower
        // bound rejects reports too old to be representative of the
        // close — caller should fetch a fresher one from the API.
        uint256 obs = uint256(report.observationsTimestamp);
        uint256 endTs = uint256(m.endTime);
        if (obs > endTs || obs + MAX_REPORT_OBSERVATION_LAG < endTs) {
            revert ReportObservationOutOfWindow(endTs, obs);
        }

        int256 settlementPrice = int256(report.price);
        uint256 winningOption = settlementPrice > info.strikePrice ? OPTION_UP : OPTION_DOWN;

        try IUpDownSettlement(info.settlement).resolve(marketId, settlementPrice, uint8(winningOption)) {
            info.resolved = true;
            emit MarketResolved(marketId, winningOption, settlementPrice, info.strikePrice);
        } catch (bytes memory reason) {
            // PR-16 (P1-18): leave resolved = false so resolve() can be
            // retried, but emit so operators see the failure on-chain
            // instead of in off-chain reconciliation logs only.
            emit ResolveFailed(marketId, settlementPrice, reason);
        }
    }

    /// @dev Pay the LINK verification fee, returning the `parameterPayload`
    ///      to pass to `verifierProxy.verify`. Encapsulates the FeeManager
    ///      lookup + approve dance so the main `resolve` flow stays linear.
    function _payVerificationFee(bytes memory signedReport)
        internal
        returns (bytes memory parameterPayload)
    {
        address feeManagerAddr = verifierProxy.s_feeManager();
        if (feeManagerAddr == address(0)) {
            // Testnet / subscription-billed deployment — no fee path.
            return bytes("");
        }
        IFeeManager feeManager = IFeeManager(feeManagerAddr);
        address feeToken = feeManager.i_linkAddress();
        // Cross-check: the LINK token reported by the FeeManager must
        // match the one this resolver was deployed against. A mismatch
        // means we'd approve a token we don't hold — fail loudly.
        require(feeToken == address(linkToken), "FeeManager LINK mismatch");

        // The unverified report payload format wraps the report data in
        // a header. `getFeeAndReward` expects the inner report bytes,
        // which the reference implementation extracts as the second
        // element of `(bytes32[3], bytes)`. Pass the full payload here
        // and let the FeeManager handle extraction internally — the
        // reference contract passes `reportData` (the inner bytes), but
        // matching the docs' tutorial flow exactly.
        (, bytes memory reportData) = abi.decode(signedReport, (bytes32[3], bytes));
        (FeeManagerAsset memory fee, , ) = feeManager.getFeeAndReward(address(this), reportData, feeToken);

        if (fee.amount > 0) {
            address rewardManager = feeManager.i_rewardManager();
            // SafeERC20 approve to a known FeeManager-blessed recipient.
            // `forceApprove` would be safer for tokens that don't allow
            // setting a new non-zero allowance without a 0-reset, but
            // LINK is OpenZeppelin-compliant so `safeIncreaseAllowance`
            // / `approve` work cleanly here. We use the plain `approve`
            // because the FeeManager pulls and we want exact-amount
            // semantics, not allowance accumulation.
            linkToken.forceApprove(rewardManager, fee.amount);
        }

        parameterPayload = abi.encode(feeToken);
    }

    // ── Internal helpers ────────────────────────────────────────────────
    function _checkSequencer() internal view {
        // F-12 (deep review, surfaced by Streams Gate 3 Sepolia E2E 2026-05-12):
        // the destructure pattern `(, A,, B,)` reads positions 1 (`answer`) and
        // 3 (`updatedAt`) from `latestRoundData() returns (roundId, answer,
        // startedAt, updatedAt, answeredInRound)`. The local variable below is
        // therefore the feed's `updatedAt`, NOT its `startedAt`. Renamed for
        // honesty; on-mainnet behavior against Chainlink's Sequencer Uptime
        // feed is unchanged because that feed only writes a new round on
        // state transitions, making `startedAt == updatedAt` in steady state.
        (, int256 answer,, uint256 updatedAt,) = sequencerFeed.latestRoundData();
        if (answer != 0) revert SequencerDown();
        if (block.timestamp - updatedAt < SEQUENCER_GRACE_PERIOD) revert SequencerGracePeriod();
    }

    function _getLatestPrice(bytes32 pairId) internal view returns (int256) {
        address feed = priceFeeds[pairId];
        if (feed == address(0)) revert FeedNotConfigured();

        (, int256 price,, uint256 updatedAt,) = AggregatorV3Interface(feed).latestRoundData();
        if (block.timestamp - updatedAt > MAX_STALENESS) revert StalePrice();

        return price;
    }
}
