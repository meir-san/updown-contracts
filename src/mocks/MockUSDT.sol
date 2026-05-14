// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice 6-decimal mock USDT for Arbitrum Sepolia testnet only. Public
///         `mint` lets anyone self-provision test balances without owner
///         gating, matching the throwaway-testnet posture of the rest of
///         the Sepolia bring-up (`MockAggregatorV3`, the throwaway deployer
///         EOA). Real Arbitrum One uses the production USDT contract;
///         this contract is never deployed to mainnet.
contract MockUSDT is ERC20 {
    constructor() ERC20("Mock USDT", "USDTM") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
