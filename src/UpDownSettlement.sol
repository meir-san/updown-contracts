// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title UpDownSettlement
/// @notice Single contract holding all UpDown markets as storage entries (no per-market proxy).
///         Relayer aggregates matched volume; resolver sets outcomes after expiry.
contract UpDownSettlement is Ownable {
    using SafeERC20 for IERC20;

    // ── Errors ──────────────────────────────────────────────────────────
    error OnlyAutocycler();
    error OnlyRelayer();
    error OnlyResolver();
    error InvalidOption();
    error InvalidWinner();
    error MarketNotOpen();
    error NotResolved();
    error AlreadySettled();
    error AlreadyResolved();
    error NotDMM();
    error ZeroAddress();
    error Paused();

    // ── Types ───────────────────────────────────────────────────────────
    /// @dev Packed for cheaper `createMarket` (fewer cold storage slots on first write).
    struct Market {
        bytes32 pairId;
        uint128 totalUp;
        uint128 totalDown;
        uint64 startTime;
        uint64 endTime;
        uint32 duration; // 300, 900, 3600
        uint8 winner; // 0 = unresolved, 1 = UP, 2 = DOWN
        bool resolved;
        bool settled;
        int128 strikePrice;
        int128 settlementPrice;
    }

    // ── Events ──────────────────────────────────────────────────────────
    event MarketCreated(
        uint256 indexed marketId,
        bytes32 indexed pairId,
        uint256 duration,
        int256 strikePrice,
        uint256 startTime,
        uint256 endTime
    );
    event PositionEntered(uint256 indexed marketId, uint8 option, uint256 amount);
    event MarketResolved(uint256 indexed marketId, uint8 winner, int256 settlementPrice);
    event SettlementWithdrawn(uint256 indexed marketId, uint256 netToRelayer, uint256 fees);
    event DMMAdded(address indexed dmm);
    event DMMRemoved(address indexed dmm);
    event RebateAccumulated(address indexed dmm, uint256 amount);
    event RebateClaimed(address indexed claimant, uint256 amount);
    event PausedSet(bool paused);
    event FeesUpdated(uint256 platformFeeBps, uint256 makerFeeBps);
    event DmmRebateBpsUpdated(uint256 bps);

    // ── Immutables / roles ─────────────────────────────────────────────
    IERC20 public immutable usdt;

    address public resolver;
    address public autocycler;
    address public relayer;

    uint256 public nextMarketId;
    mapping(uint256 => Market) public markets;

    uint256 public platformFeeBps;
    uint256 public makerFeeBps;

    mapping(address => bool) public isDMM;
    uint256 public dmmRebateBps;
    mapping(address => uint256) public dmmRebateAccumulated;
    uint256 public dmmCount;

    uint256 public totalAccumulatedFees;
    bool public paused;

    // ── Modifiers ───────────────────────────────────────────────────────
    modifier onlyAutocycler() {
        if (msg.sender != autocycler) revert OnlyAutocycler();
        _;
    }

    modifier onlyRelayer() {
        if (msg.sender != relayer) revert OnlyRelayer();
        _;
    }

    modifier onlyResolver() {
        if (msg.sender != resolver) revert OnlyResolver();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    // ── Constructor ─────────────────────────────────────────────────────
    constructor(IERC20 _usdt, address initialOwner, uint256 _platformFeeBps, uint256 _makerFeeBps)
        Ownable(initialOwner)
    {
        if (address(_usdt) == address(0)) revert ZeroAddress();
        usdt = _usdt;
        platformFeeBps = _platformFeeBps;
        makerFeeBps = _makerFeeBps;
    }

    // ── Core ────────────────────────────────────────────────────────────

    function createMarket(bytes32 pairId, uint256 duration, int256 strikePrice)
        external
        onlyAutocycler
        whenNotPaused
        returns (uint256 marketId)
    {
        marketId = ++nextMarketId;
        uint64 start = uint64(block.timestamp);
        uint64 end = start + uint64(duration);
        markets[marketId] = Market({
            pairId: pairId,
            totalUp: 0,
            totalDown: 0,
            startTime: start,
            endTime: end,
            duration: uint32(duration),
            winner: 0,
            resolved: false,
            settled: false,
            strikePrice: int128(strikePrice),
            settlementPrice: 0
        });
        emit MarketCreated(marketId, pairId, duration, strikePrice, start, end);
    }

    function enterPosition(uint256 marketId, uint8 option, uint256 amount)
        external
        onlyRelayer
        whenNotPaused
    {
        if (option != 1 && option != 2) revert InvalidOption();
        Market storage m = markets[marketId];
        if (m.startTime == 0) revert MarketNotOpen();
        if (block.timestamp >= uint256(m.endTime)) revert MarketNotOpen();

        usdt.safeTransferFrom(msg.sender, address(this), amount);
        if (option == 1) {
            m.totalUp += uint128(amount);
        } else {
            m.totalDown += uint128(amount);
        }
        emit PositionEntered(marketId, option, amount);
    }

    function resolve(uint256 marketId, int256 settlementPrice, uint8 winner) external onlyResolver whenNotPaused {
        Market storage m = markets[marketId];
        if (m.startTime == 0) revert MarketNotOpen();
        if (m.resolved) revert AlreadyResolved();
        if (block.timestamp < uint256(m.endTime)) revert MarketNotOpen();
        if (winner != 1 && winner != 2) revert InvalidWinner();

        m.settlementPrice = int128(settlementPrice);
        m.winner = winner;
        m.resolved = true;
        emit MarketResolved(marketId, winner, int256(settlementPrice));
    }

    function withdrawSettlement(uint256 marketId) external onlyRelayer whenNotPaused {
        Market storage m = markets[marketId];
        if (!m.resolved) revert NotResolved();
        if (m.settled) revert AlreadySettled();

        uint256 totalPool = uint256(m.totalUp) + uint256(m.totalDown);
        uint256 feeBps = platformFeeBps + makerFeeBps;
        uint256 fees = (totalPool * feeBps) / 10_000;
        uint256 net = totalPool - fees;

        m.settled = true;
        totalAccumulatedFees += fees;

        if (net > 0) {
            usdt.safeTransfer(relayer, net);
        }
        emit SettlementWithdrawn(marketId, net, fees);
    }

    // ── DMM ─────────────────────────────────────────────────────────────

    function addDMM(address dmm) external onlyOwner {
        if (dmm == address(0)) revert ZeroAddress();
        if (!isDMM[dmm]) {
            isDMM[dmm] = true;
            unchecked {
                ++dmmCount;
            }
        }
        emit DMMAdded(dmm);
    }

    function removeDMM(address dmm) external onlyOwner {
        if (isDMM[dmm]) {
            isDMM[dmm] = false;
            unchecked {
                --dmmCount;
            }
        }
        emit DMMRemoved(dmm);
    }

    function accumulateRebate(address dmm, uint256 amount) external onlyRelayer whenNotPaused {
        if (!isDMM[dmm]) revert NotDMM();
        usdt.safeTransferFrom(msg.sender, address(this), amount);
        dmmRebateAccumulated[dmm] += amount;
        emit RebateAccumulated(dmm, amount);
    }

    function claimRebate() external {
        uint256 amt = dmmRebateAccumulated[msg.sender];
        if (amt == 0) return;
        dmmRebateAccumulated[msg.sender] = 0;
        usdt.safeTransfer(msg.sender, amt);
        emit RebateClaimed(msg.sender, amt);
    }

    // ── Admin ───────────────────────────────────────────────────────────

    function setPaused(bool p) external onlyOwner {
        paused = p;
        emit PausedSet(p);
    }

    function setResolver(address a) external onlyOwner {
        if (a == address(0)) revert ZeroAddress();
        resolver = a;
    }

    function setAutocycler(address a) external onlyOwner {
        if (a == address(0)) revert ZeroAddress();
        autocycler = a;
    }

    function setRelayer(address a) external onlyOwner {
        if (a == address(0)) revert ZeroAddress();
        relayer = a;
    }

    function setFees(uint256 platformBps, uint256 makerBps) external onlyOwner {
        platformFeeBps = platformBps;
        makerFeeBps = makerBps;
        emit FeesUpdated(platformBps, makerBps);
    }

    function setDmmRebateBps(uint256 bps) external onlyOwner {
        dmmRebateBps = bps;
        emit DmmRebateBpsUpdated(bps);
    }

    function withdrawFees(uint256 amount) external onlyOwner {
        usdt.safeTransfer(msg.sender, amount);
    }

    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    // ── Views ───────────────────────────────────────────────────────────

    function getMarket(uint256 marketId) external view returns (Market memory) {
        return markets[marketId];
    }
}
