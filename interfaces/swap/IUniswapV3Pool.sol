// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.6.12;
pragma experimental ABIEncoderV2;
//pragma abicoder v2;

interface IUniswapV3Pool {
    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}
