// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title OracleLib for PriceFeed
 * @author Dhanesh Gujrathi
 * @notice This library is used to check the Chainlink Oracle for stale data.
 * If a priceFeed is stale, the function will revert & render the DSCEngine unusable (By design)
 * It means, if the Chainlink network explodes & you have a lot of money locked, it's bad !
 */

library OracleLib {
    error OracleLib__StalePrice();

    uint256 private constant TIMEOUT = 3 hours;

    function stalePriceCheckWithLatestRoundData(AggregatorV3Interface priceFeed)
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 roundedAnswer) =
            priceFeed.latestRoundData();

        uint256 secondsSinceUpdate = block.timestamp - updatedAt;

        if (secondsSinceUpdate > TIMEOUT) revert OracleLib__StalePrice();

        return (roundId, answer, startedAt, updatedAt, roundedAnswer);
    }
}
