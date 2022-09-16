// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { ERC20Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import { IJoeRouter02 } from "@traderjoe-xyz/core/contracts/traderjoe/interfaces/IJoeRouter02.sol";

/**
 * @title  GlacierOracle Contract
 * @author Jack Frost
 * @notice The GlacierOracle is an onchain oracle that lets us determine the price of AVAX in USDC for swaps
 */
contract GlacierOracle is Initializable {

    /// @notice The router that the oracle will query
    address public _router;

    /// @notice The address of WAVAX
    address public _wavax;

    /// @notice The address of USDC
    address public _usdc;

    function initialize(address router, address wavax, address usdc) initializer public {
        _router = router;
        _wavax = wavax;
        _usdc = usdc;
    }

    /**
     * @notice Returns how many tokens of `token` you receive in USDC
     * @dev Requires a USDC pool to be available
     */
    function getTokensForOneUSDC(address token) public view returns (uint256) {
        return getTokensForUSDC(token, 10 ** ERC20Upgradeable(token).decimals());
    }
    
    /**
     * @notice Gets the onchain price of a token in USDC
     * @dev Implementation assumes there is at least a USDC LP or an AVAX LP on TraderJoe
     */
    function getPrice(address token) public view returns (uint256) {
        uint256 price = getUSDCForTokens(token, 10 ** ERC20Upgradeable(token).decimals());
        if (price == 0) {
            uint256 avaxPriceInUsdc = getUSDCForTokens(_wavax, 10 ** ERC20Upgradeable(_wavax).decimals());
            uint256 tokenPriceInAvax = getAVAXForTokens(token, 10 ** ERC20Upgradeable(token).decimals());
            price = tokenPriceInAvax * avaxPriceInUsdc / 10 ** ERC20Upgradeable(_wavax).decimals();
        }
        return price;
    }

    /**
     * @notice Returns how many `token` tokens you get for `usdcAmount` USDC
     */
    function getTokensForUSDC(address token, uint256 usdcAmount) public view returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = _usdc;
        uint256[] memory amountsOut = IJoeRouter02(_router).getAmountsIn(usdcAmount, path);
        return amountsOut[0];
    }

    /**
     * @notice Returns how many USDC tokens you need to purchase `tokenAmount` of `token`
     */
    function getUSDCForTokens(address token, uint256 tokenAmount) public view returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = _usdc;
        path[1] = token;
        uint256[] memory amountsOut = IJoeRouter02(_router).getAmountsIn(tokenAmount, path);
        return amountsOut[0];
    }

    /**
     * @notice Returns how many AVAX tokens you need for inputed tokenAmount
     */
    function getAVAXForTokens(address token, uint256 tokenAmount) public view returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = _wavax;
        path[1] = token;
        uint256[] memory amountsOut = IJoeRouter02(_router).getAmountsIn(tokenAmount, path);
        return amountsOut[0];
    }
}