// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface IPriceOracle {
    function getPrice(address token) external view returns (uint256);

    function setPrice(address token, uint256 price) external;
}