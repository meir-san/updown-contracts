// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUpDownSettlement} from "./interfaces/IUpDownSettlement.sol";
import {ChainlinkResolver} from "./ChainlinkResolver.sol";

/// @title UpDownAutoCycler
/// @notice Chainlink Automation-compatible keeper that auto-creates and auto-resolves
///         UpDown prediction markets (e.g. BTC/USD) on 5, 15, and 60-minute cycles.
///         Markets are created inside a single `UpDownSettlement` contract (no per-market deploy).
contract UpDownAutoCycler is Ownable {
    using SafeERC20 for IERC20;

    // ── Errors ──────────────────────────────────────────────────────────
    error InvalidTimeframeIndex();
    error PreStartWindowTooLarge();

    // ── Events ──────────────────────────────────────────────────────────
    event MarketCreated(uint256 indexed marketId, bytes32 indexed pairId, uint256 duration, int256 strikePrice);
    event MarketCreationFailed(bytes32 indexed pairId, uint256 indexed timeframe, bytes reason);
    event ResolutionFailed(uint256 indexed marketId, bytes reason);
    event TimeframeToggled(uint256 indexed index, bool active);
    event FundsWithdrawn(address indexed token, uint256 amount);
    /// @notice Emitted when the owner changes the pre-start window. Off-chain
    ///         consumers (the backend's MarketSyncer) read this to know how
    ///         far ahead of `startTime` markets may now appear.
    event PreStartWindowUpdated(uint256 previous, uint256 current);

    // ── Types ───────────────────────────────────────────────────────────
    struct TimeframeConfig {
        uint256 duration;
        uint256 disputeDuration;
        bool active;
    }

    struct ActiveMarket {
        uint256 marketId;
        uint256 endTime;
        bytes32 pairId;
    }

    /// @dev Encoded in performData alongside resolve indices for market creation.
    struct CreateSlot {
        bytes32 pairId;
        uint256 tfIdx;
    }

    // ── Constants ───────────────────────────────────────────────────────
    bytes32 public constant BTCUSD = keccak256("BTC/USD");
    bytes32 public constant ETHUSD = keccak256("ETH/USD");
    uint256 public constant NUM_TIMEFRAMES = 3;

    // ── State ───────────────────────────────────────────────────────────
    ChainlinkResolver public resolver;
    IUpDownSettlement public settlement;

    TimeframeConfig[NUM_TIMEFRAMES] public timeframes;
    ActiveMarket[] internal _activeMarkets;
    mapping(bytes32 => bool) public supportedPairs;

    /// @notice Pairs that receive new markets each cycle (owner extends via `addPair`).
    bytes32[] internal _cyclingPairs;
    mapping(bytes32 => bool) public isCyclingPair;

    /// @notice Start timestamp of the last created slot (clock-aligned boundary) per (pairId, timeframeIndex).
    mapping(bytes32 => mapping(uint256 => uint256)) public pairTfLastCreated;

    /// @notice Pre-positioning window — number of seconds BEFORE a slot's
    ///         `startTime` at which `_createMarket` becomes eligible to
    ///         create that slot's market. Default 0 = current behavior
    ///         (markets are created at-or-after `startTime`, never early).
    ///         When set to e.g. 30, the cycler creates a market with
    ///         `startTime = next slot boundary` once `block.timestamp +
    ///         preStartWindowSec >= nextSlotBoundary`. Backend matching
    ///         engine refuses to match orders on a market whose
    ///         `startTime` is in the future, so trades only land at-or-
    ///         after the boundary; the pre-window exists only so makers
    ///         can sign orders + post them to the engine before the
    ///         continuous cross begins.
    ///
    ///         Capped at the smallest active timeframe duration (300s)
    ///         so the next-slot market can't be created before the
    ///         current slot's market is even live.
    uint256 public preStartWindowSec;
    uint256 public constant PRE_START_WINDOW_MAX = 300;

    // ── Constructor ─────────────────────────────────────────────────────
    constructor(address _owner, address _resolver, address _settlement) Ownable(_owner) {
        resolver = ChainlinkResolver(_resolver);
        settlement = IUpDownSettlement(_settlement);

        // 5 min markets, 10 min dispute
        timeframes[0] = TimeframeConfig({duration: 300, disputeDuration: 600, active: true});
        // 15 min markets, 30 min dispute
        timeframes[1] = TimeframeConfig({duration: 900, disputeDuration: 1800, active: true});
        // 1 hour markets, 120 min dispute
        timeframes[2] = TimeframeConfig({duration: 3600, disputeDuration: 7200, active: true});

        supportedPairs[BTCUSD] = true;
        isCyclingPair[BTCUSD] = true;
        _cyclingPairs.push(BTCUSD);
    }

    /// @notice Number of pairs that participate in automated market creation.
    function cyclingPairCount() external view returns (uint256) {
        return _cyclingPairs.length;
    }

    /// @notice Pair id at index in the cycling list (for indexers / backends).
    function cyclingPairAt(uint256 index) external view returns (bytes32) {
        return _cyclingPairs[index];
    }

    /// @notice Same layout as the default getter for a public array of structs.
    function activeMarkets(uint256 index)
        external
        view
        returns (uint256 marketId, uint256 endTime, bytes32 pairId)
    {
        ActiveMarket storage m = _activeMarkets[index];
        return (m.marketId, m.endTime, m.pairId);
    }

    // ── Chainlink Automation ────────────────────────────────────────────

    /// @notice Called off-chain by Chainlink Automation nodes every block.
    /// @dev    PR-PrePos: market creation triggers `preStartWindowSec`
    ///         seconds earlier than today; each slot's market is created
    ///         when `block.timestamp + preStartWindowSec >= pairTfLastCreated
    ///         + tf.duration`. Reduces to today's behavior (`>= pairTfLastCreated
    ///         + tf.duration`) when `preStartWindowSec == 0`.
    function checkUpkeep(bytes calldata) external view returns (bool upkeepNeeded, bytes memory performData) {
        uint256 marketsLen = _activeMarkets.length;
        uint256 preWin = preStartWindowSec;

        uint256 resolveCount;
        for (uint256 i; i < marketsLen; ++i) {
            if (block.timestamp >= _activeMarkets[i].endTime) ++resolveCount;
        }

        uint256 createCount;
        uint256 nPairs = _cyclingPairs.length;
        for (uint256 pi; pi < nPairs; ++pi) {
            bytes32 pid = _cyclingPairs[pi];
            if (!supportedPairs[pid]) continue;
            for (uint256 ti; ti < NUM_TIMEFRAMES; ++ti) {
                TimeframeConfig storage tft = timeframes[ti];
                if (tft.active && block.timestamp + preWin >= pairTfLastCreated[pid][ti] + tft.duration) {
                    ++createCount;
                }
            }
        }

        upkeepNeeded = resolveCount > 0 || createCount > 0;

        if (upkeepNeeded) {
            uint256[] memory resolveIndices = new uint256[](resolveCount);
            CreateSlot[] memory createSlots = new CreateSlot[](createCount);

            uint256 ri;
            for (uint256 i; i < marketsLen; ++i) {
                if (block.timestamp >= _activeMarkets[i].endTime) resolveIndices[ri++] = i;
            }

            uint256 ci;
            for (uint256 pi; pi < nPairs; ++pi) {
                bytes32 pid = _cyclingPairs[pi];
                if (!supportedPairs[pid]) continue;
                for (uint256 ti; ti < NUM_TIMEFRAMES; ++ti) {
                    TimeframeConfig storage tft = timeframes[ti];
                    if (tft.active && block.timestamp + preWin >= pairTfLastCreated[pid][ti] + tft.duration) {
                        createSlots[ci++] = CreateSlot({pairId: pid, tfIdx: ti});
                    }
                }
            }

            performData = abi.encode(resolveIndices, createSlots);
        }
    }

    /// @notice Called on-chain by Chainlink Automation when checkUpkeep returns true.
    /// @dev    PR-10 (P0-16): on-chain resolve dispatch was REMOVED here. The
    ///         resolver now requires `(marketId, uint80 roundId)` — the
    ///         canonical Chainlink round whose `updatedAt <= market.endTime`,
    ///         which only an off-chain helper can compute by scanning the
    ///         feed's round history. Backend `ChainlinkResolverService` owns
    ///         this responsibility now; Chainlink Automation only drives
    ///         creation + pruning. `resolveIndices` is preserved in
    ///         `performData` (still emitted by `checkUpkeep`) so a future
    ///         redesign can read it, but `performUpkeep` ignores it today.
    function performUpkeep(bytes calldata performData) external {
        // `resolveIndices` is decoded for ABI/payload stability with the
        // Chainlink Automation registration but not iterated here because
        // resolution is roundId-bound and lives off-chain.
        (, CreateSlot[] memory createSlots) =
            abi.decode(performData, (uint256[], CreateSlot[]));

        // Phase B: create new markets (external self-call so try/catch can recover)
        for (uint256 i; i < createSlots.length; ++i) {
            CreateSlot memory slot = createSlots[i];
            try this._createMarketExternal(slot.tfIdx, slot.pairId) {} catch (bytes memory reason) {
                emit MarketCreationFailed(slot.pairId, slot.tfIdx, reason);
            }
        }

        _pruneResolved();
    }

    /// @dev Callable only via `this` from performUpkeep so failures are catchable.
    function _createMarketExternal(uint256 tfIdx, bytes32 pairId) external {
        require(msg.sender == address(this), "only cycler");
        _createMarket(tfIdx, pairId);
    }

    // ── Internal ────────────────────────────────────────────────────────

    /// @dev PR-PrePos: planned start = `lastStart + tf.duration` so each
    ///      cycle creates the slot AFTER the most recently created one.
    ///      For the first-ever create on a (pair, tf), bootstrap to the
    ///      current clock-aligned boundary (preserves today's bootstrap
    ///      semantics). When `preStartWindowSec > 0`, `_createMarket` is
    ///      reachable via `checkUpkeep` up to `preStartWindowSec` seconds
    ///      before `plannedStart`, so the resulting market may have
    ///      `startTime > block.timestamp` (= "pre-start" / "WAITING_TO_START"
    ///      from the backend's perspective). The off-chain matching engine
    ///      refuses to match orders on a market whose `startTime` is in
    ///      the future, so trades only land at-or-after the boundary.
    function _createMarket(uint256 tfIdx, bytes32 pairId) internal {
        if (tfIdx >= NUM_TIMEFRAMES) revert InvalidTimeframeIndex();
        if (!supportedPairs[pairId]) revert("pair not supported");

        TimeframeConfig storage tf = timeframes[tfIdx];

        int256 strike = resolver.getPrice(pairId);

        uint256 nowTs = block.timestamp;
        uint256 lastStart = pairTfLastCreated[pairId][tfIdx];
        uint256 plannedStart;
        if (lastStart == 0) {
            // First create on this (pair, tf): align to the current boundary.
            plannedStart = (nowTs / tf.duration) * tf.duration;
        } else {
            // Continuing cycle: next slot follows the previous one exactly.
            plannedStart = lastStart + tf.duration;
        }
        uint256 end = plannedStart + tf.duration;

        uint256 marketId = settlement.createMarket(pairId, tf.duration, strike, uint64(plannedStart), uint64(end));

        resolver.registerMarket(marketId, address(settlement), pairId, strike);
        _activeMarkets.push(ActiveMarket({marketId: marketId, endTime: end, pairId: pairId}));
        pairTfLastCreated[pairId][tfIdx] = plannedStart;

        emit MarketCreated(marketId, pairId, tf.duration, strike);
    }

    // ── Owner: configuration ────────────────────────────────────────────

    function toggleTimeframe(uint256 index, bool active) external onlyOwner {
        if (index >= NUM_TIMEFRAMES) revert InvalidTimeframeIndex();
        timeframes[index].active = active;
        emit TimeframeToggled(index, active);
    }

    /// @notice Set the pre-positioning window (seconds before `startTime`
    ///         at which a slot's market becomes eligible to be created).
    ///         0 disables pre-positioning (default; matches pre-PR behavior).
    ///         Capped at `PRE_START_WINDOW_MAX` (= the smallest active
    ///         timeframe duration, 300s) so the next-slot market can't
    ///         appear before the current slot's market is even live.
    function setPreStartWindowSec(uint256 v) external onlyOwner {
        if (v > PRE_START_WINDOW_MAX) revert PreStartWindowTooLarge();
        uint256 prev = preStartWindowSec;
        preStartWindowSec = v;
        emit PreStartWindowUpdated(prev, v);
    }

    /// @notice Whitelist a pair and include it in automated cycling (idempotent for cycling list).
    function addPair(bytes32 pairId) external onlyOwner {
        supportedPairs[pairId] = true;
        if (!isCyclingPair[pairId]) {
            isCyclingPair[pairId] = true;
            _cyclingPairs.push(pairId);
        }
    }

    function setResolver(address _resolver) external onlyOwner {
        resolver = ChainlinkResolver(_resolver);
    }

    function setSettlement(address _settlement) external onlyOwner {
        settlement = IUpDownSettlement(_settlement);
    }

    // ── Owner: fund management ──────────────────────────────────────────

    /// @notice Withdraw any ERC-20 from this contract.
    function withdrawFunds(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(msg.sender, amount);
        emit FundsWithdrawn(token, amount);
    }

    // ── Owner: gas optimization ─────────────────────────────────────────

    /// @notice Remove resolved markets from the active array (swap-and-pop).
    function pruneResolved() external onlyOwner {
        _pruneResolved();
    }

    function _pruneResolved() internal {
        uint256 i;
        while (i < _activeMarkets.length) {
            uint256 mid = _activeMarkets[i].marketId;
            if (settlement.getMarket(mid).resolved) {
                _activeMarkets[i] = _activeMarkets[_activeMarkets.length - 1];
                _activeMarkets.pop();
            } else {
                ++i;
            }
        }
    }

    // ── View helpers ────────────────────────────────────────────────────

    function activeMarketCount() external view returns (uint256) {
        return _activeMarkets.length;
    }
}
