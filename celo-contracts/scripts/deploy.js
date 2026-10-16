const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
  const Factory = await hre.ethers.getContractFactory("KoraRegistry");
  const registry = await Factory.deploy();
  await registry.waitForDeployment();

  const address = await registry.getAddress();
  console.log(`KoraRegistry deployed to: ${address}`);
  console.log(`Network: ${hre.network.name}`);

  const deploymentsDir = path.join(__dirname, "..", "deployments");
  if (!fs.existsSync(deploymentsDir)) {
    fs.mkdirSync(deploymentsDir, { recursive: true });
  }

  const artifact = {
    address,
    network: hre.network.name,
    timestamp: new Date().toISOString(),
  };

  const artifactPath = path.join(deploymentsDir, `${hre.network.name}.json`);
  fs.writeFileSync(artifactPath, JSON.stringify(artifact, null, 2));
  console.log(`Deployment artifact written to deployments/${hre.network.name}.json`);

  return address;
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
