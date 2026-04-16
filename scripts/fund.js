// fund.js — tops up UpDownAutoCycler (USDT) and/or the Chainlink Automation upkeep (LINK).
//
// Usage:
//   npx hardhat run scripts/fund.js --network arbitrum
//   npm run fund:arbitrum
//
// Required env vars:
//   DEPLOYER_PRIVATE_KEY     — wallet that holds the USDT / LINK
//   ARBITRUM_RPC_URL         — Arbitrum One RPC endpoint
//   CYCLER_ADDRESS           — deployed UpDownAutoCycler address
//
// Optional env vars:
//   FUND_USDT_AMOUNT         — USDT (6-dec) to send to cycler,  default 1_000_000_000 ($1 000)
//                              set to 0 to skip USDT top-up
//   FUND_LINK_AMOUNT         — LINK (18-dec) to add to upkeep,  default 500_000_000_000_000_000 (0.5 LINK)
//                              set to 0 to skip LINK top-up
//   UPKEEP_ID                — Chainlink upkeep ID (required for LINK top-up)

const { ethers, network } = require("hardhat");

// ── Chainlink Automation v2.1 — Arbitrum One ──────────────────────────────────
const LINK_TOKEN    = "0xf97f4df75117a78c1A5a0DBb814Af92458539FB4";
const REGISTRY      = "0x37D9dC70bfcd8BC77Ec2858836B923c560E891D1"; // KeeperRegistry2_1

// ── RAIN dev USDT (Arbitrum) ───────────────────────────────────────────────────
const DEV_USDT = "0xCa4f77A38d8552Dd1D5E44e890173921B67725F4";

const ERC20_ABI = [
  "function balanceOf(address) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
  "function transfer(address to, uint256 amount) returns (bool)",
];

const REGISTRY_ABI = [
  "function addFunds(uint256 id, uint96 amount) external",
];

async function main() {
  const [signer] = await ethers.getSigners();
  const chainId  = (await ethers.provider.getNetwork()).chainId;

  // ── Resolve env vars ─────────────────────────────────────────────────────────
  const cyclerAddress = process.env.CYCLER_ADDRESS;
  if (!cyclerAddress) throw new Error("CYCLER_ADDRESS env var is required");

  const usdtAmount = process.env.FUND_USDT_AMOUNT !== undefined
    ? BigInt(process.env.FUND_USDT_AMOUNT)
    : 1_000_000_000n; // default $1 000 USDT

  const linkAmount = process.env.FUND_LINK_AMOUNT !== undefined
    ? BigInt(process.env.FUND_LINK_AMOUNT)
    : ethers.parseEther("0.5"); // default 0.5 LINK

  const upkeepId = process.env.UPKEEP_ID ? BigInt(process.env.UPKEEP_ID) : null;

  console.log("=== UpDown Fund ===");
  console.log("Network         :", network.name, `(chainId ${chainId})`);
  console.log("Signer          :", signer.address);
  console.log("Cycler          :", cyclerAddress);
  console.log("USDT top-up     :", usdtAmount > 0n ? `${usdtAmount} ($${(Number(usdtAmount) / 1e6).toFixed(2)} USDT)` : "skipped");
  console.log("LINK top-up     :", linkAmount > 0n ? `${ethers.formatEther(linkAmount)} LINK` : "skipped");
  console.log("Upkeep ID       :", upkeepId ? upkeepId.toString() : "not set");
  console.log();

  const usdt     = new ethers.Contract(DEV_USDT, ERC20_ABI, signer);
  const link     = new ethers.Contract(LINK_TOKEN, ERC20_ABI, signer);
  const registry = new ethers.Contract(REGISTRY, REGISTRY_ABI, signer);

  // ── Pre-flight balance checks ────────────────────────────────────────────────
  if (usdtAmount > 0n) {
    const bal = await usdt.balanceOf(signer.address);
    console.log(`Signer USDT balance : $${(Number(bal) / 1e6).toFixed(2)} USDT`);
    if (bal < usdtAmount) {
      throw new Error(
        `Insufficient USDT. Have $${(Number(bal)/1e6).toFixed(2)}, need $${(Number(usdtAmount)/1e6).toFixed(2)}.`
      );
    }
  }

  if (linkAmount > 0n) {
    const bal = await link.balanceOf(signer.address);
    console.log(`Signer LINK balance : ${ethers.formatEther(bal)} LINK`);
    if (bal < linkAmount) {
      throw new Error(
        `Insufficient LINK. Have ${ethers.formatEther(bal)}, need ${ethers.formatEther(linkAmount)}.`
      );
    }
  }
  console.log();

  // ── Step 1: Top up cycler with USDT ──────────────────────────────────────────
  if (usdtAmount > 0n) {
    console.log("[1/2] Sending USDT to cycler...");

    const before = await usdt.balanceOf(cyclerAddress);
    console.log(`      Cycler balance before: $${(Number(before) / 1e6).toFixed(2)} USDT`);

    const tx = await usdt.transfer(cyclerAddress, usdtAmount);
    await tx.wait();

    const after = await usdt.balanceOf(cyclerAddress);
    console.log(`      Cycler balance after : $${(Number(after) / 1e6).toFixed(2)} USDT  ✓`);
    console.log(`      Tx: ${tx.hash}\n`);
  } else {
    console.log("[1/2] USDT top-up skipped (FUND_USDT_AMOUNT=0)\n");
  }

  // ── Step 2: Top up Chainlink upkeep with LINK ─────────────────────────────────
  if (linkAmount > 0n) {
    if (!upkeepId) {
      console.log("[2/2] LINK top-up skipped — set UPKEEP_ID env var to fund the upkeep\n");
    } else {
      console.log("[2/2] Adding LINK to Chainlink upkeep...");

      const approveTx = await link.approve(REGISTRY, linkAmount);
      await approveTx.wait();
      console.log(`      Approved ${ethers.formatEther(linkAmount)} LINK to registry  ✓`);

      const fundTx = await registry.addFunds(upkeepId, linkAmount);
      await fundTx.wait();
      console.log(`      Upkeep ${upkeepId} funded  ✓`);
      console.log(`      Tx: ${fundTx.hash}\n`);
    }
  } else {
    console.log("[2/2] LINK top-up skipped (FUND_LINK_AMOUNT=0)\n");
  }

  // ── Summary ───────────────────────────────────────────────────────────────────
  console.log("══════════════════════════════════════════");
  console.log("  Funding complete");
  console.log("══════════════════════════════════════════");

  const cyclerUsdt = await usdt.balanceOf(cyclerAddress);
  console.log("  Cycler USDT balance :", `$${(Number(cyclerUsdt) / 1e6).toFixed(2)} USDT`);
  if (upkeepId && linkAmount > 0n) {
    console.log("  Monitor upkeep at   : https://automation.chain.link/arbitrum/" + upkeepId.toString());
  }
  console.log("══════════════════════════════════════════");
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
