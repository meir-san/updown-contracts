// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {ThinWallet} from "./ThinWallet.sol";

/// @title ThinWalletFactory
/// @notice Deploys one `ThinWallet` per user EOA via CREATE2 with
///         `salt = keccak256(abi.encode(owner))`. The deployed address is
///         deterministic per-owner so the frontend can predict it before
///         deployment, accept counterfactual deposits, and lazy-deploy on
///         first trade (Phase 3 / Gate 2, doc Track 2 Phase 1).
///
/// @dev    Factory is permissionless by design (doc 2.7#7): anyone can
///         call `deployWallet(owner)` for any address. Front-running the
///         deployment confers NO ownership advantage — the `owner` field
///         on the wallet is set from the caller-supplied argument at
///         construction and is `immutable`, so even if a malicious actor
///         beats the user to deployment, they cannot make themselves the
///         owner.
///
///         Re-deploying the same owner reverts (CREATE2 collision). The
///         predicted address is stable, so a caller should check for
///         existing code at `predictWallet(owner)` before deploying.
contract ThinWalletFactory {
    // ── Errors ──────────────────────────────────────────────────────────
    error ZeroOwner();

    // ── Events ──────────────────────────────────────────────────────────
    event WalletDeployed(address indexed owner, address indexed wallet);

    /// @notice Deploys a `ThinWallet` whose `owner` is `_owner`. Reverts if
    ///         a wallet already exists at the predicted address.
    /// @return wallet the deployed wallet address (= `predictWallet(_owner)`).
    function deployWallet(address _owner) external returns (address wallet) {
        if (_owner == address(0)) revert ZeroOwner();
        bytes32 salt = keccak256(abi.encode(_owner));
        wallet = address(new ThinWallet{salt: salt}(_owner));
        emit WalletDeployed(_owner, wallet);
    }

    /// @notice Returns the deterministic wallet address for `_owner` without
    ///         deploying. Public so the frontend can show users their
    ///         counterfactual deposit address before they trade.
    function predictWallet(address _owner) public view returns (address) {
        bytes32 salt = keccak256(abi.encode(_owner));
        bytes memory bytecode = abi.encodePacked(
            type(ThinWallet).creationCode,
            abi.encode(_owner)
        );
        return address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(bytecode)))
                )
            )
        );
    }
}
