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
        return (0, _price, block.timestamp, block.timestamp, 0);
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
}

contract UpDownUnit is Test {
    address owner = address(this);

    function setUp() public {
        vm.warp(1_700_000_000);
    }

    function test_resolveTieGoesDown() public {
        MockSequencerUp seq = new MockSequencerUp(0, block.timestamp - 2 hours);
        MockBtcFeed feed = new MockBtcFeed(50_000e8);

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

        vm.warp(block.timestamp + 400);
        r.resolve(mid);
        (,,, bool resolved) = r.markets(mid);
        assertTrue(resolved);
        assertEq(settlement.getMarket(mid).winner, 2, "tie price == strike => DOWN");
    }

    function test_resolverResolveTryCatchLeavesUnresolvedOnRevert() public {
        MockSequencerUp seq = new MockSequencerUp(0, block.timestamp - 2 hours);
        MockBtcFeed feed = new MockBtcFeed(50_000e8);

        MockSettlementResolve target = new MockSettlementResolve(1, BTCUSD, 40_000e8);

        ChainlinkResolver r = new ChainlinkResolver(
            owner, address(seq), BTCUSD, address(feed), bytes32(0), address(0), address(target)
        );

        r.registerMarket(1, address(target), BTCUSD, 40_000e8);
        target.setShouldRevert(true);

        vm.warp(block.timestamp + 500);
        r.resolve(1);

        (,,, bool resolved) = r.markets(1);
        assertFalse(resolved, "must stay unresolved when settlement resolve reverts");
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
}

contract RevertingSettlement {
    function createMarket(bytes32, uint256, int256) external pure returns (uint256) {
        revert("no create");
    }

    function getMarket(uint256) external pure returns (UpDownSettlement.Market memory m) {
        return m;
    }
}
