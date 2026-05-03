// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    /// @dev PR-10 (P0-16): roundId-bound resolution requires `getRoundData` so
    ///      the resolver can verify the canonical round whose `updatedAt` is
    ///      the latest <= `market.endTime` (and the next round's `updatedAt` is
    ///      strictly after). Without this view, we can't audit the price-at-
    ///      endTime claim and must fall back to live `latestRoundData`, which
    ///      is exploitable by callers racing to call `resolve` at a favorable
    ///      moment after `endTime`.
    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function decimals() external view returns (uint8);
}
