// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @notice Surface used by `UpDownAutoCycler` and `ChainlinkResolver`.
interface IUpDownSettlement {
    struct Market {
        bytes32 pairId;
        uint128 totalUp;
        uint128 totalDown;
        uint64 startTime;
        uint64 endTime;
        uint32 duration;
        uint8 winner;
        bool resolved;
        bool settled;
        int128 strikePrice;
        int128 settlementPrice;
    }

    function createMarket(bytes32 pairId, uint256 duration, int256 strikePrice) external returns (uint256 marketId);

    /// @notice Creates a market with explicit window (used by `UpDownAutoCycler` for clock-aligned slots).
    function createMarket(bytes32 pairId, uint256 duration, int256 strikePrice, uint64 startTime, uint64 endTime)
        external
        returns (uint256 marketId);

    function resolve(uint256 marketId, int256 settlementPrice, uint8 winner) external;

    function markets(uint256 marketId) external view returns (
        bytes32 pairId,
        uint128 totalUp,
        uint128 totalDown,
        uint64 startTime,
        uint64 endTime,
        uint32 duration,
        uint8 winner,
        bool resolved,
        bool settled,
        int128 strikePrice,
        int128 settlementPrice
    );

    function getMarket(uint256 marketId) external view returns (Market memory);
}
