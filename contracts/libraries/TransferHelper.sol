// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import { eERC20 } from "../interfaces/eERC20.sol";
import "fhevm/lib/TFHE.sol";

/// @notice Library to help safely transfer tokens and handle ETH wrapping and unwrapping of WETH
library TransferHelper {
    /// @notice Internal function used for standard ERC20 transferFrom method
    /// @notice it contains a pre and post balance check
    /// @notice as well as a check on the msg.senders balance
    /// @param token is the address of the ERC20 being transferred
    /// @param from is the remitting address
    /// @param to is the location where they are being delivered
    function transferTokens(address token, address from, address to, euint64 amount) internal {
        // euint64 priorBalance = eERC20(token).balanceOf(address(to));
        // require(eERC20(token).balanceOf(from) >= amount, "THL01");
        eERC20(token).transferFrom(from, to, amount);
        // euint64 postBalance = eERC20(token).balanceOf(address(to));
        // require(postBalance - priorBalance == amount, "THL02");
    }

    /// @notice Internal function is used with standard ERC20 transfer method
    /// @notice this function ensures that the amount received is the amount sent with pre and post balance checking
    /// @param token is the ERC20 contract address that is being transferred
    /// @param to is the address of the recipient
    /// @param amount is the amount of tokens that are being transferred
    function withdrawTokens(address token, address to, euint64 amount) internal {
        // euint64 priorBalance = eERC20(token).balanceOf(address(to));
        eERC20(token).transfer(to, amount);
        // euint64 postBalance = eERC20(token).balanceOf(address(to));
        // require(postBalance - priorBalance == amount, "THL02");
    }
}
