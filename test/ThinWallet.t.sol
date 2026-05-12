// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import {ThinWallet} from "../src/ThinWallet.sol";
import {ThinWalletFactory} from "../src/ThinWalletFactory.sol";

/// @title ThinWalletTest
/// @notice Phase 3 / Gate 2 test suite (post-audit research doc Track 2 Phase 1).
///
///         The single most important test in the entire post-audit batch is
///         `test_isValidSignature_rejectsReplayAcrossWallets`. Without it
///         passing, this contract DOES NOT SHIP. See its comment block for
///         the full Alchemy-LightAccount-bug context.
contract ThinWalletTest is Test {
    bytes4 internal constant ERC1271_MAGIC = IERC1271.isValidSignature.selector;
    bytes4 internal constant ERC1271_INVALID = bytes4(0xffffffff);

    ThinWalletFactory internal factory;
    ERC20Mock internal usdt;

    // Two distinct EOAs, deterministic for reproducibility. Test deployments
    // create wallets owned by `ownerA` (and a second wallet owned by the
    // same EOA for the cross-wallet replay test).
    address internal ownerA;
    uint256 internal ownerAKey;
    address internal randoSigner;
    uint256 internal randoSignerKey;

    function setUp() public {
        factory = new ThinWalletFactory();
        usdt = new ERC20Mock();
        (ownerA, ownerAKey) = makeAddrAndKey("ownerA");
        (randoSigner, randoSignerKey) = makeAddrAndKey("randoSigner");
    }

    // ── helpers ─────────────────────────────────────────────────────────

    /// @dev Computes the digest the client must sign for a given (wallet, hash).
    ///      Mirrors `ThinWallet.isValidSignature` digest construction exactly.
    function _digestForWallet(address wallet, bytes32 hash) internal view returns (bytes32) {
        bytes32 typehash = keccak256("WalletAuth(bytes32 hash)");
        bytes32 structHash = keccak256(abi.encode(typehash, hash));
        bytes32 domainSeparator = ThinWallet(wallet).domainSeparator();
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _sign(uint256 privKey, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privKey, digest);
        return abi.encodePacked(r, s, v);
    }

    // ── core: isValidSignature happy path ───────────────────────────────

    function test_isValidSignature_returnsMagicForOwner() public {
        address w = factory.deployWallet(ownerA);
        bytes32 someHash = keccak256("hello");
        bytes memory sig = _sign(ownerAKey, _digestForWallet(w, someHash));
        assertEq(ThinWallet(w).isValidSignature(someHash, sig), ERC1271_MAGIC);
    }

    function test_isValidSignature_rejectsNonOwner() public {
        address w = factory.deployWallet(ownerA);
        bytes32 someHash = keccak256("hello");
        // Sig from the wrong key over the right digest.
        bytes memory sig = _sign(randoSignerKey, _digestForWallet(w, someHash));
        assertEq(ThinWallet(w).isValidSignature(someHash, sig), ERC1271_INVALID);
    }

    function test_isValidSignature_rejectsTamperedHash() public {
        address w = factory.deployWallet(ownerA);
        bytes32 trueHash = keccak256("hello");
        bytes memory sig = _sign(ownerAKey, _digestForWallet(w, trueHash));
        bytes32 tampered = keccak256("hellp");
        assertEq(ThinWallet(w).isValidSignature(tampered, sig), ERC1271_INVALID);
    }

    function test_isValidSignature_rejectsMalformedSignature() public {
        address w = factory.deployWallet(ownerA);
        bytes32 someHash = keccak256("hello");
        // ECDSA.tryRecover returns InvalidSignatureLength → wallet returns 0xffffffff.
        bytes memory tooShort = hex"deadbeef";
        assertEq(ThinWallet(w).isValidSignature(someHash, tooShort), ERC1271_INVALID);
    }

    function test_isValidSignature_rejectsHighSValue() public {
        // EIP-2 malleability: a signature with s > secp256k1n/2 must be rejected.
        // OpenZeppelin's ECDSA.tryRecover returns RecoverError.InvalidSignatureS
        // for high-s sigs.
        address w = factory.deployWallet(ownerA);
        bytes32 someHash = keccak256("hello");
        bytes32 digest = _digestForWallet(w, someHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerAKey, digest);
        // Flip s to its high counterpart. The low-s value `s` produces a valid
        // sig; mathematically `n - s` is also a valid s on secp256k1 but is the
        // malleable counterpart that EIP-2 forbids.
        bytes32 nMinusS = bytes32(uint256(0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141 - uint256(s)));
        uint8 flippedV = v == 27 ? 28 : 27;
        bytes memory highSSig = abi.encodePacked(r, nMinusS, flippedV);
        assertEq(ThinWallet(w).isValidSignature(someHash, highSSig), ERC1271_INVALID);
    }

    // ── THE NON-NEGOTIABLE: cross-wallet replay defense ─────────────────

    /// @notice **The single most important test in the entire Phase 3 batch.**
    ///
    /// Background — Alchemy LightAccount pre-patch bug pattern:
    ///   Alchemy discovered a vulnerability in LightAccount where an EOA
    ///   that owned MULTIPLE LightAccounts could sign a message for wallet
    ///   A and have that same signature unintentionally validate against
    ///   wallet B. Root cause: `isValidSignature` checked `recovered ==
    ///   owner` against the same EOA across both wallets without any
    ///   per-wallet binding in the signed digest.
    ///
    /// Our defense: the EIP-712 domain separator embeds `verifyingContract
    /// = address(this)`. Two wallets at different addresses have different
    /// domain separators, so the same `hash` produces a different signing
    /// digest in each. A signature meant for wallet W1 has a `recovered`
    /// that's only the owner against W1's digest; against W2's digest the
    /// recovery returns a different address.
    ///
    /// This test pins BOTH directions: W1 ACCEPTS the sig (positive control,
    /// proves the binding works in the correct direction) AND W2 REJECTS
    /// the same sig (negative — the defense).
    ///
    /// Without this test green, the contract does not ship.
    function test_isValidSignature_rejectsReplayAcrossWallets() public {
        // Deploy wallet W1 owned by ownerA.
        address w1 = factory.deployWallet(ownerA);

        // Deploy wallet W2 also owned by ownerA. CREATE2 with
        // salt=keccak256(owner) collides at the factory level — re-deploying
        // the same owner reverts. To get two wallets owned by ownerA, we
        // deploy a SECOND factory and use it.
        ThinWalletFactory factory2 = new ThinWalletFactory();
        address w2 = factory2.deployWallet(ownerA);

        // Sanity: both wallets exist, both report ownerA as owner, but their
        // addresses differ. This is the exact pre-condition for the LightAccount
        // bug (same EOA, multiple wallets).
        assertEq(ThinWallet(w1).owner(), ownerA);
        assertEq(ThinWallet(w2).owner(), ownerA);
        assertTrue(w1 != w2, "W1 and W2 must have distinct addresses for this test");

        bytes32 someHash = keccak256("transfer 100 USDT to attacker");

        // Sign the message bound to W1's domain.
        bytes32 digestForW1 = _digestForWallet(w1, someHash);
        bytes memory sig = _sign(ownerAKey, digestForW1);

        // Positive control: W1 accepts the sig (its own digest was signed).
        assertEq(
            ThinWallet(w1).isValidSignature(someHash, sig),
            ERC1271_MAGIC,
            "W1 must accept its own sig (positive control)"
        );

        // The defense: W2 rejects the SAME sig because its domain separator
        // produces a different digest, so `recovered` is NOT ownerA against
        // W2's digest. Without `address(this)` in the domain, this would
        // pass — same `hash`, same `recovered == ownerA`, MAGIC. THAT is
        // the Alchemy LightAccount bug. Our domain-separator binding
        // closes it.
        assertEq(
            ThinWallet(w2).isValidSignature(someHash, sig),
            ERC1271_INVALID,
            "W2 must REJECT a sig signed for W1 - Alchemy LightAccount defense"
        );
    }

    // ── chain binding (table-stakes) ────────────────────────────────────

    /// @notice EIP-712 domain separator embeds `block.chainid`, so a sig
    ///         produced on chain X cannot replay against the same wallet
    ///         address deployed on chain Y. Free coverage (EIP-712 base
    ///         handles it), but pinning the property explicitly lets the
    ///         auditor see both wallet-binding (above) AND chain-binding
    ///         (here) under test.
    function test_isValidSignature_rejectsCrossChainReplay() public {
        // Deploy a wallet on the default test chainid.
        uint256 originalChainId = block.chainid;
        address w = factory.deployWallet(ownerA);

        bytes32 someHash = keccak256("cross-chain test");

        // Sign against the wallet's domain as it exists right now (chainId X).
        bytes32 digestChainX = _digestForWallet(w, someHash);
        bytes memory sig = _sign(ownerAKey, digestChainX);

        // Positive control: on the current chain, sig is accepted.
        assertEq(
            ThinWallet(w).isValidSignature(someHash, sig),
            ERC1271_MAGIC,
            "sig must validate on the chain it was signed for"
        );

        // Move to a different chainid. The wallet's domain separator
        // recomputes with the new chainid (OZ EIP712 base handles this on
        // chain fork). The same `someHash` now produces a different digest,
        // so the sig signed against the original chain's digest no longer
        // recovers to ownerA.
        vm.chainId(originalChainId + 1);
        assertEq(
            ThinWallet(w).isValidSignature(someHash, sig),
            ERC1271_INVALID,
            "sig signed for chain X must be REJECTED on chain Y"
        );
    }

    // ── owner ops ───────────────────────────────────────────────────────

    function test_withdraw_onlyOwner() public {
        address w = factory.deployWallet(ownerA);
        usdt.mint(w, 1_000e6);
        vm.prank(randoSigner);
        vm.expectRevert(ThinWallet.NotOwner.selector);
        ThinWallet(w).withdraw(usdt, 100e6);
    }

    function test_withdraw_ownerSucceedsAndEmits() public {
        address w = factory.deployWallet(ownerA);
        usdt.mint(w, 1_000e6);
        vm.expectEmit(true, false, false, true, w);
        emit ThinWallet.Withdrawn(address(usdt), 600e6);
        vm.prank(ownerA);
        ThinWallet(w).withdraw(usdt, 600e6);
        assertEq(usdt.balanceOf(w), 400e6);
        assertEq(usdt.balanceOf(ownerA), 600e6);
    }

    function test_approveSettlement_onlyOwner() public {
        address w = factory.deployWallet(ownerA);
        address fakeSettlement = address(0x1234);
        vm.prank(randoSigner);
        vm.expectRevert(ThinWallet.NotOwner.selector);
        ThinWallet(w).approveSettlement(usdt, fakeSettlement, 1_000e6);
    }

    function test_approveSettlement_ownerSucceedsAndEmits() public {
        address w = factory.deployWallet(ownerA);
        address fakeSettlement = address(0x1234);
        vm.expectEmit(true, true, false, true, w);
        emit ThinWallet.SettlementApproved(address(usdt), fakeSettlement, 1_000e6);
        vm.prank(ownerA);
        ThinWallet(w).approveSettlement(usdt, fakeSettlement, 1_000e6);
        assertEq(usdt.allowance(w, fakeSettlement), 1_000e6);
    }

    function test_constructor_rejectsZeroOwner() public {
        vm.expectRevert(ThinWallet.ZeroOwner.selector);
        new ThinWallet(address(0));
    }

    // ── factory ─────────────────────────────────────────────────────────

    function test_factory_deploysAtPredictedAddress() public {
        address predicted = factory.predictWallet(ownerA);
        address actual = factory.deployWallet(ownerA);
        assertEq(actual, predicted, "actual deploy must match prediction (CREATE2 determinism)");
    }

    function test_factory_redeploySameOwnerReverts() public {
        factory.deployWallet(ownerA);
        // CREATE2 collision — re-deploying same owner via same factory fails.
        vm.expectRevert();
        factory.deployWallet(ownerA);
    }

    function test_factory_anyoneCanDeployForAnyone() public {
        // A different sender deploys a wallet owned by `ownerA`. This must
        // succeed (open factory) but ownership stays with `ownerA`.
        vm.prank(randoSigner);
        address w = factory.deployWallet(ownerA);
        assertEq(ThinWallet(w).owner(), ownerA);
    }

    function test_factory_ownerCannotBeStolenViaFrontRun() public {
        // Adversary front-runs the user's intended deployment by submitting
        // the same `deployWallet(ownerA)` first. The wallet still has
        // `owner == ownerA` because owner is set from the input argument,
        // not msg.sender. The adversary's only "win" is paying gas for
        // someone else's wallet.
        vm.prank(randoSigner);
        address w = factory.deployWallet(ownerA);
        assertEq(ThinWallet(w).owner(), ownerA, "owner must be the constructor input, not msg.sender");

        // Adversary cannot now make themselves owner via any wallet method
        // — owner is immutable, no setter exists. We assert by absence: if
        // the contract had a `setOwner`, this line would change; right now
        // the contract has no such function.
        // (Compile-time check; no runtime assertion needed.)
    }

    function test_factory_zeroOwnerReverts() public {
        vm.expectRevert(ThinWalletFactory.ZeroOwner.selector);
        factory.deployWallet(address(0));
    }

    function test_factory_predictsBeforeDeploy() public {
        // Wallet doesn't exist yet — `predictWallet` returns an address
        // with no code, but the prediction is stable.
        address predicted = factory.predictWallet(ownerA);
        assertEq(predicted.code.length, 0, "predicted address has no code pre-deploy");
        address actual = factory.deployWallet(ownerA);
        assertEq(actual, predicted);
        assertGt(predicted.code.length, 0, "post-deploy, predicted address has code");
    }

    // ── domain separator readback ──────────────────────────────────────

    function test_domainSeparator_bindsVerifyingContractToWalletAddress() public {
        address w = factory.deployWallet(ownerA);
        bytes32 sep = ThinWallet(w).domainSeparator();

        // Reconstruct what the domain separator MUST be per EIP-712.
        bytes32 expected = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("PulsePairsThinWallet")),
                keccak256(bytes("1")),
                block.chainid,
                w // verifyingContract == THIS wallet's address; THE binding
            )
        );
        assertEq(sep, expected, "domain separator must embed address(this), not the factory or settlement");
    }
}
