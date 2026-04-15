// deploy.js — deploys ChainlinkResolver + UpDownAutoCycler,
// funds the cycler with dev USDT, and registers a Chainlink Automation upkeep.
//
// Local (in-process hardhat network):
//   npx hardhat run scripts/deploy.js
//   npm run deploy:local
//
// Arbitrum Mainnet (requires .env with ARBITRUM_RPC_URL + DEPLOYER_PRIVATE_KEY):
//   npx hardhat run scripts/deploy.js --network arbitrum
//   npm run deploy:arbitrum
//
// Required env vars (live only):
//   DEPLOYER_PRIVATE_KEY   — hex private key (with or without 0x prefix)
//   ARBITRUM_RPC_URL       — Arbitrum One RPC endpoint
//
// Optional env vars:
//   SEED_USDT_AMOUNT       — total USDT (6-dec) to send to cycler, default 1 000 000 000 ($1 000)
//   LINK_AMOUNT            — LINK (18-dec) to fund the upkeep, default 500 000 000 000 000 000 (0.5 LINK)
//                            set to 0 to skip upkeep registration

const { ethers, network } = require("hardhat");
const { execSync } = require("child_process");
const path = require("path");

function forgeVerify(address, contract, encodedArgs) {
  console.log(`\n[verify] ${contract} @ ${address}`);
  try {
    execSync(
      `forge verify-contract ${address} ${contract} ` +
      `--chain arbitrum ` +
      `--etherscan-api-key ${process.env.ARBISCAN_API_KEY} ` +
      `--constructor-args ${encodedArgs} ` +
      `--watch`,
      { stdio: "inherit", cwd: process.cwd() }
    );
  } catch (e) {
    console.error(`Verification failed for ${address}:`, e.message);
  }
}

// ── Helper: load a ContractFactory straight from forge's out/ artifacts ────────
function forgeFactory(name, signer) {
  const artifact = require(path.join(__dirname, `../out/${name}.sol/${name}.json`));
  const bytecode = artifact.bytecode.object.startsWith("0x")
    ? artifact.bytecode.object
    : "0x" + artifact.bytecode.object;
  return new ethers.ContractFactory(artifact.abi, bytecode, signer);
}

// ── Chainlink addresses (Arbitrum One) ────────────────────────────────────────
const CHAINLINK_BTC_USD = "0x6ce185860a4963106506C203335A2910413708e9"; // BTC/USD feed
const CHAINLINK_ETH_USD = "0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612"; // ETH/USD feed
const CHAINLINK_SEQ     = "0xFdB631F5EE196F0ed6FAa767959853A9F217697D"; // L2 sequencer uptime feed

// Chainlink Automation v2.1 — Arbitrum One
const AUTOMATION_REGISTRAR = "0x86EFBD0b6736Bed994962f9797049422A3A8E8Ad";
const LINK_TOKEN           = "0xf97f4df75117a78c1A5a0DBb814Af92458539FB4";

// ── RAIN protocol addresses ────────────────────────────────────────────────────
const DEV_FACTORY = "0x05b1fd504583B81bd14c368d59E8c3e354b6C1dc";
const DEV_USDT    = "0xCa4f77A38d8552Dd1D5E44e890173921B67725F4";

// ── Config ─────────────────────────────────────────────────────────────────────
const PER_MARKET_SEED  = 10_000_000n;         // $10 USDT per market (6 decimals)
const UPKEEP_GAS_LIMIT = 5_000_000;           // gas limit for performUpkeep

// Pair IDs — keccak256 of the human-readable symbol (mirrors Solidity)
const BTCUSD = ethers.keccak256(ethers.toUtf8Bytes("BTC/USD"));
const ETHUSD = ethers.keccak256(ethers.toUtf8Bytes("ETH/USD"));

// Minimal ABIs for tokens/registrar interactions
const ERC20_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function transfer(address to, uint256 amount) returns (bool)",
];

// Chainlink Automation Registrar v2.1 — registerUpkeep
const REGISTRAR_ABI = [
  `function registerUpkeep((
    string name,
    bytes encryptedEmail,
    address upkeepContract,
    uint32 gasLimit,
    address adminAddress,
    uint8 triggerType,
    bytes checkData,
    bytes triggerConfig,
    bytes offchainConfig,
    uint96 amount
  ) requestParams) external returns (uint256 id)`,
];

