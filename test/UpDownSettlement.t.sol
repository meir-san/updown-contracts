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
    /// PR-5-bundle: thin wrapper that translates a (order, sig, mid,
    /// option, amount) call into the new FillInputs ABI + relayer prank.
    /// Keeps the existing test bodies' visual shape intact while
    /// preserving the new onlyRelayer guard semantics.
    function _callEnter(
        UpDownSettlement.Order memory order,
        bytes memory sig,
        uint256 mid,
        uint8 option,
        uint256 amount
    ) internal {
        UpDownSettlement.FillInputs memory f = UpDownSettlement.FillInputs({
            order: order,
            signature: sig,
            marketId: mid,
            option: option,
            fillAmount: amount,
            taker: address(0),
            sellerReceives: 0,
            platformFee: 0,
            makerFee: 0,
            makerFeeRecipient: address(0)
        });
        vm.prank(relayer);
        s.enterPosition(f);
    }

    /// PR-5-bundle: legacy `_fill` helper now wraps into the FillInputs
    /// struct. By default zero-valued sellerReceives/platformFee/makerFee
    /// + zero counterparty so existing tests measure pure entry-side
    /// behavior unchanged from pre-bundle. PR-5-specific tests use
    /// `_fillAtomic` below to exercise the atomic-settlement path.
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
            side: 0,
            orderType: 0,
            price: 5500,
            amount: amount,
            nonce: nonce,
            expiry: block.timestamp + 3600
        });
        bytes32 digest = s.orderDigest(order);
        (uint8 v, bytes32 r, bytes32 sSig) = vm.sign(maker.privateKey, digest);
        bytes memory sig = abi.encodePacked(r, sSig, v);
        UpDownSettlement.FillInputs memory f = UpDownSettlement.FillInputs({
            order: order,
            signature: sig,
            marketId: marketId,
            option: option,
            fillAmount: amount,
            taker: address(0),
            sellerReceives: 0,
            platformFee: 0,
            makerFee: 0,
            makerFeeRecipient: address(0)
        });
        vm.prank(relayer);
        s.enterPosition(f);
    }

    /// PR-5-bundle: atomic-settlement helper. Caller supplies the seller,
    /// fee breakdown, and maker rebate recipient. Used by PR-5 tests.
    function _fillAtomic(
        uint256 marketId,
        uint8 option,
        uint256 amount,
        uint256 nonce,
        address taker,
        uint256 sellerReceives,
        uint256 platformFee,
        uint256 makerFee,
        address makerFeeRecipient
    ) internal {
        UpDownSettlement.Order memory order = UpDownSettlement.Order({
            maker: maker.addr,
            market: marketId,
            option: uint256(option),
            side: 0,
            orderType: 0,
            price: 5500,
            amount: amount,
            nonce: nonce,
            expiry: block.timestamp + 3600
        });
        bytes32 digest = s.orderDigest(order);
        (uint8 v, bytes32 r, bytes32 sSig) = vm.sign(maker.privateKey, digest);
        bytes memory sig = abi.encodePacked(r, sSig, v);
        UpDownSettlement.FillInputs memory f = UpDownSettlement.FillInputs({
            order: order,
            signature: sig,
            marketId: marketId,
            option: option,
            fillAmount: amount,
            taker: taker,
            sellerReceives: sellerReceives,
            platformFee: platformFee,
            makerFee: makerFee,
            makerFeeRecipient: makerFeeRecipient
        });
        vm.prank(relayer);
        s.enterPosition(f);
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
        _callEnter(order, sig, mid, 1, 50e18);
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
        _callEnter(order, sig, mid, 1, 60e18);
        vm.expectRevert(UpDownSettlement.FillExceedsOrderAmount.selector);
        _callEnter(order, sig, mid, 1, 41e18);
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

        _callEnter(order, sig, mid, 2, 30e18);
        _callEnter(order, sig, mid, 2, 40e18);
        _callEnter(order, sig, mid, 2, 30e18); // exactly at cap
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
        _callEnter(order, sig, mid, 1, 50e18);
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
        _callEnter(order, sig, other, 1, 50e18);
    }

    function test_rejectsInvalidSide() public {
        // PR-5-bundle: SELL (side=1) is now valid — atomic settlement
        // routes seller payout through enterPosition. Only side values
        // outside {0, 1} should revert. Sign side=2 directly to exercise.
        vm.prank(autocycler);
        uint256 mid = s.createMarket(PAIR, 300, 50_000e8);

        UpDownSettlement.Order memory order = UpDownSettlement.Order({
            maker: maker.addr,
            market: mid,
            option: 1,
            side: 2, // INVALID — only 0 (BUY) or 1 (SELL) allowed
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
        _callEnter(order, sig, mid, 1, 50e18);
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
        _callEnter(order, sig, mid, 1, 50e18);
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
        _callEnter(order, sig, mid, 1, 50e18);
    }

    function test_pr5_onlyRelayerCanSubmit() public {
        // PR-5-bundle (P0-13): the "anyone can submit a signed order"
        // model is rejected. Only the relayer is allowed to call
        // enterPosition. A leaked signed order is no longer settleable
        // by an unauthorized caller post-cancel.
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
        UpDownSettlement.FillInputs memory f = UpDownSettlement.FillInputs({
            order: order,
            signature: sig,
            marketId: mid,
            option: 1,
            fillAmount: 50e18,
            taker: address(0),
            sellerReceives: 0,
            platformFee: 0,
            makerFee: 0,
            makerFeeRecipient: address(0)
        });

        address randomCaller = makeAddr("random");
        vm.prank(randomCaller);
        vm.expectRevert(UpDownSettlement.OnlyRelayer.selector);
        s.enterPosition(f);

        // Relayer succeeds.
        vm.prank(relayer);
        s.enterPosition(f);
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

    /// PR-Gap-bundle: `withdrawSettlement` now hands the relayer exactly
    /// `marketRetained[mid]` (collateral that the contract actually holds)
    /// rather than the pre-fix parimutuel `totalPool × (1 − feeBps/10000)`
    /// figure that had no relationship to formula (c) outflows.
    /// `_fill` here passes sellerReceives=platformFee=makerFee=0, so the
    /// contract retains the entire fillAmount per fill — the relayer
    /// receives 2000e18 and `totalAccumulatedFees` stays at 0 (fees never
    /// accumulate in-contract under formula (c) — they leave atomically
    /// inside `enterPosition`).
    function test_withdrawSettlementFees() public {
        vm.prank(autocycler);
        uint256 mid = s.createMarket(PAIR, 300, 1e18);

        _fill(mid, 1, 1000e18, 10);
        _fill(mid, 2, 1000e18, 11);

        vm.warp(block.timestamp + 301);
        vm.prank(resolver);
        s.resolve(mid, 2e18, 1);

        uint256 relBefore = usdt.balanceOf(relayer);
        // Pre-withdraw, the contract holds the per-market retained.
        assertEq(s.marketRetained(mid), 2000e18);

        vm.prank(relayer);
        s.withdrawSettlement(mid);

        // Post-withdraw: relayer holds the full retained, on-chain
        // bookkeeping is cleared, fee counter unchanged.
        assertEq(usdt.balanceOf(relayer), relBefore + 2000e18);
        assertEq(s.marketRetained(mid), 0);
        assertEq(s.totalAccumulatedFees(), 0);

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

    /// PR-Gap-bundle reframe (was: test_rebateAccumulateAndClaim happy path):
    /// under formula (c), `totalAccumulatedFees` is intentionally never
    /// incremented — fees leave the contract atomically inside
    /// `enterPosition` (to `treasury` and `makerFeeRecipient`). The
    /// pre-bundle DMM rebate path that drew from the in-contract fee
    /// bucket is therefore unreachable until a follow-up rebuilds it
    /// against `treasury` rather than the contract. This test now pins
    /// the new invariant: even after a fully settled market, accumulating
    /// any non-zero rebate reverts.
    function test_postGap_dmmRebatePathUnreachable() public {
        address dmm = address(0xd00);
        s.addDMM(dmm);

        vm.prank(autocycler);
        uint256 mid = s.createMarket(PAIR, 300, 1e18);
        _fill(mid, 1, 1000e18, 60);
        _fill(mid, 2, 1000e18, 61);
        vm.warp(block.timestamp + 301);
        vm.prank(resolver);
        s.resolve(mid, 2e18, 1);
        vm.prank(relayer);
        s.withdrawSettlement(mid);

        // Post-settlement, the fee counter must still be zero — fees are
        // not in-contract under formula (c).
        assertEq(s.totalAccumulatedFees(), 0);

        vm.prank(relayer);
        vm.expectRevert(UpDownSettlement.InsufficientAccumulatedFees.selector);
        s.accumulateRebate(dmm, 1);

        // DMM never received anything — rebate funding mechanism is
        // intentionally disabled until the follow-up.
        assertEq(s.dmmRebateAccumulated(dmm), 0);
        assertEq(usdt.balanceOf(dmm), 0);
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

    /// @dev Helper: leave the contract holding some USDT so withdraw-fee /
    ///      emergency-withdraw tests have something to draw from. Pre
    ///      PR-Gap-bundle this seeded `totalAccumulatedFees` via the
    ///      pre-fix `withdrawSettlement` path; under formula (c) that
    ///      path no longer increments the counter, so we mint USDT
    ///      directly into the contract instead. The fees counter
    ///      stays at 0, which is the correct post-fix invariant.
    function _settleOneMarketForFees() internal returns (uint256 feesAfter) {
        usdt.mint(address(s), 100e18);
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

    /// PR-Gap-bundle reframe: the pre-fix decrement-on-rebate path is
    /// unreachable under formula (c). The single-revert `…revertsWhenAmount
    /// ExceedsFees` test above is now the canonical assertion that
    /// rebate accumulation is gated on a counter that's always zero.
    /// This test is preserved as a marker for the follow-up that should
    /// rebuild rebates against `treasury` rather than the contract.
    function test_postGap_rebateDecrementMechanismIsDisabled() public {
        address dmm = address(0xd00);
        s.addDMM(dmm);
        // No path increments totalAccumulatedFees under formula (c).
        assertEq(s.totalAccumulatedFees(), 0);
        vm.prank(relayer);
        vm.expectRevert(UpDownSettlement.InsufficientAccumulatedFees.selector);
        s.accumulateRebate(dmm, 1);
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

    // ── PR-5-bundle atomic-settlement tests ─────────────────────────────

    /// @dev Helper: create a market + register a treasury + a fresh seller
    ///      with an approved USDT allowance. Returns (marketId, treasury, seller).
    function _atomicFixture() internal returns (uint256 mid, address treas, address sellerEoa, address takerEoa) {
        vm.prank(autocycler);
        mid = s.createMarket(PAIR, 300, 1e18);

        treas = makeAddr("treasury");
        s.setTreasury(treas);

        sellerEoa = makeAddr("sellerEoa");
        takerEoa = makeAddr("takerEoa");
        usdt.mint(sellerEoa, 10_000e18);
        usdt.mint(takerEoa, 10_000e18);
        vm.prank(sellerEoa);
        usdt.approve(address(s), type(uint256).max);
        vm.prank(takerEoa);
        usdt.approve(address(s), type(uint256).max);
    }

    function test_pr5_atomicHappyPath_buyerPaysSellerTreasuryMakerAtomically() public {
        (uint256 mid, address treas, address sellerEoa,) = _atomicFixture();
        // Buyer is the maker (BUY-side), seller is the taker.
        // 100 USDT fill, 95 to seller, 0.7 platform fee, 0.8 maker rebate.
        uint256 fillAmt = 100e18;
        uint256 sellerReceives = 95e18;
        uint256 platformFee = 7e17; // 0.7
        uint256 makerFee = 8e17;    // 0.8 — total = 96.5; buyer's residual 3.5 stays in pool

        uint256 buyerBefore = usdt.balanceOf(maker.addr);
        uint256 contractBefore = usdt.balanceOf(address(s));
        uint256 sellerBefore = usdt.balanceOf(sellerEoa);
        uint256 treasBefore = usdt.balanceOf(treas);

        _fillAtomic(mid, 1, fillAmt, 100, sellerEoa, sellerReceives, platformFee, makerFee, maker.addr);

        // Buyer (= maker) paid `fillAmt` out of their wallet.
        assertEq(usdt.balanceOf(maker.addr), buyerBefore - fillAmt + makerFee, "buyer net = -fill + makerFee (maker is also recipient)");
        // Seller received `sellerReceives`.
        assertEq(usdt.balanceOf(sellerEoa), sellerBefore + sellerReceives);
        // Treasury received `platformFee`.
        assertEq(usdt.balanceOf(treas), treasBefore + platformFee);
        // Contract retains the residual.
        uint256 residual = fillAmt - sellerReceives - platformFee - makerFee;
        assertEq(usdt.balanceOf(address(s)), contractBefore + residual, "contract retains the buyer's residual for at-resolution backing");
        // PositionEntered + FillSettled both fired.
        assertEq(s.getMarket(mid).totalUp, fillAmt);
    }

    function test_pr5_feeBreakdownInvalid_revertsWhenSumExceedsFill() public {
        (uint256 mid,, address sellerEoa,) = _atomicFixture();
        // Inline so vm.expectRevert lands on `enterPosition`, not the
        // helper's intervening `orderDigest` view call.
        UpDownSettlement.Order memory order = UpDownSettlement.Order({
            maker: maker.addr, market: mid, option: 1, side: 0, orderType: 0,
            price: 5500, amount: 100e18, nonce: 101, expiry: block.timestamp + 3600
        });
        bytes32 digest = s.orderDigest(order);
        (uint8 v, bytes32 r, bytes32 sSig) = vm.sign(maker.privateKey, digest);
        bytes memory sig = abi.encodePacked(r, sSig, v);
        UpDownSettlement.FillInputs memory f = UpDownSettlement.FillInputs({
            order: order, signature: sig, marketId: mid, option: 1,
            fillAmount: 100e18,           // 95 + 6 + 0 = 101 > 100 — must revert.
            taker: sellerEoa, sellerReceives: 95e18, platformFee: 6e18,
            makerFee: 0, makerFeeRecipient: address(0)
        });
        vm.prank(relayer);
        vm.expectRevert(UpDownSettlement.FeeBreakdownInvalid.selector);
        s.enterPosition(f);
    }

    function test_pr5_treasuryNotConfigured_revertsWhenPlatformFeeOnZeroAddress() public {
        // No setTreasury — fee path should fail closed.
        vm.prank(autocycler);
        uint256 mid = s.createMarket(PAIR, 300, 1e18);
        address sellerEoa = makeAddr("sellerNoTreas");
        usdt.mint(sellerEoa, 10_000e18);
        vm.prank(sellerEoa);
        usdt.approve(address(s), type(uint256).max);

        UpDownSettlement.Order memory order = UpDownSettlement.Order({
            maker: maker.addr, market: mid, option: 1, side: 0, orderType: 0,
            price: 5500, amount: 100e18, nonce: 102, expiry: block.timestamp + 3600
        });
        bytes32 digest = s.orderDigest(order);
        (uint8 v, bytes32 r, bytes32 sSig) = vm.sign(maker.privateKey, digest);
        bytes memory sig = abi.encodePacked(r, sSig, v);
        UpDownSettlement.FillInputs memory f = UpDownSettlement.FillInputs({
            order: order, signature: sig, marketId: mid, option: 1,
            fillAmount: 100e18, taker: sellerEoa, sellerReceives: 90e18,
            platformFee: 1e18, makerFee: 0, makerFeeRecipient: address(0)
        });
        vm.prank(relayer);
        vm.expectRevert(UpDownSettlement.TreasuryNotConfigured.selector);
        s.enterPosition(f);
    }

    function test_pr5_makerRebateForNonDmmMaker_paid() public {
        // PR-5-bundle (P0-17): rebates flow to ALL makers, not just DMMs.
        // The contract has no DMM check on enterPosition — the relayer
        // computes makerFee for every maker and the contract pays them.
        (uint256 mid,, address sellerEoa,) = _atomicFixture();
        // maker (the resting BUY side) is NOT registered as a DMM.
        assertFalse(s.isDMM(maker.addr));

        uint256 makerBefore = usdt.balanceOf(maker.addr);
        // 100 fill, 95 to seller, 1 platform, 1 maker rebate. Buyer = maker.
        _fillAtomic(mid, 1, 100e18, 103, sellerEoa, 95e18, 1e18, 1e18, maker.addr);

        // Maker paid 100 out (as buyer), got 1 back as rebate. Net = -99.
        assertEq(usdt.balanceOf(maker.addr), makerBefore - 100e18 + 1e18);
    }

    function test_pr5_zeroSellerSkipsSellerTransfer_initialIssuance() public {
        // PR-5: when seller == address(0), the fill is initial issuance
        // (no counterparty cashing out). Only fees + buyer pull happen.
        (uint256 mid, address treas,,) = _atomicFixture();
        uint256 contractBefore = usdt.balanceOf(address(s));
        uint256 makerBefore = usdt.balanceOf(maker.addr);

        // 100 fill, no seller, 1 platform, 0 maker. Buyer pays 100, treasury gets 1.
        _fillAtomic(mid, 1, 100e18, 104, address(0), 0, 1e18, 0, address(0));

        assertEq(usdt.balanceOf(maker.addr), makerBefore - 100e18);
        assertEq(usdt.balanceOf(treas), 1e18);
        // Contract retains 99 (fillAmount - platformFee).
        assertEq(usdt.balanceOf(address(s)), contractBefore + 99e18);
    }

    function test_pr5_conservationInvariant_sumOfDeltasEqualsZero() public {
        // The audit-defending property test (matches the repro spec's A8).
        // Σ Δ on-chain USDT across {buyer, seller, treasury, contract,
        // makerFeeRecipient} == 0 per fill. No phantom inflows or
        // disappearing collateral.
        (uint256 mid, address treas, address sellerEoa,) = _atomicFixture();
        address makerRecipient = makeAddr("makerRebate");

        int256 buyerBefore = int256(usdt.balanceOf(maker.addr));
        int256 sellerBefore = int256(usdt.balanceOf(sellerEoa));
        int256 treasBefore = int256(usdt.balanceOf(treas));
        int256 makerBefore = int256(usdt.balanceOf(makerRecipient));
        int256 contractBefore = int256(usdt.balanceOf(address(s)));

        _fillAtomic(mid, 1, 100e18, 105, sellerEoa, 90e18, 5e18, 4e18, makerRecipient);

        int256 sumDelta = (int256(usdt.balanceOf(maker.addr)) - buyerBefore)
            + (int256(usdt.balanceOf(sellerEoa)) - sellerBefore)
            + (int256(usdt.balanceOf(treas)) - treasBefore)
            + (int256(usdt.balanceOf(makerRecipient)) - makerBefore)
            + (int256(usdt.balanceOf(address(s))) - contractBefore);
        assertEq(sumDelta, 0, "conservation: no USDT created or destroyed");
    }

    function test_pr5_emitsFillSettledWithFullBreakdown() public {
        (uint256 mid, address treas, address sellerEoa,) = _atomicFixture();
        // Build the order to fish out the structHash for the event topic.
        UpDownSettlement.Order memory order = UpDownSettlement.Order({
            maker: maker.addr,
            market: mid,
            option: 1,
            side: 0,
            orderType: 0,
            price: 5500,
            amount: 100e18,
            nonce: 106,
            expiry: block.timestamp + 3600
        });
        bytes32 structHash = s.hashOrder(order);

        vm.expectEmit(true, true, true, true);
        emit UpDownSettlement.FillSettled(
            structHash,
            maker.addr,    // buyer (BUY-side maker)
            sellerEoa,     // seller (taker)
            100e18,
            90e18,
            5e18,
            4e18,
            maker.addr     // makerFeeRecipient
        );
        // Suppress unused-warning for treas — it's set up but the event uses
        // index args only.
        treas;

        _fillAtomic(mid, 1, 100e18, 106, sellerEoa, 90e18, 5e18, 4e18, maker.addr);
    }

    function test_pr5_setTreasury_emitsAndOnlyOwner() public {
        address t1 = makeAddr("t1");
        s.setTreasury(t1);
        assertEq(s.treasury(), t1);

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert();
        s.setTreasury(makeAddr("t2"));

        vm.expectRevert(UpDownSettlement.ZeroAddress.selector);
        s.setTreasury(address(0));
    }
}
