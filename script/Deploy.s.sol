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
///   DEPLOYER_PRIVATE_KEY  — the deployer/owner key
///   ARBITRUM_RPC_URL      — Arbitrum One RPC
///   USDT_ADDRESS          — USDT token on the target network
///   RELAYER_ADDRESS       — relayer wallet that calls enterPosition / withdrawSettlement
contract DeployUpDown is Script {
    // ── Chainlink addresses (Arbitrum Mainnet) ──────────────────────────
    address constant CHAINLINK_BTC_USD = 0x6ce185860a4963106506C203335A2910413708e9;
    address constant CHAINLINK_ETH_USD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address constant CHAINLINK_SEQUENCER = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D;

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

        console.log("Deployer:", deployer);
        console.log("USDT:", usdt);
        console.log("Relayer:", relayer);

        vm.startBroadcast(deployerKey);

        UpDownSettlement settlement =
            new UpDownSettlement(IERC20(usdt), deployer, PLATFORM_FEE_BPS, MAKER_FEE_BPS);
        console.log("UpDownSettlement:", address(settlement));

        ChainlinkResolver resolver = new ChainlinkResolver(
            deployer, CHAINLINK_SEQUENCER, BTCUSD, CHAINLINK_BTC_USD, ETHUSD, CHAINLINK_ETH_USD, address(settlement)
        );
        console.log("ChainlinkResolver:", address(resolver));

        UpDownAutoCycler cycler = new UpDownAutoCycler(deployer, address(resolver), address(settlement));
        console.log("UpDownAutoCycler:", address(cycler));

        settlement.setResolver(address(resolver));
        settlement.setAutocycler(address(cycler));
        settlement.setRelayer(relayer);

        resolver.setAuthorizedCaller(address(cycler), true);

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
