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

    // ── Constants ───────────────────────────────────────────────────────
    /// @notice ERC-1271 magic return value: `bytes4(keccak256("isValidSignature(bytes32,bytes)"))`.
    bytes4 private constant ERC1271_MAGIC = IERC1271.isValidSignature.selector;

    /// @notice EIP-712 type hash for the `WalletAuth` wrap. The wrap binds
    ///         the original `hash` to THIS wallet's domain separator
    ///         (which includes `verifyingContract = address(this)`), thereby
    ///         binding the signature to this specific wallet address.
    bytes32 private constant WALLET_AUTH_TYPEHASH = keccak256("WalletAuth(bytes32 hash)");

    // ── State ───────────────────────────────────────────────────────────
    address public immutable owner;

    // ── Events ──────────────────────────────────────────────────────────
    event Withdrawn(address indexed token, uint256 amount);
    event SettlementApproved(address indexed token, address indexed settlement, uint256 amount);

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
}
