const hre = require("hardhat");

async function main() {
  const stableTokenAddress = "0xYourStableTokenAddress"; // Replace with deployed token address

  const StableFund = await hre.ethers.getContractFactory("StableFund");
  const stableFund = await StableFund.deploy(stableTokenAddress);
  await stableFund.deployed();

  console.log("StableFund deployed to:", stableFund.address);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
