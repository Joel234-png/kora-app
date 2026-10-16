const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
  const [deployer] = await hre.ethers.getSigners();

  const KoraRegistry = await hre.ethers.getContractFactory("KoraRegistry");
  const registry = await KoraRegistry.deploy();
  await registry.waitForDeployment();

  const address = await registry.getAddress();
  console.log(`KoraRegistry deployed to: ${address}`);
  console.log(`Network: ${hre.network.name}`);

  // Verify on-chain bytecode exists at the deployed address before writing the artifact.
  const code = await hre.ethers.provider.getCode(address);
  if (!code || code === "0x") {
    throw new Error(`No bytecode found at deployed address ${address}`);
  }

  const deploymentTx = registry.deploymentTransaction();
  const receipt = deploymentTx ? await deploymentTx.wait() : null;

  const artifact = {
    contractName: "KoraRegistry",
    address,
    network: hre.network.name,
    chainId: Number((await hre.ethers.provider.getNetwork()).chainId),
    deployer: deployer.address,
    blockNumber: receipt ? receipt.blockNumber : null,
    timestamp: new Date().toISOString(),
  };

  const deploymentsDir = path.join(__dirname, "..", "deployments");
  fs.mkdirSync(deploymentsDir, { recursive: true });

  const artifactPath = path.join(deploymentsDir, `${hre.network.name}.json`);
  fs.writeFileSync(artifactPath, JSON.stringify(artifact, null, 2) + "\n");

  console.log(`Deployment artifact written to: ${artifactPath}`);

  return address;
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
