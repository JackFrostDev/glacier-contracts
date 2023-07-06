// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;


import { Test } from "@forge-std/Test.sol";
import { console } from "@forge-std/console.sol";

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import { GReservePool } from "contracts/protocol/ReservePool/GReservePool.sol";
import { GLendingPool } from "contracts/protocol/LendingPool/GLendingPool.sol";
import { GlacierAddressBook } from "contracts/GlacierAddressBook.sol";
import { glAVAX } from "contracts/protocol/GlacialAVAX/glAVAX.sol";
import { wglAVAX } from "contracts/protocol/GlacialAVAX/wglAVAX.sol";

contract Fixture is Test {

    address public constant trajerJoe = 0x60aE616a2155Ee3d9A68541Ba4544862310933d4;
    ERC20 public constant wAvaxToken = ERC20(0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7); 
    ERC20 public constant usdcToken = ERC20(0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E);
    address public constant networkWalletAddress = 0x145d729EAe53DEA212cE970558D6Eb1846D15d20;

    uint256 public constant lendingPoolUsdc = 2000;
    uint256 public constant lendingPoolWavax = 500; 
    uint256 public constant reservePercentage = 1000;

    //GlacierOracle public glacierOracle; //missing contract
    GReservePool public reservePool;
    GLendingPool public lendingPool;
    GlacierAddressBook public glacierAddressBook;
    glAVAX public glAVAXToken;
    wglAVAX public wglAVAXToken;
    ProxyAdmin public proxyAdmin;

    address deployer = makeAddr("Deployer");
    address alice = makeAddr("Alice");
    address bob = makeAddr("Bob");
    address charlie = makeAddr("Charlie");
    address daniel = makeAddr("Daniel");

    uint256 public constant INITIAL_DEPLOYER_USDC_BALANCE = 100000;
    uint256 public constant INITIAL_DEPLOYER_WAVAX_BALANCE = 7500;
    uint256 public constant INITIAL_ACTOR_WAVAX_BALANCE = 1000;
    uint256 public constant INITIAL_DEPLOYER_AVAX_BALANCE = 7500;
    uint256 public constant INITIAL_ACTOR_AVAX_BALANCE = 1000;

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("AVAX_MAINNET"));
        assertEq(block.chainid, 43114);

        vm.label(address(usdcToken), "USDC");
        vm.label(address(wAvaxToken), "WAVAX");

        vm.startPrank(deployer);

        proxyAdmin = new ProxyAdmin();

        reservePool = GReservePool(
            _deployProxy(
                address(new GReservePool()), 
                abi.encodeWithSelector(GReservePool.initialize.selector, address(wAvaxToken))
            )
        );
        vm.label(address(reservePool), "ReservePool");

        lendingPool = GLendingPool(
            _deployProxy(
                address(new GLendingPool()), 
                abi.encodeWithSelector(GLendingPool.initialize.selector, address(wAvaxToken), address(usdcToken))
            )
        );
        vm.label(address(lendingPool), "LendingPool");

        glacierAddressBook = GlacierAddressBook(
            _deployProxy(
                address(new GlacierAddressBook()), 
                abi.encodeWithSelector(
                    GlacierAddressBook.initialize.selector, 
                    address(wAvaxToken), 
                    address(usdcToken), 
                    address(reservePool),
                    address(lendingPool),
                    address(0), // missing glacierOracle
                    networkWalletAddress
                )
            )
        );
        vm.label(address(glacierAddressBook), "GlacierAddressBook");

        glAVAXToken = glAVAX(
            payable(_deployProxy(
                address(new glAVAX()), 
                abi.encodeWithSelector(
                    glAVAX.initialize.selector, 
                    address(glacierAddressBook)
                )
            ))
        );
        vm.label(address(glAVAXToken), "glAVAX");

        wglAVAXToken = wglAVAX(
            _deployProxy(
                address(new wglAVAX()), 
                abi.encodeWithSelector(
                    wglAVAX.initialize.selector, 
                    address(glAVAXToken)
                )
            )
        );
        vm.label(address(wglAVAXToken), "wglAVAX");

        glAVAXToken.setReservePercentage(reservePercentage);
        lendingPool.setClient(address(glAVAXToken));
        reservePool.setManager(address(glAVAXToken));

        wAvaxToken.approve(address(lendingPool), type(uint256).max);
        vm.stopPrank();

        deal(address(wAvaxToken), deployer, INITIAL_DEPLOYER_WAVAX_BALANCE*10**wAvaxToken.decimals());
        deal(address(usdcToken), deployer, INITIAL_DEPLOYER_USDC_BALANCE*10**usdcToken.decimals());
        deal(address(wAvaxToken), alice, INITIAL_ACTOR_WAVAX_BALANCE*10**wAvaxToken.decimals());
        deal(address(wAvaxToken), bob, INITIAL_ACTOR_WAVAX_BALANCE*10**wAvaxToken.decimals());
        deal(address(wAvaxToken), charlie, INITIAL_ACTOR_WAVAX_BALANCE*10**wAvaxToken.decimals());
        deal(address(wAvaxToken), address(lendingPool), lendingPoolWavax*10**wAvaxToken.decimals());
    }

    function _deployProxy(address implementation_, bytes memory initializer_) internal returns (address) {
        return address(new TransparentUpgradeableProxy(implementation_, address(proxyAdmin), initializer_));
    }
}