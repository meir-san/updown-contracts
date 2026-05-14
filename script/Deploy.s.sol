// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console} from "forge-std/Script.sol";
import {ChainlinkResolver} from "../src/ChainlinkResolver.sol";
import {UpDownAutoCycler} from "../src/UpDownAutoCycler.sol";
import {UpDownSettlement} from "../src/UpDownSettlement.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Deploys UpDownSettlement, ChainlinkResolver, and UpDownAutoCycler; wires roles.
///         Run with:
///
///   forge script script/Deploy.s.sol --rpc-url $ARBITRUM_RPC_URL --broadcast --verify
///
/// Required env vars:
///   DEPLOYER_PRIVATE_KEY            — the deployer/owner key
///   ARBITRUM_RPC_URL                — Arbitrum One RPC
///   USDT_ADDRESS                    — USDT token on the target network
///   RELAYER_ADDRESS                 — relayer wallet that calls enterPosition / withdrawSettlement
///   TREASURY_ADDRESS                — treasury EOA that receives platformFee + funds rebate claims
///   CHAINLINK_VERIFIER_PROXY_ADDRESS — Data Streams VerifierProxy on the target network
///                                     (Arbitrum Sepolia testnet: 0x2ff010DEbC1297f19579B4246cad07bd24F2488A)
///   CHAINLINK_LINK_TOKEN_ADDRESS    — LINK token address on the target network
///                                     (Arbitrum One: 0xf97f4df75117a78c1A5a0DBb814Af92458539FB4)
///   CHAINLINK_BTC_USD_FEED          — BTC/USD AggregatorV3 (strike-side, push-based)
///                                     Arbitrum One:     0x6ce185860a4963106506C203335A2910413708e9
///                                     Arbitrum Sepolia: deploy `MockAggregatorV3` and supply its addr.
///   CHAINLINK_ETH_USD_FEED          — ETH/USD AggregatorV3 (strike-side)
///                                     Arbitrum One:     0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612
///                                     Arbitrum Sepolia: deploy `MockAggregatorV3` and supply its addr.
///   CHAINLINK_SEQUENCER_FEED        — L2 sequencer uptime feed
///                                     Arbitrum One:     0xFdB631F5EE196F0ed6FAa767959853A9F217697D
///                                     Arbitrum Sepolia: deploy `MockAggregatorV3(0, 0, 1)` (answer=0, ancient updatedAt).
contract DeployUpDown is Script {

    // ── Pair IDs ────────────────────────────────────────────────────────
    bytes32 constant BTCUSD = keccak256("BTC/USD");
    bytes32 constant ETHUSD = keccak256("ETH/USD");

    // ── Fee defaults (basis points) ─────────────────────────────────────
    uint256 constant PLATFORM_FEE_BPS = 70;
    uint256 constant MAKER_FEE_BPS = 80;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address usdt = vm.envAddress("USDT_ADDRESS");
        address relayer = vm.envAddress("RELAYER_ADDRESS");
        // PR-5-bundle (P0-7): treasury must be configured pre-broadcast or
        // any fill with platformFee > 0 reverts on TreasuryNotConfigured.
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        // 2026-05-13 Data Streams swap: resolver constructor now also
        // takes the VerifierProxy + LINK token addresses. Both must be
        // env-supplied to avoid hardcoding per-network values in the
        // script. On Arbitrum One, LINK = 0xf97f4df75117a78c1A5a0DBb814Af92458539FB4.
        address verifierProxy = vm.envAddress("CHAINLINK_VERIFIER_PROXY_ADDRESS");
        address linkToken = vm.envAddress("CHAINLINK_LINK_TOKEN_ADDRESS");
        // Strike-side feeds + sequencer feed. Env-driven so the same
        // script targets both Arbitrum One (real Chainlink addresses) and
        // Arbitrum Sepolia (MockAggregatorV3 deploys) — see header doc
        // for the canonical addresses on each network.
        address btcUsdFeed = vm.envAddress("CHAINLINK_BTC_USD_FEED");
        address ethUsdFeed = vm.envAddress("CHAINLINK_ETH_USD_FEED");
        address sequencerFeed = vm.envAddress("CHAINLINK_SEQUENCER_FEED");

        console.log("Deployer:", deployer);
        console.log("USDT:", usdt);
        console.log("Relayer:", relayer);
        console.log("Treasury:", treasury);

        vm.startBroadcast(deployerKey);

        UpDownSettlement settlement =
            new UpDownSettlement(IERC20(usdt), deployer, PLATFORM_FEE_BPS, MAKER_FEE_BPS);
        console.log("UpDownSettlement:", address(settlement));

        ChainlinkResolver resolver = new ChainlinkResolver(
            deployer,
            sequencerFeed,
            BTCUSD,
            btcUsdFeed,
            ETHUSD,
            ethUsdFeed,
            address(settlement),
            verifierProxy,
            linkToken
        );
        console.log("ChainlinkResolver:", address(resolver));
        // Post-deploy ops: ops must (a) `configureStreamsFeed(pairId, feedId)`
        // for each pair once the DON allow-lists this resolver address,
        // and (b) topup the resolver with LINK for verify fees (default
        // floor 5 LINK per the OPS_RUNBOOK).

        UpDownAutoCycler cycler = new UpDownAutoCycler(deployer, address(resolver), address(settlement));
        console.log("UpDownAutoCycler:", address(cycler));

        settlement.setResolver(address(resolver));
        settlement.setAutocycler(address(cycler));
        settlement.setRelayer(relayer);
        // PR-5-bundle: wire treasury so atomic platformFee transfers land
        // on the right EOA from the very first fill.
        settlement.setTreasury(treasury);

        resolver.setAuthorizedCaller(address(cycler), true);

        // Whitelist + start cycling both pairs so AutoCycler creates markets
        // for the repros immediately (the prior dev deployment did this in a
        // separate one-off tx; folded in here).
        cycler.addPair(BTCUSD);
        cycler.addPair(ETHUSD);

        vm.stopBroadcast();

        uint256 ts = block.timestamp;
        console.log("");
        console.log("Clock-aligned market boundaries at deploy block.timestamp:");
        console.log("  5m slot start (unix):", (ts / 300) * 300);
        console.log("  15m slot start (unix):", (ts / 900) * 900);
        console.log("  60m slot start (unix):", (ts / 3600) * 3600);
        console.log("(Add ETH/USD to cycling via owner addPair if desired.)");
        console.log("");
        console.log("=== Deployment complete ===");
        console.log("UpDownSettlement:", address(settlement));
        console.log("ChainlinkResolver:", address(resolver));
        console.log("UpDownAutoCycler:", address(cycler));
        console.log("Next: register UpDownAutoCycler on Chainlink Automation, fund 5-10 LINK, verify on Arbiscan");
    }
}
