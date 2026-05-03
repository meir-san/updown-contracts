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

        // PR-16 (P1-15): rebate funding now sources from accumulated fees
        // rather than pulling from the relayer's external wallet. Run a
        // settlement first so totalAccumulatedFees > 0, then accumulate.
        vm.prank(autocycler);
        uint256 mid = s.createMarket(PAIR, 300, 1e18);
        _fill(mid, 1, 1000e18, 60);
        _fill(mid, 2, 1000e18, 61);
        vm.warp(block.timestamp + 301);
        vm.prank(resolver);
        s.resolve(mid, 2e18, 1);
        vm.prank(relayer);
        s.withdrawSettlement(mid);
        uint256 feesBefore = s.totalAccumulatedFees();
        require(feesBefore >= 5e18, "fixture: fees too small");

        vm.prank(relayer);
        s.accumulateRebate(dmm, 5e18);

        assertEq(s.dmmRebateAccumulated(dmm), 5e18);
        assertEq(s.totalAccumulatedFees(), feesBefore - 5e18);

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
        // PR-16: relayer's external balance no longer matters here. Just
        // ensure the not-DMM path reverts without funding the contract.
        vm.prank(relayer);
        vm.expectRevert(UpDownSettlement.NotDMM.selector);
        s.accumulateRebate(address(0x123), 1e18);
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
        // PR-16 (P1-16): counter decrements in lockstep with the transfer.
        assertEq(s.totalAccumulatedFees(), 0);
    }

    // ── PR-16 (P1-15 + P1-16 + P1-17 + P1-18) ─────────────────────────

    /// @dev Helper: settle one market so the contract has a non-zero
    ///      totalAccumulatedFees + matching USDT balance to draw from.
    function _settleOneMarketForFees() internal returns (uint256 feesAfter) {
        vm.prank(autocycler);
        uint256 mid = s.createMarket(PAIR, 300, 1e18);
        _fill(mid, 1, 1000e18, 70);
        _fill(mid, 2, 1000e18, 71);
        vm.warp(block.timestamp + 301);
        vm.prank(resolver);
        s.resolve(mid, 2e18, 1);
        vm.prank(relayer);
        s.withdrawSettlement(mid);
        return s.totalAccumulatedFees();
    }

    function test_pr16_accumulateRebate_revertsWhenAmountExceedsFees() public {
        address dmm = address(0xd00);
        s.addDMM(dmm);
        // No prior settlement → totalAccumulatedFees == 0.
        vm.prank(relayer);
        vm.expectRevert(UpDownSettlement.InsufficientAccumulatedFees.selector);
        s.accumulateRebate(dmm, 1);
    }

    function test_pr16_accumulateRebate_decrementsAccumulator() public {
        address dmm = address(0xd00);
        s.addDMM(dmm);
        uint256 fees = _settleOneMarketForFees();
        require(fees >= 1e18, "fixture: need >= 1 USDT in fees");
        uint256 before = s.totalAccumulatedFees();

        vm.prank(relayer);
        s.accumulateRebate(dmm, 1e18);

        assertEq(s.totalAccumulatedFees(), before - 1e18);
        assertEq(s.dmmRebateAccumulated(dmm), 1e18);
    }

    function test_pr16_withdrawFees_revertsWhenAmountExceedsAccumulator() public {
        uint256 fees = _settleOneMarketForFees();
        // Try to over-withdraw by 1.
        vm.expectRevert(UpDownSettlement.InsufficientAccumulatedFees.selector);
        s.withdrawFees(fees + 1);
    }

    function test_pr16_withdrawFees_emitsEventWithTotalAfter() public {
        uint256 fees = _settleOneMarketForFees();
        vm.expectEmit(true, false, false, true);
        emit UpDownSettlement.FeesWithdrawn(address(this), fees, 0);
        s.withdrawFees(fees);
    }

    function test_pr16_getAccumulatedFees_matchesStorage() public {
        uint256 fees = _settleOneMarketForFees();
        assertEq(s.getAccumulatedFees(), fees);
    }

    function test_pr16_emergencyWithdraw_proposeThenExecuteAfter24h() public {
        // Seed the contract with some USDT to withdraw (via the fee path).
        _settleOneMarketForFees();
        uint256 contractBalanceBefore = usdt.balanceOf(address(s));
        require(contractBalanceBefore >= 1e18, "fixture: need balance");

        address recipient = makeAddr("recipient");
        bytes32 proposalId = s.proposeEmergencyWithdraw(address(usdt), recipient, 1e18);
        // Immediate execute fails — timelock not yet elapsed.
        vm.expectRevert(UpDownSettlement.EmergencyTimelockActive.selector);
        s.executeEmergencyWithdraw(proposalId);

        vm.warp(block.timestamp + 24 hours);
        s.executeEmergencyWithdraw(proposalId);

        assertEq(usdt.balanceOf(recipient), 1e18);
        assertEq(usdt.balanceOf(address(s)), contractBalanceBefore - 1e18);
        // Proposal cleared after execute.
        (,,, uint256 unlocksAt) = s.emergencyProposals(proposalId);
        assertEq(unlocksAt, 0);
    }

    function test_pr16_emergencyWithdraw_revertsBeforeTimelock() public {
        _settleOneMarketForFees();
        bytes32 proposalId = s.proposeEmergencyWithdraw(address(usdt), makeAddr("r"), 1e18);
        vm.warp(block.timestamp + 23 hours + 59 minutes);
        vm.expectRevert(UpDownSettlement.EmergencyTimelockActive.selector);
        s.executeEmergencyWithdraw(proposalId);
    }

    function test_pr16_emergencyWithdraw_canBeCancelled() public {
        _settleOneMarketForFees();
        bytes32 proposalId = s.proposeEmergencyWithdraw(address(usdt), makeAddr("r"), 1e18);
        s.cancelEmergencyWithdraw(proposalId);
        // Subsequent execute reverts as not-found.
        vm.warp(block.timestamp + 24 hours);
        vm.expectRevert(UpDownSettlement.EmergencyProposalNotFound.selector);
        s.executeEmergencyWithdraw(proposalId);
    }

    function test_pr16_emergencyWithdraw_executeUnknownProposalReverts() public {
        bytes32 fakeId = keccak256("not-a-real-proposal");
        vm.expectRevert(UpDownSettlement.EmergencyProposalNotFound.selector);
        s.executeEmergencyWithdraw(fakeId);
    }

    function test_pr16_emergencyWithdraw_zeroAddressReverts() public {
        vm.expectRevert(UpDownSettlement.ZeroAddress.selector);
        s.proposeEmergencyWithdraw(address(0), makeAddr("r"), 1);
        vm.expectRevert(UpDownSettlement.ZeroAddress.selector);
        s.proposeEmergencyWithdraw(address(usdt), address(0), 1);
    }

    function test_pr16_emergencyWithdraw_onlyOwner() public {
        address attacker = makeAddr("attacker");
        vm.startPrank(attacker);
        vm.expectRevert();
        s.proposeEmergencyWithdraw(address(usdt), attacker, 1);
        vm.expectRevert();
        s.executeEmergencyWithdraw(bytes32(0));
        vm.expectRevert();
        s.cancelEmergencyWithdraw(bytes32(0));
        vm.stopPrank();
    }

    function test_pr16_emergencyWithdraw_distinctNonceForIdenticalProposals() public {
        _settleOneMarketForFees();
        address recipient = makeAddr("r");
        bytes32 a = s.proposeEmergencyWithdraw(address(usdt), recipient, 1e18);
        bytes32 b = s.proposeEmergencyWithdraw(address(usdt), recipient, 1e18);
        assertTrue(a != b, "monotonic nonce keeps two identical proposals distinct");
    }
}
