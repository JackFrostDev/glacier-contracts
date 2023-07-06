import { time, loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";
import { mine } from "@nomicfoundation/hardhat-network-helpers";
import { expect } from "chai";
import { ethers } from "hardhat";
import { deployProxy } from "../helpers/deployer";
import { getERC20TokenBalance, impersonateAndSendTokens } from "../helpers/utils";
import ERC20 from "../abis/ERC20.json"
import PoolV3Artifact from '@aave/core-v3/artifacts/contracts/protocol/pool/Pool.sol/Pool.json'

const traderjoeRouter = "0x60aE616a2155Ee3d9A68541Ba4544862310933d4"

const wavaxToken = {
    address: '0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7',
    name: 'Wrapped AVAX',
    symbol: 'WAVAX',
    decimals: 18
}

const wavaxHolder = "0x9a8cf02f3e56c664ce75e395d0e4f3dc3dafe138"
const usdcHolder = "0x4aefa39caeadd662ae31ab0ce7c8c2c9c0a013e8"

const usdcToken = {
    address: '0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E',
    name: "USDC",
    symbol: "USDC",
    decimals: 6
}


const TEN_AVAX = ethers.utils.parseUnits("10", 18)
const ONE_HUNDRED_AVAX = ethers.utils.parseUnits("100", 18)
const ONE_THOUSAND_AVAX = ethers.utils.parseUnits("1000", 18)

const lendingPoolUsdc = 2000   // $2,000
const lendingPoolAvax = 500    // $10,000

const networkWalletAddress = '0x145d729EAe53DEA212cE970558D6Eb1846D15d20'

describe("wglAVAX", function () {

  const reservePercentage = 1000
  const lendingPoolStartingAVAXBalance = ethers.utils.parseUnits(lendingPoolAvax.toString(), wavaxToken.decimals)
  const lendingPoolStartingUSDCBalance = ethers.utils.parseUnits(lendingPoolUsdc.toString(), usdcToken.decimals)

  // We define a fixture to reuse the same setup in every test.
  // We use loadFixture to run this setup once, snapshot that state,
  // and reset Hardhat Network to that snapshot in every test.
  async function deployProtocol() {
    // Contracts are deployed using the first signer/account by default
    const [deployer, alice, bob, charlie, daniel] = await ethers.getSigners();

    const wavax = await ethers.getContractAt(ERC20, wavaxToken.address)
    const usdc = await ethers.getContractAt(ERC20, usdcToken.address)

    const oracle = await deployProxy("GlacierOracle", traderjoeRouter, wavaxToken.address, usdcToken.address)
    const reservePool = await deployProxy("GReservePool", wavaxToken.address)
    
    const lendingPool = await deployProxy("GLendingPool", oracle.address, traderjoeRouter, wavaxToken.address, usdcToken.address)

    const addressBook = await deployProxy("GlacierAddressBook",
        wavaxToken.address,
        usdcToken.address,
        reservePool.address,          // Reserve Pool
        lendingPool.address,          // Lending Pool
        oracle.address,               // Oracle
        networkWalletAddress          // Network wallet
    )


    // Deploy and configure glAVAX
    const glAVAX = await deployProxy("glAVAX", addressBook.address)
    await glAVAX.setReservePercentage(reservePercentage)
    await lendingPool.setClient(glAVAX.address)
    await reservePool.setManager(glAVAX.address)

    await wavax.connect(deployer).approve(lendingPool.address, ethers.constants.MaxUint256)

    await impersonateAndSendTokens(wavaxToken, wavaxHolder, deployer, 7500)
    await impersonateAndSendTokens(usdcToken, usdcHolder, deployer, 100000)
    await impersonateAndSendTokens(wavaxToken, wavaxHolder, alice, 1000)
    await impersonateAndSendTokens(wavaxToken, wavaxHolder, bob, 1000)
    await impersonateAndSendTokens(wavaxToken, wavaxHolder, charlie, 1000)

    await wavax.transfer(lendingPool.address, lendingPoolStartingAVAXBalance)
    //await usdc.transfer(lendingPool.address, lendingPoolStartingUSDCBalance)

    return { glAVAX, oracle, addressBook, reservePool, lendingPool, wavax, usdc, deployer, alice, bob, charlie, daniel};
  }

  describe("Deployment", function () {
    it.only("Token stats set correctly", async function () {
        const { glAVAX } = await loadFixture(deployProtocol)
        expect(await glAVAX.name()).to.equal("Glacial AVAX", "Name doesnt match")
        expect(await glAVAX.symbol()).to.equal("glAVAX", "Symbol not set")
        expect(await glAVAX.decimals()).to.equal(18, "Decimals not set")
    })

    it("Address book is set correctly", async function () {
        const { glAVAX, addressBook } = await loadFixture(deployProtocol)
        const addressBookFromContract = await ethers.getContractAt("GlacierAddressBook", await glAVAX.addresses())
        expect(addressBookFromContract.address).to.equal(addressBook.address, "Address book didn't set")
        expect(await addressBookFromContract.wavaxAddress()).to.equal(await addressBook.wavaxAddress())
        expect(await addressBookFromContract.usdcAddress()).to.equal(await addressBook.usdcAddress())
        expect(await addressBookFromContract.reservePoolAddress()).to.equal(await addressBook.reservePoolAddress())
        expect(await addressBookFromContract.lendingPoolAddress()).to.equal(await addressBook.lendingPoolAddress())
        expect(await addressBookFromContract.networkWalletAddress()).to.equal(await addressBook.networkWalletAddress())
    })

    it("Enable deployer as admin", async function () {
        const { glAVAX, deployer } = await loadFixture(deployProtocol)
        expect(await glAVAX.hasRole(ethers.constants.HashZero, deployer.address)).to.equal(true)
    })

    it("Enable deployer as network manager", async function () {
        const { glAVAX, deployer } = await loadFixture(deployProtocol)
        expect(await glAVAX.hasRole(await glAVAX.NETWORK_MANAGER(), deployer.address)).to.equal(true)
    })

    it("Reserve percentage is set correctly", async function () {
      const { glAVAX } = await loadFixture(deployProtocol)
      await glAVAX.setReservePercentage(reservePercentage)
      expect(await glAVAX.reservePercentage()).to.be.equal(1000)
    })

    it("Network total is set correctly", async function () {
      const { glAVAX } = await loadFixture(deployProtocol)
      const amount = ethers.utils.parseEther("10000")
      await glAVAX.setNetworkTotal(amount)
      expect(await glAVAX.totalNetworkAVAX(), "Total network AVAX didn't set correctly").to.be.equal(amount)
      expect(await glAVAX.totalAVAX(), "Total AVAX isn't calculating correctly").to.be.equal(amount)
    })
  })

  // describe("Admin Functions", function () {

  // })

  describe("Deposit", function () {

    let fixture: any
    this.beforeEach(async function () {
      fixture = await loadFixture(deployProtocol)
    })

    describe("Validation", function () {
      it("Revert if trying to deposit for another account", async function () {
        // Charlie tries to deposit 10 AVAX for Alice
        await expect(fixture.glAVAX.connect(fixture.charlie).deposit(fixture.alice.address, 0, { value: TEN_AVAX }))
          .to.be.revertedWith("USER_NOT_SENDER")
      })

      it("Revert if trying to deposit zero", async function () {
        await expect(fixture.glAVAX.connect(fixture.charlie).deposit(fixture.charlie.address, 0, { value: 0 }))
          .to.be.revertedWith("ZERO_DEPOSIT")
      })
    })

    describe("Logic", function () {
      it("Deposited AVAX successfully (contract receives WAVAX)", async function () {
        const balanceBefore = await fixture.wavax.balanceOf(fixture.glAVAX.address)
        await expect(fixture.glAVAX.connect(fixture.alice).deposit(fixture.alice.address, 0, { value: TEN_AVAX }))
          .to.not.be.reverted
        const balanceAfter = await fixture.wavax.balanceOf(fixture.glAVAX.address)
        expect(balanceAfter.sub(balanceBefore)).to.equal(TEN_AVAX)
      })

      it("User receives the correct amount of glAVAX token", async function () {
        await fixture.glAVAX.connect(fixture.alice).deposit(fixture.alice.address, 0, { value: TEN_AVAX })
        expect(await fixture.glAVAX.balanceOf(fixture.alice.address)).to.equal(TEN_AVAX)
      })

      it("User receives the correct amount of glAVAX token after rebasing", async function () {
        await fixture.glAVAX.connect(fixture.alice).deposit(fixture.alice.address, 0, { value: TEN_AVAX })
        expect(await fixture.glAVAX.balanceOf(fixture.alice.address)).to.equal(TEN_AVAX)
        await fixture.glAVAX.connect(fixture.deployer).rebalance()
        await fixture.glAVAX.connect(fixture.alice).deposit(fixture.alice.address, 0, { value: TEN_AVAX })
        expect(await fixture.glAVAX.balanceOf(fixture.alice.address)).to.equal(TEN_AVAX.add(TEN_AVAX))
      })

      it("Deposit event emitted", async function () {
        await expect(fixture.glAVAX.connect(fixture.alice).deposit(fixture.alice.address, 0, { value: TEN_AVAX }))
          .to.emit(fixture.glAVAX, "Deposit")
          .withArgs(fixture.alice.address, TEN_AVAX, anyValue)
      })

      it("glAVAX and AVAX exchange rates hold after two deposits of 10 AVAX", async function () {
        await fixture.glAVAX.connect(fixture.alice).deposit(fixture.alice.address, 0, { value: TEN_AVAX })
        await fixture.glAVAX.connect(fixture.bob).deposit(fixture.bob.address, 0, { value: TEN_AVAX })
        expect(await fixture.glAVAX.avaxFromGlavax(ethers.utils.parseEther("1"))).to.equal(ethers.utils.parseEther("1"))
      })
    })
  })

  describe("Rebalance", function () {
    let fixture: any
    this.beforeEach(async function () {
      fixture = await loadFixture(deployProtocol)
      await fixture.glAVAX.connect(fixture.alice).deposit(fixture.alice.address, 0, { value: TEN_AVAX })
      await fixture.glAVAX.connect(fixture.bob).deposit(fixture.bob.address, 0, { value: ONE_HUNDRED_AVAX })
    })

    describe("Validation", function () {
      it("Revert if called by a non-network manager account", async function () {
        await expect(fixture.glAVAX.connect(fixture.alice).rebalance()).to.be.revertedWith("INCORRECT_ROLE")
      })
    })

    describe("Logic", function () {
      it("Rebalanced glAVAX contract successfully", async function () {
        await fixture.glAVAX.connect(fixture.deployer).rebalance()
        await expect(fixture.glAVAX.connect(fixture.deployer).rebalance()).to.not.be.reverted
      })

      it("Reserve pool successfully filled up", async function () {
        const reserveBalanceBefore = await fixture.wavax.balanceOf(fixture.reservePool.address)
        await fixture.glAVAX.connect(fixture.deployer).rebalance()
        const reserveBalanceAfter = await fixture.wavax.balanceOf(fixture.reservePool.address)

        // We expect an increase, but the amount may vary depending on conditions
        expect(Number(reserveBalanceAfter.sub(reserveBalanceBefore).toString())).to.be.greaterThan(0)

        // We expect the amount to increase by exactly x% of the total deposited (x = reserve percentage)
        expect(reserveBalanceAfter.sub(reserveBalanceBefore))
          .to.be.equal(TEN_AVAX.add(ONE_HUNDRED_AVAX).mul(await fixture.glAVAX.reservePercentage()).div(1e4))
      })

      it("Excess AVAX sent to the network", async function () {
        const networkBalanceBefore = await (await ethers.getImpersonatedSigner(networkWalletAddress)).getBalance()
        await fixture.glAVAX.connect(fixture.deployer).rebalance()
        const networkBalanceAfter = await (await ethers.getImpersonatedSigner(networkWalletAddress)).getBalance()

        // We expect an increase, but the amount may vary depending on conditions
        expect(Number(networkBalanceAfter.sub(networkBalanceBefore).toString())).to.be.greaterThan(0)

        // We expect the amount to increase by exactly y% of the total deposited (y = 100 - reserve percentage)
        expect(networkBalanceAfter.sub(networkBalanceBefore))
          .to.be.equal(TEN_AVAX.add(ONE_HUNDRED_AVAX).mul(ethers.BigNumber.from(1e4).sub(await fixture.glAVAX.reservePercentage())).div(1e4))
      })

      it("Avax to glAVAX ratio stays the same", async function () {
        await fixture.glAVAX.connect(fixture.deployer).rebalance()
        expect(await fixture.glAVAX.avaxFromGlavax(ethers.utils.parseEther('1'))).to.equal(ethers.utils.parseEther('1'))
      })
    })
  })

  describe("Withdraw", function () {
    let fixture: any
    this.beforeEach(async function () {
      fixture = await loadFixture(deployProtocol)
      await fixture.glAVAX.connect(fixture.alice).deposit(fixture.alice.address, 0, { value: ONE_THOUSAND_AVAX })
      await fixture.glAVAX.connect(fixture.bob).deposit(fixture.bob.address, 0, { value: ONE_THOUSAND_AVAX })
      await fixture.glAVAX.connect(fixture.deployer).rebalance()
      await fixture.glAVAX.connect(fixture.charlie).deposit(fixture.charlie.address, 0, { value: ONE_HUNDRED_AVAX })
    })

    describe("Validation", function () {
      it("Revert if trying to withdraw from another account", async function () {
        await expect(fixture.glAVAX.connect(fixture.alice).withdraw(fixture.bob.address, TEN_AVAX))
          .to.be.revertedWith("USER_NOT_SENDER")
      })

      it("Revert if trying to withdraw zero", async function () {
        await expect(fixture.glAVAX.connect(fixture.alice).withdraw(fixture.alice.address, 0))
          .to.be.revertedWith("ZERO_WITHDRAW")
      })

      it("Revert if trying to withdraw with no glAVAX balance", async function () {
        await expect(fixture.glAVAX.connect(fixture.daniel).withdraw(fixture.daniel.address, TEN_AVAX))
          .to.be.revertedWith("INSUFFICIENT_BALANCE")
      })
    })

    describe("Logic", function () {
      it("User receives correct amount of AVAX", async function () {
        const balanceBefore = await fixture.alice.getBalance()
        await expect(fixture.glAVAX.connect(fixture.alice).withdraw(fixture.alice.address, TEN_AVAX)).to.not.be.reverted
        const balanceAfter = await fixture.alice.getBalance()
        expect(Number(balanceAfter.sub(balanceBefore).toString())).to.be.greaterThan(0)
      })

      it("Withdraw event emitted", async function () {
        await expect(fixture.glAVAX.connect(fixture.alice).withdraw(fixture.alice.address, TEN_AVAX))
          .to.emit(fixture.glAVAX, "Withdraw")
          .withArgs(fixture.alice.address, await fixture.glAVAX.avaxFromGlavax(TEN_AVAX))
      })

      it("Network correctly throttles when a large withdrawal is made", async function () {
        await fixture.glAVAX.connect(fixture.bob).approve(fixture.bob.address, ethers.constants.MaxUint256)
        console.log("Balance: ", ethers.utils.formatEther(await fixture.glAVAX.balanceOf(fixture.bob.address)))
        await fixture.glAVAX.connect(fixture.bob).withdraw(fixture.bob.address, ONE_THOUSAND_AVAX)
        expect(await fixture.glAVAX.throttleNetwork()).to.be.equal(true)
      })
    })
  })

  /**
   * Describes the tests for the User Withdraw Request feature, testing the timing of withdrawals
   */
  describe("Withdraw Requests", function () {
    let fixture: any
    this.beforeEach(async function () {
      fixture = await loadFixture(deployProtocol)
      await fixture.glAVAX.connect(fixture.alice).deposit(fixture.alice.address, 0, { value: ONE_THOUSAND_AVAX })
      await fixture.glAVAX.connect(fixture.bob).deposit(fixture.bob.address, 0, { value: ONE_THOUSAND_AVAX })
      await fixture.glAVAX.connect(fixture.deployer).rebalance()
      await fixture.glAVAX.connect(fixture.charlie).deposit(fixture.charlie.address, 0, { value: ONE_HUNDRED_AVAX })
      await fixture.glAVAX.connect(fixture.bob).approve(fixture.bob.address, ethers.constants.MaxUint256)
    })

    describe("General", function () {
      it("When withdrawing a large amount a withdraw request is created", async function () {
        await expect(fixture.glAVAX.connect(fixture.bob).withdraw(fixture.bob.address, ONE_THOUSAND_AVAX)).to.not.be.reverted

        const requests = await fixture.glAVAX._userWithdrawRequestCount(fixture.bob.address)
        for (let i = 0; i < 1; ++i) {
          const requestId = await fixture.glAVAX.requestIdFromUserIndex(fixture.bob.address, i)
          const request = await fixture.glAVAX._withdrawRequests(requestId)
          //console.log(`[Withdraw Request] ${fixture.bob.address} made withdraw request at ${request.timestamp}: deposited ${ethers.utils.formatEther(request.glavaxAmount)} glAVAX [Fufilled: ${request.fufilled} | Claimed: ${request.claimed}]`)
          const withdrawRequestAmount = ONE_THOUSAND_AVAX.sub(lendingPoolStartingAVAXBalance).sub(ONE_HUNDRED_AVAX).sub(ONE_THOUSAND_AVAX.add(ONE_THOUSAND_AVAX).div(ethers.BigNumber.from(10)))
          expect(withdrawRequestAmount).to.be.equal(request.glavaxAmount)
        }
      })

      it("Withdraw request emits a user withdraw request event", async function () {
        await expect(fixture.glAVAX.connect(fixture.bob).withdraw(fixture.bob.address, ONE_THOUSAND_AVAX))
          .to.emit(fixture.glAVAX, "UserWithdrawRequest")
          .withArgs(fixture.bob.address, anyValue)
      })

      it("Revert if trying to withdraw more than allowed ", async function () {
        await fixture.glAVAX.connect(fixture.bob).withdraw(fixture.bob.address, ONE_THOUSAND_AVAX)
        await expect(fixture.glAVAX.connect(fixture.bob).withdraw(fixture.bob.address, 100)).to.be.revertedWith('INSUFFICIENT_BALANCE')
      })
    })

    describe("Cancel", function () {
      it("User cannot cancel someone elses request", async function () {
        await fixture.glAVAX.connect(fixture.bob).withdraw(fixture.bob.address, ONE_THOUSAND_AVAX)
        await expect(fixture.glAVAX.connect(fixture.alice).cancel(fixture.bob.address,0 )).to.be.revertedWith("USER_NOT_SENDER")
      })

      it("User receives back their glAVAX", async function () {
        await fixture.glAVAX.connect(fixture.bob).withdraw(fixture.bob.address, ONE_THOUSAND_AVAX)
        await fixture.glAVAX.connect(fixture.bob).cancel(fixture.bob.address, 0)
        const balance = await fixture.glAVAX.balanceOf(fixture.bob.address)
        const withdrawRequestAmount = ONE_THOUSAND_AVAX.sub(lendingPoolStartingAVAXBalance).sub(ONE_HUNDRED_AVAX).sub(ONE_THOUSAND_AVAX.add(ONE_THOUSAND_AVAX).div(ethers.BigNumber.from(10)))
        expect(balance).to.equal(withdrawRequestAmount)
      })

      it("Event 'Cancel' is emitted", async function () {
        await fixture.glAVAX.connect(fixture.bob).withdraw(fixture.bob.address, ONE_THOUSAND_AVAX)
        await expect(fixture.glAVAX.connect(fixture.bob).cancel(fixture.bob.address, 0))
          .to.emit(fixture.glAVAX, "CancelWithdrawRequest")
          .withArgs(fixture.bob.address, anyValue)
      })

      it("Request is no longer readible in the contract", async function () {
        await fixture.glAVAX.connect(fixture.bob).withdraw(fixture.bob.address, ONE_THOUSAND_AVAX)
        await fixture.glAVAX.connect(fixture.bob).cancel(fixture.bob.address, 0)

        const requests = await fixture.glAVAX._userWithdrawRequestCount(fixture.bob.address)
        for (let i = 0; i < requests; ++i) {
          const requestId = await fixture.glAVAX.requestIdFromUserIndex(fixture.bob.address, i)
          const request = await fixture.glAVAX._withdrawRequests(requestId)
          //console.log(`[Withdraw Request] ${fixture.bob.address} made withdraw request at ${request.timestamp}: deposited ${ethers.utils.formatEther(request.glavaxAmount)} glAVAX [Fufilled: ${request.fufilled} | Claimed: ${request.claimed}]`)
          const withdrawRequestAmount = ONE_THOUSAND_AVAX.sub(lendingPoolStartingAVAXBalance).sub(ONE_HUNDRED_AVAX).sub(ONE_THOUSAND_AVAX.add(ONE_THOUSAND_AVAX).div(ethers.BigNumber.from(10)))
          expect(request.glavaxAmount).to.be.equal(0)
        }
      })

      it("'Cancel All' correctly cancels every withdraw request", async function () {
        await fixture.glAVAX.connect(fixture.bob).withdraw(fixture.bob.address, ONE_THOUSAND_AVAX.sub(ONE_HUNDRED_AVAX))   // Req 1   (Index 0)
        await fixture.glAVAX.connect(fixture.bob).withdraw(fixture.bob.address, 100)                                       // Req 2   (Index 1)
        await fixture.glAVAX.connect(fixture.bob).withdraw(fixture.bob.address, 100)                                       // Req 3   (Index 2)
        await fixture.glAVAX.connect(fixture.bob).withdraw(fixture.bob.address, 100)                                       // Req 4   (Index 3)
        await fixture.glAVAX.connect(fixture.bob).withdraw(fixture.bob.address, 100)                                       // Req 5   (Index 4)
        await fixture.glAVAX.connect(fixture.bob).withdraw(fixture.bob.address, 100)                                       // Req 6   (Index 5)
        await fixture.glAVAX.connect(fixture.bob).withdraw(fixture.bob.address, 100)                                       // Req 7   (Index 6)

        await fixture.glAVAX.connect(fixture.bob).cancelAll(fixture.bob.address)

        const requests = await fixture.glAVAX._userWithdrawRequestCount(fixture.bob.address)
        for (let i = requests - 1; i >= 0; --i) {
          const requestId = await fixture.glAVAX.requestIdFromUserIndex(fixture.bob.address, i)
          const request = await fixture.glAVAX._withdrawRequests(requestId)
          //console.log(`[Withdraw Request ${i}] ${fixture.bob.address} made withdraw request at ${request.timestamp}: deposited ${ethers.utils.formatEther(request.glavaxAmount)} glAVAX [Fufilled: ${request.fufilled} | Claimed: ${request.claimed}]`)
          expect(request.glavaxAmount).to.be.equal(0)
        }
      })
    })

    describe("Claim", function () {
      it("User cannot claim a request that isn't yet fufilled", async function () {
        await fixture.glAVAX.connect(fixture.bob).withdraw(fixture.bob.address, ONE_THOUSAND_AVAX)
        await expect(fixture.glAVAX.connect(fixture.bob).claim(fixture.bob.address, 0)).to.be.revertedWith("REQUEST_NOT_FUFILLED")
      })

      it("User cannot claim a request that has already been claimed", async function () {
        await fixture.glAVAX.connect(fixture.bob).withdraw(fixture.bob.address, ONE_THOUSAND_AVAX)
        await fixture.glAVAX.connect(fixture.deployer).fufillWithdrawal({ value: ethers.utils.parseEther("1000") })
        await expect(fixture.glAVAX.connect(fixture.bob).claim(fixture.bob.address, 0)).to.not.be.reverted
        await expect(fixture.glAVAX.connect(fixture.bob).claim(fixture.bob.address, 0)).to.be.revertedWith("REQUEST_ALREADY_CLAIMED")
      })
      
      it("User cannot claim someone elses request", async function () {
        await fixture.glAVAX.connect(fixture.bob).withdraw(fixture.bob.address, ONE_THOUSAND_AVAX)
        await expect(fixture.glAVAX.connect(fixture.alice).cancel(fixture.bob.address,0 )).to.be.revertedWith("USER_NOT_SENDER")
      })

      it("'Claim All' successfully claims every pending withdrawal request", async function () {
        await fixture.glAVAX.connect(fixture.bob).withdraw(fixture.bob.address, ONE_THOUSAND_AVAX.sub(ONE_HUNDRED_AVAX))
        await fixture.glAVAX.connect(fixture.bob).withdraw(fixture.bob.address, 100)
        await fixture.glAVAX.connect(fixture.bob).withdraw(fixture.bob.address, 100)
        await fixture.glAVAX.connect(fixture.deployer).fufillWithdrawal({ value: ethers.utils.parseEther("1000") })
        await expect(fixture.glAVAX.connect(fixture.bob).claimAll(fixture.bob.address)).to.not.be.reverted
      })

      it("User receives AVAX from claiming", async function () {
        await fixture.glAVAX.connect(fixture.bob).withdraw(fixture.bob.address, ONE_THOUSAND_AVAX.sub(ONE_HUNDRED_AVAX))
        await fixture.glAVAX.connect(fixture.bob).withdraw(fixture.bob.address, 100)
        await fixture.glAVAX.connect(fixture.bob).withdraw(fixture.bob.address, 100)
        await fixture.glAVAX.connect(fixture.deployer).fufillWithdrawal({ value: ethers.utils.parseEther("1000") })

        const balanceBefore = await fixture.bob.getBalance()
        await fixture.glAVAX.connect(fixture.bob).claimAll(fixture.bob.address)
        const balanceAfter = await fixture.bob.getBalance()
        expect(Number(balanceAfter.sub(balanceBefore).toString())).to.be.greaterThan(0)
      })

      it("Event 'Claim' is emitted", async function () {
        await fixture.glAVAX.connect(fixture.bob).withdraw(fixture.bob.address, ONE_THOUSAND_AVAX)
        await fixture.glAVAX.connect(fixture.deployer).fufillWithdrawal({ value: ethers.utils.parseEther("1000") })
        await expect(fixture.glAVAX.connect(fixture.bob).claim(fixture.bob.address, 0))
          .to.emit(fixture.glAVAX, "Claim")
          .withArgs(fixture.bob.address, anyValue)
      })
    })
  })
})