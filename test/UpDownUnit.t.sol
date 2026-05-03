// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {ChainlinkResolver} from "../src/ChainlinkResolver.sol";
import {UpDownAutoCycler} from "../src/UpDownAutoCycler.sol";
import {UpDownSettlement} from "../src/UpDownSettlement.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

bytes32 constant BTCUSD = keccak256("BTC/USD");

contract MockSequencerUp {
    int256 private _answer;
    uint256 private _graceRef;

    constructor(int256 answer_, uint256 graceRef_) {
        _answer = answer_;
        _graceRef = graceRef_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, _answer, block.timestamp, _graceRef, 0);
    }

    function decimals() external pure returns (uint8) {
        return 0;
    }
}

contract MockBtcFeed {
    int256 private _price;

    constructor(int256 price_) {
        _price = price_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, _price, block.timestamp, block.timestamp, 1);
    }

    /// @dev PR-10 (P0-16): minimal `getRoundData` so the new roundId-bound
    ///      `resolve` path compiles against this mock. Returns the same
    ///      single-round answer for any id and pretends the next round is far
    ///      in the future — sufficient for tests that don't exercise the
    ///      multi-round canonicality logic. Tests that care about that logic
    ///      use `MockAggregatorV3` below.
    function getRoundData(uint80 rid) external view returns (uint80, int256, uint256, uint256, uint80) {
        // Shape: round 1 = the configured price at "now"; round 2+ in the far future.
        if (rid <= 1) return (rid, _price, block.timestamp, block.timestamp, rid);
        return (rid, _price, block.timestamp + 365 days, block.timestamp + 365 days, rid);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }
}

/// @notice Multi-round Chainlink mock for PR-10 (P0-16) tests. Lets each test
///         set an explicit (price, updatedAt) per roundId and adjust which
///         id is the "latest" for the off-chain scan path.
contract MockAggregatorV3 {
    struct Round {
        int256 answer;
        uint256 updatedAt;
        bool exists;
    }

    mapping(uint80 => Round) public rounds;
    uint80 public latestId;

    function setRound(uint80 rid, int256 answer, uint256 updatedAt) external {
        rounds[rid] = Round({answer: answer, updatedAt: updatedAt, exists: true});
        if (rid > latestId) latestId = rid;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        Round memory r = rounds[latestId];
        return (latestId, r.answer, r.updatedAt, r.updatedAt, latestId);
    }

    function getRoundData(uint80 rid) external view returns (uint80, int256, uint256, uint256, uint80) {
        Round memory r = rounds[rid];
        // Mirror real Chainlink behaviour: unknown round reverts. The
        // resolver's `getRoundData(roundId + 1)` call must therefore be
        // protected against a missing next round — tests for that case
        // pre-populate a sentinel round with a far-future updatedAt.
        require(r.exists, "MockAggregatorV3: unknown round");
        return (rid, r.answer, r.updatedAt, r.updatedAt, rid);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }
}

/// @notice Resolver try target: first resolve reverts, second succeeds if toggled.
contract MockSettlementResolve {
    uint256 public marketId;
    bytes32 public pairId;
    int256 public strikePrice;
    bool public shouldRevert;
    uint8 public lastWinner;
    int256 public lastPrice;

    constructor(uint256 mid, bytes32 pid, int256 strike) {
        marketId = mid;
        pairId = pid;
        strikePrice = strike;
    }

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function getMarket(uint256 mid) external view returns (UpDownSettlement.Market memory m) {
        if (mid != marketId) return m;
        m.endTime = uint64(block.timestamp - 1);
        m.startTime = 1;
        m.pairId = pairId;
        m.strikePrice = int128(strikePrice);
    }

    function resolve(uint256 mid, int256 settlementPrice, uint8 winner) external {
        if (mid != marketId) revert("bad id");
        if (shouldRevert) revert("resolve failed");
        lastPrice = settlementPrice;
        lastWinner = winner;
    }
}

contract UpDownAutoCyclerHarness is UpDownAutoCycler {
    constructor(address o, address r, address st) UpDownAutoCycler(o, r, st) {}

    function harnessPushActive(uint256 marketId, uint256 endTime, bytes32 pairId) external {
        _activeMarkets.push(ActiveMarket({marketId: marketId, endTime: endTime, pairId: pairId}));
    }

    function harnessCreateMarket(uint256 tfIdx, bytes32 pairId) external {
        _createMarket(tfIdx, pairId);
    }
}

