// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import "fhevm/lib/TFHE.sol";

/// @notice Library to assist with calculation methods of the balances, ends, period amounts for a given plan
/// used by both the Lockup and Vesting Plans
library TimelockLibrary {
    function min(uint256 a, uint256 b) internal pure returns (uint256 _min) {
        _min = (a <= b) ? a : b;
    }

    /// @notice function to calculate the end date of a plan based on its start, amount, rate and period
    function endDate(euint64 start, euint64 amount, uint256 rate, uint256 period) internal pure returns (euint64 end) {
        // end = (amount % rate == 0) ? (amount / rate) * period + start : ((amount / rate) * period) + period + start;
        ebool mod = TFHE.eq(TFHE.rem(amount, uint64(rate)), TFHE.asEuint64(0));
        euint64 temp = TFHE.add(start, TFHE.mul(TFHE.asEuint64(period), TFHE.div(amount, uint64(rate))));
        end = TFHE.select(mod, temp, TFHE.add(temp, TFHE.asEuint64(period)));
    }

    /// @notice function to calculate the end period and validate that the parameters passed in are valid
    function validateEnd(
        euint64 start,
        euint64 cliff,
        euint64 amount,
        uint256 rate,
        uint256 period
    ) internal pure returns (euint64 end, ebool valid) {
        // require(amount > 0, "0_amount");
        // require(rate > 0, "0_rate");
        // require(rate <= amount, "rate > amount");
        // require(period > 0, "0_period");
        ebool req1 = TFHE.gt(amount, TFHE.asEuint64(0));
        ebool req2 = TFHE.gt(TFHE.asEuint64(rate), TFHE.asEuint64(0));
        ebool req3 = TFHE.le(TFHE.asEuint64(rate), amount);
        ebool req4 = TFHE.gt(TFHE.asEuint64(period), TFHE.asEuint64(0));
        ebool all = TFHE.and(TFHE.and(req1, req2), TFHE.and(req3, req4));

        // end = (amount % rate == 0) ? (amount / rate) * period + start : ((amount / rate) * period) + period + start;
        end = endDate(start, amount, rate, period);
        // require(cliff <= end, "cliff > end");
        euint64 num = TFHE.select(TFHE.and(all, TFHE.le(cliff, end)), TFHE.asEuint64(0), TFHE.asEuint64(1));
        valid = TFHE.eq(num, TFHE.asEuint64(0));
    }

    /// @notice function to calculate the unlocked (claimable) balance, still locked balance, and the most recent timestamp the unlock would take place
    /// the most recent unlock time is based on the periods, so if the periods are 1, then the unlock time will be the same as the redemption time,
    /// however if the period more than 1 second, the latest unlock will be a discrete time stamp
    /// @param start is the start time of the plan
    /// @param cliffDate is the timestamp of the cliff of the plan
    /// @param amount is the total unclaimed amount tokens still in the vesting plan
    /// @param rate is the amount of tokens that unlock per period
    /// @param period is the seconds in each period, a 1 is a period of 1 second whereby tokens unlock every second
    /// @param currentTime is the current time being evaluated, typically the block.timestamp, but used just to check the plan is past the start or cliff
    /// @param redemptionTime is the time requested for the plan to be redeemed, this can be the same as the current time or prior to it for partial redemptions
    function balanceAtTime(
        euint64 start,
        euint64 cliffDate,
        euint64 amount,
        uint256 rate,
        uint256 period,
        uint256 currentTime,
        uint256 redemptionTime
    ) internal pure returns (euint64 unlockedBalance, euint64 lockedBalance, euint64 unlockTime) {

        ebool time = TFHE.gt(start, TFHE.asEuint64(currentTime));
        ebool cliff = TFHE.gt(cliffDate, TFHE.asEuint64(currentTime));
        ebool redemption = TFHE.le(TFHE.asEuint64(redemptionTime), start);
        ebool all = TFHE.or(TFHE.or(time, cliff), redemption);

        euint64 periodsElapsed = TFHE.div(TFHE.sub(TFHE.asEuint64(redemptionTime), start), uint64(period));
        euint64 calculatedBalance = TFHE.mul(periodsElapsed, TFHE.asEuint64(rate));

        unlockedBalance = TFHE.select(all, TFHE.asEuint64(0), TFHE.min(calculatedBalance, amount));
        lockedBalance = TFHE.select(all, amount, TFHE.sub(amount, unlockedBalance));
        unlockTime = TFHE.select(all, start, TFHE.add(start, TFHE.mul(TFHE.asEuint64(period), periodsElapsed)));
    }

    // function calculateCombinedRate(
    //     euint64 combinedAmount,
    //     uint256 combinedRates,
    //     euint64 start,
    //     uint256 period,
    //     uint256 targetEnd
    // ) internal pure returns (uint256 rate, euint64 end) {
    //     euint64 numerator = TFHE.mul(combinedAmount, TFHE.asEuint64(period));
    //     uint256 denominator = (combinedAmount % combinedRates == 0) ? targetEnd - start : targetEnd - start - period;
    //     rate = numerator / denominator;
    //     end = endDate(start, combinedAmount, rate, period);
    // }

    // function calculateSegmentRates(
    //     uint256 originalRate,
    //     euint64 originalAmount,
    //     euint64 planAmount,
    //     euint64 segmentAmount,
    //     euint64 start,
    //     uint256 end,
    //     uint256 period,
    //     euint64 cliff
    // ) internal pure returns (uint256 planRate, uint256 segmentRate, uint256 planEnd, uint256 segmentEnd) {
    //     planRate = (originalRate * ((planAmount * (10 ** 18)) / originalAmount)) / (10 ** 18);
    //     segmentRate = (segmentAmount % (originalRate - planRate) == 0)
    //         ? (segmentAmount * period) / (end - start)
    //         : (segmentAmount * period) / (end - start - period);
    //     ebool validPlanEnd;
    //     ebool validSegmentEnd;
    //     (planEnd, validPlanEnd) = validateEnd(start, cliff, planAmount, planRate, period);
    //     (segmentEnd, validSegmentEnd) = validateEnd(start, cliff, segmentAmount, segmentRate, period);
    //     require(validPlanEnd && validSegmentEnd, "invalid end date");
    // }
}
