// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {OracleRecord, IOracleManager} from "./IOracleManager.sol";


interface IOracleQuorumManager {
    error InvalidReporter();
    error AlreadyReporter();
    error RelativeThresholdExceedsOne();

    /// @notice 当记录达到法定人数并提交给预言机时发出
    /// @param block 记录最终确定的区块
    event ReportQuorumReached(uint64 indexed block);

    /// @notice 当记录被报告者报告时发出
    /// @param block 记录被记录的区块
    /// @param reporter 报告记录的报告者
    /// @param recordHash 报告的记录哈希
    /// @param record 收到的记录
    event ReportReceived(uint64 indexed block, address indexed reporter, bytes32 indexed recordHash, OracleRecord record);

    /// @notice 当预言机未能从预言机法定人数管理器接收记录时发出
    /// @param reason 失败原因，即捕获的错误
    event OracleRecordReceivedError(bytes reason);
}