// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import '../v3-core/libraries/LowGasSafeMath.sol';
import '../v3-core/libraries/SafeCast.sol';
import '../v3-core/libraries/FullMath.sol';
import '../v3-core/libraries/FixedPoint128.sol';
import '../v3-core/interfaces/IMorphexV3Pool.sol';

import './libraries/LmTick.sol';

import './interfaces/IMorphexV3LmPool.sol';
import './interfaces/IMasterChefV3.sol';
import './interfaces/IMorphexV3LmPoolDeveloper.sol';

contract MorphexV3LmPool is IMorphexV3LmPool {
  using LowGasSafeMath for uint256;
  using LowGasSafeMath for int256;
  using SafeCast for uint256;
  using SafeCast for int256;
  using LmTick for mapping(int24 => LmTick.Info);

  uint256 public constant REWARD_PRECISION = 1e12;

  IMorphexV3Pool public immutable pool;
  IMasterChefV3 public immutable masterChef;

  uint256[10] public rewardsGrowthGlobalX128;

  mapping(int24 => LmTick.Info) public lmTicks;

  uint128 public lmLiquidity;

  uint32 public lastRewardTimestamp;

  modifier onlyPool() {
    require(msg.sender == address(pool), "Not pool");
    _;
  }

  modifier onlyMasterChef() {
    require(msg.sender == address(masterChef), "Not MC");
    _;
  }

  modifier onlyPoolOrMasterChef() {
    require(msg.sender == address(pool) || msg.sender == address(masterChef), "Not pool or MC");
    _;
  }

  constructor() {
    (address poolAddress, address masterChefAddress) = IMorphexV3LmPoolDeveloper(msg.sender).parameters();
    pool = IMorphexV3Pool(poolAddress);
    masterChef = IMasterChefV3(masterChefAddress);
    lastRewardTimestamp = uint32(block.timestamp);
  }

  function accumulateRewards(uint32 currTimestamp) external override onlyPoolOrMasterChef {
    if (currTimestamp <= lastRewardTimestamp) {
      return;
    }
    if (lmLiquidity != 0) {
      (uint256[10] memory rewardsPerSecond, uint256 endTime) = masterChef.getLatestPeriodInfo(address(pool));
      uint32 endTimestamp = uint32(endTime);
      uint32 duration;
      if (endTimestamp > currTimestamp) {
        duration = currTimestamp - lastRewardTimestamp;
      } else if (endTimestamp > lastRewardTimestamp) {
        duration = endTimestamp - lastRewardTimestamp;
      }
      if (duration != 0) {
        for (uint256 i; i < 10; i++) {
          rewardsGrowthGlobalX128[i] += FullMath.mulDiv(duration, FullMath.mulDiv(rewardsPerSecond[i], FixedPoint128.Q128, REWARD_PRECISION), lmLiquidity);
        }
      }
    }
    lastRewardTimestamp = currTimestamp;
  }

  function crossLmTick(int24 tick, bool zeroForOne) external override onlyPool {
    if (lmTicks[tick].liquidityGross == 0) {
      return;
    }

    int128 lmLiquidityNet = lmTicks.cross(tick, rewardsGrowthGlobalX128);

    if (zeroForOne) {
      lmLiquidityNet = -lmLiquidityNet;
    }

    lmLiquidity = LiquidityMath.addDelta(lmLiquidity, lmLiquidityNet);
  }

  function updatePosition(int24 tickLower, int24 tickUpper, int128 liquidityDelta) external onlyMasterChef {
    (, int24 tick, , , , ,) = pool.slot0();
    uint128 maxLiquidityPerTick = pool.maxLiquidityPerTick();
    uint256[10] memory _rewardsGrowthGlobalX128 = rewardsGrowthGlobalX128;

    bool flippedLower;
    bool flippedUpper;
    if (liquidityDelta != 0) {
      flippedLower = lmTicks.update(
        tickLower,
        tick,
        liquidityDelta,
        _rewardsGrowthGlobalX128,
        false,
        maxLiquidityPerTick
      );
      flippedUpper = lmTicks.update(
        tickUpper,
        tick,
        liquidityDelta,
        _rewardsGrowthGlobalX128,
        true,
        maxLiquidityPerTick
      );
    }

    if (tick >= tickLower && tick < tickUpper) {
      lmLiquidity = LiquidityMath.addDelta(lmLiquidity, liquidityDelta);
    }

    if (liquidityDelta < 0) {
      if (flippedLower) {
        lmTicks.clear(tickLower);
      }
      if (flippedUpper) {
        lmTicks.clear(tickUpper);
      }
    }
  }

  function getRewardsGrowthInside(int24 tickLower, int24 tickUpper) external view returns (uint256[10] memory rewardsGrowthInsideX128) {
    (, int24 tick, , , , ,) = pool.slot0();
    return lmTicks.getRewardsGrowthInside(tickLower, tickUpper, tick, rewardsGrowthGlobalX128);
  }
}
