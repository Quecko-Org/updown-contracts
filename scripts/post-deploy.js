// post-deploy.js — wires, funds, and registers upkeep for already-deployed contracts.
//
// Use this when ChainlinkResolver + UpDownAutoCycler are already on-chain and you
// only need to run steps 3-5 (authorize, add pair, fund USDT, register upkeep).
//
// Usage:
//   npx hardhat run scripts/post-deploy.js --network arbitrum
//   npm run post-deploy:arbitrum
//
// Required env vars:
//   DEPLOYER_PRIVATE_KEY   — owner wallet
//   ARBITRUM_RPC_URL       — Arbitrum One RPC
//   RESOLVER_ADDRESS       — deployed ChainlinkResolver address
//   CYCLER_ADDRESS         — deployed UpDownAutoCycler address
//
// Optional env vars:
//   SEED_USDT_AMOUNT       — USDT (6-dec) to send to cycler, default 1_000_000_000 ($1 000)
//                            set to 0 to skip USDT funding
//   LINK_AMOUNT            — LINK (18-dec) to fund the upkeep, default 500_000_000_000_000_000 (0.5 LINK)
//                            set to 0 to skip upkeep registration

const { ethers, network } = require("hardhat");
const { execSync } = require("child_process");

// ── Chainlink Automation v2.1 — Arbitrum One ──────────────────────────────────
const AUTOMATION_REGISTRAR = "0x86EFBD0b6736Bed994962f9797049422A3A8E8Ad";
const LINK_TOKEN           = "0xf97f4df75117a78c1A5a0DBb814Af92458539FB4";

// ── RAIN dev USDT ─────────────────────────────────────────────────────────────
const DEV_USDT = "0xCa4f77A38d8552Dd1D5E44e890173921B67725F4";

// ── Config ─────────────────────────────────────────────────────────────────────
const UPKEEP_GAS_LIMIT = 5_000_000;
const ETHUSD = ethers.keccak256(ethers.toUtf8Bytes("ETH/USD"));

const ERC20_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function transfer(address to, uint256 amount) returns (bool)",
];

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

const RESOLVER_ABI = [
  "function setAuthorizedCaller(address caller, bool authorized) external",
  "function authorizedCallers(address) view returns (bool)",
];

const CYCLER_ABI = [
  "function addPair(bytes32 pairId) external",
  "function isCyclingPair(bytes32) view returns (bool)",
];


