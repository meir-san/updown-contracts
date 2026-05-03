// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, console} from "forge-std/Test.sol";
import {ChainlinkResolver} from "../src/ChainlinkResolver.sol";
import {UpDownAutoCycler} from "../src/UpDownAutoCycler.sol";
import {UpDownSettlement} from "../src/UpDownSettlement.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/// @notice Fork tests for ChainlinkResolver + UpDownAutoCycler + UpDownSettlement against Arbitrum Chainlink feeds.
contract UpDownForkTest is Test {
    // ── Arbitrum mainnet Chainlink addresses ────────────────────────────
    address constant CHAINLINK_BTC_USD = 0x6ce185860a4963106506C203335A2910413708e9;
    address constant CHAINLINK_ETH_USD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address constant CHAINLINK_SEQUENCER = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D;

    // ── Pair IDs ────────────────────────────────────────────────────────
    bytes32 constant BTCUSD = keccak256("BTC/USD");
    bytes32 constant ETHUSD = keccak256("ETH/USD");

    // ── Test state ──────────────────────────────────────────────────────
    ChainlinkResolver resolver;
    UpDownAutoCycler cycler;
    UpDownSettlement settlement;
    ERC20Mock usdt;
    address owner = address(this);

    function setUp() public {
        string memory rpc = vm.envOr("ARBITRUM_RPC_URL", string("https://arb1.arbitrum.io/rpc"));
        vm.createSelectFork(rpc);

        usdt = new ERC20Mock();
        settlement = new UpDownSettlement(usdt, owner, 70, 80);

        resolver = new ChainlinkResolver(
            owner, CHAINLINK_SEQUENCER, BTCUSD, CHAINLINK_BTC_USD, ETHUSD, CHAINLINK_ETH_USD, address(settlement)
        );
        settlement.setResolver(address(resolver));

        cycler = new UpDownAutoCycler(owner, address(resolver), address(settlement));
        settlement.setAutocycler(address(cycler));
        settlement.setRelayer(owner);

        resolver.setAuthorizedCaller(address(cycler), true);

        usdt.mint(owner, 10_000_000e18);
        usdt.approve(address(settlement), type(uint256).max);
    }

    function test_getPrice() public view {
        int256 price = resolver.getPrice(BTCUSD);
        assertGt(price, 0, "BTC price should be positive");
        assertGt(price, 1000e8, "BTC price should be > $1000");
        console.log("BTC/USD price:", uint256(price));
    }

    function test_getPriceETH() public view {
        int256 price = resolver.getPrice(ETHUSD);
        assertGt(price, 0, "ETH price should be positive");
        assertGt(price, 100e8, "ETH price should be > $100");
        console.log("ETH/USD price:", uint256(price));
    }

    function test_getPriceUnconfiguredReverts() public {
        bytes32 fakePair = keccak256("FAKE/USD");
        vm.expectRevert(ChainlinkResolver.FeedNotConfigured.selector);
        resolver.getPrice(fakePair);
    }

    function test_sequencerDownReverts() public {
        MockSequencer mockSeq = new MockSequencer(1, block.timestamp);
        ERC20Mock u = new ERC20Mock();
        UpDownSettlement st = new UpDownSettlement(u, owner, 70, 80);
        ChainlinkResolver resolverDown =
            new ChainlinkResolver(owner, address(mockSeq), BTCUSD, CHAINLINK_BTC_USD, ETHUSD, address(0), address(st));

        vm.expectRevert(ChainlinkResolver.SequencerDown.selector);
        resolverDown.getPrice(BTCUSD);
    }

    function test_sequencerGracePeriodReverts() public {
        MockSequencer mockSeq = new MockSequencer(0, block.timestamp);
        ERC20Mock u = new ERC20Mock();
        UpDownSettlement st = new UpDownSettlement(u, owner, 70, 80);
        ChainlinkResolver resolverGrace =
            new ChainlinkResolver(owner, address(mockSeq), BTCUSD, CHAINLINK_BTC_USD, ETHUSD, address(0), address(st));

        vm.expectRevert(ChainlinkResolver.SequencerGracePeriod.selector);
        resolverGrace.getPrice(BTCUSD);
    }

    function test_stalePriceReverts() public {
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(ChainlinkResolver.StalePrice.selector);
        resolver.getPrice(BTCUSD);
    }

    /// @dev PR-10 (P0-16): walk the live Chainlink BTC feed backwards from
    ///      `latestRoundData()` to find the latest round whose `updatedAt <=
    ///      endTime`, with the next round's `updatedAt > endTime`. Mirrors
    ///      what the off-chain `ChainlinkResolverService` does. Bounded to
    ///      512 hops to keep fork-test gas finite even on a stale feed.
    function _findCanonicalRound(address feedAddr, uint256 endTime) internal view returns (uint80) {
        AggregatorV3Interface feed = AggregatorV3Interface(feedAddr);
        (uint80 latestId,,, uint256 latestUpdatedAt,) = feed.latestRoundData();
        // If the feed hasn't produced a round AFTER endTime yet, no canonical
        // round exists — the contract's nextRound > endTime check would fail.
        // Fork tests warp +400s after endTime, so this should never trigger
        // on a healthy mainnet feed; revert loud if it does.
        require(latestUpdatedAt > endTime, "fork: latest round predates endTime");
        uint80 r = latestId;
        for (uint256 i = 0; i < 512 && r > 0; ++i) {
            uint80 candidate = r - 1;
            (, , , uint256 updatedAt, ) = feed.getRoundData(candidate);
            if (updatedAt <= endTime) return candidate;
            r = candidate;
        }
        revert("fork: canonical round not found in 512 hops");
    }

    function test_resolveBeforeExpiryReverts() public {
        vm.prank(address(cycler));
        uint256 mid = settlement.createMarket(BTCUSD, 300, 50_000e8);
        resolver.registerMarket(mid, address(settlement), BTCUSD, 50_000e8);

        vm.expectRevert(ChainlinkResolver.MarketNotExpired.selector);
        // Any roundId — the call must revert at the endTime check first.
        resolver.resolve(mid, 1);
    }

    function test_resolveUnregisteredReverts() public {
        vm.expectRevert(ChainlinkResolver.MarketNotRegistered.selector);
        resolver.resolve(999_999, 1);
    }

    function test_doubleResolveReverts() public {
        vm.prank(address(cycler));
        uint256 mid = settlement.createMarket(BTCUSD, 300, 50_000e8);
        resolver.registerMarket(mid, address(settlement), BTCUSD, 50_000e8);

        uint256 endTime = uint256(settlement.getMarket(mid).endTime);
        vm.warp(block.timestamp + 400);
        uint80 canonical = _findCanonicalRound(CHAINLINK_BTC_USD, endTime);
        resolver.resolve(mid, canonical);

        vm.expectRevert(ChainlinkResolver.AlreadyResolved.selector);
        resolver.resolve(mid, canonical);
    }

    function test_resolveUpWins() public {
        int256 currentPrice = resolver.getPrice(BTCUSD);
        int256 strike = currentPrice - 1000e8;

        vm.prank(address(cycler));
        uint256 mid = settlement.createMarket(BTCUSD, 300, strike);
        resolver.registerMarket(mid, address(settlement), BTCUSD, strike);

        uint256 endTime = uint256(settlement.getMarket(mid).endTime);
        vm.warp(block.timestamp + 400);
        uint80 canonical = _findCanonicalRound(CHAINLINK_BTC_USD, endTime);
        resolver.resolve(mid, canonical);

        assertEq(settlement.getMarket(mid).winner, resolver.OPTION_UP(), "UP should win when price > strike");
    }

    function test_resolveDownWins() public {
        int256 currentPrice = resolver.getPrice(BTCUSD);
        int256 strike = currentPrice + 1000e8;

        vm.prank(address(cycler));
        uint256 mid = settlement.createMarket(BTCUSD, 300, strike);
        resolver.registerMarket(mid, address(settlement), BTCUSD, strike);

        uint256 endTime = uint256(settlement.getMarket(mid).endTime);
        vm.warp(block.timestamp + 400);
        uint80 canonical = _findCanonicalRound(CHAINLINK_BTC_USD, endTime);
        resolver.resolve(mid, canonical);

        assertEq(settlement.getMarket(mid).winner, resolver.OPTION_DOWN(), "DOWN should win when price <= strike");
    }

    function test_registerMarketAuth() public {
        address rando = address(0xbabe);

        vm.prank(address(cycler));
        uint256 mid = settlement.createMarket(BTCUSD, 300, 50_000e8);

        vm.prank(rando);
        vm.expectRevert("unauthorized");
        resolver.registerMarket(mid, address(settlement), BTCUSD, 50_000e8);

        resolver.registerMarket(mid, address(settlement), BTCUSD, 50_000e8);
    }

    function test_checkUpkeepReturnsTrue() public view {
        (bool needed,) = cycler.checkUpkeep("");
        assertTrue(needed, "upkeep should be needed on fresh deploy");
    }

    function test_pruneResolved() public {
        cycler.pruneResolved();
        assertEq(cycler.activeMarketCount(), 0);
    }

    function test_toggleTimeframe() public {
        cycler.toggleTimeframe(0, false);
        (uint256 dur,, bool active) = cycler.timeframes(0);
        assertFalse(active, "timeframe 0 should be inactive");
        assertEq(dur, 300, "duration should still be 300");

        cycler.toggleTimeframe(0, true);
        (,, active) = cycler.timeframes(0);
        assertTrue(active, "timeframe 0 should be active again");
    }

    function test_toggleTimeframeInvalidReverts() public {
        vm.expectRevert(UpDownAutoCycler.InvalidTimeframeIndex.selector);
        cycler.toggleTimeframe(5, true);
    }

    function test_withdrawFunds() public {
        deal(address(usdt), address(cycler), 100_000_000);
        uint256 balBefore = IERC20(address(usdt)).balanceOf(owner);

        cycler.withdrawFunds(address(usdt), 50_000_000);

        assertEq(IERC20(address(usdt)).balanceOf(owner), balBefore + 50_000_000);
    }

    function test_configureFeedOnlyOwner() public {
        address rando = address(0xbabe);
        bytes32 newPair = keccak256("SOL/USD");

        vm.prank(rando);
        vm.expectRevert();
        resolver.configureFeed(newPair, address(0x123));

        resolver.configureFeed(newPair, address(0x123));
        assertEq(resolver.priceFeeds(newPair), address(0x123));
    }

    function test_autocyclerCreatesViaSettlement() public {
        (bool needed, bytes memory data) = cycler.checkUpkeep("");
        assertTrue(needed);
        cycler.performUpkeep(data);
        assertGt(settlement.nextMarketId(), 0);
        assertGt(cycler.activeMarketCount(), 0);
    }

    function test_resolverResolvesViaSettlementNotPool() public {
        vm.prank(address(cycler));
        uint256 mid = settlement.createMarket(BTCUSD, 300, 1);
        resolver.registerMarket(mid, address(settlement), BTCUSD, 1);

        uint256 endTime = uint256(settlement.getMarket(mid).endTime);
        vm.warp(block.timestamp + 400);
        uint80 canonical = _findCanonicalRound(CHAINLINK_BTC_USD, endTime);
        resolver.resolve(mid, canonical);
        assertTrue(settlement.getMarket(mid).resolved);
    }
}

contract MockSequencer {
    int256 private _answer;
    uint256 private _startedAt;

    constructor(int256 answer_, uint256 startedAt_) {
        _answer = answer_;
        _startedAt = startedAt_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, _answer, _startedAt, block.timestamp, 0);
    }

    function decimals() external pure returns (uint8) {
        return 0;
    }
}