contract UpDownUnit is Test {
    address owner = address(this);

    function setUp() public {
        vm.warp(1_700_000_000);
    }

    /// @dev Full stack: resolver + settlement + harness cycler (BTC only), automation caller authorized.
    function _deployCyclerSystem() internal returns (UpDownAutoCyclerHarness cycler, UpDownSettlement settlement) {
        MockSequencerUp seq = new MockSequencerUp(0, block.timestamp - 2 hours);
        MockBtcFeed feed = new MockBtcFeed(50_000e8);
        ERC20Mock usdt = new ERC20Mock();
        settlement = new UpDownSettlement(usdt, owner, 70, 80);
        ChainlinkResolver r =
            new ChainlinkResolver(owner, address(seq), BTCUSD, address(feed), bytes32(0), address(0), address(settlement));
        settlement.setResolver(address(r));
        cycler = new UpDownAutoCyclerHarness(owner, address(r), address(settlement));
        settlement.setAutocycler(address(cycler));
        r.setAuthorizedCaller(address(cycler), true);
    }

    function test_resolveTieGoesDown() public {
        MockSequencerUp seq = new MockSequencerUp(0, block.timestamp - 2 hours);
        MockAggregatorV3 feed = new MockAggregatorV3();
        // Market is created at `now`, ends at `now + 300`. Round 7 lands
        // 60s before endTime; round 8 lands 60s after — round 7 is the
        // canonical one for this market.
        uint256 createdAt = block.timestamp;
        feed.setRound(7, 50_000e8, createdAt + 240);
        feed.setRound(8, 60_000e8, createdAt + 360);

        ERC20Mock usdt = new ERC20Mock();
        UpDownSettlement settlement = new UpDownSettlement(usdt, owner, 70, 80);

        ChainlinkResolver r = new ChainlinkResolver(
            owner, address(seq), BTCUSD, address(feed), bytes32(0), address(0), address(settlement)
        );
        settlement.setResolver(address(r));

        vm.prank(address(this));
        settlement.setAutocycler(address(this));
        uint256 mid = settlement.createMarket(BTCUSD, 300, 50_000e8);

        r.registerMarket(mid, address(settlement), BTCUSD, 50_000e8);

        // Warp into the resolution window. `MAX_STALENESS = 1h` so the
        // canonical round (60s pre-endTime) is well within the staleness
        // bound at this point.
        vm.warp(createdAt + 400);
        r.resolve(mid, 7);
        (,,, bool resolved) = r.markets(mid);
        assertTrue(resolved);
        assertEq(settlement.getMarket(mid).winner, 2, "tie price == strike => DOWN");
    }

    function test_resolverResolveTryCatchLeavesUnresolvedOnRevert() public {
        MockSequencerUp seq = new MockSequencerUp(0, block.timestamp - 2 hours);
        MockAggregatorV3 feed = new MockAggregatorV3();
        // MockSettlementResolve hardcodes `endTime = block.timestamp - 1` at
        // the moment its `getMarket` is called. We resolve at warp+500 below,
        // so endTime ~= (createdAt + 500) - 1. Place round 4 strictly before
        // that and round 5 strictly after.
        uint256 createdAt = block.timestamp;
        feed.setRound(4, 50_000e8, createdAt + 100);
        feed.setRound(5, 50_000e8, createdAt + 600);

        MockSettlementResolve target = new MockSettlementResolve(1, BTCUSD, 40_000e8);

        ChainlinkResolver r = new ChainlinkResolver(
            owner, address(seq), BTCUSD, address(feed), bytes32(0), address(0), address(target)
        );

        r.registerMarket(1, address(target), BTCUSD, 40_000e8);
        target.setShouldRevert(true);

        vm.warp(createdAt + 500);
        r.resolve(1, 4);

        (,,, bool resolved) = r.markets(1);
        assertFalse(resolved, "must stay unresolved when settlement resolve reverts");
    }

    // ── PR-10 (P0-16): roundId-bound resolution invariants ──────────────

    /// @notice Happy path: caller supplies the canonical roundId (latest
    ///         updatedAt <= endTime; next round updatedAt > endTime) and
    ///         resolution succeeds with that round's price.
    function test_resolve_happyPath_picksCanonicalRound() public {
        MockSequencerUp seq = new MockSequencerUp(0, block.timestamp - 2 hours);
        MockAggregatorV3 feed = new MockAggregatorV3();
        uint256 createdAt = block.timestamp;
        feed.setRound(10, 60_000e8, createdAt + 100);
        feed.setRound(11, 70_000e8, createdAt + 250); // canonical: latest <= endTime
        feed.setRound(12, 80_000e8, createdAt + 350); // next: postdates endTime
        ERC20Mock usdt = new ERC20Mock();
        UpDownSettlement settlement = new UpDownSettlement(usdt, owner, 70, 80);
        ChainlinkResolver r = new ChainlinkResolver(
            owner, address(seq), BTCUSD, address(feed), bytes32(0), address(0), address(settlement)
        );
        settlement.setResolver(address(r));
        settlement.setAutocycler(address(this));
        uint256 mid = settlement.createMarket(BTCUSD, 300, 50_000e8); // endTime = createdAt + 300
        r.registerMarket(mid, address(settlement), BTCUSD, 50_000e8);

        vm.warp(createdAt + 400);
        r.resolve(mid, 11);

        (,,, bool resolved) = r.markets(mid);
        assertTrue(resolved);
        assertEq(int256(settlement.getMarket(mid).settlementPrice), 70_000e8, "settles at the canonical round's price");
        assertEq(settlement.getMarket(mid).winner, 1, "70k > 50k strike => UP");
    }

    /// @notice Wrong roundId: round AFTER endTime → reverts RoundTooLate.
    ///         This is the core race-to-resolve attack: a caller submits a
    ///         roundId that postdates endTime to bias the price in their
    ///         favour. The contract must reject regardless of `block.timestamp`.
    function test_resolve_revertsWhenRoundIsAfterEndTime() public {
        MockSequencerUp seq = new MockSequencerUp(0, block.timestamp - 2 hours);
        MockAggregatorV3 feed = new MockAggregatorV3();
        uint256 createdAt = block.timestamp;
        feed.setRound(10, 60_000e8, createdAt + 250); // canonical
        feed.setRound(11, 80_000e8, createdAt + 350); // post-endTime: attacker would want this
        feed.setRound(12, 90_000e8, createdAt + 450);
        ERC20Mock usdt = new ERC20Mock();
        UpDownSettlement settlement = new UpDownSettlement(usdt, owner, 70, 80);
        ChainlinkResolver r = new ChainlinkResolver(
            owner, address(seq), BTCUSD, address(feed), bytes32(0), address(0), address(settlement)
        );
        settlement.setResolver(address(r));
        settlement.setAutocycler(address(this));
        uint256 mid = settlement.createMarket(BTCUSD, 300, 50_000e8); // endTime = createdAt + 300
        r.registerMarket(mid, address(settlement), BTCUSD, 50_000e8);

        vm.warp(createdAt + 500);
        vm.expectRevert(ChainlinkResolver.RoundTooLate.selector);
        r.resolve(mid, 11);
    }

    /// @notice Wrong roundId: caller supplies a round whose `updatedAt` is
    ///         pre-endTime, but the NEXT round's `updatedAt` is ALSO pre-
    ///         endTime — i.e. there's a strictly later valid round. Reverts
    ///         NotLastPreEndTimeRound. Forces the resolution price to the
    ///         single canonical round per market regardless of which
    ///         pre-endTime round the caller picked.
    function test_resolve_revertsWhenEarlierThanLatestPreEndTime() public {
        MockSequencerUp seq = new MockSequencerUp(0, block.timestamp - 2 hours);
        MockAggregatorV3 feed = new MockAggregatorV3();
        uint256 createdAt = block.timestamp;
        feed.setRound(10, 30_000e8, createdAt + 50); // earlier; caller picks this
        feed.setRound(11, 60_000e8, createdAt + 250); // canonical
        feed.setRound(12, 80_000e8, createdAt + 350); // post-endTime
        ERC20Mock usdt = new ERC20Mock();
        UpDownSettlement settlement = new UpDownSettlement(usdt, owner, 70, 80);
        ChainlinkResolver r = new ChainlinkResolver(
            owner, address(seq), BTCUSD, address(feed), bytes32(0), address(0), address(settlement)
        );
        settlement.setResolver(address(r));
        settlement.setAutocycler(address(this));
        uint256 mid = settlement.createMarket(BTCUSD, 300, 50_000e8);
        r.registerMarket(mid, address(settlement), BTCUSD, 50_000e8);

        vm.warp(createdAt + 400);
        vm.expectRevert(ChainlinkResolver.NotLastPreEndTimeRound.selector);
        r.resolve(mid, 10);
    }

    /// @notice Race scenario: two callers submit different roundIds for the
    ///         same market simultaneously. Only the canonical roundId
    ///         resolves; the other one reverts. Confirms the
    ///         race-to-resolve attack surface is gone.
    function test_resolve_raceTwoCallersOnlyCanonicalSucceeds() public {
        MockSequencerUp seq = new MockSequencerUp(0, block.timestamp - 2 hours);
        MockAggregatorV3 feed = new MockAggregatorV3();
        uint256 createdAt = block.timestamp;
        feed.setRound(20, 40_000e8, createdAt + 100);
        feed.setRound(21, 60_000e8, createdAt + 240); // canonical
        feed.setRound(22, 90_000e8, createdAt + 360); // attacker prefers this (UP swing)
        ERC20Mock usdt = new ERC20Mock();
        UpDownSettlement settlement = new UpDownSettlement(usdt, owner, 70, 80);
        ChainlinkResolver r = new ChainlinkResolver(
            owner, address(seq), BTCUSD, address(feed), bytes32(0), address(0), address(settlement)
        );
        settlement.setResolver(address(r));
        settlement.setAutocycler(address(this));
        uint256 mid = settlement.createMarket(BTCUSD, 300, 50_000e8);
        r.registerMarket(mid, address(settlement), BTCUSD, 50_000e8);

        vm.warp(createdAt + 500);

        // Attacker tries to resolve with the post-endTime round 22 first;
        // contract rejects.
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(ChainlinkResolver.RoundTooLate.selector);
        r.resolve(mid, 22);

        // Honest caller resolves with the canonical round; succeeds.
        address honest = makeAddr("honest");
        vm.prank(honest);
        r.resolve(mid, 21);

        (,,, bool resolved) = r.markets(mid);
        assertTrue(resolved);
        assertEq(int256(settlement.getMarket(mid).settlementPrice), 60_000e8);
        assertEq(settlement.getMarket(mid).winner, 1, "60k > 50k strike => UP at canonical round");
    }

    /// @notice After a successful resolve, a second attempt — even with the
    ///         canonical roundId — reverts AlreadyResolved. Defence-in-depth
    ///         on top of the existing settlement-side double-resolve guard.
    function test_resolve_revertsWhenAlreadyResolved() public {
        MockSequencerUp seq = new MockSequencerUp(0, block.timestamp - 2 hours);
        MockAggregatorV3 feed = new MockAggregatorV3();
        uint256 createdAt = block.timestamp;
        feed.setRound(1, 60_000e8, createdAt + 240);
        feed.setRound(2, 70_000e8, createdAt + 360);
        ERC20Mock usdt = new ERC20Mock();
        UpDownSettlement settlement = new UpDownSettlement(usdt, owner, 70, 80);
        ChainlinkResolver r = new ChainlinkResolver(
            owner, address(seq), BTCUSD, address(feed), bytes32(0), address(0), address(settlement)
        );
        settlement.setResolver(address(r));
        settlement.setAutocycler(address(this));
        uint256 mid = settlement.createMarket(BTCUSD, 300, 50_000e8);
        r.registerMarket(mid, address(settlement), BTCUSD, 50_000e8);

        vm.warp(createdAt + 400);
        r.resolve(mid, 1);
        vm.expectRevert(ChainlinkResolver.AlreadyResolved.selector);
        r.resolve(mid, 1);
    }

    function test_performUpkeepPrunesResolved() public {
        MockSequencerUp seq = new MockSequencerUp(0, block.timestamp - 2 hours);
        MockBtcFeed feed = new MockBtcFeed(50_000e8);
        ERC20Mock usdt = new ERC20Mock();
        UpDownSettlement settlement = new UpDownSettlement(usdt, owner, 70, 80);

        ChainlinkResolver resolver =
            new ChainlinkResolver(owner, address(seq), BTCUSD, address(feed), bytes32(0), address(0), address(settlement));
        settlement.setResolver(address(resolver));

        UpDownAutoCyclerHarness cycler = new UpDownAutoCyclerHarness(owner, address(resolver), address(settlement));
        settlement.setAutocycler(address(cycler));
        resolver.setAuthorizedCaller(address(cycler), true);

        vm.prank(address(cycler));
        uint256 mid = settlement.createMarket(BTCUSD, 300, 50_000e8);
        resolver.registerMarket(mid, address(settlement), BTCUSD, 50_000e8);

        vm.warp(block.timestamp + 400);
        vm.prank(address(resolver));
        settlement.resolve(mid, 50_000e8, 2);

        cycler.harnessPushActive(mid, 0, BTCUSD);

        assertEq(cycler.activeMarketCount(), 1);

        uint256[] memory empty = new uint256[](0);
        UpDownAutoCycler.CreateSlot[] memory noCreates = new UpDownAutoCycler.CreateSlot[](0);
        cycler.performUpkeep(abi.encode(empty, noCreates));

        assertEq(cycler.activeMarketCount(), 0, "prune should remove resolved market");
    }

    function test_createMarketFailureIsolation() public {
        // Settlement that always reverts on createMarket
        RevertingSettlement bad = new RevertingSettlement();

        MockSequencerUp seq = new MockSequencerUp(0, block.timestamp - 2 hours);
        MockBtcFeed feed = new MockBtcFeed(50_000e8);
        ChainlinkResolver resolver =
            new ChainlinkResolver(owner, address(seq), BTCUSD, address(feed), bytes32(0), address(0), address(bad));

        UpDownAutoCyclerHarness cycler = new UpDownAutoCyclerHarness(owner, address(resolver), address(bad));
        resolver.setAuthorizedCaller(address(cycler), true);

        vm.warp(block.timestamp + 400 days);
        uint256[] memory resolveEmpty = new uint256[](0);
        UpDownAutoCycler.CreateSlot[] memory createAll = new UpDownAutoCycler.CreateSlot[](3);
        createAll[0] = UpDownAutoCycler.CreateSlot({pairId: BTCUSD, tfIdx: 0});
        createAll[1] = UpDownAutoCycler.CreateSlot({pairId: BTCUSD, tfIdx: 1});
        createAll[2] = UpDownAutoCycler.CreateSlot({pairId: BTCUSD, tfIdx: 2});

        cycler.performUpkeep(abi.encode(resolveEmpty, createAll));

        assertEq(cycler.activeMarketCount(), 0, "all creates fail; nothing active");
    }

    /// @notice Same idea as "12:01:30": 90s after a 5-minute boundary; market snaps to the slot start.
    function test_clockAlignedFiveMin_intraSlotCreation() public {
        uint256 ts = 1_234_567_890;
        assertEq(ts % 300, 90);
        vm.warp(ts);
        (UpDownAutoCyclerHarness cycler, UpDownSettlement settlement) = _deployCyclerSystem();

        cycler.harnessCreateMarket(0, BTCUSD);

        uint256 slotStart = (ts / 300) * 300;
        UpDownSettlement.Market memory m = settlement.getMarket(1);
        assertEq(uint256(m.startTime), slotStart, "start = floor(now/300)*300");
        assertEq(uint256(m.endTime), slotStart + 300, "end = next 5m boundary");
    }

    function test_clockAligned_multiTimeframe_sharedBoundary() public {
        uint256 ts = 1_234_567_890;
        vm.warp(ts);
        (UpDownAutoCyclerHarness cycler, UpDownSettlement settlement) = _deployCyclerSystem();

        uint256 b5 = (ts / 300) * 300;
        uint256 b15 = (ts / 900) * 900;
        assertEq(b5, b15, "fixture: 5m and 15m boundaries coincide");

        cycler.harnessCreateMarket(0, BTCUSD);
        cycler.harnessCreateMarket(1, BTCUSD);

        UpDownSettlement.Market memory m5 = settlement.getMarket(1);
        UpDownSettlement.Market memory m15 = settlement.getMarket(2);
        assertEq(m5.startTime, m15.startTime);
        assertEq(uint256(m5.endTime), b5 + 300);
        assertEq(uint256(m15.endTime), b15 + 900);
    }

    function test_pairTfLastCreated_storesBoundaryNotBlockTimestamp() public {
        uint256 ts = 1_234_567_890;
        vm.warp(ts);
        (UpDownAutoCyclerHarness cycler,) = _deployCyclerSystem();

        cycler.harnessCreateMarket(0, BTCUSD);

        uint256 boundary = (ts / 300) * 300;
        assertEq(cycler.pairTfLastCreated(BTCUSD, 0), boundary);
        assertTrue(cycler.pairTfLastCreated(BTCUSD, 0) != ts);
    }
}

contract RevertingSettlement {
    function createMarket(bytes32, uint256, int256) external pure returns (uint256) {
        revert("no create");
    }

    function createMarket(bytes32, uint256, int256, uint64, uint64) external pure returns (uint256) {
        revert("no create");
    }

    function getMarket(uint256) external pure returns (UpDownSettlement.Market memory m) {
        return m;
    }
}
