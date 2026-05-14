// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Script, console} from "forge-std/Script.sol";
import {ThinWalletFactory} from "../src/ThinWalletFactory.sol";

/// @notice Stand-alone factory deploy script (Phase 4a-2). Kept separate
///         from Deploy.s.sol so the Settlement + Resolver + Cycler bundle
///         (already in the audit firm's scope at audit-freeze-2026-05-13)
///         stays untouched. Factory is stateless from a deploy POV — wallets
///         get deployed later via the factory per-user, paid by relayer.
///
/// Required env vars:
///   DEPLOYER_PRIVATE_KEY — the EOA that owns the factory deployment tx
///
/// Run (Arbitrum Sepolia):
///   forge script script/DeployThinWalletFactory.s.sol:DeployThinWalletFactoryScript \
///     --rpc-url $ARBITRUM_SEPOLIA_RPC_URL --broadcast --private-key $DEPLOYER_PRIVATE_KEY
///
/// Run (Arbitrum One — deferred until Phase 4b+4c land on dev):
///   forge script script/DeployThinWalletFactory.s.sol:DeployThinWalletFactoryScript \
///     --rpc-url $ARBITRUM_RPC_URL --broadcast --private-key $DEPLOYER_PRIVATE_KEY
///
/// Post-deploy: record the printed address into the appropriate `.env`
/// under `THIN_WALLET_FACTORY_ADDRESS`. The backend's `/config` endpoint
/// surfaces it to the frontend at runtime (no env baked into the build).
///
/// Factory address is CREATE-determined (not CREATE2 like the wallets it
/// deploys), so Arbitrum One and Arbitrum Sepolia factories will have
/// different addresses depending on (deployer, nonce) at deploy time.
/// User TWs derive from `(factory, eoa)` so same user gets different TW
/// addresses on each chain — backend keys by `(chainId, eoa) → twAddress`.
contract DeployThinWalletFactoryScript is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        console.log("Deployer:", deployer);
        console.log("Chain id:", block.chainid);

        vm.startBroadcast(deployerKey);
        ThinWalletFactory factory = new ThinWalletFactory();
        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment complete ===");
        console.log("ThinWalletFactory:", address(factory));
        console.log("");
        console.log("Next: record THIN_WALLET_FACTORY_ADDRESS in .env, then");
        console.log("      restart the backend so /config exposes it to the frontend.");
    }
}
