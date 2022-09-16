import { time, loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";
import { expect } from "chai";
import { ethers } from "hardhat";
import { deployProxy } from "../helpers/deployer";
import { getERC20TokenBalance, impersonateAndSendTokens } from "../helpers/utils";
import ERC20 from "../abis/ERC20.json"
import PoolV3Artifact from '@aave/core-v3/artifacts/contracts/protocol/pool/Pool.sol/Pool.json'

const traderjoeRouter = "0x60aE616a2155Ee3d9A68541Ba4544862310933d4"
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

const usdcToken = {
    address: '0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E',
    name: "USDC",
    symbol: "USDC",
    decimals: 6
}


const TEN_AVAX = ethers.utils.parseUnits("10", 18)

describe("LendingPool", function () {
  // We define a fixture to reuse the same setup in every test.
  // We use loadFixture to run this setup once, snapshot that state,
  // and reset Hardhat Network to that snapshot in every test.
  async function deployProtocol() {
    // Contracts are deployed using the first signer/account by default
    const [deployer, alice, bob, charlie] = await ethers.getSigners();

    const oracle = await deployProxy("GlacierOracle", traderjoeRouter, wavaxToken.address, usdcToken.address)
    const reservePool = await deployProxy("GReservePool", wavaxToken.address)
    const lendingPool = await deployProxy("GLendingPool", oracle.address, traderjoeRouter, wavaxToken.address, usdcToken.address)
    await lendingPool.setClient(deployer.address)

    const addressBook = await deployProxy("GlacierAddressBook",
        wavaxToken.address,
        usdcToken.address,
        reservePool.address,          // Reserve Pool
        lendingPool.address,          // Lending Pool
        oracle.address,               // Oracle
        ethers.constants.AddressZero  // Network wallet
    )

    const glAVAX = await deployProxy("glAVAX", addressBook.address)

    const wavax = await ethers.getContractAt(ERC20, wavaxToken.address)
    const usdc = await ethers.getContractAt(ERC20, usdcToken.address)
    await wavax.connect(deployer).approve(lendingPool.address, ethers.constants.MaxUint256)

    await impersonateAndSendTokens(wavaxToken, wavaxHolder, deployer, 7500)
    await impersonateAndSendTokens(wavaxToken, wavaxHolder, alice, 1000)
    await impersonateAndSendTokens(usdcToken, usdcHolder, deployer, 50000)

    return { glAVAX, oracle, reservePool, lendingPool, wavax, usdc, deployer, alice, bob, charlie };
  }

  describe("Deployment", function () {
    it("Set oracle address", async function () {
        const { lendingPool, oracle } = await loadFixture(deployProtocol)
        const ad = await lendingPool.oracle()
        expect(await lendingPool.oracle()).to.equal(oracle.address)
    })
    it("Set WAVAX address", async function () {
        const { lendingPool } = await loadFixture(deployProtocol)
        expect(await lendingPool.WAVAX()).to.equal(wavaxToken.address)
    })
    it("Set USDC address", async function () {
        const { lendingPool } = await loadFixture(deployProtocol)
        expect(await lendingPool.USDC()).to.equal(usdcToken.address)
    })
    it("Set dex address", async function () {
        const { lendingPool } = await loadFixture(deployProtocol)
        expect(await lendingPool.dex()).to.equal(traderjoeRouter)
    })
    it("Enable deployer as admin", async function () {
        const { lendingPool, deployer } = await loadFixture(deployProtocol);
        expect(await lendingPool.hasRole(await lendingPool.DEFAULT_ADMIN_ROLE(), deployer.address)).to.equal(true)
    })
    it("Enable glAVAX as a lending pool client", async function () {
        const { lendingPool, glAVAX } = await loadFixture(deployProtocol);
        await lendingPool.grantRole(await lendingPool.LENDING_POOL_CLIENT(), glAVAX.address)
        expect(await lendingPool.hasRole(ethers.utils.keccak256(ethers.utils.toUtf8Bytes("LENDING_POOL_CLIENT")), glAVAX.address)).to.equal(true)
    })
  })

  describe("General", function () {
    it("Check AVAX reserves", async function () {
        const { lendingPool, wavax } = await loadFixture(deployProtocol)
        const wavaxAmount = ethers.utils.parseUnits('5000', await wavax.decimals())
        await wavax.transfer(lendingPool.address, wavaxAmount)
        expect(await lendingPool.totalReserves()).to.equal(wavaxAmount)
        expect(await wavax.balanceOf(lendingPool.address)).to.equal(wavaxAmount)
    })

    it("Check USDC reserves", async function () {
        const { lendingPool, usdc } = await loadFixture(deployProtocol)
        const usdcAmount = ethers.utils.parseUnits('3000', await usdc.decimals())
        await usdc.transfer(lendingPool.address, usdcAmount)
        expect(await lendingPool.usableUSDC()).to.equal(usdcAmount)
        expect(await usdc.balanceOf(lendingPool.address)).to.equal(usdcAmount)
    })

    it("Check buying power", async function () {
        const { lendingPool, usdc } = await loadFixture(deployProtocol)
        const usdcAmount = ethers.utils.parseUnits('3000', await usdc.decimals())
        await usdc.transfer(lendingPool.address, usdcAmount)
        const avaxBuyingPower = Number(ethers.utils.formatEther(await lendingPool.purchasingPower()))
        expect(avaxBuyingPower).to.be.greaterThan(0)
    })
  })

  describe("Borrow", function () {
    describe("Validation", function () {
        it("Revert if borrowing with a non-client wallet", async function () {
            const { lendingPool, alice, wavax } = await loadFixture(deployProtocol)
            const wavaxAmount = ethers.utils.parseUnits('5000', await wavax.decimals())
            await wavax.transfer(lendingPool.address, wavaxAmount)
            await expect(lendingPool.connect(alice).borrow(TEN_AVAX)).to.be.revertedWith("INCORRECT_ROLE")
        })
        
        it("Revert if amount is zero", async function () {
            const { lendingPool, deployer, wavax } = await loadFixture(deployProtocol)
            const wavaxAmount = ethers.utils.parseUnits('5000', await wavax.decimals())
            await wavax.transfer(lendingPool.address, wavaxAmount)
            await expect(lendingPool.borrow(0)).to.be.revertedWith("ZERO_BORROW")
        })

        it("Revert if exceeding the total borrow amount available", async function () {
            const { lendingPool, alice, wavax } = await loadFixture(deployProtocol)
            const wavaxAmount = ethers.utils.parseUnits('1', await wavax.decimals())
            await wavax.transfer(lendingPool.address, wavaxAmount)
            await expect(lendingPool.borrow(TEN_AVAX)).to.be.revertedWith("EXCEEDED_BORROW_AMOUNT")
        })
    })

    describe("Logic", function () {
        let fixture: any
        this.beforeEach(async function () {
            fixture = await loadFixture(deployProtocol)
            const wavaxAmount = ethers.utils.parseUnits('5000', await fixture.wavax.decimals())
            await fixture.wavax.transfer(fixture.lendingPool.address, wavaxAmount)
            const usdcAmount = ethers.utils.parseUnits('20000', await fixture.usdc.decimals())
            await fixture.usdc.transfer(fixture.lendingPool.address, usdcAmount)
        })

        it("Borrowed AVAX successfully", async function() {
            let balanceBefore = await fixture.wavax.balanceOf(fixture.deployer.address) 
            await expect(fixture.lendingPool.borrow(TEN_AVAX)).to.not.be.reverted
            let balanceAfter = await fixture.wavax.balanceOf(fixture.deployer.address)
            await expect(balanceAfter.sub(balanceBefore)).to.be.equal(TEN_AVAX)
        })

        it("Borrow event emitted properly", async function() {
            await expect(fixture.lendingPool.borrow(TEN_AVAX))
                .to.emit(fixture.lendingPool, "Borrowed")
                .withArgs(fixture.deployer.address, TEN_AVAX)
        })

        it("Total loaned amount increases", async function() {
            let amountBefore = await fixture.lendingPool.totalLoaned()
            await fixture.lendingPool.borrow(TEN_AVAX)
            let amountAfter = await fixture.lendingPool.totalLoaned()
            expect(amountAfter.sub(amountBefore)).to.be.equal(TEN_AVAX)
        })

        it("Total loaned amount for the user increases", async function() {
            let amountBefore = (await fixture.lendingPool._loans(fixture.deployer.address)).borrowed
            await fixture.lendingPool.borrow(TEN_AVAX)
            let amountAfter = (await fixture.lendingPool._loans(fixture.deployer.address)).borrowed
            expect(amountAfter.sub(amountBefore)).to.be.equal(TEN_AVAX)
        })
    })
  })

  describe("Repay", function () {
    let fixture: any
    const borrowAmount = ethers.utils.parseUnits('1000', 18)
    this.beforeEach(async function () {
        fixture = await loadFixture(deployProtocol)
        const wavaxAmount = ethers.utils.parseUnits('5000', await fixture.wavax.decimals())
        await fixture.wavax.transfer(fixture.lendingPool.address, wavaxAmount)
        const usdcAmount = ethers.utils.parseUnits('20000', await fixture.usdc.decimals())
        await fixture.usdc.transfer(fixture.lendingPool.address, usdcAmount)

        // Deployer takes out a loan of 10000 AVAX
        await fixture.lendingPool.borrow(borrowAmount)
    })

    describe("Validation", function () {
        it("Revert if repaying zero", async function () {
            await expect(fixture.lendingPool.repay(fixture.deployer.address, 0)).to.be.revertedWith("ZERO_REPAY")
        })
        
        it("Revert if trying to repay too much", async function () {
            await expect(fixture.lendingPool.repay(fixture.deployer.address, ethers.utils.parseUnits('5001', await fixture.wavax.decimals()))).to.be.revertedWith("EXCEEDED_REPAY_AMOUNT")
        })

        it("Revert if repaying without token approval", async function () {
            await fixture.wavax.connect(fixture.deployer).approve(fixture.lendingPool.address, 0)
            await expect(fixture.lendingPool.repay(fixture.deployer.address, borrowAmount)).to.be.reverted
        })
    })

    describe("Logic", function () {
        it("Repayed AVAX successfully", async function () {
            let balanceBefore = await fixture.wavax.balanceOf(fixture.deployer.address) 
            await expect(fixture.lendingPool.repay(fixture.deployer.address, borrowAmount)).to.not.be.reverted
            let balanceAfter = await fixture.wavax.balanceOf(fixture.deployer.address)
            expect(balanceBefore.sub(balanceAfter)).to.equal(borrowAmount)
        })

        it("Repay event emitted properly", async function () {
            await expect(fixture.lendingPool.repay(fixture.deployer.address, borrowAmount))
                .to.emit(fixture.lendingPool, "Repayed")
                .withArgs(fixture.deployer.address, fixture.deployer.address, borrowAmount)
        })

        it("Total loaned amount decreases", async function () {
            let amountBefore = await fixture.lendingPool.totalLoaned()
            await fixture.lendingPool.repay(fixture.deployer.address, borrowAmount)
            let amountAfter = await fixture.lendingPool.totalLoaned()
            expect(amountBefore.sub(amountAfter)).to.be.equal(borrowAmount)
        })

        it("Total loaned amount for user decreases", async function () {
            let amountBefore = (await fixture.lendingPool._loans(fixture.deployer.address)).borrowed
            await fixture.lendingPool.repay(fixture.deployer.address, borrowAmount)
            let amountAfter = (await fixture.lendingPool._loans(fixture.deployer.address)).borrowed
            expect(amountBefore.sub(amountAfter)).to.be.equal(borrowAmount)
        })
    })
  })

  describe("Buy And Borrow", function () {
    describe("Validation", function () {
        it("Revert if borrowing with a non-client wallet", async function () {
            const { lendingPool, alice, usdc } = await loadFixture(deployProtocol)
            const usdcAmount = ethers.utils.parseUnits('2000', await usdc.decimals())
            await usdc.transfer(lendingPool.address, usdcAmount)
            await expect(lendingPool.connect(alice).buyAndBorrow(TEN_AVAX)).to.be.revertedWith("INCORRECT_ROLE")
        })

        it("Revert if amount is zero", async function () {
            const { lendingPool, wavax } = await loadFixture(deployProtocol)
            const wavaxAmount = ethers.utils.parseUnits('5000', await wavax.decimals())
            await wavax.transfer(lendingPool.address, wavaxAmount)
            await expect(lendingPool.buyAndBorrow(0)).to.be.revertedWith("ZERO_BORROW")
        })
    })

    describe("Logic", function () {
        let fixture: any
        this.beforeEach(async function () {
            fixture = await loadFixture(deployProtocol)
            const wavaxAmount = ethers.utils.parseUnits('5000', await fixture.wavax.decimals())
            await fixture.wavax.transfer(fixture.lendingPool.address, wavaxAmount)
            const usdcAmount = ethers.utils.parseUnits('20000', await fixture.usdc.decimals())
            await fixture.usdc.transfer(fixture.lendingPool.address, usdcAmount)
        })

        it("Bought and borrowed AVAX successfully", async function () {
            let balanceBefore = await fixture.wavax.balanceOf(fixture.deployer.address)
            let usdcBefore = await fixture.lendingPool.usableUSDC()
            expect(fixture.lendingPool.buyAndBorrow(TEN_AVAX), "Execution reverted").to.not.be.reverted
            let balanceAfter = await fixture.wavax.balanceOf(fixture.deployer.address)
            let usdcAfter = await fixture.lendingPool.usableUSDC()
            expect(Number(balanceAfter.sub(balanceBefore).toString()), "AVAX balance didn't top up in deploy wallet").to.be.greaterThan(0)
            expect(usdcBefore.sub(usdcAfter), "USDC balance didn't go down in lending pool").to.not.be.equal(0)
        })

        it("Bought and borrowed event emitted properly", async function () {
            await expect(fixture.lendingPool.buyAndBorrow(TEN_AVAX))
                .to.emit(fixture.lendingPool, "BoughtAndBorrowed")
                .withArgs(fixture.deployer.address, anyValue)
        })

        it("Total bought amount increases", async function () {
            let amountBefore = await fixture.lendingPool.totalBought()
            await fixture.lendingPool.buyAndBorrow(TEN_AVAX)
            let amountAfter = await fixture.lendingPool.totalBought()
            expect(Number(amountAfter.sub(amountBefore).toString())).to.be.greaterThan(0)
        })

        it("Total bought amount for the user increases", async function () {
            let amountBefore = (await fixture.lendingPool._loans(fixture.deployer.address)).bought
            await fixture.lendingPool.buyAndBorrow(TEN_AVAX)
            let amountAfter = (await fixture.lendingPool._loans(fixture.deployer.address)).bought
            expect(Number(amountAfter.sub(amountBefore).toString())).to.be.greaterThan(0)
        })
    })
  })

  describe("Repay Bought", function () {
    let fixture: any
    const borrowAmount = ethers.utils.parseUnits('1000', 18)
    this.beforeEach(async function () {
        fixture = await loadFixture(deployProtocol)
        const wavaxAmount = ethers.utils.parseUnits('5000', await fixture.wavax.decimals())
        await fixture.wavax.transfer(fixture.lendingPool.address, wavaxAmount)
        const usdcAmount = ethers.utils.parseUnits('20000', await fixture.usdc.decimals())
        await fixture.usdc.transfer(fixture.lendingPool.address, usdcAmount)

        // Deployer takes out a loan of 10000 AVAX
        await fixture.lendingPool.buyAndBorrow(borrowAmount)
    })
    describe("Validation", function () {
        it("Revert if repaying zero", async function () {
            await expect(fixture.lendingPool.repayBought(fixture.deployer.address, 0)).to.be.revertedWith("ZERO_REPAY")
        })

        it("Revert if trying to repay too much", async function () {
            await expect(fixture.lendingPool.repayBought(fixture.deployer.address, ethers.utils.parseUnits('1001', await fixture.wavax.decimals()))).to.be.revertedWith("EXCEEDED_REPAY_AMOUNT")
        })

        it("Revert if repaying without token approval", async function () {
            await fixture.wavax.connect(fixture.deployer).approve(fixture.lendingPool.address, 0)
            await expect(fixture.lendingPool.repayBought(fixture.deployer.address, borrowAmount)).to.be.reverted
        })
    })

    describe("Logic", function () {
        it("Repayed and sold AVAX successfully", async function () {
            let balanceBefore = await fixture.usdc.balanceOf(fixture.lendingPool.address)
            await expect(fixture.lendingPool.repayBought(fixture.deployer.address, await fixture.lendingPool.totalBought()), "Execution reverted").to.not.be.reverted
            let balanceAfter = await fixture.usdc.balanceOf(fixture.lendingPool.address)
            expect(balanceAfter.sub(balanceBefore), "Unkown usdc balance").to.not.be.equal(0)
        })

        it("Repay and sell event emitted properly", async function () {
            await expect(fixture.lendingPool.repayBought(fixture.deployer.address, await fixture.lendingPool.totalBought()))
                .to.emit(fixture.lendingPool, "RepayedAndSold")
                .withArgs(fixture.deployer.address, fixture.deployer.address, anyValue, anyValue)
        })

        it("Total bought amount decreases", async function () {
            let amountBefore = await fixture.lendingPool.totalBought()
            await fixture.lendingPool.repayBought(fixture.deployer.address, await fixture.lendingPool.totalBought())
            let amountAfter = await fixture.lendingPool.totalBought()
            expect(Number(amountBefore.sub(amountAfter).toString())).to.be.greaterThan(0)
        })

        it("Total bought amount for user decreases", async function () {
            let amountBefore = (await fixture.lendingPool._loans(fixture.deployer.address)).bought
            await fixture.lendingPool.repayBought(fixture.deployer.address, await fixture.lendingPool.totalBought())
            let amountAfter = (await fixture.lendingPool._loans(fixture.deployer.address)).bought
            expect(Number(amountBefore.sub(amountAfter).toString())).to.be.greaterThan(0)
        })
    })
  })
})