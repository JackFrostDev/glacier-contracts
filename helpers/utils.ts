/* eslint-disable no-await-in-loop */
import { BigNumber, BigNumberish } from "ethers";
import hre, { ethers } from "hardhat";

import ERC20 from "../abis/ERC20.json"

export async function mineBlock() : Promise<void> {
    await hre.network.provider.request({
        method: "evm_mine"
    });
}

export async function mineBlocks(blocks: number) : Promise<void> {
  await hre.network.provider.send("hardhat_mine", ["0x"+blocks.toString(16)]);
}

export async function setNextBlockTimestamp(timestamp: number) : Promise<void> {
    await hre.network.provider.request({
        method: "evm_setNextBlockTimestamp",
        params: [timestamp]}
    );
}

export async function getLatestBlockTimestamp() : Promise<number> {
    return (await ethers.provider.getBlock("latest")).timestamp;
}

export async function getLatestBlockNumber() : Promise<number> {
  return (await ethers.provider.getBlock("latest")).number;
}

export async function mineBlockTo(blockNumber: number) : Promise<void> {
  for (let i = await ethers.provider.getBlockNumber(); i < blockNumber; i += 1) {
    await mineBlock()
  }
}

export async function latest() : Promise<BigNumber> {
  const block = await ethers.provider.getBlock("latest")
  return BigNumber.from(block.timestamp)
}


export async function advanceTime(time: number) : Promise<void> {
  await ethers.provider.send("evm_increaseTime", [time])
}

export async function advanceTimeAndBlock(time: number) : Promise<void> {
  await advanceTime(time)
  await mineBlock()
}

export const duration = {
  seconds (val: BigNumberish) : BigNumber {
    return BigNumber.from(val)
  },
  minutes (val: BigNumberish) : BigNumber {
    return BigNumber.from(val).mul(this.seconds("60"))
  },
  hours (val: BigNumberish) : BigNumber {
    return BigNumber.from(val).mul(this.minutes("60"))
  },
  days (val: BigNumberish) : BigNumber {
    return BigNumber.from(val).mul(this.hours("24"))
  },
  weeks (val: BigNumberish) : BigNumber {
    return BigNumber.from(val).mul(this.days("7"))
  },
  years (val: BigNumberish) : BigNumber {
    return BigNumber.from(val).mul(this.days("365"))
  },
}

// Defaults to e18 using amount * 10^18
export function getBigNumber(amount: BigNumberish, decimals = 18) : BigNumber {
  return BigNumber.from(amount).mul(BigNumber.from(10).pow(decimals))
}

export async function impersonateAccount(account: string) {
  await hre.network.provider.request({
      method: "hardhat_impersonateAccount",
      params: [account]}
  );
}

export async function impersonateAccounts(accounts: string[]) {
  await hre.network.provider.request({
      method: "hardhat_impersonateAccount",
      params: accounts}
  );
}

export async function stopImpersonatingAccount(account: string) {
  await hre.network.provider.request({
      method: "hardhat_stopImpersonatingAccount",
      params: [account]}
  );
}

export interface ITokenInfo {
  address: string
  name: string
  symbol: string
  decimals: number
}

export async function impersonateAndSendTokens(token: ITokenInfo, holder: string, receiver: any, amount: any) {
  //console.log(`Sending ${amount} ${token.symbol} to ${receiver} ...`);
  const erc20 = await ethers.getContractAt(ERC20, token.address);
  await receiver.sendTransaction({
      to: holder,
      value: ethers.utils.parseEther("1.0")
  });

  const transferAmount = ethers.utils.parseUnits(amount.toString(), token.decimals)

  await impersonateAccount(holder);
  const signedHolder = await ethers.provider.getSigner(holder);
  if ((await erc20.balanceOf(signedHolder.getAddress())).lt(transferAmount)) {
    throw "Token holder balance high enough for this transfer! Consider using another wallet"
  }
  await erc20.connect(signedHolder).transfer(receiver.address, ethers.utils.parseUnits(amount.toString(), token.decimals));
  await stopImpersonatingAccount(holder);
}


export async function getERC20TokenBalance(tokenAddress: string, account: string, format: boolean = true) {
  const token = await ethers.getContractAt(ERC20, tokenAddress)
  return format ? Number(ethers.utils.formatUnits(await token.balanceOf(account), await token.decimals())) : await token.balanceOf(account)
}

export function sleep(ms: any) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

export function dateString(ms: any) {
  var currentdate = new Date(ms); 
  return currentdate.getDate() + "/"
                  + (currentdate.getMonth()+1)  + "/" 
                  + currentdate.getFullYear() + " @ "  
                  + currentdate.getHours() + ":"  
                  + currentdate.getMinutes() + ":" 
                  + currentdate.getSeconds();
}