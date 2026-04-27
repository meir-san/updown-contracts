// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/// @title UpDownSettlement
/// @notice Single contract holding all UpDown markets as storage entries (no per-market proxy).
///         Orders are signed by makers off-chain via EIP-712; any caller may submit a signed
///         fill through `enterPosition`, which verifies the signature, tracks cumulative fills
///         against the signed amount (partial fills allowed), and pulls USDT from the maker.
///         Resolver sets outcomes after expiry; relayer withdraws settled pools.
contract UpDownSettlement is Ownable, EIP712 {
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
    error InvalidMarketWindow();
    error OrderExpired();
    error InvalidSignature();
    error FillExceedsOrderAmount();
    error InvalidSide();
    error MarketMismatch();
    error OptionMismatch();

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

    /// @dev EIP-712 Order struct mirroring the off-chain matching engine's typed-data shape.
    ///      `orderType` is named to avoid Solidity's `type` keyword collision; the EIP-712
    ///      typehash string below uses "type" to match the backend's signed payloads verbatim.
    ///      Side is 0=BUY, 1=SELL. Only BUY orders enter positions — sellers are settled
    ///      off-chain via the backend's Mongo ledger.
    struct Order {
        address maker;
        uint256 market;
        uint256 option;
        uint8 side;
        uint8 orderType;
        uint256 price;
        uint256 amount;
        uint256 nonce;
        uint256 expiry;
    }

    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "Order(address maker,uint256 market,uint256 option,uint8 side,uint8 type,uint256 price,uint256 amount,uint256 nonce,uint256 expiry)"
    );

    // ── Events ──────────────────────────────────────────────────────────
    event MarketCreated(
        uint256 indexed marketId,
        bytes32 indexed pairId,
        uint256 duration,
        int256 strikePrice,
        uint256 startTime,
        uint256 endTime
    );
    event PositionEntered(uint256 indexed marketId, uint8 option, uint256 amount, address indexed maker);
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

    /// @notice Cumulative filled amount per signed order hash. Caps at `order.amount` to
    ///         prevent over-fill; replays that would push total past the signed max revert.
    mapping(bytes32 => uint256) public orderFills;

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
        EIP712("UpDown Exchange", "1")
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
        uint64 start = uint64(block.timestamp);
        uint64 end = start + uint64(duration);
        return _createMarket(pairId, duration, strikePrice, start, end);
    }

    function createMarket(bytes32 pairId, uint256 duration, int256 strikePrice, uint64 startTime, uint64 endTime)
        external
        onlyAutocycler
        whenNotPaused
        returns (uint256 marketId)
    {
        return _createMarket(pairId, duration, strikePrice, startTime, endTime);
    }

    function _createMarket(bytes32 pairId, uint256 duration, int256 strikePrice, uint64 startTime, uint64 endTime)
        internal
        returns (uint256 marketId)
    {
        if (uint256(endTime) < uint256(startTime)) revert InvalidMarketWindow();
        if (uint256(endTime) - uint256(startTime) != duration) revert InvalidMarketWindow();

        marketId = ++nextMarketId;
        markets[marketId] = Market({
            pairId: pairId,
            totalUp: 0,
            totalDown: 0,
            startTime: startTime,
            endTime: endTime,
            duration: uint32(duration),
            winner: 0,
            resolved: false,
            settled: false,
            strikePrice: int128(strikePrice),
            settlementPrice: 0
        });
        emit MarketCreated(marketId, pairId, duration, strikePrice, startTime, endTime);
    }

    /// @notice EIP-712 struct hash for a given Order. Exposed for off-chain tooling.
    function hashOrder(Order memory order) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                order.maker,
                order.market,
                order.option,
                order.side,
                order.orderType,
                order.price,
                order.amount,
                order.nonce,
                order.expiry
            )
        );
    }

    /// @notice EIP-712 digest including domain separator. Exposed for off-chain tooling.
    function orderDigest(Order memory order) public view returns (bytes32) {
        return _hashTypedDataV4(hashOrder(order));
    }

    /// @notice Submit a signed BUY order as a fill against a market. Anyone may call.
    ///         Signature must recover to `order.maker`. Cumulative fills per signed order are
    ///         tracked on-chain and cannot exceed `order.amount`.
    /// @param order      The EIP-712 Order the maker signed off-chain.
    /// @param signature  65-byte secp256k1 signature by `order.maker`.
    /// @param marketId   Must equal `order.market`. Redundant in args but matches the
    ///                   backend's existing calldata shape for simpler migration.
    /// @param option     Must equal `order.option`. Same reason as `marketId`.
    /// @param fillAmount Amount to enter for this call. May be less than `order.amount`
    ///                   (partial fill); subsequent calls with same signature may top up.
    function enterPosition(
        Order calldata order,
        bytes calldata signature,
        uint256 marketId,
        uint8 option,
        uint256 fillAmount
    ) external whenNotPaused {
        // Arg/order consistency (prevents calldata from asking for one market while sig
        // was for another, even though sig itself ties those fields).
        if (marketId != order.market) revert MarketMismatch();
        if (uint256(option) != order.option) revert OptionMismatch();

        if (block.timestamp > order.expiry) revert OrderExpired();
        if (order.option != 1 && order.option != 2) revert InvalidOption();
        if (order.side != 0) revert InvalidSide(); // 0 = BUY; sellers settled off-chain
        if (fillAmount == 0) revert FillExceedsOrderAmount();

        // Verify maker's EIP-712 signature over the Order. SignatureChecker
        // handles BOTH plain EOAs (via ECDSA.recover internally) AND contract
        // accounts that implement ERC-1271 (e.g. Alchemy MA v2 smart accounts:
        // order.maker IS the SA address; the SA's `isValidSignature` delegates
        // to its EOA owner). Required because user USDT lives on the SA, so
        // `transferFrom(order.maker, ...)` below pulls from the SA — meaning
        // `maker` must be the SA. EOA-only `ECDSA.recover` would never accept
        // an SA as the recovered address. This is the prediction-market-
        // standard pattern (Polymarket, etc.).
        bytes32 structHash = hashOrder(order);
        bytes32 digest = _hashTypedDataV4(structHash);
        if (!SignatureChecker.isValidSignatureNow(order.maker, digest, signature)) {
            revert InvalidSignature();
        }

        // Partial-fill bookkeeping: cumulative filled must not exceed signed amount.
        uint256 already = orderFills[structHash];
        uint256 newFilled = already + fillAmount;
        if (newFilled > order.amount) revert FillExceedsOrderAmount();
        orderFills[structHash] = newFilled;

        // Market must be active.
        Market storage m = markets[marketId];
        if (m.startTime == 0) revert MarketNotOpen();
        if (block.timestamp >= uint256(m.endTime)) revert MarketNotOpen();

        // Pull USDT from maker's account. Maker must have approved this contract.
        usdt.safeTransferFrom(order.maker, address(this), fillAmount);

        if (order.option == 1) {
            m.totalUp += uint128(fillAmount);
        } else {
            m.totalDown += uint128(fillAmount);
        }
        emit PositionEntered(marketId, uint8(order.option), fillAmount, order.maker);
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

    /// @notice Remaining signed amount available for further fills on this order.
    function orderRemaining(Order calldata order) external view returns (uint256) {
        bytes32 h = hashOrder(order);
        uint256 filled = orderFills[h];
        if (filled >= order.amount) return 0;
        unchecked {
            return order.amount - filled;
        }
    }

    /// @notice Public getter matching the EIP-712 domain separator spec. Useful for
    ///         off-chain signing libraries that want to verify the domain they'll hash.
    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }
}
