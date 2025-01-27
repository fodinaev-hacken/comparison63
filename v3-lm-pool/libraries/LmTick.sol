// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import '../../v3-core/libraries/LowGasSafeMath.sol';
import '../../v3-core/libraries/SafeCast.sol';

import '../../v3-core/libraries/TickMath.sol';
import '../../v3-core/libraries/LiquidityMath.sol';

/// @title LmTick
/// @notice Contains functions for managing tick processes and relevant calculations
library LmTick {
    using LowGasSafeMath for int256;
    using SafeCast for int256;

    // info stored for each initialized individual tick
    struct Info {
        // the total position liquidity that references this tick
        uint128 liquidityGross;
        // amount of net liquidity added (subtracted) when tick is crossed from left to right (right to left),
        int128 liquidityNet;
        // reward growth per unit of liquidity on the _other_ side of this tick (relative to the current tick)
        // only has relative meaning, not absolute — the value depends on when the tick is initialized
        uint256[10] rewardsGrowthOutsideX128;
    }

    /// @notice Retrieves reward growth data
    /// @param self The mapping containing all tick information for initialized ticks
    /// @param tickLower The lower tick boundary of the position
    /// @param tickUpper The upper tick boundary of the position
    /// @param tickCurrent The current tick
    /// @param rewardsGrowthGlobalX128 The all-time global rewards growth, per unit of liquidity
    /// @return rewardsGrowthInsideX128 The all-time rewards growth, per unit of liquidity, inside the position's tick boundaries
    function getRewardsGrowthInside(
        mapping(int24 => LmTick.Info) storage self,
        int24 tickLower,
        int24 tickUpper,
        int24 tickCurrent,
        uint256[10] memory rewardsGrowthGlobalX128
    ) internal view returns (uint256[10] memory rewardsGrowthInsideX128) {
        Info storage lower = self[tickLower];
        Info storage upper = self[tickUpper];
        for (uint256 i; i < 10; i++) {

            // calculate reward growth below
            uint256 rewardGrowthBelowX128;
            if (tickCurrent >= tickLower) {
                rewardGrowthBelowX128 = lower.rewardsGrowthOutsideX128[i];
            } else {
                rewardGrowthBelowX128 = rewardsGrowthGlobalX128[i] - lower.rewardsGrowthOutsideX128[i];
            }

            // calculate reward growth above
            uint256 rewardGrowthAboveX128;
            if (tickCurrent < tickUpper) {
                rewardGrowthAboveX128 = upper.rewardsGrowthOutsideX128[i];
            } else {
                rewardGrowthAboveX128 = rewardsGrowthGlobalX128[i] - upper.rewardsGrowthOutsideX128[i];
            }
            rewardsGrowthInsideX128[i] = rewardsGrowthGlobalX128[i] - rewardGrowthBelowX128 - rewardGrowthAboveX128;
        }

    }

    /// @notice Updates a tick and returns true if the tick was flipped from initialized to uninitialized, or vice versa
    /// @param self The mapping containing all tick information for initialized ticks
    /// @param tick The tick that will be updated
    /// @param tickCurrent The current tick
    /// @param liquidityDelta A new amount of liquidity to be added (subtracted) when tick is crossed from left to right (right to left)
    /// @param rewardsGrowthGlobalX128 The all-time global rewards growth, per unit of liquidity
    /// @param upper true for updating a position's upper tick, or false for updating a position's lower tick
    /// @param maxLiquidity The maximum liquidity allocation for a single tick
    /// @return flipped Whether the tick was flipped from initialized to uninitialized, or vice versa
    function update(
        mapping(int24 => LmTick.Info) storage self,
        int24 tick,
        int24 tickCurrent,
        int128 liquidityDelta,
        uint256[10] memory rewardsGrowthGlobalX128,
        bool upper,
        uint128 maxLiquidity
    ) internal returns (bool flipped) {
        LmTick.Info storage info = self[tick];

        uint128 liquidityGrossBefore = info.liquidityGross;
        uint128 liquidityGrossAfter = LiquidityMath.addDelta(liquidityGrossBefore, liquidityDelta);

        require(liquidityGrossAfter <= maxLiquidity, 'LO');

        flipped = (liquidityGrossAfter == 0) != (liquidityGrossBefore == 0);

        if (liquidityGrossBefore == 0) {
            // by convention, we assume that all growth before a tick was initialized happened _below_ the tick
            if (tick <= tickCurrent) {
                info.rewardsGrowthOutsideX128 = rewardsGrowthGlobalX128;
            }
        }

        info.liquidityGross = liquidityGrossAfter;

        // when the lower (upper) tick is crossed left to right (right to left), liquidity must be added (removed)
        info.liquidityNet = upper
            ? int256(info.liquidityNet).sub(liquidityDelta).toInt128()
            : int256(info.liquidityNet).add(liquidityDelta).toInt128();
    }

    /// @notice Clears tick data
    /// @param self The mapping containing all initialized tick information for initialized ticks
    /// @param tick The tick that will be cleared
    function clear(mapping(int24 => LmTick.Info) storage self, int24 tick) internal {
        delete self[tick];
    }

    /// @notice Transitions to next tick as needed by price movement
    /// @param self The mapping containing all tick information for initialized ticks
    /// @param tick The destination tick of the transition
    /// @param rewardsGrowthGlobalX128 The all-time global rewards growth, per unit of liquidity, in token0
    /// @return liquidityNet The amount of liquidity added (subtracted) when tick is crossed from left to right (right to left)
    function cross(
        mapping(int24 => LmTick.Info) storage self,
        int24 tick,
        uint256[10] memory rewardsGrowthGlobalX128
    ) internal returns (int128 liquidityNet) {
        LmTick.Info storage info = self[tick];
        for (uint256 i; i < 10; i++) {
            info.rewardsGrowthOutsideX128[i] = rewardsGrowthGlobalX128[i] - info.rewardsGrowthOutsideX128[i];
        }
        liquidityNet = info.liquidityNet;
    }
}
