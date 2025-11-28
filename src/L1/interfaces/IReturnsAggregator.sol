// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {OracleRecord} from "./IOracleManager.sol";

interface IReturnsAggregator {
    error InvalidConfiguration();
    error NotOracle();
    error Paused();
    event FeesCollected(uint256 amount);

    /// @notice 从预言机获取记录，相应地聚合净收益并将其转发到质押合约。
    function processReturns(uint256 rewardAmount, uint256 principalAmount, bool shouldIncludeELRewards, address bridge, address l2Strategy, uint256 sourceChainId, uint256 destChainId) external;
}