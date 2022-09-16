import hre, { ethers, upgrades } from "hardhat";

async function verifyContract(address: string, ...constructorArguments: any[]) : Promise<void> {
    await hre.run("verify:verify", {
        address,
        constructorArguments
    });
}

async function deployContract(name: string, ...constructorArgs: any[]) : Promise<any> {
    const factory = await ethers.getContractFactory(name);
    const contract = await factory.deploy(...constructorArgs);
    await contract.deployed();
    return contract;
}

async function deployProxy(name: string, ...constructorArgs: any[]) : Promise<any> {
    const factory = await ethers.getContractFactory(name);
    const contract = await upgrades.deployProxy(factory, constructorArgs);
    await contract.deployed();
    return contract;
}

async function upgradeProxy(proxy: string, name: string, ...constructorArgs: any[]) : Promise<any> {
    const factory = await ethers.getContractFactory(name);
    const contract = await upgrades.upgradeProxy(proxy, factory);
    return contract;
}

async function deployAndVerifyProxy(name: string, ...constructorArgs: any[]) : Promise<any> {
    const contract = await deployProxy(name, ...constructorArgs);
    await hre.run("verify:verify", {
        address: contract.address,
        constructorArguments: [],
    });
    return contract;
}

export {
    verifyContract,
    deployContract,
    deployProxy,
    deployAndVerifyProxy,
}