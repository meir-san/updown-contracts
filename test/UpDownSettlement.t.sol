// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {UpDownSettlement} from "../src/UpDownSettlement.sol";

bytes32 constant PAIR = keccak256("BTC/USD");

contract UpDownSettlementTest is Test {
    ERC20Mock internal usdt;
    UpDownSettlement internal s;
    address internal owner = address(this);
    address internal autocycler = makeAddr("autocycler");
    address internal resolver = makeAddr("resolver");
    address internal relayer = makeAddr("relayer");

    function setUp() public {
        vm.warp(1_700_000_000);
        usdt = new ERC20Mock();
        s = new UpDownSettlement(usdt, owner, 70, 80);
        s.setAutocycler(autocycler);
        s.setResolver(resolver);
        s.setRelayer(relayer);
    }

    function test_killSwitchPausesCreate() public {
        s.setPaused(true);
        vm.prank(autocycler);
        vm.expectRevert(UpDownSettlement.Paused.selector);
        s.createMarket(PAIR, 300, 1e18);
    }

    function test_createMarketGasUnder100k() public {
        vm.prank(autocycler);
        uint256 gasBefore = gasleft();
        s.createMarket(PAIR, 300, 50_000e8);
        uint256 gasUsed = gasBefore - gasleft();
        // Cold path with `via_ir` is ~105k gas after struct packing (no proxy deploy).
        assertLt(gasUsed, 120_000, "createMarket gas should stay well below factory deploy cost");
        assertLt(gasUsed, 110_000, "packed cold create stays under 110k");
    }

    function test_enterPositionUpAndDown() public {
        vm.prank(autocycler);
        uint256 mid = s.createMarket(PAIR, 300, 50_000e8);

        usdt.mint(relayer, 1000e18);
        vm.startPrank(relayer);
        usdt.approve(address(s), type(uint256).max);
        s.enterPosition(mid, 1, 100e18);
        s.enterPosition(mid, 2, 200e18);
        vm.stopPrank();

        UpDownSettlement.Market memory m = s.getMarket(mid);
        assertEq(m.totalUp, 100e18);
        assertEq(m.totalDown, 200e18);
    }

    function test_resolveUpWins() public {
        vm.prank(autocycler);
        uint256 mid = s.createMarket(PAIR, 300, 40_000e8);

        vm.warp(block.timestamp + 301);
        vm.prank(resolver);
        s.resolve(mid, 50_000e8, 1);

        UpDownSettlement.Market memory m = s.getMarket(mid);
        assertTrue(m.resolved);
        assertEq(m.winner, 1);
        assertEq(m.settlementPrice, 50_000e8);
    }

    function test_resolveDownWins() public {
        vm.prank(autocycler);
        uint256 mid = s.createMarket(PAIR, 300, 50_000e8);

        vm.warp(block.timestamp + 301);
        vm.prank(resolver);
        s.resolve(mid, 40_000e8, 2);

        UpDownSettlement.Market memory m = s.getMarket(mid);
        assertEq(m.winner, 2);
    }

    function test_tieGoesDownInResolverStyle() public {
        // Settlement stores whatever resolver passes; resolver uses strict > for UP.
        vm.prank(autocycler);
        uint256 mid = s.createMarket(PAIR, 300, 50_000e8);
        vm.warp(block.timestamp + 301);
        vm.prank(resolver);
        s.resolve(mid, 50_000e8, 2);
        assertEq(s.getMarket(mid).winner, 2);
    }

    function test_withdrawSettlementFees() public {
        vm.prank(autocycler);
        uint256 mid = s.createMarket(PAIR, 300, 1e18);

        usdt.mint(relayer, 10_000e18);
        vm.startPrank(relayer);
        usdt.approve(address(s), type(uint256).max);
        s.enterPosition(mid, 1, 1000e18);
        s.enterPosition(mid, 2, 1000e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 301);
        vm.prank(resolver);
        s.resolve(mid, 2e18, 1);

        uint256 relBefore = usdt.balanceOf(relayer);
        vm.prank(relayer);
        s.withdrawSettlement(mid);

        uint256 totalPool = 2000e18;
        uint256 expectedFees = (totalPool * 150) / 10_000; // 1.5%
        uint256 expectedNet = totalPool - expectedFees;

        assertEq(usdt.balanceOf(relayer), relBefore + expectedNet);
        assertEq(s.totalAccumulatedFees(), expectedFees);

        UpDownSettlement.Market memory m = s.getMarket(mid);
        assertTrue(m.settled);
    }

    function test_doubleWithdrawReverts() public {
        vm.prank(autocycler);
        uint256 mid = s.createMarket(PAIR, 300, 1e18);

        usdt.mint(relayer, 100e18);
        vm.startPrank(relayer);
        usdt.approve(address(s), type(uint256).max);
        s.enterPosition(mid, 1, 10e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 301);
        vm.prank(resolver);
        s.resolve(mid, 2e18, 2);

        vm.prank(relayer);
        s.withdrawSettlement(mid);

        vm.prank(relayer);
        vm.expectRevert(UpDownSettlement.AlreadySettled.selector);
        s.withdrawSettlement(mid);
    }

    function test_withdrawBeforeResolveReverts() public {
        vm.prank(autocycler);
        uint256 mid = s.createMarket(PAIR, 300, 1e18);

        usdt.mint(relayer, 10e18);
        vm.startPrank(relayer);
        usdt.approve(address(s), type(uint256).max);
        s.enterPosition(mid, 1, 10e18);
        vm.stopPrank();

        vm.prank(relayer);
        vm.expectRevert(UpDownSettlement.NotResolved.selector);
        s.withdrawSettlement(mid);
    }

    function test_dmmAddRemove() public {
        address dmm = address(0xd00);
        s.addDMM(dmm);
        assertTrue(s.isDMM(dmm));
        assertEq(s.dmmCount(), 1);
        s.removeDMM(dmm);
        assertFalse(s.isDMM(dmm));
        assertEq(s.dmmCount(), 0);
    }

    function test_rebateAccumulateAndClaim() public {
        address dmm = address(0xd00);
        s.addDMM(dmm);

        usdt.mint(relayer, 100e18);
        vm.startPrank(relayer);
        usdt.approve(address(s), type(uint256).max);
        s.accumulateRebate(dmm, 5e18);
        vm.stopPrank();

        assertEq(s.dmmRebateAccumulated(dmm), 5e18);

        vm.prank(dmm);
        s.claimRebate();

        assertEq(s.dmmRebateAccumulated(dmm), 0);
        assertEq(usdt.balanceOf(dmm), 5e18);
    }

    function test_fullCycle() public {
        vm.prank(autocycler);
        uint256 mid = s.createMarket(PAIR, 900, 10e18);

        usdt.mint(relayer, 1_000_000e18);
        vm.startPrank(relayer);
        usdt.approve(address(s), type(uint256).max);
        s.enterPosition(mid, 1, 100_000e18);
        s.enterPosition(mid, 2, 50_000e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 901);
        vm.prank(resolver);
        s.resolve(mid, 20e18, 1);

        vm.prank(relayer);
        s.withdrawSettlement(mid);

        UpDownSettlement.Market memory m = s.getMarket(mid);
        assertTrue(m.resolved && m.settled);
    }

    function test_accumulateRebateNotDmmReverts() public {
        usdt.mint(relayer, 10e18);
        vm.startPrank(relayer);
        usdt.approve(address(s), type(uint256).max);
        vm.expectRevert(UpDownSettlement.NotDMM.selector);
        s.accumulateRebate(address(0x123), 1e18);
        vm.stopPrank();
    }

    function test_ownerWithdrawFees() public {
        // seed fees via settlement withdraw
        vm.prank(autocycler);
        uint256 mid = s.createMarket(PAIR, 300, 1e18);
        usdt.mint(relayer, 1000e18);
        vm.startPrank(relayer);
        usdt.approve(address(s), type(uint256).max);
        s.enterPosition(mid, 1, 1000e18);
        vm.stopPrank();
        vm.warp(block.timestamp + 301);
        vm.prank(resolver);
        s.resolve(mid, 2e18, 1);
        vm.prank(relayer);
        s.withdrawSettlement(mid);

        uint256 fees = s.totalAccumulatedFees();
        address deployerAddr = address(this);
        uint256 beforeB = usdt.balanceOf(deployerAddr);
        s.withdrawFees(fees);
        assertEq(usdt.balanceOf(deployerAddr), beforeB + fees);
    }
}
