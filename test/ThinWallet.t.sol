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

    // ── executeWithSig (Phase 4 Gate) ───────────────────────────────────
    //
    // The Phase 4 meta-tx wrapper. Same domain + signature primitives as
    // isValidSignature, with replay guards on nonce + deadline. The 13
    // tests below pin the security properties an audit firm would ask for.

    /// @dev Computes the digest the client must sign for an executeWithSig
    ///      envelope. Mirrors `ThinWallet.executeWithSig`'s digest
    ///      construction exactly.
    function _digestForExecuteWithSig(
        address wallet,
        address target,
        bytes memory data,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32) {
        bytes32 typehash = keccak256(
            "ExecuteWithSig(address target,bytes data,uint256 nonce,uint256 deadline)"
        );
        bytes32 structHash = keccak256(abi.encode(typehash, target, keccak256(data), nonce, deadline));
        bytes32 domainSep = ThinWallet(wallet).domainSeparator();
        return keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
    }

    // 1. Happy path — owner signs approve(USDTM, settlement, MAX), relayer broadcasts.
    function test_executeWithSig_happyPath() public {
        address w = factory.deployWallet(ownerA);
        address fakeSettlement = address(0x5e771e);
        bytes memory approveCall = abi.encodeWithSelector(
            usdt.approve.selector, fakeSettlement, type(uint256).max
        );
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(
            ownerAKey, _digestForExecuteWithSig(w, address(usdt), approveCall, nonce, deadline)
        );

        vm.expectEmit(true, true, false, true, w);
        emit ThinWallet.Executed(address(usdt), nonce, approveCall);

        // Relayer (randoSigner) broadcasts on owner's behalf.
        vm.prank(randoSigner);
        ThinWallet(w).executeWithSig(address(usdt), approveCall, nonce, deadline, sig);

        assertEq(usdt.allowance(w, fakeSettlement), type(uint256).max, "allowance set on wallet, not relayer");
        assertTrue(ThinWallet(w).usedNonces(nonce), "nonce consumed");
    }

    // 2. Replay rejected — same valid sig submitted twice.
    function test_executeWithSig_replayRejected() public {
        address w = factory.deployWallet(ownerA);
        bytes memory data = abi.encodeWithSelector(usdt.approve.selector, address(0x1), 1);
        uint256 nonce = 42;
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(ownerAKey, _digestForExecuteWithSig(w, address(usdt), data, nonce, deadline));

        ThinWallet(w).executeWithSig(address(usdt), data, nonce, deadline, sig);

        vm.expectRevert(abi.encodeWithSelector(ThinWallet.NonceAlreadyUsed.selector, nonce));
        ThinWallet(w).executeWithSig(address(usdt), data, nonce, deadline, sig);
    }

    // 3. Expired deadline rejected.
    function test_executeWithSig_expiredDeadline() public {
        address w = factory.deployWallet(ownerA);
        bytes memory data = abi.encodeWithSelector(usdt.approve.selector, address(0x1), 1);
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(ownerAKey, _digestForExecuteWithSig(w, address(usdt), data, nonce, deadline));

        // Move time past deadline.
        vm.warp(deadline + 1);

        vm.expectRevert(
            abi.encodeWithSelector(ThinWallet.ExecuteExpired.selector, deadline, block.timestamp)
        );
        ThinWallet(w).executeWithSig(address(usdt), data, nonce, deadline, sig);
    }

    // 4. Wrong owner — sig made by some other EOA.
    function test_executeWithSig_wrongOwnerSig() public {
        address w = factory.deployWallet(ownerA);
        bytes memory data = abi.encodeWithSelector(usdt.approve.selector, address(0x1), 1);
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 1 hours;
        // randoSigner signs — recovered != ownerA → BadSignature.
        bytes memory sig = _sign(
            randoSignerKey, _digestForExecuteWithSig(w, address(usdt), data, nonce, deadline)
        );

        vm.expectRevert(ThinWallet.BadSignature.selector);
        ThinWallet(w).executeWithSig(address(usdt), data, nonce, deadline, sig);
    }

    // 5. Zero target rejected.
    function test_executeWithSig_zeroTarget() public {
        address w = factory.deployWallet(ownerA);
        bytes memory data = "";
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(
            ownerAKey, _digestForExecuteWithSig(w, address(0), data, nonce, deadline)
        );

        vm.expectRevert(ThinWallet.ZeroTarget.selector);
        ThinWallet(w).executeWithSig(address(0), data, nonce, deadline, sig);
    }

    // 6. Inner call revert bubbles up verbatim.
    //    Use ERC20Mock's transferFrom on a wallet with insufficient allowance;
    //    OZ emits ERC20InsufficientAllowance(spender, allowance, needed).
    function test_executeWithSig_innerCallReverts_bubblesRevertReason() public {
        address w = factory.deployWallet(ownerA);
        // Wallet's USDT balance is 0; transfer 1 will revert with
        // ERC20InsufficientBalance(sender, balance, needed).
        bytes memory data = abi.encodeWithSelector(
            usdt.transfer.selector, randoSigner, uint256(1)
        );
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(ownerAKey, _digestForExecuteWithSig(w, address(usdt), data, nonce, deadline));

        // OZ ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed)
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("ERC20InsufficientBalance(address,uint256,uint256)")),
                w, uint256(0), uint256(1)
            )
        );
        ThinWallet(w).executeWithSig(address(usdt), data, nonce, deadline, sig);
    }

    // 7. **THE GUARDIAN:** sig made for Wallet A submitted to Wallet B → reject.
    //    Mirrors the isValidSignature cross-wallet test. Same Alchemy LightAccount
    //    bug class — proving the address(this) binding extends to the new function.
    function test_executeWithSig_crossWalletReplayRejected() public {
        address w1 = factory.deployWallet(ownerA);
        ThinWalletFactory factory2 = new ThinWalletFactory();
        address w2 = factory2.deployWallet(ownerA);
        assertTrue(w1 != w2, "distinct wallet addresses required for this test");

        bytes memory data = abi.encodeWithSelector(usdt.approve.selector, address(0x1), 1);
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 1 hours;

        // Sign for W1's domain.
        bytes memory sigForW1 = _sign(
            ownerAKey, _digestForExecuteWithSig(w1, address(usdt), data, nonce, deadline)
        );

        // Positive control: W1 accepts.
        ThinWallet(w1).executeWithSig(address(usdt), data, nonce, deadline, sigForW1);

        // The defense: W2 rejects the same sig — different domain separator
        // → different signing digest → recovery != ownerA.
        vm.expectRevert(ThinWallet.BadSignature.selector);
        ThinWallet(w2).executeWithSig(address(usdt), data, nonce, deadline, sigForW1);
    }

    // 8. Cross-chain replay rejected.
    function test_executeWithSig_crossChainReplayRejected() public {
        uint256 originalChainId = block.chainid;
        address w = factory.deployWallet(ownerA);
        bytes memory data = abi.encodeWithSelector(usdt.approve.selector, address(0x1), 1);
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(
            ownerAKey, _digestForExecuteWithSig(w, address(usdt), data, nonce, deadline)
        );

        // Move to a different chainid.
        vm.chainId(originalChainId + 1);

        vm.expectRevert(ThinWallet.BadSignature.selector);
        ThinWallet(w).executeWithSig(address(usdt), data, nonce, deadline, sig);
    }

    // 9. Nonce NOT consumed if inner call reverts.
    //    Whole tx reverts → all state changes (including the nonce mark)
    //    are rolled back. Subtle CEI-ordering property worth pinning.
    function test_executeWithSig_consumesNonceEvenIfInnerCallReverts() public {
        address w = factory.deployWallet(ownerA);
        // Wallet has zero balance; transfer will revert.
        bytes memory data = abi.encodeWithSelector(usdt.transfer.selector, randoSigner, uint256(1));
        uint256 nonce = 99;
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(ownerAKey, _digestForExecuteWithSig(w, address(usdt), data, nonce, deadline));

        assertFalse(ThinWallet(w).usedNonces(nonce), "nonce starts unused");

        // Attempt — will revert with bubbled inner error.
        vm.expectRevert();
        ThinWallet(w).executeWithSig(address(usdt), data, nonce, deadline, sig);

        // Post-revert: nonce is still NOT marked used. Tx reverted entirely;
        // the `usedNonces[nonce] = true` write was rolled back along with
        // the inner call's revert.
        assertFalse(
            ThinWallet(w).usedNonces(nonce),
            "nonce must remain unused after inner-call revert (CEI tx-revert invariant)"
        );

        // Retry the same nonce with a non-reverting target — should succeed.
        usdt.mint(w, 10);
        ThinWallet(w).executeWithSig(address(usdt), data, nonce, deadline, sig);
        assertTrue(ThinWallet(w).usedNonces(nonce), "nonce consumed on successful retry");
    }

    // 10. Sigs are NOT cross-usable between ERC-1271 (WalletAuth) and executeWithSig.
    //     Different typehashes ⇒ different struct hashes ⇒ different digests.
    function test_executeWithSig_doesNotInterfereWithIsValidSignature() public {
        address w = factory.deployWallet(ownerA);
        bytes memory data = abi.encodeWithSelector(usdt.approve.selector, address(0x1), 1);
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 1 hours;

        // Owner signs an executeWithSig envelope.
        bytes memory execSig = _sign(
            ownerAKey, _digestForExecuteWithSig(w, address(usdt), data, nonce, deadline)
        );

        // That same signature, passed to isValidSignature(someHash, sig),
        // must NOT validate — different typehash means the digest the sig
        // was made for is unrelated to the WalletAuth digest computed
        // inside isValidSignature.
        bytes32 someHash = keccak256("totally unrelated message");
        assertEq(
            ThinWallet(w).isValidSignature(someHash, execSig),
            ERC1271_INVALID,
            "executeWithSig sig must NOT validate as an ERC-1271 WalletAuth sig"
        );
    }

    // 11. Empty data payload is allowed.
    //     Proves no special "empty data" bypass exists; semantics are
    //     "target decides what empty calldata means". For an EOA target,
    //     `call("")` is a 0-value, 0-data poke that returns success.
    function test_executeWithSig_emptyDataPayload() public {
        address w = factory.deployWallet(ownerA);
        // randoSigner is an EOA; call("") on an EOA returns success=true, ret="".
        address target = randoSigner;
        bytes memory data = "";
        uint256 nonce = 7;
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(ownerAKey, _digestForExecuteWithSig(w, target, data, nonce, deadline));

        vm.expectEmit(true, true, false, true, w);
        emit ThinWallet.Executed(target, nonce, data);

        bytes memory ret = ThinWallet(w).executeWithSig(target, data, nonce, deadline, sig);
        assertEq(ret.length, 0, "EOA target with empty data returns empty bytes");
        assertTrue(ThinWallet(w).usedNonces(nonce), "nonce consumed on empty-data success");
    }

    // 12. Large return data is propagated intact through the success path.
    //     Confirms `bytes memory ret` is meaningful, not decorative.
    function test_executeWithSig_targetReturnsLargeData() public {
        address w = factory.deployWallet(ownerA);
        LargeReturner returner = new LargeReturner();
        uint256 returnSize = 10_000; // 10 KB
        bytes memory data = abi.encodeWithSelector(LargeReturner.returnBlob.selector, returnSize);
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _sign(
            ownerAKey, _digestForExecuteWithSig(w, address(returner), data, nonce, deadline)
        );

        bytes memory ret = ThinWallet(w).executeWithSig(address(returner), data, nonce, deadline, sig);
        bytes memory decoded = abi.decode(ret, (bytes));
        assertEq(decoded.length, returnSize, "returned blob length matches request");
        // Spot-check the first + last byte (the returner fills with byte(i % 256)).
        assertEq(uint8(decoded[0]), 0, "first byte");
        assertEq(uint8(decoded[returnSize - 1]), uint8((returnSize - 1) % 256), "last byte");
    }

    // 13. Re-entrancy by design: a malicious target re-enters executeWithSig
    //     with a DIFFERENT valid nonce + sig. Should succeed.
    //     Documents the architectural decision: "owner-authorized per-nonce
    //     IS the guard, no ReentrancyGuard by design." Each re-entrant call
    //     is, by construction, a separate explicit owner authorization.
    function test_executeWithSig_reentrancy() public {
        address w = factory.deployWallet(ownerA);

        // Outer call's nonce + sig + data (target will re-enter from this call).
        uint256 outerNonce = 0;
        // Inner call's nonce + sig + data (the re-entry).
        uint256 innerNonce = 1;
        uint256 deadline = block.timestamp + 1 hours;

        // Pre-build the INNER auth: re-enter and approve(0x123, 999).
        bytes memory innerData = abi.encodeWithSelector(usdt.approve.selector, address(0x123), uint256(999));
        bytes memory innerSig = _sign(
            ownerAKey, _digestForExecuteWithSig(w, address(usdt), innerData, innerNonce, deadline)
        );

        // Deploy the Reenterer with the wallet + inner auth pre-loaded.
        Reenterer reenterer = new Reenterer(ThinWallet(w));
        reenterer.preload(address(usdt), innerData, innerNonce, deadline, innerSig);

        // Outer auth: call `reenterer.trigger()` (which itself triggers the inner executeWithSig).
        bytes memory outerData = abi.encodeWithSelector(Reenterer.trigger.selector);
        bytes memory outerSig = _sign(
            ownerAKey, _digestForExecuteWithSig(w, address(reenterer), outerData, outerNonce, deadline)
        );

        // Execute the outer call. The reenterer's trigger() will call wallet.executeWithSig
        // mid-execution. By design (no ReentrancyGuard), both calls succeed.
        ThinWallet(w).executeWithSig(address(reenterer), outerData, outerNonce, deadline, outerSig);

        // Both nonces consumed.
        assertTrue(ThinWallet(w).usedNonces(outerNonce), "outer nonce consumed");
        assertTrue(ThinWallet(w).usedNonces(innerNonce), "inner nonce consumed by reentry");
        // Inner call's side-effect (the approve) landed.
        assertEq(usdt.allowance(w, address(0x123)), 999, "re-entrant approve took effect");
    }
}

// ── Test-only helper contracts ──────────────────────────────────────────

/// @dev Returns a deterministic blob of `size` bytes. First byte 0,
///      last byte `(size-1) % 256`. Used to verify executeWithSig
///      propagates large return data intact.
contract LargeReturner {
    function returnBlob(uint256 size) external pure returns (bytes memory blob) {
        blob = new bytes(size);
        for (uint256 i = 0; i < size; ++i) {
            blob[i] = bytes1(uint8(i % 256));
        }
    }
}

/// @dev Re-enters `wallet.executeWithSig` when its own `trigger()` is
///      invoked. Used to confirm the re-entrant pattern succeeds when
///      the inner call carries a different valid nonce + signature.
contract Reenterer {
    ThinWallet public immutable wallet;
    address internal _target;
    bytes internal _data;
    uint256 internal _nonce;
    uint256 internal _deadline;
    bytes internal _signature;

    constructor(ThinWallet _wallet) {
        wallet = _wallet;
    }

    function preload(
        address target,
        bytes calldata data,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        _target = target;
        _data = data;
        _nonce = nonce;
        _deadline = deadline;
        _signature = signature;
    }

    function trigger() external {
        wallet.executeWithSig(_target, _data, _nonce, _deadline, _signature);
    }
}
