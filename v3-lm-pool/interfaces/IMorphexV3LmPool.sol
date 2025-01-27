// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

interface IMorphexV3LmPool {
  function accumulateRewards(uint32 currTimestamp) external;

  function crossLmTick(int24 tick, bool zeroForOne) external;

  function getRewardsGrowthInside(
    int24 tickLower,
    int24 tickUpper
  ) external view returns (uint256[10] memory rewardsGrowthInsideX128);

  function lmLiquidity() external view returns (uint128);

  function lastRewardTimestamp() external view returns (uint32);

  function updatePosition(int24 tickLower, int24 tickUpper, int128 liquidityDelta) external;
}
