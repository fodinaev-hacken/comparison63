// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// CONTRACTS
import "./libs/NZGuard.sol";
import "./libs/SafeOPS.sol";
import "./MorphexQuoter.sol";

/// INTERFACES
import "./interfaces/ISwapRouter.sol";
import "../v3-core/interfaces/IMorphexV3Pool.sol";
import "../v3-core/interfaces/IMorphexV3Factory.sol";
import "./interfaces/ITickLens.sol";
/// LIBRARIES
import "../v3-core/libraries/TickMath.sol";
import "./libraries/LiquidityAmounts.sol";
import "../v3-core/libraries/FixedPoint96.sol";
import "../v3-core/libraries/FixedPoint128.sol";
import "./libraries/PositionValue.sol";

/**
 * @title PositionLens contract
 * @author https://lumia.org/
 * @notice PositionLens contract for MorphexV3-like protocols
 */
contract MorphexLens is NZGuard, MorphexQuoter {
    using PositionValue for INonfungiblePositionManager;

    struct PoolKey {
        address token0;
        address token1;
        uint24 fee;
    }

    struct FeeParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 positionFeeGrowthInside0LastX128;
        uint256 positionFeeGrowthInside1LastX128;
        uint256 tokensOwed0;
        uint256 tokensOwed1;
    }

    struct UniV3Pos {
        uint96 nonce;
        address operator;
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    // bytes32 public immutable POOL_INIT_CODE_HASH;
    address public immutable swapRouter;
    address public immutable swapFactory;
    // address public immutable priceOracle;
    INonfungiblePositionManager public immutable nfpm;
    address public immutable tickLens;
    error INVALID_RECIPIENT();
    error INVALID_POSITION_OWNER();
    error POSITION_NOT_FOUND();
    error DEADLINE_PASSED();

    /**
     * @notice UniswapV3Controller constructor
     * @param _swapRouter - address of the Morphex SwapRouter
     * @param _swapFactory - address of the MorphexV3 factory
     * @param _nfpm - address of the MorphexV3 NonfungiblePositionManager
     * @param _WETH9 - address of the WETH9
     * @param _tickLens - address of the MorphexV3 TickLens
     */
    constructor(
        address _deployer,
        address _swapRouter,
        address _swapFactory,
        address _nfpm,
        address _WETH9,
        address _tickLens
    )
        MorphexQuoter(_deployer, _swapFactory, _WETH9)
        nonZeroAddress(_swapRouter)
        nonZeroAddress(_swapFactory)
        nonZeroAddress(_nfpm)
    {
        swapRouter = _swapRouter;
        swapFactory = _swapFactory;
        nfpm = INonfungiblePositionManager(_nfpm);
        tickLens = _tickLens;
    }

    /**
     * @notice Returns liquidity amount for specified amounts of tokens
     * @param token0 - token0 address
     * @param token1 - token1 address
     * @param fee - pool fee
     * @param tickLower - lower tick of position
     * @param tickUpper - upper tick of position
     * @param amount0Desired - amount of token0 desired
     * @param amount1Desired - amount of token1 desired
     */
    function getLiquidityForAmounts(
        address token0,
        address token1,
        uint24 fee,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) external view returns (uint128 liquidity) {
        // TODO: add logic for new pool
        // Ensure the token addresses are ordered correctly for Morphex V3
        (address tokenA, address tokenB) = token0 < token1
            ? (token0, token1)
            : (token1, token0);
        (uint256 amountA, uint256 amountB) = token0 < token1
            ? (amount0Desired, amount1Desired)
            : (amount1Desired, amount0Desired);

        // Calculate the pool address
        IMorphexV3Pool pool = IMorphexV3Pool(
            getPoolAddr(
                swapFactory,
                PoolKey({token0: tokenA, token1: tokenB, fee: fee})
            )
        );

        // Fetch the current price of the pool
        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();

        // Calculate the square root prices for the specified tick range
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);

        // Compute the liquidity amount
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtRatioAX96,
            sqrtRatioBX96,
            amountA,
            amountB
        );
    }

    function _getPositionData(
        uint256 id
    ) internal view returns (UniV3Pos memory posInfo) {
        (bool success, bytes memory result) = address(nfpm).staticcall(
            abi.encodeCall(nfpm.positions, (id))
        );

        if (!success) revert POSITION_NOT_FOUND();

        posInfo = abi.decode(result, (UniV3Pos));
    }

    function _getAmountsForLiquidity(
        address _pool,
        uint128 _liquidity,
        int24 _tickLower,
        int24 _tickUpper
    ) internal view returns (uint256 amount0, uint256 amount1) {
        // uint160 sqrtPriceX96 = getTWAPsqrt(_TWAP_PERIOD, _pool);
        (uint160 sqrtPriceX96, , , , , , ) = IMorphexV3Pool(_pool).slot0();

        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(_tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(_tickUpper);

        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            sqrtRatioAX96,
            sqrtRatioBX96,
            _liquidity
        );
    }

    /**
     * @dev Converts a tick value to a price.
     * @param _tick The tick value to convert.
     * @return price The corresponding price.
     */
    function tickToPrice(int24 _tick) public pure returns (uint256 price) {
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(_tick);
        price =
            (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >>
            (2 * FixedPoint96.RESOLUTION);
    }

    function getPoolAddr(
        address _factory,
        PoolKey memory key
    ) public view returns (address pool) {
        if (key.token0 < key.token1) {
            pool = IMorphexV3Factory(_factory).getPool(
                key.token0,
                key.token1,
                key.fee
            );
        } else {
            pool = IMorphexV3Factory(_factory).getPool(
                key.token1,
                key.token0,
                key.fee
            );
        }
    }

    function _getPendingFeesFromPos(
        address MorphexV3Factory,
        UniV3Pos memory feeParams
    ) private view returns (uint256 amount0, uint256 amount1) {
        (
            uint256 poolFeeGrowthInside0LastX128,
            uint256 poolFeeGrowthInside1LastX128
        ) = _getFeeGrowthInside(
                IMorphexV3Pool(
                    getPoolAddr(
                        MorphexV3Factory,
                        PoolKey({
                            token0: feeParams.token0,
                            token1: feeParams.token1,
                            fee: feeParams.fee
                        })
                    )
                ),
                feeParams.tickLower,
                feeParams.tickUpper
            );

        amount0 =
            ((poolFeeGrowthInside0LastX128 -
                feeParams.feeGrowthInside0LastX128) * feeParams.liquidity) /
            FixedPoint128.Q128 +
            feeParams.tokensOwed0;

        amount1 =
            ((poolFeeGrowthInside1LastX128 -
                feeParams.feeGrowthInside1LastX128) * feeParams.liquidity) /
            FixedPoint128.Q128 +
            feeParams.tokensOwed1;
    }

    function _getFeeGrowthInside(
        IMorphexV3Pool pool,
        int24 tickLower,
        int24 tickUpper
    )
        private
        view
        returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128)
    {
        (, int24 tickCurrent, , , , , ) = pool.slot0();
        (
            ,
            ,
            uint256 lowerFeeGrowthOutside0X128,
            uint256 lowerFeeGrowthOutside1X128,
            ,
            ,
            ,

        ) = pool.ticks(tickLower);
        (
            ,
            ,
            uint256 upperFeeGrowthOutside0X128,
            uint256 upperFeeGrowthOutside1X128,
            ,
            ,
            ,

        ) = pool.ticks(tickUpper);

        if (tickCurrent < tickLower) {
            feeGrowthInside0X128 =
                lowerFeeGrowthOutside0X128 -
                upperFeeGrowthOutside0X128;
            feeGrowthInside1X128 =
                lowerFeeGrowthOutside1X128 -
                upperFeeGrowthOutside1X128;
        } else if (tickCurrent < tickUpper) {
            (uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128) = (
                pool.feeGrowthGlobal0X128(),
                pool.feeGrowthGlobal1X128()
            );

            feeGrowthInside0X128 =
                feeGrowthGlobal0X128 -
                lowerFeeGrowthOutside0X128 -
                upperFeeGrowthOutside0X128;
            feeGrowthInside1X128 =
                feeGrowthGlobal1X128 -
                lowerFeeGrowthOutside1X128 -
                upperFeeGrowthOutside1X128;
        } else {
            feeGrowthInside0X128 =
                upperFeeGrowthOutside0X128 -
                lowerFeeGrowthOutside0X128;
            feeGrowthInside1X128 =
                upperFeeGrowthOutside1X128 -
                lowerFeeGrowthOutside1X128;
        }
    }

    function getAmountsAndAddressesFromPosition(
        uint128 positionId
    )
        external
        view
        returns (
            uint24 poolFee,
            address pool,
            address token0,
            address token1,
            uint256 amount0,
            uint256 amount1,
            uint256 feeAmount0,
            uint256 feeAmount1,
            int24 tickLower,
            int24 tickUpper
        )
    {
        UniV3Pos memory posInfo = _getPositionData(positionId);

        pool = getPoolAddr(
            swapFactory,
            PoolKey({
                token0: posInfo.token0,
                token1: posInfo.token1,
                fee: posInfo.fee
            })
        );
        poolFee = posInfo.fee;
        (token0, token1) = (posInfo.token0, posInfo.token1);
        tickLower = posInfo.tickLower;
        tickUpper = posInfo.tickUpper;

        (amount0, amount1) = _getAmountsForLiquidity(
            // TWAP_PERIOD(),
            pool,
            posInfo.liquidity,
            posInfo.tickLower,
            posInfo.tickUpper
        );

        (feeAmount0, feeAmount1) = _getPendingFeesFromPos(swapFactory, posInfo);
    }
}
