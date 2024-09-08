// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import "fhevm/lib/TFHE.sol";

interface IVestingPlans {
    function createPlan(
        address recipient,
        address token,
        einput amount,
        einput start,
        einput cliff,
        uint256 rate,
        uint256 period,
        address vestingAdmin,
        bool adminTransferOBO,
        bytes calldata inputProof
    ) external;
}
