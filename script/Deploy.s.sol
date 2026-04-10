// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console} from "forge-std/Script.sol";
import {ChainlinkResolver} from "../src/ChainlinkResolver.sol";
import {UpDownAutoCycler} from "../src/UpDownAutoCycler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Deploys ChainlinkResolver + UpDownAutoCycler, wires them together,
///         and funds the cycler with seed USDT. Run with:
///
///   forge script script/Deploy.s.sol --rpc-url $ARBITRUM_RPC_URL --broadcast --verify
///
/// Required env vars:
///   DEPLOYER_PRIVATE_KEY  — the deployer/owner key
///   ARBITRUM_RPC_URL      — Arbitrum One RPC
///   SEED_USDT_AMOUNT      — (optional) total USDT to fund cycler, default $1000
contract DeployUpDown is Script {
    using SafeERC20 for IERC20;
    // ── Chainlink addresses (Arbitrum Mainnet) ──────────────────────────
    address constant CHAINLINK_BTC_USD = 0x6ce185860a4963106506C203335A2910413708e9;
    address constant CHAINLINK_ETH_USD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address constant CHAINLINK_SEQUENCER = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D;

    // ── RAIN addresses ──────────────────────────────────────────────────
    address constant DEV_FACTORY = 0x05b1fd504583B81bd14c368d59E8c3e354b6C1dc;
    address constant DEV_USDT = 0xCa4f77A38d8552Dd1D5E44e890173921B67725F4;

    // ── Pair IDs ────────────────────────────────────────────────────────
    bytes32 constant BTCUSD = keccak256("BTC/USD");
    bytes32 constant ETHUSD = keccak256("ETH/USD");

    // ── Config ──────────────────────────────────────────────────────────
    uint256 constant PER_MARKET_SEED = 10_000_000; // $10 USDT (6 decimals)

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        uint256 totalSeed = vm.envOr("SEED_USDT_AMOUNT", uint256(1_000_000_000)); // default $1000

        console.log("Deployer:", deployer);
        console.log("Seed USDT:", totalSeed);

        vm.startBroadcast(deployerKey);

        // 1. Deploy ChainlinkResolver
        ChainlinkResolver resolver = new ChainlinkResolver(
            deployer, CHAINLINK_SEQUENCER, BTCUSD, CHAINLINK_BTC_USD, ETHUSD, CHAINLINK_ETH_USD
        );
        console.log("ChainlinkResolver:", address(resolver));

        // 2. Deploy UpDownAutoCycler
        UpDownAutoCycler cycler =
            new UpDownAutoCycler(deployer, address(resolver), DEV_FACTORY, DEV_USDT, PER_MARKET_SEED);
        console.log("UpDownAutoCycler:", address(cycler));

        // 3. Authorize cycler on resolver
        resolver.setAuthorizedCaller(address(cycler), true);

        // 3b. Cycle ETH/USD alongside BTC/USD (resolver already has ETH feed from constructor)
        cycler.addPair(ETHUSD);

        // 4. Fund cycler with USDT (deployer must hold sufficient balance)
        if (totalSeed > 0) {
            IERC20(DEV_USDT).safeTransfer(address(cycler), totalSeed);
            console.log("Funded cycler with USDT:", totalSeed);
        }

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment complete ===");
        console.log("Next steps:");
        console.log("  1. Register the UpDownAutoCycler as a Chainlink Automation upkeep");
        console.log("     at https://automation.chain.link/arbitrum");
        console.log("  2. Fund the upkeep with LINK for gas");
        console.log("  3. Verify contracts on Arbiscan");
    }
}