async function main() {
  const [deployer] = await ethers.getSigners();
  const chainId    = (await ethers.provider.getNetwork()).chainId;

  // ── Resolve env vars ─────────────────────────────────────────────────────────
  const resolverAddr = process.env.RESOLVER_ADDRESS;
  const cyclerAddr   = process.env.CYCLER_ADDRESS;
  if (!resolverAddr) throw new Error("RESOLVER_ADDRESS env var is required");
  if (!cyclerAddr)   throw new Error("CYCLER_ADDRESS env var is required");

  const totalSeed = process.env.SEED_USDT_AMOUNT !== undefined
    ? BigInt(process.env.SEED_USDT_AMOUNT)
    : 1_000_000_000n; // default $1 000 USDT

  const linkAmount = process.env.LINK_AMOUNT !== undefined
    ? BigInt(process.env.LINK_AMOUNT)
    : ethers.parseEther("0.5"); // default 0.5 LINK

  console.log("=== UpDown Post-Deploy ===");
  console.log("Network           :", network.name, `(chainId ${chainId})`);
  console.log("Deployer          :", deployer.address);
  console.log("ChainlinkResolver :", resolverAddr);
  console.log("UpDownAutoCycler  :", cyclerAddr);
  console.log("Seed USDT         :", totalSeed > 0n ? `${totalSeed} ($${(Number(totalSeed)/1e6).toFixed(2)} USDT)` : "skipped");
  console.log("LINK upkeep       :", linkAmount > 0n ? `${ethers.formatEther(linkAmount)} LINK` : "skipped");
  console.log();

  const resolver = new ethers.Contract(resolverAddr, RESOLVER_ABI, deployer);
  const cycler   = new ethers.Contract(cyclerAddr, CYCLER_ABI, deployer);
  const usdt     = new ethers.Contract(DEV_USDT, ERC20_ABI, deployer);

  // ── Step 3a: Authorize cycler on resolver ─────────────────────────────────
  console.log("[3/5] Wiring contracts...");
  const alreadyAuthorized = await resolver.authorizedCallers(cyclerAddr);
  if (alreadyAuthorized) {
    console.log("    Cycler already authorised on resolver  ✓");
  } else {
    const tx = await resolver.setAuthorizedCaller(cyclerAddr, true);
    await tx.wait();
    console.log("    Cycler authorised on resolver  ✓");
  }

  // ── Step 3b: Add ETH/USD pair to cycler ──────────────────────────────────
  const alreadyAdded = await cycler.isCyclingPair(ETHUSD);
  if (alreadyAdded) {
    console.log("    ETH/USD pair already added to cycler  ✓\n");
  } else {
    const tx = await cycler.addPair(ETHUSD);
    await tx.wait();
    console.log("    ETH/USD pair added to cycler  ✓\n");
  }

  // ── Step 4: Fund cycler with USDT ─────────────────────────────────────────
  if (totalSeed > 0n) {
    console.log("[4/5] Funding cycler with dev USDT...");
    const bal = await usdt.balanceOf(deployer.address);
    if (bal < totalSeed) {
      throw new Error(
        `Insufficient USDT. Have $${(Number(bal)/1e6).toFixed(2)}, need $${(Number(totalSeed)/1e6).toFixed(2)}. ` +
        `Run: npm run mint:usdt`
      );
    }
    const before = await usdt.balanceOf(cyclerAddr);
    const tx = await usdt.transfer(cyclerAddr, totalSeed);
    await tx.wait();
    const after = await usdt.balanceOf(cyclerAddr);
    console.log(`    Cycler balance: $${(Number(before)/1e6).toFixed(2)} → $${(Number(after)/1e6).toFixed(2)} USDT  ✓\n`);
  } else {
    console.log("[4/5] USDT funding skipped (SEED_USDT_AMOUNT=0)\n");
  }

  // ── Step 5: Register Chainlink Automation upkeep ──────────────────────────
  let upkeepId = null;
  if (linkAmount > 0n) {
    console.log("[5/5] Registering Chainlink Automation upkeep...");

    const link = new ethers.Contract(LINK_TOKEN, ERC20_ABI, deployer);
    const linkBal = await link.balanceOf(deployer.address);
    if (linkBal < linkAmount) {
      throw new Error(
        `Insufficient LINK. Have ${ethers.formatEther(linkBal)}, need ${ethers.formatEther(linkAmount)}.`
      );
    }

    const registrar = new ethers.Contract(AUTOMATION_REGISTRAR, REGISTRAR_ABI, deployer);

    const approveTx = await link.approve(AUTOMATION_REGISTRAR, linkAmount);
    await approveTx.wait();
    console.log(`    Approved ${ethers.formatEther(linkAmount)} LINK to registrar  ✓`);

    const params = {
      name:           "UpDownAutoCycler",
      encryptedEmail: "0x",
      upkeepContract: cyclerAddr,
      gasLimit:       UPKEEP_GAS_LIMIT,
      adminAddress:   deployer.address,
      triggerType:    0,
      checkData:      "0x",
      triggerConfig:  "0x",
      offchainConfig: "0x",
      amount:         linkAmount,
    };

    const receipt = await (await registrar.registerUpkeep(params)).wait();
    const iface   = new ethers.Interface(["event UpkeepRegistered(uint256 indexed id, uint32 executeGas, address admin)"]);
    const parsed  = receipt.logs.map(l => { try { return iface.parseLog(l); } catch { return null; } }).find(Boolean);
    upkeepId = parsed ? parsed.args.id.toString() : "(check Arbiscan)";

    console.log("    Upkeep registered  ✓");
    console.log("    Upkeep ID         :", upkeepId, "\n");
  } else {
    console.log("[5/5] Upkeep registration skipped (LINK_AMOUNT=0)\n");
  }

  // ── Summary ────────────────────────────────────────────────────────────────
  console.log("══════════════════════════════════════════");
  console.log("  Post-deploy complete");
  console.log("══════════════════════════════════════════");
  console.log("  ChainlinkResolver :", resolverAddr);
  console.log("  UpDownAutoCycler  :", cyclerAddr);
  if (upkeepId) console.log("  Upkeep ID         :", upkeepId);
  console.log("══════════════════════════════════════════");

  if (upkeepId) {
    console.log("\n  Monitor upkeep at: https://automation.chain.link/arbitrum/" + upkeepId);
    console.log("  Set UPKEEP_ID=" + upkeepId + " in your .env");
  }

  // ── Verify contracts via forge (contracts compiled with Foundry) ──────────
  if (process.env.ARBISCAN_API_KEY) {
    console.log("\n[verify] Waiting 20s for Arbiscan to index...");
    await new Promise((resolve) => setTimeout(resolve, 20000));

    const CHAINLINK_SEQ     = "0xFdB631F5EE196F0ed6FAa767959853A9F217697D";
    const CHAINLINK_BTC_USD = "0x6ce185860a4963106506C203335A2910413708e9";
    const CHAINLINK_ETH_USD = "0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612";
    const BTCUSD  = ethers.keccak256(ethers.toUtf8Bytes("BTC/USD"));
    const PER_MARKET_SEED = "10000000";
    const FACTORY = "0x05b1fd504583B81bd14c368d59E8c3e354b6C1dc";

    const resolverArgs = ethers.AbiCoder.defaultAbiCoder().encode(
      ["address","address","bytes32","address","bytes32","address"],
      [deployer.address, CHAINLINK_SEQ, BTCUSD, CHAINLINK_BTC_USD, ETHUSD, CHAINLINK_ETH_USD]
    ).slice(2); // remove 0x

    const cyclerArgs = ethers.AbiCoder.defaultAbiCoder().encode(
      ["address","address","address","address","uint256"],
      [deployer.address, resolverAddr, FACTORY, DEV_USDT, PER_MARKET_SEED]
    ).slice(2);

    const apiKey = process.env.ARBISCAN_API_KEY;

    for (const [address, contract, encodedArgs] of [
      [resolverAddr, "src/ChainlinkResolver.sol:ChainlinkResolver", resolverArgs],
      [cyclerAddr,   "src/UpDownAutoCycler.sol:UpDownAutoCycler",   cyclerArgs],
    ]) {
      console.log(`\n[verify] ${contract} @ ${address}`);
      try {
        execSync(
          `forge verify-contract ${address} ${contract} ` +
          `--chain arbitrum ` +
          `--etherscan-api-key ${apiKey} ` +
          `--constructor-args ${encodedArgs} ` +
          `--watch`,
          { stdio: "inherit", cwd: process.cwd() }
        );
      } catch (e) {
        console.error(`Verification failed for ${address}:`, e.message);
      }
    }
  }
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
