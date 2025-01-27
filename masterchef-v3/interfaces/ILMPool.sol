// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface ILMPool {
    function updatePosition(int24 tickLower, int24 tickUpper, int128 liquidityDelta) external;

    function getRewardsGrowthInside(
        int24 tickLower,
        int24 tickUpper
    ) external view returns (uint256[10] memory rewardsGrowthInsideX128);

    function accumulateRewards(uint32 currTimestamp) external;
}
