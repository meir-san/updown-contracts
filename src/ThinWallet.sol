// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/// @title ThinWallet
/// @notice Minimal ERC-1271 smart-account wallet per user (Phase 3 / Gate 2,
///         post-audit-research doc Track 2 Phase 1). Holds USDT (or other
///         ERC-20 collateral), approves settlement to pull funds, supports
///         signature verification via the wallet's owner EOA.
///
/// @dev Security posture (each item gets an explicit test):
///
///       1. `address(this)` binding — the central audit point (doc 2.5#5).
///          The Alchemy LightAccount pre-patch bug pattern was: a user's
///          EOA owning two wallets meant signing for wallet A also
///          validated for wallet B, because both checked `recovered ==
///          owner` against the SAME EOA without any per-wallet binding.
///          Our defense satisfies the property through EIP-712-native
///          encoding rather than the doc-literal raw-hash wrap:
///
///            - We inherit OpenZeppelin's `EIP712` with name
///              `"PulsePairsThinWallet"` v1. The OZ base computes the
///              domain separator with `verifyingContract = address(this)`
///              automatically.
///            - `isValidSignature(hash, sig)` wraps the caller-provided
///              hash in a `WalletAuth(bytes32 hash)` typed-data struct,
///              then `_hashTypedDataV4` produces a digest bound to THIS
///              wallet's domain separator (and therefore to `address(this)`).
///            - Same security property as the doc's literal recipe, with
///              browser-wallet-native typed-data UX. Pattern matches
///              Safe + Argent + production ERC-1271 wallets.
///
///       2. EIP-2 s-value malleability — handled by OpenZeppelin's
///          `ECDSA.tryRecover` (rejects `s > secp256k1n/2`). We use
///          `tryRecover` for non-reverting behavior so a malformed sig
///          returns the standard 0xffffffff rather than a revert.
///
///       3. Reentrancy — `isValidSignature` is `view`-only, no state
///          changes during validation. EIP-1271 mandates this.
///
///       4. Owner immutability — `address public immutable owner` set in
///          constructor; no setter, no init function, no proxy pattern.
///          Bug discovered post-deploy → v2 wallet + migration, not
///          in-place upgrade. Avoids storage-collision class of bugs in
///          proxy patterns.
///
///       5. Token surface minimality — `withdraw` sends to `owner` only
///          (escape hatch). No arbitrary `transfer(to, amount)` —
///          reduces attack surface. Owner who wants to send elsewhere
///          withdraws to EOA first.
///
///       6. ETH not custodied — no `receive()`/`fallback()`. The wallet
///          handles ERC-20s only; the EOA holds ETH for gas.
contract ThinWallet is EIP712 {
    using SafeERC20 for IERC20;

    // ── Errors ──────────────────────────────────────────────────────────
    error ZeroOwner();
    error NotOwner();
    error ZeroTarget();
    error ExecuteExpired(uint256 deadline, uint256 nowTs);
    error NonceAlreadyUsed(uint256 nonce);
    error BadSignature();

    // ── Constants ───────────────────────────────────────────────────────
    /// @notice ERC-1271 magic return value: `bytes4(keccak256("isValidSignature(bytes32,bytes)"))`.
    bytes4 private constant ERC1271_MAGIC = IERC1271.isValidSignature.selector;

    /// @notice EIP-712 type hash for the `WalletAuth` wrap. The wrap binds
    ///         the original `hash` to THIS wallet's domain separator
    ///         (which includes `verifyingContract = address(this)`), thereby
    ///         binding the signature to this specific wallet address.
    bytes32 private constant WALLET_AUTH_TYPEHASH = keccak256("WalletAuth(bytes32 hash)");

    /// @notice EIP-712 type hash for the `executeWithSig` meta-tx envelope.
    ///         Authorizes any caller to invoke `target.call(data)` from this
    ///         wallet, exactly once, before `deadline`, on behalf of `owner`.
    ///         Replay-safe across nonces (consumed in-tx), wallets
    ///         (`verifyingContract` in domain), and chains (`chainId` in
    ///         domain). Standard meta-tx pattern — Safe / Argent / EIP-4337.
    bytes32 private constant EXECUTE_WITH_SIG_TYPEHASH =
        keccak256("ExecuteWithSig(address target,bytes data,uint256 nonce,uint256 deadline)");

    // ── State ───────────────────────────────────────────────────────────
    address public immutable owner;

    /// @notice Per-nonce replay guard for `executeWithSig`. Owner picks
    ///         nonces; frontend convention is monotonic-per-wallet starting
    ///         from 0 to keep audit trails readable. Public getter lets
    ///         off-chain consumers check whether a given nonce is still
    ///         spendable without crafting a probe tx.
    mapping(uint256 => bool) public usedNonces;

    // ── Events ──────────────────────────────────────────────────────────
    event Withdrawn(address indexed token, uint256 amount);
    event SettlementApproved(address indexed token, address indexed settlement, uint256 amount);
    /// @notice Emitted on each successful `executeWithSig` call. Off-chain
    ///         indexers map (target, nonce) back to user authorizations.
    ///         `recovered` deliberately not included — by tx-revert
    ///         invariant it always equals `owner`; explicit field would
    ///         waste gas + indexer storage.
    event Executed(address indexed target, uint256 indexed nonce, bytes data);

    // ── Constructor ─────────────────────────────────────────────────────
    /// @param _owner the EOA that will sign on behalf of this wallet.
    /// @dev OZ EIP712 base: domain becomes `{name:"PulsePairsThinWallet",
    ///      version:"1", chainId:block.chainid, verifyingContract:address(this)}`.
    constructor(address _owner) EIP712("PulsePairsThinWallet", "1") {
        if (_owner == address(0)) revert ZeroOwner();
        owner = _owner;
    }

    // ── ERC-1271 ────────────────────────────────────────────────────────
    /// @notice ERC-1271 signature verifier. Verifies that `signature` is a signature by `owner` over a
    ///         `WalletAuth(bytes32 hash)` typed-data message bound to THIS
    ///         wallet's EIP-712 domain. Returns the ERC-1271 magic value
    ///         iff the signature is valid; `0xffffffff` otherwise.
    ///
    /// @dev The caller passes `hash` (typically an EIP-712 hash from some
    ///      other domain — e.g. the settlement contract's order domain).
    ///      We do NOT recover from `hash` directly. We wrap it:
    ///
    ///        structHash = keccak256(abi.encode(WALLET_AUTH_TYPEHASH, hash))
    ///        digest     = _hashTypedDataV4(structHash)
    ///                   = keccak256(abi.encodePacked("\x19\x01",
    ///                       <PulsePairsThinWallet domain w/ this wallet's address>,
    ///                       structHash))
    ///
    ///      The client signs `digest` (via `signTypedData` against this
    ///      wallet's domain). The recovery is bound to `address(this)`
    ///      because the domain separator embeds it. Same EOA owning two
    ///      wallets cannot have a signature for wallet A validate on
    ///      wallet B — different `verifyingContract` ⇒ different domain
    ///      separator ⇒ different digest ⇒ different signature.
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        bytes32 structHash = keccak256(abi.encode(WALLET_AUTH_TYPEHASH, hash));
        bytes32 digest = _hashTypedDataV4(structHash);

        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
        if (err != ECDSA.RecoverError.NoError) return bytes4(0xffffffff);
        if (recovered == owner) return ERC1271_MAGIC;
        return bytes4(0xffffffff);
    }

    // ── Owner ops ───────────────────────────────────────────────────────
    /// @notice Pull `amount` of `token` out of this wallet to the owner EOA.
    ///         Escape hatch for the case where the backend / frontend is
    ///         unavailable — owner can always reclaim funds via direct call.
    function withdraw(IERC20 token, uint256 amount) external {
        if (msg.sender != owner) revert NotOwner();
        token.safeTransfer(owner, amount);
        emit Withdrawn(address(token), amount);
    }

    /// @notice Approve `settlement` to pull up to `amount` of `token` from
    ///         this wallet. Standard ERC-20 allowance pattern used by
    ///         `UpDownSettlement` on fills. `forceApprove` resets to 0
    ///         first to dodge non-standard tokens (USDT classic) that
    ///         require zero-allowance-before-set.
    function approveSettlement(IERC20 token, address settlement, uint256 amount) external {
        if (msg.sender != owner) revert NotOwner();
        token.forceApprove(settlement, amount);
        emit SettlementApproved(address(token), settlement, amount);
    }

    /// @notice Expose this wallet's EIP-712 domain separator. Audit-friendly
    ///         readback so reviewers can confirm `verifyingContract ==
    ///         address(this)` directly on-chain.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ── Meta-tx (Phase 4 Gate) ──────────────────────────────────────────
    /// @notice Execute an arbitrary call from this wallet, authorized by an
    ///         owner-signed EIP-712 typed-data envelope. Standard meta-tx
    ///         pattern (Safe / Argent / EIP-4337 family). Same domain +
    ///         signature recovery primitives as `isValidSignature` — relies
    ///         on the same `address(this)` binding via OZ `_hashTypedDataV4`
    ///         so a sig made for Wallet A cannot replay against Wallet B.
    ///
    /// @param target the contract (or EOA) to call (e.g. USDTM for `approve(...)`).
    /// @param data the calldata to send. Decoded by `target`, not this wallet.
    ///             Empty bytes are allowed and forwarded verbatim — target
    ///             contract semantics decide what an empty call means.
    /// @param nonce a one-time nonce. Reverts `NonceAlreadyUsed(nonce)` if
    ///              the same nonce has been used on this wallet before.
    /// @param deadline unix seconds; reverts `ExecuteExpired(...)` if
    ///                 `block.timestamp > deadline`. Frontend convention is
    ///                 ~1 hour from sign time.
    /// @param signature the owner's EIP-712 signature over the typed envelope.
    /// @return ret the raw return data from `target.call(data)`. Surfaces
    ///             whatever the inner call returned; caller decodes per
    ///             target ABI.
    ///
    /// @dev Reverts on:
    ///   - `target == address(0)`             → `ZeroTarget`
    ///   - `block.timestamp > deadline`       → `ExecuteExpired`
    ///   - `usedNonces[nonce] == true`        → `NonceAlreadyUsed`
    ///   - signature recovery error or owner mismatch → `BadSignature`
    ///   - underlying `target.call(data)` reverts → bubbles the inner
    ///     revert data verbatim via assembly (preserves selector + payload
    ///     so callers see e.g. `ERC20InsufficientAllowance(...)` not a
    ///     stringified "call failed")
    ///
    /// @dev Re-entrancy: NOT guarded. Architectural decision — owner's
    ///      per-nonce signature IS the guard. A re-entrant call with a
    ///      different valid nonce + sig is, by construction, a separate
    ///      explicit authorization from the owner. Same posture as Safe.
    function executeWithSig(
        address target,
        bytes calldata data,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external returns (bytes memory ret) {
        if (target == address(0)) revert ZeroTarget();
        if (block.timestamp > deadline) revert ExecuteExpired(deadline, block.timestamp);
        if (usedNonces[nonce]) revert NonceAlreadyUsed(nonce);

        bytes32 structHash = keccak256(
            abi.encode(EXECUTE_WITH_SIG_TYPEHASH, target, keccak256(data), nonce, deadline)
        );
        bytes32 digest = _hashTypedDataV4(structHash);

        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
        if (err != ECDSA.RecoverError.NoError || recovered != owner) revert BadSignature();

        // Consume nonce BEFORE the external call (checks-effects-interactions).
        usedNonces[nonce] = true;

        bool ok;
        (ok, ret) = target.call(data);
        if (!ok) {
            // Bubble inner revert verbatim — preserves selector + payload
            // so callers see e.g. `ERC20InsufficientAllowance(...)` rather
            // than a stringified wrapper. mload(ret) is the bytes length;
            // add(ret, 32) points past the length prefix to the data.
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }

        emit Executed(target, nonce, data);
    }
}
