// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;

import "../v3-core/libraries/SafeCast.sol";
import "../v3-core/libraries/TickMath.sol";
import "../v3-core/libraries/TickBitmap.sol";
import "../v3-core/interfaces/IMorphexV3Pool.sol";
import "../v3-core/interfaces/callback/IMorphexV3SwapCallback.sol";
import "../v3-core/interfaces/IMorphexV3Factory.sol";
import "../v3-core/libraries/FullMath.sol";
import "./interfaces/IQuoterV2.sol";
import "./base/PeripheryImmutableState.sol";
import "./libraries/Path.sol";
import "./libraries/PoolAddress.sol";
import "./libraries/CallbackValidation.sol";
import "./libraries/PoolTicksCounter.sol";

/// @title Provides quotes for swaps
/// @notice Allows getting the expected amount out or amount in for a given swap without executing the swap
/// @dev These functions are not gas efficient and should _not_ be called on chain. Instead, optimistically execute
/// the swap and check the amounts in the callback.
contract MorphexQuoter is
    IQuoterV2,
    IMorphexV3SwapCallback,
    PeripheryImmutableState
{
    using Path for bytes;
    using SafeCast for uint256;
    using PoolTicksCounter for IMorphexV3Pool;
    using FullMath for uint256;
    /// @dev Transient storage variable used to check a safety condition in exact output swaps.
    uint256 private amountOutCached;

    constructor(
        address _deployer,
        address _factory,
        address _WETH9
    ) PeripheryImmutableState(_deployer, _factory, _WETH9) {}

    // function getPool(
    //     address tokenA,
    //     address tokenB,
    //     uint24 fee
    // ) private view returns (IMorphexV3Pool) {
    //     return
    //         IMorphexV3Pool(
    //             PoolAddress.computeAddress(
    //                 factory,
    //                 PoolAddress.getPoolKey(tokenA, tokenB, fee)
    //             )
    //         );
    // }


    function getPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) private view returns (IMorphexV3Pool) {
        address pool;
        if (tokenA < tokenB) {
            pool = IMorphexV3Factory(factory).getPool(
                tokenA,
                tokenB,
                fee
            );
        } else {
            pool = IMorphexV3Factory(factory).getPool(
                tokenB,
                tokenA,
                fee
            );
        }
        return IMorphexV3Pool(pool);
    }


    function verifyCallback(
        address,
        address tokenA,
        address tokenB,
        uint24 fee
    ) internal view returns (IMorphexV3Pool pool) {
        pool = getPool(tokenA, tokenB, fee);
        require(msg.sender == address(pool));
    }

    /// @inheritdoc IMorphexV3SwapCallback
    function morphexV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes memory path
    ) external view override {
        require(amount0Delta > 0 || amount1Delta > 0); // swaps entirely within 0-liquidity regions are not supported
        (address tokenIn, address tokenOut, uint24 fee) = path
            .decodeFirstPool();
        verifyCallback(factory, tokenIn, tokenOut, fee);

        (
            bool isExactInput,
            uint256 amountToPay,
            uint256 amountReceived
        ) = amount0Delta > 0
                ? (
                    tokenIn < tokenOut,
                    uint256(amount0Delta),
                    uint256(-amount1Delta)
                )
                : (
                    tokenOut < tokenIn,
                    uint256(amount1Delta),
                    uint256(-amount0Delta)
                );

        IMorphexV3Pool pool = getPool(tokenIn, tokenOut, fee);
        (uint160 sqrtPriceX96After, int24 tickAfter, , , , , ) = pool.slot0();

        if (isExactInput) {
            assembly {
                let ptr := mload(0x40)
                mstore(ptr, amountReceived)
                mstore(add(ptr, 0x20), sqrtPriceX96After)
                mstore(add(ptr, 0x40), tickAfter)
                revert(ptr, 96)
            }
        } else {
            // if the cache has been populated, ensure that the full output amount has been received
            if (amountOutCached != 0)
                require(amountReceived == amountOutCached);
            assembly {
                let ptr := mload(0x40)
                mstore(ptr, amountToPay)
                mstore(add(ptr, 0x20), sqrtPriceX96After)
                mstore(add(ptr, 0x40), tickAfter)
                revert(ptr, 96)
            }
        }
    }

    /// @dev Parses a revert reason that should contain the numeric quote
    function parseRevertReason(
        bytes memory reason
    )
        private
        pure
        returns (uint256 amount, uint160 sqrtPriceX96After, int24 tickAfter)
    {
        if (reason.length != 96) {
            if (reason.length < 68) revert("Unexpected error");
            assembly {
                reason := add(reason, 0x04)
            }
            revert(abi.decode(reason, (string)));
        }
        return abi.decode(reason, (uint256, uint160, int24));
    }

    function handleRevert(
        bytes memory reason,
        IMorphexV3Pool pool,
        uint256 gasEstimate
    )
        private
        view
        returns (
            uint256 amount,
            uint160 sqrtPriceX96After,
            uint32 initializedTicksCrossed,
            uint256
        )
    {
        int24 tickBefore;
        int24 tickAfter;
        (, tickBefore, , , , , ) = pool.slot0();
        (amount, sqrtPriceX96After, tickAfter) = parseRevertReason(reason);

        initializedTicksCrossed = pool.countInitializedTicksCrossed(
            tickBefore,
            tickAfter
        );

        return (
            amount,
            sqrtPriceX96After,
            initializedTicksCrossed,
            gasEstimate
        );
    }

    struct HandledRevert {
        uint256 amount;
        uint160 sqrtPriceX96After;
        uint32 initializedTicksCrossed;
        uint256 gasEstimate;
    }

    function handleRevertStruct(
        bytes memory reason,
        IMorphexV3Pool pool,
        uint256 gasEstimate
    ) private view returns (HandledRevert memory) {
        int24 tickBefore;
        int24 tickAfter;
        uint256 amount;
        uint160 sqrtPriceX96After;
        uint32 initializedTicksCrossed;
        (, tickBefore, , , , , ) = pool.slot0();
        (amount, sqrtPriceX96After, tickAfter) = parseRevertReason(reason);

        initializedTicksCrossed = pool.countInitializedTicksCrossed(
            tickBefore,
            tickAfter
        );

        return
            HandledRevert(
                amount,
                sqrtPriceX96After,
                initializedTicksCrossed,
                gasEstimate
            );
    }

    function quoteExactInputSingle(
        QuoteExactInputSingleParams memory params
    )
        public
        virtual
        override
        returns (
            uint256 amountOut,
            uint160 sqrtPriceX96After,
            uint32 initializedTicksCrossed,
            uint256 gasEstimate
        )
    {
        bool zeroForOne = params.tokenIn < params.tokenOut;
        IMorphexV3Pool pool = getPool(
            params.tokenIn,
            params.tokenOut,
            params.fee
        );

        uint256 gasBefore = gasleft();
        try
            pool.swap(
                address(this), // address(0) might cause issues with some tokens
                zeroForOne,
                params.amountIn.toInt256(),
                params.sqrtPriceLimitX96 == 0
                    ? (
                        zeroForOne
                            ? TickMath.MIN_SQRT_RATIO + 1
                            : TickMath.MAX_SQRT_RATIO - 1
                    )
                    : params.sqrtPriceLimitX96,
                abi.encodePacked(params.tokenIn, params.fee, params.tokenOut)
            )
        {} catch (bytes memory reason) {
            gasEstimate = gasBefore - gasleft();
            return handleRevert(reason, pool, gasEstimate);
        }
    }

    function quoteExactInputSingleStruct(
        QuoteExactInputSingleParams memory params
    )
        public
        virtual
        returns (HandledRevert memory outputParams)
    {
        bool zeroForOne = params.tokenIn < params.tokenOut;
        IMorphexV3Pool pool = getPool(
            params.tokenIn,
            params.tokenOut,
            params.fee
        );

        uint256 gasBefore = gasleft();
        try
            pool.swap(
                address(this), // address(0) might cause issues with some tokens
                zeroForOne,
                params.amountIn.toInt256(),
                params.sqrtPriceLimitX96 == 0
                    ? (
                        zeroForOne
                            ? TickMath.MIN_SQRT_RATIO + 1
                            : TickMath.MAX_SQRT_RATIO - 1
                    )
                    : params.sqrtPriceLimitX96,
                abi.encodePacked(params.tokenIn, params.fee, params.tokenOut)
            )
        {} catch (bytes memory reason) {
            outputParams.gasEstimate = gasBefore - gasleft();
            return handleRevertStruct(reason, pool, outputParams.gasEstimate);
        }
    }


    function quoteExactInput(
        bytes memory path,
        uint256 amountIn
    )
        public
        virtual
        override
        returns (
            uint256 amountOut,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksCrossedList,
            uint256 gasEstimate
        )
    {
        sqrtPriceX96AfterList = new uint160[](path.numPools());
        initializedTicksCrossedList = new uint32[](path.numPools());

        uint256 i = 0;
        while (true) {
            (address tokenIn, address tokenOut, uint24 fee) = path
                .decodeFirstPool();

            // the outputs of prior swaps become the inputs to subsequent ones
            (
                uint256 _amountOut,
                uint160 _sqrtPriceX96After,
                uint32 _initializedTicksCrossed,
                uint256 _gasEstimate
            ) = quoteExactInputSingle(
                    QuoteExactInputSingleParams({
                        tokenIn: tokenIn,
                        tokenOut: tokenOut,
                        fee: fee,
                        amountIn: amountIn,
                        sqrtPriceLimitX96: 0
                    })
                );

            sqrtPriceX96AfterList[i] = _sqrtPriceX96After;
            initializedTicksCrossedList[i] = _initializedTicksCrossed;
            amountIn = _amountOut;
            gasEstimate += _gasEstimate;
            i++;

            // decide whether to continue or terminate
            if (path.hasMultiplePools()) {
                path = path.skipToken();
            } else {
                return (
                    amountIn,
                    sqrtPriceX96AfterList,
                    initializedTicksCrossedList,
                    gasEstimate
                );
            }
        }
    }

    function quoteExactInputWithFees(
        bytes memory path,
        uint256 amountIn
    )
        public
        virtual
        returns (
            uint256 amountOut,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksCrossedList,
            uint256 gasEstimate,
            uint256[] memory fees
        )
    {
        sqrtPriceX96AfterList = new uint160[](path.numPools());
        initializedTicksCrossedList = new uint32[](path.numPools());
        fees = new uint256[](path.numPools());
        uint256 i;
        while (true) {
            (address tokenIn, address tokenOut, uint24 fee) = path
                .decodeFirstPool();

            // the outputs of prior swaps become the inputs to subsequent ones
            // (
            //     uint256 _amountOut,
            //     uint160 _sqrtPriceX96After,
            //     uint32 _initializedTicksCrossed,
            //     uint256 _gasEstimate
            // ) = quoteExactInputSingle(
            //         QuoteExactInputSingleParams({
            //             tokenIn: tokenIn,
            //             tokenOut: tokenOut,
            //             fee: fee,
            //             amountIn: amountIn,
            //             sqrtPriceLimitX96: 0
            //         })
            //     );
            HandledRevert memory outputParams = quoteExactInputSingleStruct(
                QuoteExactInputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: fee,
                    amountIn: amountIn,
                    sqrtPriceLimitX96: 0
                })
            );

            fees[i] = (amountIn * fee) / 1e6;
            sqrtPriceX96AfterList[i] = outputParams.sqrtPriceX96After;
            initializedTicksCrossedList[i] = outputParams.initializedTicksCrossed;
            amountIn = outputParams.amount;
            gasEstimate += outputParams.gasEstimate;
            i++;

            // decide whether to continue or terminate
            if (path.hasMultiplePools()) {
                path = path.skipToken();
            } else {
                return (
                    amountIn,
                    sqrtPriceX96AfterList,
                    initializedTicksCrossedList,
                    gasEstimate,
                    fees
                );
            }
        }
    }

    function quoteExactOutputSingleStruct(
        QuoteExactOutputSingleParams memory params
    ) public virtual returns (HandledRevert memory outputParams) {
        bool zeroForOne = params.tokenIn < params.tokenOut;
        IMorphexV3Pool pool = getPool(
            params.tokenIn,
            params.tokenOut,
            params.fee
        );

        // if no price limit has been specified, cache the output amount for comparison in the swap callback
        if (params.sqrtPriceLimitX96 == 0) amountOutCached = params.amount;
        uint256 gasBefore = gasleft();
        try
            pool.swap(
                address(this), // address(0) might cause issues with some tokens
                zeroForOne,
                -params.amount.toInt256(),
                params.sqrtPriceLimitX96 == 0
                    ? (
                        zeroForOne
                            ? TickMath.MIN_SQRT_RATIO + 1
                            : TickMath.MAX_SQRT_RATIO - 1
                    )
                    : params.sqrtPriceLimitX96,
                abi.encodePacked(params.tokenOut, params.fee, params.tokenIn)
            )
        {} catch (bytes memory reason) {
            outputParams.gasEstimate = gasBefore - gasleft();
            if (params.sqrtPriceLimitX96 == 0) delete amountOutCached; // clear cache
            return handleRevertStruct(reason, pool, outputParams.gasEstimate);
        }
    }

    function quoteExactOutputSingle(
        QuoteExactOutputSingleParams memory params
    )
        public
        virtual
        override
        returns (
            uint256 amountIn,
            uint160 sqrtPriceX96After,
            uint32 initializedTicksCrossed,
            uint256 gasEstimate
        )
    {
        bool zeroForOne = params.tokenIn < params.tokenOut;
        IMorphexV3Pool pool = getPool(
            params.tokenIn,
            params.tokenOut,
            params.fee
        );

        // if no price limit has been specified, cache the output amount for comparison in the swap callback
        if (params.sqrtPriceLimitX96 == 0) amountOutCached = params.amount;
        uint256 gasBefore = gasleft();
        try
            pool.swap(
                address(this), // address(0) might cause issues with some tokens
                zeroForOne,
                -params.amount.toInt256(),
                params.sqrtPriceLimitX96 == 0
                    ? (
                        zeroForOne
                            ? TickMath.MIN_SQRT_RATIO + 1
                            : TickMath.MAX_SQRT_RATIO - 1
                    )
                    : params.sqrtPriceLimitX96,
                abi.encodePacked(params.tokenOut, params.fee, params.tokenIn)
            )
        {} catch (bytes memory reason) {
            gasEstimate = gasBefore - gasleft();
            if (params.sqrtPriceLimitX96 == 0) delete amountOutCached; // clear cache
            return handleRevert(reason, pool, gasEstimate);
        }
    }

    function quoteExactOutput(
        bytes memory path,
        uint256 amountOut
    )
        public
        virtual
        override
        returns (
            uint256 amountIn,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksCrossedList,
            uint256 gasEstimate
        )
    {
        sqrtPriceX96AfterList = new uint160[](path.numPools());
        initializedTicksCrossedList = new uint32[](path.numPools());

        uint256 i = 0;
        while (true) {
            (address tokenOut, address tokenIn, uint24 fee) = path
                .decodeFirstPool();

            // the inputs of prior swaps become the outputs of subsequent ones
            (
                uint256 _amountIn,
                uint160 _sqrtPriceX96After,
                uint32 _initializedTicksCrossed,
                uint256 _gasEstimate
            ) = quoteExactOutputSingle(
                    QuoteExactOutputSingleParams({
                        tokenIn: tokenIn,
                        tokenOut: tokenOut,
                        amount: amountOut,
                        fee: fee,
                        sqrtPriceLimitX96: 0
                    })
                );

            sqrtPriceX96AfterList[i] = _sqrtPriceX96After;
            initializedTicksCrossedList[i] = _initializedTicksCrossed;
            amountOut = _amountIn;
            gasEstimate += _gasEstimate;
            i++;

            // decide whether to continue or terminate
            if (path.hasMultiplePools()) {
                path = path.skipToken();
            } else {
                return (
                    amountOut,
                    sqrtPriceX96AfterList,
                    initializedTicksCrossedList,
                    gasEstimate
                );
            }
        }
    }

    function quoteExactOutputWithFees(
        bytes memory path,
        uint256 amountOut
    )
        public
        virtual
        returns (
            uint256 amountIn,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksCrossedList,
            uint256 gasEstimate,
            uint256[] memory fees
        )
    {
        sqrtPriceX96AfterList = new uint160[](path.numPools());
        initializedTicksCrossedList = new uint32[](path.numPools());
        fees = new uint256[](path.numPools());
        uint256 i;
        while (true) {
            (address tokenOut, address tokenIn, uint24 fee) = path
                .decodeFirstPool();

            // the inputs of prior swaps become the outputs of subsequent ones
            // (
            //     uint256 _amountIn,
            //     uint160 _sqrtPriceX96After,
            //     uint32 _initializedTicksCrossed,
            //     uint256 _gasEstimate
            // ) = quoteExactOutputSingle(
            //         QuoteExactOutputSingleParams({
            //             tokenIn: tokenIn,
            //             tokenOut: tokenOut,
            //             amount: amountOut,
            //             fee: fee,
            //             sqrtPriceLimitX96: 0
            //         })
            //     );
            HandledRevert memory outputParams = quoteExactOutputSingleStruct(
                QuoteExactOutputSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    amount: amountOut,
                    fee: fee,
                    sqrtPriceLimitX96: 0
                })
            );

            sqrtPriceX96AfterList[i] = outputParams.sqrtPriceX96After;
            initializedTicksCrossedList[i] = outputParams.initializedTicksCrossed;
            amountOut = outputParams.amount;

            outputParams.amount = FullMath.mulDivRoundingUp(outputParams.amount, 1e6, 1e6 - fee);
            fees[i] = outputParams.amount - amountOut;

            gasEstimate += outputParams.gasEstimate;
            i++;

            // decide whether to continue or terminate
            if (path.hasMultiplePools()) {
                path = path.skipToken();
            } else {
                return (
                    amountOut,
                    sqrtPriceX96AfterList,
                    initializedTicksCrossedList,
                    gasEstimate,
                    fees
                );
            }
        }
    }
}
