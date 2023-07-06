import { time, loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";
import { expect } from "chai";
import { ethers } from "hardhat";
import { deployProxy } from "../helpers/deployer";
import { getERC20TokenBalance, impersonateAndSendTokens } from "../helpers/utils";
import ERC20 from "../abis/ERC20.json"
import PoolV3Artifact from '@aave/core-v3/artifacts/contracts/protocol/pool/Pool.sol/Pool.json'

const aaveV3Address = '0x794a61358D6845594F94dc1DB02A252b5b4814aD'
const glAvaxAddress = ethers.constants.AddressZero

const wavaxToken = {
    address: '0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7',
    name: 'Wrapped AVAX',
    symbol: 'WAVAX',
    decimals: 18
}

const wavaxHolder = "0xa9497fd9d1dd0d00de1bf988e0e36794848900f9"
const usdcHolder = "0x9f8c163cba728e99993abe7495f06c0a3c8ac8b9"

const TEN_AVAX = ethers.utils.parseUnits("10", 18)

describe("ReservePool", function () {
  // We define a fixture to reuse the same setup in every test.
  // We use loadFixture to run this setup once, snapshot that state,
  // and reset Hardhat Network to that snapshot in every test.
  async function deployReservePool() {
    // Contracts are deployed using the first signer/account by default
    const [deployer, alice, bob, charlie] = await ethers.getSigners();

    const reservePool = await deployProxy("GReservePool", wavaxToken.address)

    const wavax = await ethers.getContractAt(ERC20, wavaxToken.address)

    await wavax.connect(deployer).approve(reservePool.address, ethers.constants.MaxUint256)

    await impersonateAndSendTokens(wavaxToken, wavaxHolder, deployer, 1000)
    await impersonateAndSendTokens(wavaxToken, wavaxHolder, alice, 1000)

    return { reservePool, wavax, deployer, alice, bob, charlie };
  }

  describe("Deployment", function () {
    it("Set WAVAX address", async function () {
        const { reservePool } = await loadFixture(deployReservePool)
        await expect(await reservePool.WAVAX()).to.equal(wavaxToken.address)
    });

    it("Enable deployer as admin", async function () {
        const { reservePool, deployer } = await loadFixture(deployReservePool)
        await expect(await reservePool.hasRole(ethers.constants.HashZero, deployer.address)).to.equal(true)
    });

    it("Enable glAVAX as reserve pool manager", async function () {
        const { reservePool } = await loadFixture(deployReservePool);
        await reservePool.grantRole(await reservePool.RESERVE_POOL_MANAGER(), glAvaxAddress)
        await expect(await reservePool.hasRole(ethers.utils.keccak256(ethers.utils.toUtf8Bytes("RESERVE_POOL_MANAGER")), glAvaxAddress)).to.equal(true)
    });

    it("Initialize default strategy", async function () {
        const { reservePool } = await loadFixture(deployReservePool)

        await expect(await reservePool._maxStrategies()).to.equal(5)
        await expect(await reservePool._totalWeight()).to.equal(100)
        await expect((await reservePool._strategies(0)).weight).to.equal(100)
        await expect(await reservePool._strategyCount()).to.equal(1)
    });
  });

  describe("Admin Functions", function () {

    let reservePool: any
    let aaveStrategy: any

    beforeEach(async function () {
        const fixture = await loadFixture(deployReservePool)
        reservePool = fixture.reservePool
        aaveStrategy = await deployProxy("AaveV3Strategy", reservePool.address, wavaxToken.address, aaveV3Address)
        await reservePool.addStrategy(aaveStrategy.address, 100)
    })

    describe("Add Strategy", function () {
        it("Strategy exists in list", async function () {
            const newStrategy = await reservePool._strategies(1)
            await expect(newStrategy.logic).to.equal(aaveStrategy.address)
        })
        it("Strategy count increases", async function () {
            await expect(await reservePool._strategyCount()).to.equal(2)
        })
        it("Strategy weight calculates correctly", async function () {
            const totalWeight = await reservePool._totalWeight()
            const newStrategy = await reservePool._strategies(1)
            await expect(newStrategy.weight / totalWeight).to.equal(100 / 200)
        })
        it("Strategy cant exceed max strategies", async function () {
            const maxStrategies = await reservePool._maxStrategies()
            const count = (await reservePool._maxStrategies()) + 5
            for (let i = 2; i < count; ++i) {
                const strat = await deployProxy("AaveV3Strategy", reservePool.address, wavaxToken.address, aaveV3Address)

                // 0 - Base
                // 1 - New
                // 2 - Create NO REVERT
                // 3 - Create NO REVERT
                // 4 - Create NO REVERT
                // 5 - Create REVERT
                if (i == maxStrategies) {
                    await expect(reservePool.addStrategy(strat.address, 100)).to.be.revertedWith("TOO_MANY_STRATEGIES")
                    break
                } else {
                    await expect(reservePool.addStrategy(strat.address, 100)).to.not.be.revertedWith("TOO_MANY_STRATEGIES")
                }
            }
        })
    })
    describe("Clear Strategies", function () {
        it("Clear strategies correctly resets", async function () {
            const newStrategy = await reservePool._strategies(1)
            await expect(await reservePool._strategyCount()).to.equal(2)
            await expect(newStrategy.logic).to.equal(aaveStrategy.address)
            
            await reservePool.clearStrategies()

            await expect(await reservePool._strategyCount()).to.equal(1)
        })
    })
  })

  describe("Deposit", function () {

    let reservePool: any

    beforeEach(async function () {
        const fixture = await loadFixture(deployReservePool)
        reservePool = fixture.reservePool
    })

    describe("Validations", function () {
        it("Revert if called by a non-approved wallet", async function () {
            const { reservePool, alice } = await loadFixture(deployReservePool);
            await expect(reservePool.connect(alice).deposit(TEN_AVAX)).to.be.revertedWith("INCORRECT_ROLE")
        })
    
        it("Revert if depositing zero", async function () {
            const { reservePool, deployer } = await loadFixture(deployReservePool);
            await expect(reservePool.deposit(0)).to.be.revertedWith("ZERO_DEPOSIT")
        })
    
        it("Revert if depositing without approval", async function () {
            const { reservePool, wavax, deployer } = await loadFixture(deployReservePool);
            await wavax.connect(deployer).approve(reservePool.address, 0)
            await expect(reservePool.deposit(TEN_AVAX)).to.be.reverted
        })
    })

    describe("Logic", function () {
        it("Deposit event emitted", async function () {
            const { reservePool, deployer } = await loadFixture(deployReservePool);
            await expect(reservePool.deposit(TEN_AVAX))
                .to.emit(reservePool, "Deposit")
                .withArgs(deployer.address, TEN_AVAX)
        })

        it("Deposits AVAX successfully into the reserve pool", async function () {
            const { reservePool, wavax, deployer } = await loadFixture(deployReservePool);
            await reservePool.deposit(TEN_AVAX)
            expect(await reservePool.totalReserves()).to.equal(TEN_AVAX)
            expect(await wavax.balanceOf(reservePool.address)).to.equal(TEN_AVAX)
        })

        it("Deposits AVAX successfully into the reserve pool with strategies", async function () {
            const { reservePool, wavax, deployer } = await loadFixture(deployReservePool);
            const aaveStrategy = await deployProxy("AaveV3Strategy", reservePool.address, wavaxToken.address, aaveV3Address)
            await reservePool.addStrategy(aaveStrategy.address, 100)
            await reservePool.deposit(TEN_AVAX)
            expect(await reservePool.totalReserves()).to.equal(TEN_AVAX)
        })
    })

    describe("Aave V3", function () {
       // let aaveStrategy: any

        //beforeEach(async function() {
            //aaveStrategy = await deployProxy("AaveV3Strategy", reservePool.address, wavaxToken.address, aaveV3Address)
            //await reservePool.addStrategy(aaveStrategy.address, 100)
        //})

        it("Deposit AVAX successfully into Aave V3", async function () {
            const { reservePool, wavax, deployer } = await loadFixture(deployReservePool);
            const aaveStrategy = await deployProxy("AaveV3Strategy", reservePool.address, wavaxToken.address, aaveV3Address)
            await reservePool.addStrategy(aaveStrategy.address, 100)
            await reservePool.deposit(TEN_AVAX)
        })

        it("Reserve pool holds the AVAX yield bearing token", async function () {
            const { reservePool, wavax, deployer } = await loadFixture(deployReservePool);
            const aaveStrategy = await deployProxy("AaveV3Strategy", reservePool.address, wavaxToken.address, aaveV3Address)
            await reservePool.addStrategy(aaveStrategy.address, 100)
            await reservePool.deposit(TEN_AVAX)

            const aaveLendingPool = await ethers.getContractAt(PoolV3Artifact.abi, aaveV3Address)
            const userAccountData = await aaveLendingPool.getUserAccountData(reservePool.address);
            expect(Number(userAccountData.totalCollateralBase.toString())).to.be.greaterThan(0)
            
            const userConfig = await aaveLendingPool.getUserConfiguration(reservePool.address)
            const binary = int2bin(userConfig)
            const reserveAssetAddresses = await aaveLendingPool.getReservesList()

            let wavaxDepositAmount = 0
            for (let i = 0; i < reserveAssetAddresses.length; ++i) {
                const reserveAssetAddress = reserveAssetAddresses[i]
                const collat = binary[binary.length - 1 - i*2 - 1] == "1" ? true : false
                if (collat && reserveAssetAddress == wavax.address) {
                    const reserveData = await aaveLendingPool.getReserveData(reserveAssetAddress)
                    wavaxDepositAmount = await getERC20TokenBalance(reserveData.aTokenAddress, reservePool.address)
                    break
                }
            }
            
            expect(wavaxDepositAmount).to.be.greaterThan(0)
        })
    })
  })

  describe("Withdrawals", function () {
    describe("Validations", function () {

    });

    describe("Events", function () {
      
    });

    describe("Transfers", function () {

    });
  });
});

function int2bin(int: any){
    return Number(int.toString()).toString(2)
}