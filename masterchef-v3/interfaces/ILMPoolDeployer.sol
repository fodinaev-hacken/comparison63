// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "./IMorphexV3Pool.sol";
import "./ILMPool.sol";

interface ILMPoolDeployer {
    function deploy(IMorphexV3Pool pool) external returns (ILMPool lmPool);
}
