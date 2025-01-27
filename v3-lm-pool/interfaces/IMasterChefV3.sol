// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

interface IMasterChefV3 {
    function nonfungiblePositionManager() external view returns (address);

    function getLatestPeriodInfo(address _v3Pool) external view returns (uint256[10] memory rewardsPerSecond, uint256 endTime);
}
