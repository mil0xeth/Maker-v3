// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface IOSMedianizer {
    function peep() external view returns (uint256 price, bool osm);
    function peek() external view returns (uint256 price, bool osm);
    function foresight() external view returns (uint256 price, bool osm);
    function read() external view returns (uint256 price, bool osm);
}
