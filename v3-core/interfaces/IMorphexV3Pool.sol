// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import './pool/IMorphexV3PoolImmutables.sol';
import './pool/IMorphexV3PoolState.sol';
import './pool/IMorphexV3PoolDerivedState.sol';
import './pool/IMorphexV3PoolActions.sol';
import './pool/IMorphexV3PoolOwnerActions.sol';
import './pool/IMorphexV3PoolEvents.sol';

/// @title The interface for a MorphexSwap V3 Pool
/// @notice A MorphexSwap pool facilitates swapping and automated market making between any two assets that strictly conform
/// to the ERC20 specification
/// @dev The pool interface is broken up into many smaller pieces
interface IMorphexV3Pool is
    IMorphexV3PoolImmutables,
    IMorphexV3PoolState,
    IMorphexV3PoolDerivedState,
    IMorphexV3PoolActions,
    IMorphexV3PoolOwnerActions,
    IMorphexV3PoolEvents
{

}
