// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {IUpDownSettlement} from "./interfaces/IUpDownSettlement.sol";

/// @title ChainlinkResolver
/// @notice Reads Chainlink price feeds on Arbitrum, validates the L2 sequencer,
///         and resolves UpDown markets via `UpDownSettlement.resolve`.
///         Resolution is permissionless — anyone can call `resolve` since the
///         outcome is deterministic from the Chainlink feed (UP if price > strike, else DOWN; tie => DOWN).
contract ChainlinkResolver is Ownable {
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
    /// @notice PR-10 (P0-16): the supplied `roundId`'s `updatedAt` is AFTER
    ///         `market.endTime` — i.e. the caller picked a round that postdates
    ///         the market window. The canonical round for this market is the
    ///         latest round whose `updatedAt <= endTime`.
    error RoundTooLate();
    /// @notice PR-10 (P0-16): the supplied `roundId` is valid (`updatedAt <=
    ///         endTime`) but the *next* round's `updatedAt` is also `<=
    ///         endTime` — meaning the caller picked an earlier round, not the
    ///         last one before endTime. Forces the resolution price to the
    ///         single deterministic round per market.
    error NotLastPreEndTimeRound();

    // ── Events ──────────────────────────────────────────────────────────
    event FeedConfigured(bytes32 indexed pairId, address feed);
    event MarketRegistered(uint256 indexed marketId, address indexed settlement, bytes32 indexed pairId, int256 strikePrice);
    event MarketResolved(uint256 indexed marketId, uint256 winningOption, int256 settlementPrice, int256 strikePrice);
    event AuthorizedCallerSet(address indexed caller, bool authorized);
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
    uint256 public constant MAX_STALENESS = 1 hours;
    uint256 public constant SEQUENCER_GRACE_PERIOD = 1 hours;
    uint256 public constant OPTION_UP = 1;
    uint256 public constant OPTION_DOWN = 2;

    // ── State ───────────────────────────────────────────────────────────
    AggregatorV3Interface public immutable sequencerFeed;
    address public immutable trustedSettlement;

    mapping(bytes32 => address) public priceFeeds;
    mapping(uint256 => MarketInfo) public markets;
    mapping(address => bool) public authorizedCallers;

    // ── Constructor ─────────────────────────────────────────────────────
    constructor(
        address _owner,
        address _sequencerFeed,
        bytes32 _btcUsdPairId,
        address _btcUsdFeed,
        bytes32 _ethUsdPairId,
        address _ethUsdFeed,
        address _trustedSettlement
    ) Ownable(_owner) {
        if (_trustedSettlement == address(0)) revert ZeroTrustedSettlement();
        trustedSettlement = _trustedSettlement;
        sequencerFeed = AggregatorV3Interface(_sequencerFeed);

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
    function getPrice(bytes32 pairId) external view returns (int256) {
        _checkSequencer();
        return _getLatestPrice(pairId);
    }

    // ── Public: permissionless roundId-bound resolution ─────────────────
    /// @notice Resolve `marketId` using the Chainlink round identified by
    ///         `roundId`. The contract verifies `roundId` is the *canonical*
    ///         round for the market — i.e. the latest round whose `updatedAt`
    ///         is `<= market.endTime`, with the next round strictly after.
    ///         This is permissionless: anyone can call, but only the canonical
    ///         `roundId` will succeed, eliminating the race-to-resolve attack
    ///         that existed under the old `latestRoundData` semantics.
    /// @dev    PR-10 (P0-16). Off-chain helpers (see backend
    ///         `ChainlinkResolverService`) compute the canonical round and
    ///         submit it; on-chain we re-derive the constraints rather than
    ///         trust the caller. `_isStale(updatedAt)` (via MAX_STALENESS) is
    ///         still applied so a feed gap that places the canonical round far
    ///         in the past clamps rather than silently resolves on an ancient
    ///         price.
    function resolve(uint256 marketId, uint80 roundId) external {
        MarketInfo storage info = markets[marketId];
        if (info.settlement == address(0)) revert MarketNotRegistered();
        if (info.resolved) revert AlreadyResolved();

        IUpDownSettlement.Market memory m = IUpDownSettlement(info.settlement).getMarket(marketId);
        if (block.timestamp < uint256(m.endTime)) revert MarketNotExpired();

        _checkSequencer();

        // ── Roundtrip: pull the supplied round and the next round, verify
        //    canonicality, then use the supplied round's `answer` as the
        //    settlement price. ───────────────────────────────────────────
        address feed = priceFeeds[info.pairId];
        if (feed == address(0)) revert FeedNotConfigured();

        AggregatorV3Interface aggregator = AggregatorV3Interface(feed);

        (, int256 settlementPrice,, uint256 updatedAt,) = aggregator.getRoundData(roundId);
        if (updatedAt > uint256(m.endTime)) revert RoundTooLate();

        // Existing MAX_STALENESS guard — still meaningful because the
        // *canonical* round can itself be ancient if the feed is gapped
        // (e.g. the resolver runs days after endTime on a stalled feed).
        if (block.timestamp - updatedAt > MAX_STALENESS) revert StalePrice();

        // The next round MUST postdate endTime — proves the caller picked
        // the LAST pre-endTime round, not just any earlier one. If the
        // round is missing (some Chainlink feeds may revert for unknown
        // ids) `getRoundData` reverts and the call fails closed, which
        // is the safe default.
        (, , , uint256 nextUpdatedAt,) = aggregator.getRoundData(roundId + 1);
        if (nextUpdatedAt <= uint256(m.endTime)) revert NotLastPreEndTimeRound();

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

    // ── Internal helpers ────────────────────────────────────────────────
    function _checkSequencer() internal view {
        (, int256 answer,, uint256 startedAt,) = sequencerFeed.latestRoundData();
        if (answer != 0) revert SequencerDown();
        if (block.timestamp - startedAt < SEQUENCER_GRACE_PERIOD) revert SequencerGracePeriod();
    }

    function _getLatestPrice(bytes32 pairId) internal view returns (int256) {
        address feed = priceFeeds[pairId];
        if (feed == address(0)) revert FeedNotConfigured();

        (, int256 price,, uint256 updatedAt,) = AggregatorV3Interface(feed).latestRoundData();
        if (block.timestamp - updatedAt > MAX_STALENESS) revert StalePrice();

        return price;
    }
}
