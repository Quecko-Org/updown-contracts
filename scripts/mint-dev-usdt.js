// mint-dev-usdt.js — mints dev USDT (mock token) to the deployer wallet on Arbitrum.
//
// The dev USDT at 0xCa4f77A38d8552Dd1D5E44e890173921B67725F4 is a permissionless
// mock ERC20 with a public mint() function — anyone can mint to any address.
//
// Usage:
//   npx hardhat run scripts/mint-dev-usdt.js --network arbitrum
//   npm run mint:usdt
//
// Optional env vars:
//   MINT_USDT_AMOUNT   — amount in 6-decimal units, default 5_000_000_000 ($5 000)
//   MINT_RECIPIENT     — recipient address, default = deployer

const { ethers, network } = require("hardhat");

const DEV_USDT = "0xCa4f77A38d8552Dd1D5E44e890173921B67725F4";

const DEV_USDT_ABI = [
  "function mint(address to, uint256 amount) external",
  "function balanceOf(address) view returns (uint256)",
  "function decimals() view returns (uint8)",
];

async function main() {
  const [deployer] = await ethers.getSigners();

  const amount    = process.env.MINT_USDT_AMOUNT
    ? BigInt(process.env.MINT_USDT_AMOUNT)
    : 5_000_000_000n; // default $5 000 USDT

  const recipient = process.env.MINT_RECIPIENT || deployer.address;

  console.log("=== Mint Dev USDT ===");
  console.log("Network   :", network.name);
  console.log("Deployer  :", deployer.address);
  console.log("Recipient :", recipient);
  console.log("Amount    :", amount.toString(), `($${(Number(amount) / 1e6).toFixed(2)} USDT)`);
  console.log();

  const usdt = new ethers.Contract(DEV_USDT, DEV_USDT_ABI, deployer);

  const before = await usdt.balanceOf(recipient);
  console.log(`Balance before: $${(Number(before) / 1e6).toFixed(2)} USDT`);

  const tx = await usdt.mint(recipient, amount);
  console.log("Tx sent:", tx.hash);
  await tx.wait();

  const after = await usdt.balanceOf(recipient);
  console.log(`Balance after : $${(Number(after) / 1e6).toFixed(2)} USDT  ✓`);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