async function main() {
  const [deployer] = await ethers.getSigners();
  const chainId    = (await ethers.provider.getNetwork()).chainId;
  const isLocal    = chainId === 31337n;

  // Parse env-var overrides
  const totalSeed = process.env.SEED_USDT_AMOUNT
    ? BigInt(process.env.SEED_USDT_AMOUNT)
    : 1_000_000_000n; // default $1 000 USDT

  const linkAmount = process.env.LINK_AMOUNT !== undefined
    ? BigInt(process.env.LINK_AMOUNT)
    : ethers.parseEther("0.5"); // default 0.5 LINK

  console.log("=== UpDown Deploy ===");
  console.log("Network      :", network.name, `(chainId ${chainId})`);
  console.log("Deployer     :", deployer.address);
  console.log("Seed USDT    :", totalSeed.toString(), `($${(Number(totalSeed) / 1e6).toFixed(2)})`);
  console.log("Per-mkt seed :", PER_MARKET_SEED.toString(), "($10 USDT)");
  console.log("LINK upkeep  :", linkAmount > 0n ? ethers.formatEther(linkAmount) + " LINK" : "skipped (LINK_AMOUNT=0)");
  console.log();

  // ────────────────────────────────────────────────────────────────────────────
  // Local network: swap live on-chain deps for in-process mocks so constructors
  // don't revert. Chainlink feed / factory addresses are stored-only (no calls
  // in the constructor), so they can be real mainnet values even locally.
  // ────────────────────────────────────────────────────────────────────────────
  let baseToken = DEV_USDT;
  let factory   = DEV_FACTORY;

  if (isLocal) {
    console.log("Local network — deploying ERC20Mock as base token...");
    const ERC20Mock = forgeFactory("ERC20Mock", deployer);
    const mockUSDT  = await ERC20Mock.deploy();
    await mockUSDT.waitForDeployment();
    baseToken = await mockUSDT.getAddress();
    console.log("ERC20Mock (mock USDT) :", baseToken);

    // Mint enough to cover the seed transfer
    await mockUSDT.mint(deployer.address, totalSeed * 10n);
    console.log("Minted", (totalSeed * 10n).toString(), "mock tokens to deployer\n");
  } else {
    // Live: check deployer USDT balance before proceeding
    const usdt = new ethers.Contract(DEV_USDT, ERC20_ABI, deployer);
    const bal  = await usdt.balanceOf(deployer.address);
    if (bal < totalSeed) {
      throw new Error(
        `Insufficient dev USDT. Have ${bal} (${Number(bal)/1e6} USDT), need ${totalSeed} (${Number(totalSeed)/1e6} USDT). ` +
        `Adjust SEED_USDT_AMOUNT or fund the deployer wallet.`
      );
    }
    console.log(`Deployer USDT balance: ${Number(bal)/1e6} USDT  ✓`);

    // Check LINK balance if registration is requested
    if (linkAmount > 0n) {
      const link    = new ethers.Contract(LINK_TOKEN, ERC20_ABI, deployer);
      const linkBal = await link.balanceOf(deployer.address);
      if (linkBal < linkAmount) {
        throw new Error(
          `Insufficient LINK. Have ${ethers.formatEther(linkBal)} LINK, ` +
          `need ${ethers.formatEther(linkAmount)} LINK. ` +
          `Adjust LINK_AMOUNT or fund the deployer wallet.`
        );
      }
      console.log(`Deployer LINK balance: ${ethers.formatEther(linkBal)} LINK  ✓`);
    }
    console.log();
  }

  // ── Step 1: Deploy ChainlinkResolver ──────────────────────────────────────
  console.log("[1/5] Deploying ChainlinkResolver...");
  const resolver = await forgeFactory("ChainlinkResolver", deployer).deploy(
    deployer.address,  // _owner
    CHAINLINK_SEQ,     // _sequencerFeed  (Arbitrum sequencer uptime)
    BTCUSD,            // _btcUsdPairId
    CHAINLINK_BTC_USD, // _btcUsdFeed
    ETHUSD,            // _ethUsdPairId
    CHAINLINK_ETH_USD  // _ethUsdFeed
  );
  await resolver.waitForDeployment();
  const resolverAddr = await resolver.getAddress();
  console.log("    ChainlinkResolver:", resolverAddr, "✓\n");

  // ── Step 2: Deploy UpDownAutoCycler ───────────────────────────────────────
  console.log("[2/5] Deploying UpDownAutoCycler...");
  const cycler = await forgeFactory("UpDownAutoCycler", deployer).deploy(
    deployer.address, // _owner
    resolverAddr,     // _resolver
    factory,          // _factory  (DEV_FACTORY on live / DEV_FACTORY locally — just stored)
    baseToken,        // _baseToken  (dev USDT live, ERC20Mock locally)
    PER_MARKET_SEED   // _seedLiquidity  $10 USDT per market
  );
  await cycler.waitForDeployment();
  const cyclerAddr = await cycler.getAddress();
  console.log("    UpDownAutoCycler:", cyclerAddr, "✓\n");

  // ── Step 3a: Authorize cycler on resolver ─────────────────────────────────
  console.log("[3/5] Wiring contracts...");
  let tx = await resolver.setAuthorizedCaller(cyclerAddr, true);
  await tx.wait();
  console.log("    Cycler authorised on resolver  ✓");

  // ── Step 3b: Add ETH/USD pair to cycler ──────────────────────────────────
  tx = await cycler.addPair(ETHUSD);
  await tx.wait();
  console.log("    ETH/USD pair added to cycler   ✓\n");

  // ── Step 4: Fund cycler with dev USDT for seed liquidity ──────────────────
  // PER_MARKET_SEED = $10 USDT per market.
  // The cycler manages 3 timeframes × 2 pairs = up to 6 concurrent markets.
  // totalSeed (default $1 000) gives ~16 full rotation cycles of buffer.
  console.log("[4/5] Funding cycler with dev USDT...");
  console.log(`    Sending ${totalSeed} ($${Number(totalSeed)/1e6} USDT) → cycler`);
  const usdt = new ethers.Contract(baseToken, ERC20_ABI, deployer);
  tx = await usdt.transfer(cyclerAddr, totalSeed);
  await tx.wait();
  console.log("    Cycler funded  ✓\n");

  // ── Step 5: Register Chainlink Automation upkeep ──────────────────────────
  // Skipped on local hardhat (no live registrar) or when LINK_AMOUNT=0.
  let upkeepId = null;
  if (!isLocal && linkAmount > 0n) {
    console.log("[5/5] Registering Chainlink Automation upkeep...");
    const link      = new ethers.Contract(LINK_TOKEN, ERC20_ABI, deployer);
    const registrar = new ethers.Contract(AUTOMATION_REGISTRAR, REGISTRAR_ABI, deployer);

    // Approve registrar to pull LINK
    tx = await link.approve(AUTOMATION_REGISTRAR, linkAmount);
    await tx.wait();
    console.log(`    Approved ${ethers.formatEther(linkAmount)} LINK to registrar  ✓`);

    // Register the upkeep
    const params = {
      name:           "UpDownAutoCycler",
      encryptedEmail: "0x",
      upkeepContract: cyclerAddr,
      gasLimit:       UPKEEP_GAS_LIMIT,
      adminAddress:   deployer.address,
      triggerType:    0,    // 0 = CONDITION (uses checkUpkeep)
      checkData:      "0x",
      triggerConfig:  "0x",
      offchainConfig: "0x",
      amount:         linkAmount,
    };

    const receipt = await (await registrar.registerUpkeep(params)).wait();

    // The UpkeepRegistered event carries the new upkeep ID
    const iface  = new ethers.Interface(["event UpkeepRegistered(uint256 indexed id, uint32 executeGas, address admin)"]);
    const parsed = receipt.logs.map(l => { try { return iface.parseLog(l); } catch { return null; } }).find(Boolean);
    upkeepId = parsed ? parsed.args.id.toString() : "(check Arbiscan)";

    console.log("    Upkeep registered  ✓");
    console.log("    Upkeep ID         :", upkeepId, "\n");
  } else if (isLocal) {
    console.log("[5/5] Chainlink Automation registration — skipped (local network)\n");
  } else {
    console.log("[5/5] Chainlink Automation registration — skipped (LINK_AMOUNT=0)\n");
  }

  // ── Summary ────────────────────────────────────────────────────────────────
  console.log("══════════════════════════════════════════");
  console.log("  Deployment complete");
  console.log("══════════════════════════════════════════");
  console.log("  ChainlinkResolver  :", resolverAddr);
  console.log("  UpDownAutoCycler   :", cyclerAddr);
  console.log("  Seed USDT funded   :", totalSeed.toString());
  if (upkeepId) console.log("  Upkeep ID          :", upkeepId);
  console.log("══════════════════════════════════════════");

  if (!isLocal) {
    console.log("\nNext steps:");
    if (!upkeepId) {
      console.log("  1. Register the cycler as a Chainlink Automation upkeep:");
      console.log("       https://automation.chain.link/arbitrum");
      console.log("     Or re-run with LINK_AMOUNT set to fund registration automatically.");
    } else {
      console.log("  1. Monitor upkeep at https://automation.chain.link/arbitrum/" + upkeepId);
      console.log("     Top up LINK when balance runs low.");
    }

    // ── Verify contracts on Arbiscan ────────────────────────────────────────
    if (process.env.ARBISCAN_API_KEY) {
      console.log("\n[verify] Waiting 20s for Arbiscan to index the contracts...");
      await new Promise((resolve) => setTimeout(resolve, 20000));

      const resolverArgs = ethers.AbiCoder.defaultAbiCoder().encode(
        ["address","address","bytes32","address","bytes32","address"],
        [deployer.address, CHAINLINK_SEQ, BTCUSD, CHAINLINK_BTC_USD, ETHUSD, CHAINLINK_ETH_USD]
      ).slice(2);

      const cyclerArgs = ethers.AbiCoder.defaultAbiCoder().encode(
        ["address","address","address","address","uint256"],
        [deployer.address, resolverAddr, factory, baseToken, PER_MARKET_SEED]
      ).slice(2);

      forgeVerify(resolverAddr, "src/ChainlinkResolver.sol:ChainlinkResolver", resolverArgs);
      forgeVerify(cyclerAddr,   "src/UpDownAutoCycler.sol:UpDownAutoCycler",   cyclerArgs);
    } else {
      console.log("\n  Skipping Arbiscan verification — set ARBISCAN_API_KEY to verify automatically.");
    }
  }
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
