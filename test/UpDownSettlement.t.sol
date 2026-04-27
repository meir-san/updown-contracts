// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UpDownSettlement} from "../src/UpDownSettlement.sol";

bytes32 constant PAIR = keccak256("BTC/USD");

/// @notice Minimal ERC-1271 contract account used to test SA-style traders.
///         Mirrors how Alchemy MA v2 SAs verify signatures: delegate to a
///         configured owner EOA via ECDSA recover, return magic value on match.
contract MockERC1271Account is IERC1271 {
    bytes4 private constant MAGIC = 0x1626ba7e;
    address public owner;

    constructor(address _owner) {
        owner = _owner;
    }

    function isValidSignature(bytes32 hash, bytes memory signature) external view override returns (bytes4) {
        if (ECDSA.recover(hash, signature) == owner) return MAGIC;
        return 0xffffffff;
    }
}

contract UpDownSettlementTest is Test {
    ERC20Mock internal usdt;
    UpDownSettlement internal s;
    address internal owner = address(this);
    address internal autocycler = makeAddr("autocycler");
    address internal resolver = makeAddr("resolver");
    address internal relayer = makeAddr("relayer");

    // Test maker with known key so we can sign EIP-712 orders in-test via vm.sign.
    Vm.Wallet internal maker;

    function setUp() public {
        vm.warp(1_700_000_000);
        usdt = new ERC20Mock();
        s = new UpDownSettlement(usdt, owner, 70, 80);
        s.setAutocycler(autocycler);
        s.setResolver(resolver);
        s.setRelayer(relayer);

        maker = vm.createWallet("maker");
        usdt.mint(maker.addr, 10_000_000e18);
        vm.prank(maker.addr);
        usdt.approve(address(s), type(uint256).max);
    }

    // Internal helper: makers sign an EIP-712 Order and we submit it through enterPosition.
    // Mirrors the backend's flow: the maker signs once when placing the order, the settlement
    // service later calls enterPosition with the signed order + the actual fill amount.
    function _fill(
        uint256 marketId,
        uint8 option,
        uint256 amount,
        uint256 nonce
    ) internal {
        UpDownSettlement.Order memory order = UpDownSettlement.Order({
            maker: maker.addr,
            market: marketId,
            option: uint256(option),
            side: 0, // BUY
            orderType: 0, // LIMIT
            price: 5500,
            amount: amount,
            nonce: nonce,
            expiry: block.timestamp + 3600
        });
        bytes32 digest = s.orderDigest(order);
        (uint8 v, bytes32 r, bytes32 sSig) = vm.sign(maker.privateKey, digest);
        bytes memory sig = abi.encodePacked(r, sSig, v);
        s.enterPosition(order, sig, marketId, option, amount);
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
        assertLt(gasUsed, 120_000, "createMarket gas should stay well below factory deploy cost");
        assertLt(gasUsed, 110_000, "packed cold create stays under 110k");
    }

    function test_enterPositionUpAndDown() public {
        vm.prank(autocycler);
        uint256 mid = s.createMarket(PAIR, 300, 50_000e8);

        _fill(mid, 1, 100e18, 1);
        _fill(mid, 2, 200e18, 2);

        UpDownSettlement.Market memory m = s.getMarket(mid);
        assertEq(m.totalUp, 100e18);
        assertEq(m.totalDown, 200e18);
    }

    // ── Signature-path tests (new) ──────────────────────────────────────

    function test_rejectsBadSignature() public {
        vm.prank(autocycler);
        uint256 mid = s.createMarket(PAIR, 300, 50_000e8);

        UpDownSettlement.Order memory order = UpDownSettlement.Order({
            maker: maker.addr,
            market: mid,
            option: 1,
            side: 0,
            orderType: 0,
            price: 5500,
            amount: 50e18,
            nonce: 99,
            expiry: block.timestamp + 3600
        });
        // Sign with the WRONG key — recovery returns another address, not maker.
        Vm.Wallet memory imposter = vm.createWallet("imposter");
        bytes32 digest = s.orderDigest(order);
        (uint8 v, bytes32 r, bytes32 sSig) = vm.sign(imposter.privateKey, digest);
        bytes memory sig = abi.encodePacked(r, sSig, v);

        vm.expectRevert(UpDownSettlement.InvalidSignature.selector);
        s.enterPosition(order, sig, mid, 1, 50e18);
    }

    function test_rejectsFillExceedingSignedAmount() public {
        vm.prank(autocycler);
        uint256 mid = s.createMarket(PAIR, 300, 50_000e8);

        UpDownSettlement.Order memory order = UpDownSettlement.Order({
            maker: maker.addr,
            market: mid,
            option: 1,
            side: 0,
            orderType: 0,
            price: 5500,
            amount: 100e18,
            nonce: 1,
            expiry: block.timestamp + 3600
        });
        bytes32 digest = s.orderDigest(order);
        (uint8 v, bytes32 r, bytes32 sSig) = vm.sign(maker.privateKey, digest);
        bytes memory sig = abi.encodePacked(r, sSig, v);

        // First call for 60 ok; second call for 41 (total 101 > 100) must revert.
        s.enterPosition(order, sig, mid, 1, 60e18);
        vm.expectRevert(UpDownSettlement.FillExceedsOrderAmount.selector);
        s.enterPosition(order, sig, mid, 1, 41e18);
    }

    function test_partialFillsAccumulate() public {
        vm.prank(autocycler);
        uint256 mid = s.createMarket(PAIR, 300, 50_000e8);

        UpDownSettlement.Order memory order = UpDownSettlement.Order({
            maker: maker.addr,
            market: mid,
            option: 2,
            side: 0,
            orderType: 0,
            price: 5500,
            amount: 100e18,
            nonce: 2,
            expiry: block.timestamp + 3600
        });
        bytes32 digest = s.orderDigest(order);
        (uint8 v, bytes32 r, bytes32 sSig) = vm.sign(maker.privateKey, digest);
        bytes memory sig = abi.encodePacked(r, sSig, v);

        s.enterPosition(order, sig, mid, 2, 30e18);
        s.enterPosition(order, sig, mid, 2, 40e18);
        s.enterPosition(order, sig, mid, 2, 30e18); // exactly at cap
        assertEq(s.getMarket(mid).totalDown, 100e18);
        assertEq(s.orderRemaining(order), 0);
    }

    function test_rejectsExpiredOrder() public {
        vm.prank(autocycler);
        uint256 mid = s.createMarket(PAIR, 300, 50_000e8);

        UpDownSettlement.Order memory order = UpDownSettlement.Order({
            maker: maker.addr,
            market: mid,
            option: 1,
            side: 0,
            orderType: 0,
            price: 5500,
            amount: 50e18,
            nonce: 3,
            expiry: block.timestamp + 60
        });
        bytes32 digest = s.orderDigest(order);
        (uint8 v, bytes32 r, bytes32 sSig) = vm.sign(maker.privateKey, digest);
        bytes memory sig = abi.encodePacked(r, sSig, v);

        vm.warp(order.expiry + 1);
        vm.expectRevert(UpDownSettlement.OrderExpired.selector);
        s.enterPosition(order, sig, mid, 1, 50e18);
    }

    function test_rejectsMarketMismatch() public {
        vm.prank(autocycler);
        uint256 mid = s.createMarket(PAIR, 300, 50_000e8);
        vm.prank(autocycler);
        uint256 other = s.createMarket(PAIR, 300, 60_000e8);

        UpDownSettlement.Order memory order = UpDownSettlement.Order({
            maker: maker.addr,
            market: mid,
            option: 1,
            side: 0,
            orderType: 0,
            price: 5500,
            amount: 50e18,
            nonce: 4,
            expiry: block.timestamp + 3600
        });
        bytes32 digest = s.orderDigest(order);
        (uint8 v, bytes32 r, bytes32 sSig) = vm.sign(maker.privateKey, digest);
        bytes memory sig = abi.encodePacked(r, sSig, v);

        vm.expectRevert(UpDownSettlement.MarketMismatch.selector);
        s.enterPosition(order, sig, other, 1, 50e18);
    }

    function test_rejectsSellSide() public {
        vm.prank(autocycler);
        uint256 mid = s.createMarket(PAIR, 300, 50_000e8);

        UpDownSettlement.Order memory order = UpDownSettlement.Order({
            maker: maker.addr,
            market: mid,
            option: 1,
            side: 1, // SELL — sellers don't enter positions via this path
            orderType: 0,
            price: 5500,
            amount: 50e18,
            nonce: 5,
            expiry: block.timestamp + 3600
        });
        bytes32 digest = s.orderDigest(order);
        (uint8 v, bytes32 r, bytes32 sSig) = vm.sign(maker.privateKey, digest);
        bytes memory sig = abi.encodePacked(r, sSig, v);

        vm.expectRevert(UpDownSettlement.InvalidSide.selector);
        s.enterPosition(order, sig, mid, 1, 50e18);
    }

    function test_erc1271_smartAccountAsMaker() public {
        // Mirror prod: SA holds USDT; EOA owner signs; order.maker = SA address.
        Vm.Wallet memory eoaOwner = vm.createWallet("eoaOwner");
        MockERC1271Account sa = new MockERC1271Account(eoaOwner.addr);

        // Fund the SA (not the EOA). Approve settlement from the SA.
        usdt.mint(address(sa), 1_000e18);
        vm.prank(address(sa));
        usdt.approve(address(s), type(uint256).max);

        vm.prank(autocycler);
        uint256 mid = s.createMarket(PAIR, 300, 50_000e8);

        UpDownSettlement.Order memory order = UpDownSettlement.Order({
            maker: address(sa), // ← SA is the maker
            market: mid,
            option: 1,
            side: 0,
            orderType: 0,
            price: 5500,
            amount: 50e18,
            nonce: 1,
            expiry: block.timestamp + 3600
        });
        // Critical: sign with EOA OWNER, not the SA. The SA's isValidSignature
        // recovers the EOA and returns MAGIC iff it matches.
        bytes32 digest = s.orderDigest(order);
        (uint8 v, bytes32 r, bytes32 sSig) = vm.sign(eoaOwner.privateKey, digest);
        bytes memory sig = abi.encodePacked(r, sSig, v);

        uint256 saBefore = usdt.balanceOf(address(sa));
        s.enterPosition(order, sig, mid, 1, 50e18);
        // USDT was pulled from the SA, not from the EOA owner.
        assertEq(usdt.balanceOf(address(sa)), saBefore - 50e18);
        assertEq(s.getMarket(mid).totalUp, 50e18);
    }

    function test_erc1271_rejectsWrongOwnerSignature() public {
        // Owner-mismatch must revert with InvalidSignature, not silently accept.
        Vm.Wallet memory eoaOwner = vm.createWallet("eoaOwner2");
        Vm.Wallet memory imposter = vm.createWallet("imposter1271");
        MockERC1271Account sa = new MockERC1271Account(eoaOwner.addr);

        vm.prank(autocycler);
        uint256 mid = s.createMarket(PAIR, 300, 50_000e8);

        UpDownSettlement.Order memory order = UpDownSettlement.Order({
            maker: address(sa),
            market: mid,
            option: 1,
            side: 0,
            orderType: 0,
            price: 5500,
            amount: 50e18,
            nonce: 2,
            expiry: block.timestamp + 3600
        });
        bytes32 digest = s.orderDigest(order);
        (uint8 v, bytes32 r, bytes32 sSig) = vm.sign(imposter.privateKey, digest);
        bytes memory sig = abi.encodePacked(r, sSig, v);

        vm.expectRevert(UpDownSettlement.InvalidSignature.selector);
        s.enterPosition(order, sig, mid, 1, 50e18);
    }

    function test_anyoneCanSubmit() public {
        // Anyone may call — no onlyRelayer gate. Maker's sig is the only auth.
        vm.prank(autocycler);
        uint256 mid = s.createMarket(PAIR, 300, 50_000e8);

        UpDownSettlement.Order memory order = UpDownSettlement.Order({
            maker: maker.addr,
            market: mid,
            option: 1,
            side: 0,
            orderType: 0,
            price: 5500,
            amount: 50e18,
            nonce: 6,
            expiry: block.timestamp + 3600
        });
        bytes32 digest = s.orderDigest(order);
        (uint8 v, bytes32 r, bytes32 sSig) = vm.sign(maker.privateKey, digest);
        bytes memory sig = abi.encodePacked(r, sSig, v);

        address randomCaller = makeAddr("random");
        vm.prank(randomCaller);
        s.enterPosition(order, sig, mid, 1, 50e18);
        assertEq(s.getMarket(mid).totalUp, 50e18);
    }

    // ── End-to-end flow tests (adapted to signed-order path) ────────────

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

        assertEq(s.getMarket(mid).winner, 2);
    }

    function test_tieGoesDownInResolverStyle() public {
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

        _fill(mid, 1, 1000e18, 10);
        _fill(mid, 2, 1000e18, 11);

        vm.warp(block.timestamp + 301);
        vm.prank(resolver);
        s.resolve(mid, 2e18, 1);

        uint256 relBefore = usdt.balanceOf(relayer);
        vm.prank(relayer);
        s.withdrawSettlement(mid);

        uint256 totalPool = 2000e18;
        uint256 expectedFees = (totalPool * 150) / 10_000;
        uint256 expectedNet = totalPool - expectedFees;

        assertEq(usdt.balanceOf(relayer), relBefore + expectedNet);
        assertEq(s.totalAccumulatedFees(), expectedFees);

        UpDownSettlement.Market memory m = s.getMarket(mid);
        assertTrue(m.settled);
    }

    function test_doubleWithdrawReverts() public {
        vm.prank(autocycler);
        uint256 mid = s.createMarket(PAIR, 300, 1e18);

        _fill(mid, 1, 10e18, 20);

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

        _fill(mid, 1, 10e18, 30);

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

        _fill(mid, 1, 100_000e18, 40);
        _fill(mid, 2, 50_000e18, 41);

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
        vm.prank(autocycler);
        uint256 mid = s.createMarket(PAIR, 300, 1e18);
        _fill(mid, 1, 1000e18, 50);
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
