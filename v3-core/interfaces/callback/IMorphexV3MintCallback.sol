// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

/// @title Callback for IMorphexV3PoolActions#mint
/// @notice Any contract that calls IMorphexV3PoolActions#mint must implement this interface
interface IMorphexV3MintCallback {
    /// @notice Called to `msg.sender` after minting liquidity to a position from IMorphexV3Pool#mint.
    /// @dev In the implementation you must pay the pool tokens owed for the minted liquidity.
    /// The caller of this method must be checked to be a MorphexV3Pool deployed by the canonical MorphexV3Factory.
    /// @param amount0Owed The amount of token0 due to the pool for the minted liquidity
    /// @param amount1Owed The amount of token1 due to the pool for the minted liquidity
    /// @param data Any data passed through by the caller via the IMorphexV3PoolActions#mint call
    function morphexV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external;
}
