// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {L1Base} from "./L1Base.sol";
import {OracleRecord, IOracleManager} from "../interfaces/IOracleManager.sol";
import { IOracleQuorumManager } from "../interfaces/IOracleQuorumManager.sol";

/// @title OracleQuorumManager
/// @notice 负责管理预言机报告者的法定人数
contract OracleQuorumManager is
    L1Base,
    IOracleQuorumManager
{
    /// @notice 预言机管理员角色，可更新 OracleQuorumManager 中的属性
    bytes32 public constant QUORUM_MANAGER_ROLE = keccak256("QUORUM_MANAGER_ROLE");

    /// @notice 报告者修改者角色，可更改可产生有效预言机报告的预言机服务集合。
    /// 这是一个相当关键的角色，应具有更高的访问要求
    bytes32 public constant REPORTER_MODIFIER_ROLE = keccak256("REPORTER_MODIFIER_ROLE");

    /// @notice 服务预言机报告者角色，用于标识哪些预言机服务可以产生有效的预言机报告。
    /// 注意，向地址授予此角色可能对合约逻辑产生影响，例如合约可能根据此集合中的成员数量计算法定人数。
    /// 因此，您不应将该角色添加到预言机服务以外的任何对象
    /// @dev 要发现所有预言机服务，可以使用 `getRoleMemberCount` 和 `getRoleMember(role, N)`（在同一区块上）
    bytes32 public constant SERVICE_ORACLE_REPORTER = keccak256("SERVICE_ORACLE_REPORTER");

    /// @dev 基点（通常表示为 bp，1bp = 0.01%）是金融中用于描述金融工具百分比变化的度量单位。
    /// 这是一个设置为 10000 的常量值，表示以基点计算的 100%
    uint16 internal constant _BASIS_POINTS_DENOMINATOR = 10000;

    /// @notice 按报告者按区块存储的报告哈希
    /// @dev 报告者可以使用此映射来验证记录计算并在出错时更新它
    mapping(uint64 block => mapping(address reporter => bytes32 recordHash)) public reporterRecordHashesByBlock;

    /// @notice 某个区块的记录哈希被报告的次数
    mapping(uint64 block => mapping(bytes32 recordHash => uint256)) public recordHashCountByBlock;

    /// @notice 报告窗口的目标区块数
    uint64 public targetReportWindowBlocks;

    /// @notice 必须提交相同报告才能被接受的报告者绝对数量
    uint16 public absoluteThreshold;

    /// @notice 必须提交相同报告才能被接受的报告者相对数量（以基点计）
    /// @dev 这是一个介于 0 和 10000 基点（即 0 到 100%）之间的值。用于确定报告者总数中需要就报告达成一致的比例
    /// @dev 按 `getRoleMemberCount(SERVICE_ORACLE_REPORTER)` 缩放
    uint16 public relativeThresholdBasisPoints;


    // ============================================
    // 初始化配置
    // ============================================
    struct Init {
        address admin;
        address reporterModifier;
        address manager;
        address[] allowedReporters;
    }

    constructor() {
        _disableInitializers();
    }

    /// @notice 初始化合约
    /// @dev 必须在合约升级期间调用以设置代理状态
    function initialize(Init memory init) external initializer {
        __L1Base_init(init.admin);
        _grantRole(REPORTER_MODIFIER_ROLE, init.reporterModifier);
        _setRoleAdmin(SERVICE_ORACLE_REPORTER, REPORTER_MODIFIER_ROLE);

        _grantRole(QUORUM_MANAGER_ROLE, init.manager);

        uint256 len = init.allowedReporters.length;
        for (uint256 i = 0; i < len; i++) {
            _grantRole(SERVICE_ORACLE_REPORTER, init.allowedReporters[i]);
        }

        // 假设每 12 秒创建一个区块
        // 实践中可能略长于 8 小时目标，因为槽位可能为空
        targetReportWindowBlocks = 8 hours / 12 seconds;

        absoluteThreshold = 1;
        relativeThresholdBasisPoints = 0;
    }


    // ============================================
    // 内部函数 - 法定人数检查
    // ============================================

    /// @notice 确定给定记录哈希是否已达到给定区块的法定人数
    /// @dev 如果同意记录哈希的报告者数量大于或等于绝对阈值和相对阈值，则返回 true
    /// @param blockNumber 区块号
    /// @param recordHash 记录哈希
    function _hasReachedQuroum(uint64 blockNumber, bytes32 recordHash) internal view returns (bool) {
        uint256 numReports = recordHashCountByBlock[blockNumber][recordHash];
        uint256 numReporters = getRoleMemberCount(SERVICE_ORACLE_REPORTER);

        return (numReports >= absoluteThreshold)
            && (numReports * _BASIS_POINTS_DENOMINATOR >= numReporters * relativeThresholdBasisPoints);
    }

    function _wasReceivedByOracle(uint256 updateEndBlock) internal view returns (bool) {
        return getOracle().latestRecord().updateEndBlock >= updateEndBlock
            || (getOracle().hasPendingUpdate() && getOracle().pendingUpdate().updateEndBlock >= updateEndBlock);
    }

    function recordHashByBlockAndSender(uint64 blockNumber, address sender) external view returns (bytes32) {
        return reporterRecordHashesByBlock[blockNumber][sender];
    }

    function _trackReceivedRecord(address reporter, OracleRecord calldata record) internal returns (bytes32) {
        bytes32 newHash = keccak256(abi.encode(record));
        emit ReportReceived(record.updateEndBlock, reporter, newHash, record);

        bytes32 previousHash = reporterRecordHashesByBlock[record.updateEndBlock][reporter];
        if (newHash == previousHash) {
            return newHash;
        }

        if (previousHash != 0) {
            recordHashCountByBlock[record.updateEndBlock][previousHash] -= 1;
        }

        recordHashCountByBlock[record.updateEndBlock][newHash] += 1;
        reporterRecordHashesByBlock[record.updateEndBlock][reporter] = newHash;

        return newHash;
    }

    function receiveRecord(OracleRecord calldata record,  address bridge, address l2Strategy, uint256 sourceChainId, uint256 destChainId) external onlyRole(SERVICE_ORACLE_REPORTER) {
        bytes32 recordHash = _trackReceivedRecord(msg.sender, record);

        if (!_hasReachedQuroum(record.updateEndBlock, recordHash)) {
            return;
        }

        if (_wasReceivedByOracle(record.updateEndBlock)) {
            return;
        }

        emit ReportQuorumReached(record.updateEndBlock);

        try getOracle().receiveRecord(record, bridge, l2Strategy, sourceChainId, destChainId) {}
        catch (bytes memory reason) {
            emit OracleRecordReceivedError(reason);
        }
    }

    function setTargetReportWindowBlocks(uint64 newTargetReportWindowBlocks) external onlyRole(QUORUM_MANAGER_ROLE) {
        targetReportWindowBlocks = newTargetReportWindowBlocks;
        emit ProtocolConfigChanged(
            this.setTargetReportWindowBlocks.selector,
            "setTargetReportWindowBlocks(uint64)",
            abi.encode(newTargetReportWindowBlocks)
        );
    }

    function setQuorumThresholds(uint16 absoluteThreshold_, uint16 relativeThresholdBasisPoints_)
    external
    onlyRole(QUORUM_MANAGER_ROLE)
    {
        if (relativeThresholdBasisPoints_ > _BASIS_POINTS_DENOMINATOR) {
            revert RelativeThresholdExceedsOne();
        }

        emit ProtocolConfigChanged(
            this.setQuorumThresholds.selector,
            "setQuorumThresholds(uint16,uint16)",
            abi.encode(absoluteThreshold_, relativeThresholdBasisPoints_)
        );
        absoluteThreshold = absoluteThreshold_;
        relativeThresholdBasisPoints = relativeThresholdBasisPoints_;
    }

    function getOracle()internal view returns (IOracleManager) {
        return IOracleManager(getLocator().oracleManager());
    }
}