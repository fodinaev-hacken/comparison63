// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IReceiver {
    function upkeep(uint256 amount, uint256 duration, bool withUpdate) external;
}
