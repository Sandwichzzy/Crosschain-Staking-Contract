// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/math/Math.sol";

import {L1Base} from "./L1Base.sol";
import  "../interfaces/IOracleManager.sol";
import { IReturnsAggregator } from "../interfaces/IReturnsAggregator.sol";
import { IL1Pauser } from "../../access/interface/IL1Pauser.sol";

/// @title OracleManager - 预言机管理合约
/// @notice 管理链下预言机提交的验证者状态记录,包括验证者余额、提款和存款信息
/// @dev 实现完整性检查和合理性检查,确保预言机数据的准确性和一致性
contract OracleManager is L1Base, IOracleManager {

    /// @notice 预言机管理员角色,可以设置预言机参数
    bytes32 public constant ORACLE_MANAGER_ROLE = keccak256("ORACLE_MANAGER_ROLE");

    /// @notice 预言机修改者角色,可以修改已存在的预言机记录
    bytes32 public constant ORACLE_MODIFIER_ROLE = keccak256("ORACLE_MODIFIER_ROLE");

    /// @notice 预言机待处理更新解决者角色,可以接受或拒绝待处理的更新
    bytes32 public constant ORACLE_PENDING_UPDATE_RESOLVER_ROLE = keccak256("ORACLE_PENDING_UPDATE_RESOLVER_ROLE");

    /// @notice 完成区块号增量的上限(2048 个区块)
    uint256 internal constant _FINALIZATION_BLOCK_NUMBER_DELTA_UPPER_BOUND = 2048;

    /// @notice 预言机记录数组,存储所有历史记录
    OracleRecord[] internal _records;

    /// @notice 是否有待处理的更新
    bool public hasPendingUpdate;

    /// @notice 待处理的预言机更新
    OracleRecord internal _pendingUpdate;

    /// @notice 完成所需的区块号增量
    uint256 public finalizationBlockNumberDelta;

    /// @notice 预言机更新者地址,有权提交新的预言机记录
    address public oracleUpdater;

    /// @notice 每个验证者的最小存款金额
    uint256 public minDepositPerValidator;

    /// @notice 每个验证者的最大存款金额
    uint256 public maxDepositPerValidator;

    /// @notice 共识层每个区块的最小收益率(以 PPT 为单位,1 PPT = 10^-12)
    uint40 public minConsensusLayerGainPerBlockPPT;

    /// @notice 共识层每个区块的最大收益率(以 PPT 为单位)
    uint40 public maxConsensusLayerGainPerBlockPPT;

    /// @notice 共识层的最大损失率(以 PPM 为单位,1 PPM = 10^-6)
    uint24 public maxConsensusLayerLossPPM;

    /// @notice 最小报告区块数
    uint16 public minReportSizeBlocks;

    /// @notice PPM 分母(百万分之一)
    uint24 internal constant _PPM_DENOMINATOR = 1e6;

    /// @notice PPT 分母(万亿分之一)
    uint40 internal constant _PPT_DENOMINATOR = 1e12;

    /// @notice 初始化参数结构体
    struct Init {
        address admin;              // 管理员地址
        address manager;            // 管理者地址
        address oracleUpdater;      // 预言机更新者地址
        address pendingResolver;    // 待处理更新解决者地址
    }

    constructor() {
        _disableInitializers();
    }

    /// @notice 初始化预言机管理合约
    /// @param init 初始化参数
    function initialize(Init memory init) external initializer {
        __L1Base_init(init.admin);
        _grantRole(ORACLE_MANAGER_ROLE, init.manager);
        _grantRole(ORACLE_PENDING_UPDATE_RESOLVER_ROLE, init.pendingResolver);

        oracleUpdater = init.oracleUpdater;

        finalizationBlockNumberDelta = 64;

        minReportSizeBlocks = 100;
        minDepositPerValidator = 32 ether;
        maxDepositPerValidator = 32 ether;

        maxConsensusLayerGainPerBlockPPT = 190250; // 10x 近似比率
        minConsensusLayerGainPerBlockPPT = 1903; // 0.1x 近似比率

        maxConsensusLayerLossPPM = 1000;

    }

    /// @notice 初始化第一条预言机记录
    /// @dev 仅待处理更新解决者可调用,用于协议初始化
    function initRecord()external onlyRole(ORACLE_PENDING_UPDATE_RESOLVER_ROLE) {
        _pushRecord(OracleRecord(0, uint64(getStakingManager().initializationBlockNumber()), 0, 0, 0, 0, 0, 0), msg.sender, msg.sender, 0, 0);
    }

    /// @notice 接收并处理新的预言机记录
    /// @dev 仅预言机更新者可调用,执行验证和合理性检查
    /// @param newRecord 新的预言机记录
    /// @param bridge 桥接合约地址
    /// @param l2Strategy L2 策略地址
    /// @param sourceChainId 源链 ID
    /// @param destChainId 目标链 ID
    function receiveRecord(OracleRecord calldata newRecord, address bridge, address l2Strategy, uint256 sourceChainId, uint256 destChainId) external {
        if (IL1Pauser(getLocator().pauser()).isSubmitOracleRecordsPaused()) {
            revert Paused();
        }

        if (msg.sender != oracleUpdater) {
            revert UnauthorizedOracleUpdater(msg.sender, oracleUpdater);
        }

        if (hasPendingUpdate) {
            revert CannotUpdateWhileUpdatePending();
        }

        validateUpdate(_records.length - 1, newRecord);

        uint256 updateFinalizingBlock = newRecord.updateEndBlock + finalizationBlockNumberDelta;
        if (block.number < updateFinalizingBlock) {
            revert UpdateEndBlockNumberNotFinal(updateFinalizingBlock);
        }

        (string memory rejectionReason, uint256 value, uint256 bound) = sanityCheckUpdate(latestRecord(), newRecord);
        if (bytes(rejectionReason).length > 0) {
            _pendingUpdate = newRecord;
            hasPendingUpdate = true;
            emit OracleRecordFailedSanityCheck({
                reasonHash: keccak256(bytes(rejectionReason)),
                reason: rejectionReason,
                record: newRecord,
                value: value,
                bound: bound
            });

            IL1Pauser(getLocator().pauser()).pauseAll();
            return;
        }
        _pushRecord(newRecord, bridge, l2Strategy, sourceChainId, destChainId);
    }

    /// @notice 修改已存在的预言机记录
    /// @dev 仅预言机修改者可调用,用于修正错误的历史记录
    /// @param idx 要修改的记录索引
    /// @param record 新的记录数据
    /// @param bridge 桥接合约地址
    /// @param l2Strategy L2 策略地址
    /// @param sourceChainId 源链 ID
    /// @param destChainId 目标链 ID
    function modifyExistingRecord(uint256 idx, OracleRecord calldata record, address bridge, address l2Strategy, uint256 sourceChainId, uint256 destChainId) external onlyRole(ORACLE_MODIFIER_ROLE) {
        if (idx == 0) {
            revert CannotModifyInitialRecord();
        }

        if (idx >= _records.length) {
            revert RecordDoesNotExist(idx);
        }

        OracleRecord storage existingRecord = _records[idx];
        if (
            existingRecord.updateStartBlock != record.updateStartBlock
            || existingRecord.updateEndBlock != record.updateEndBlock
        ) {
            revert InvalidRecordModification();
        }

        validateUpdate(idx - 1, record);

        uint256 missingRewards = 0;
        uint256 missingPrincipals = 0;

        if (record.windowWithdrawnRewardAmount > existingRecord.windowWithdrawnRewardAmount) {
            missingRewards = record.windowWithdrawnRewardAmount - existingRecord.windowWithdrawnRewardAmount;
        }
        if (record.windowWithdrawnPrincipalAmount > existingRecord.windowWithdrawnPrincipalAmount) {
            missingPrincipals = record.windowWithdrawnPrincipalAmount - existingRecord.windowWithdrawnPrincipalAmount;
        }

        _records[idx] = record;
        emit OracleRecordModified(idx, record);

        if (missingRewards > 0 || missingPrincipals > 0) {
            IReturnsAggregator(getLocator().returnsAggregator()).processReturns({
                rewardAmount: missingRewards,
                principalAmount: missingPrincipals,
                shouldIncludeELRewards: false,
                bridge: bridge,
                l2Strategy: l2Strategy,
                sourceChainId: sourceChainId,
                destChainId: destChainId
            });
        }
    }

    /// @notice 验证新记录的完整性
    /// @dev 检查记录的区块范围、存款和验证者数量的一致性
    /// @param prevRecordIndex 前一条记录的索引
    /// @param newRecord 新记录
    function validateUpdate(uint256 prevRecordIndex, OracleRecord calldata newRecord) public view {
        OracleRecord storage prevRecord = _records[prevRecordIndex];
        if (newRecord.updateEndBlock <= newRecord.updateStartBlock) {
            revert InvalidUpdateEndBeforeStartBlock(newRecord.updateEndBlock, newRecord.updateStartBlock);
        }

        if (newRecord.updateStartBlock != prevRecord.updateEndBlock + 1) {
            revert InvalidUpdateStartBlock(prevRecord.updateEndBlock + 1, newRecord.updateStartBlock);
        }

        if (newRecord.cumulativeProcessedDepositAmount > getStakingManager().totalDepositedInValidators()) {
            revert InvalidUpdateMoreDepositsProcessedThanSent(
                newRecord.cumulativeProcessedDepositAmount, getStakingManager().totalDepositedInValidators()
            );
        }

        if (
            uint256(newRecord.currentNumValidatorsNotWithdrawable)
            + uint256(newRecord.cumulativeNumValidatorsWithdrawable) > getStakingManager().numInitiatedValidators()
        ) {
            revert InvalidUpdateMoreValidatorsThanInitiated(
                newRecord.currentNumValidatorsNotWithdrawable + newRecord.cumulativeNumValidatorsWithdrawable,
                getStakingManager().numInitiatedValidators()
            );
        }
    }

    /// @notice 对新记录进行合理性检查
    /// @dev 检查验证者余额变化是否在合理范围内
    /// @param prevRecord 前一条记录
    /// @param newRecord 新记录
    /// @return 拒绝原因(空字符串表示通过)
    /// @return 实际值
    /// @return 边界值
    function sanityCheckUpdate(OracleRecord memory prevRecord, OracleRecord calldata newRecord)
    public
    view
    returns (string memory, uint256, uint256)
    {
        uint64 reportSize = newRecord.updateEndBlock - newRecord.updateStartBlock + 1;
        {
            if (reportSize < minReportSizeBlocks) {
                return ("Report blocks below minimum bound", reportSize, minReportSizeBlocks);
            }
        }
        {
            if (newRecord.cumulativeNumValidatorsWithdrawable < prevRecord.cumulativeNumValidatorsWithdrawable) {
                return (
                    "Cumulative number of withdrawable validators decreased",
                    newRecord.cumulativeNumValidatorsWithdrawable,
                    prevRecord.cumulativeNumValidatorsWithdrawable
                );
            }
            {
                uint256 prevNumValidators =
                    prevRecord.currentNumValidatorsNotWithdrawable + prevRecord.cumulativeNumValidatorsWithdrawable;
                uint256 newNumValidators =
                    newRecord.currentNumValidatorsNotWithdrawable + newRecord.cumulativeNumValidatorsWithdrawable;

                if (newNumValidators < prevNumValidators) {
                    return ("Total number of validators decreased", newNumValidators, prevNumValidators);
                }
            }
        }

        {
            if (newRecord.cumulativeProcessedDepositAmount < prevRecord.cumulativeProcessedDepositAmount) {
                return (
                    "Processed deposit amount decreased",
                    newRecord.cumulativeProcessedDepositAmount,
                    prevRecord.cumulativeProcessedDepositAmount
                );
            }

            uint256 newDeposits =
            (newRecord.cumulativeProcessedDepositAmount - prevRecord.cumulativeProcessedDepositAmount);
            uint256 newValidators = (
                newRecord.currentNumValidatorsNotWithdrawable + newRecord.cumulativeNumValidatorsWithdrawable
                - prevRecord.currentNumValidatorsNotWithdrawable - prevRecord.cumulativeNumValidatorsWithdrawable
            );

            if (newDeposits < newValidators * minDepositPerValidator) {
                return (
                    "New deposits below min deposit per validator", newDeposits, newValidators * minDepositPerValidator
                );
            }

            if (newDeposits > newValidators * maxDepositPerValidator) {
                return (
                    "New deposits above max deposit per validator", newDeposits, newValidators * maxDepositPerValidator
                );
            }
        }

        {
            uint256 baselineGrossCLBalance = prevRecord.currentTotalValidatorBalance
                + (newRecord.cumulativeProcessedDepositAmount - prevRecord.cumulativeProcessedDepositAmount);

            uint256 newGrossCLBalance = newRecord.currentTotalValidatorBalance
                + newRecord.windowWithdrawnPrincipalAmount + newRecord.windowWithdrawnRewardAmount;

            {
                uint256 lowerBound = baselineGrossCLBalance
                    - Math.mulDiv(maxConsensusLayerLossPPM, baselineGrossCLBalance, _PPM_DENOMINATOR)
                    + Math.mulDiv(minConsensusLayerGainPerBlockPPT * reportSize, baselineGrossCLBalance, _PPT_DENOMINATOR);

                if (newGrossCLBalance < lowerBound) {
                    return ("Consensus layer change below min gain or max loss", newGrossCLBalance, lowerBound);
                }
            }
            {
                uint256 upperBound = baselineGrossCLBalance
                    + Math.mulDiv(maxConsensusLayerGainPerBlockPPT * reportSize, baselineGrossCLBalance, _PPT_DENOMINATOR);

                if (newGrossCLBalance > upperBound) {
                    return ("Consensus layer change above max gain", newGrossCLBalance, upperBound);
                }
            }
        }

        return ("", 0, 0);
    }

    /// @notice 添加新的预言机记录并处理收益
    /// @dev 内部函数,添加记录到数组并调用收益聚合器处理提款
    /// @param record 要添加的记录
    /// @param bridge 桥接合约地址
    /// @param l2Strategy L2 策略地址
    /// @param sourceChainId 源链 ID
    /// @param destChainId 目标链 ID
    function _pushRecord(OracleRecord memory record, address bridge, address l2Strategy, uint256 sourceChainId, uint256 destChainId) internal {
        emit OracleRecordAdded(_records.length, record);
        _records.push(record);

        IReturnsAggregator(getLocator().returnsAggregator()).processReturns({
            rewardAmount: record.windowWithdrawnRewardAmount,
            principalAmount: record.windowWithdrawnPrincipalAmount,
            shouldIncludeELRewards: true,
            bridge: bridge,
            l2Strategy: l2Strategy,
            sourceChainId: sourceChainId,
            destChainId: destChainId
        });
    }

    /// @notice 接受待处理的预言机更新
    /// @dev 仅待处理更新解决者可调用
    /// @param bridge 桥接合约地址
    /// @param l2Strategy L2 策略地址
    /// @param sourceChainId 源链 ID
    /// @param destChainId 目标链 ID
    function acceptPendingUpdate(address bridge, address l2Strategy, uint256 sourceChainId, uint256 destChainId) external onlyRole(ORACLE_PENDING_UPDATE_RESOLVER_ROLE) {
        if (!hasPendingUpdate) {
            revert NoUpdatePending();
        }

        _pushRecord(_pendingUpdate, bridge, l2Strategy, sourceChainId, destChainId);
        _resetPending();
    }

    /// @notice 拒绝待处理的预言机更新
    /// @dev 仅待处理更新解决者可调用
    function rejectPendingUpdate() external onlyRole(ORACLE_PENDING_UPDATE_RESOLVER_ROLE) {
        if (!hasPendingUpdate) {
            revert NoUpdatePending();
        }

        emit OraclePendingUpdateRejected(_pendingUpdate);
        _resetPending();
    }

    /// @notice 获取最新的预言机记录
    /// @return 最新的预言机记录
    function latestRecord() public view returns (OracleRecord memory) {
        return _records[_records.length - 1];
    }

    /// @notice 获取待处理的预言机更新
    /// @return 待处理的预言机更新
    function pendingUpdate() external view returns (OracleRecord memory) {
        if (!hasPendingUpdate) {
            revert NoUpdatePending();
        }
        return _pendingUpdate;
    }

    /// @notice 根据索引获取预言机记录
    /// @param idx 记录索引
    /// @return 指定索引的预言机记录
    function recordAt(uint256 idx) external view returns (OracleRecord memory) {
        return _records[idx];
    }

    /// @notice 获取预言机记录总数
    /// @return 记录总数
    function numRecords() external view returns (uint256) {
        return _records.length;
    }

    /// @notice 重置待处理的更新
    /// @dev 内部函数,清除待处理状态
    function _resetPending() internal {
        delete _pendingUpdate;
        hasPendingUpdate = false;
    }

    /// @notice 设置完成所需的区块号增量
    /// @param finalizationBlockNumberDelta_ 新的区块号增量
    function setFinalizationBlockNumberDelta(uint256 finalizationBlockNumberDelta_)
    external
    onlyRole(ORACLE_MANAGER_ROLE)
    {
        if (
            finalizationBlockNumberDelta_ == 0
            || finalizationBlockNumberDelta_ > _FINALIZATION_BLOCK_NUMBER_DELTA_UPPER_BOUND
        ) {
            revert InvalidConfiguration();
        }

        finalizationBlockNumberDelta = finalizationBlockNumberDelta_;
        emit ProtocolConfigChanged(
            this.setFinalizationBlockNumberDelta.selector,
            "setFinalizationBlockNumberDelta(uint256)",
            abi.encode(finalizationBlockNumberDelta_)
        );
    }

    /// @notice 设置预言机更新者地址
    /// @param newUpdater 新的更新者地址
    function setOracleUpdater(address newUpdater) external onlyRole(ORACLE_MANAGER_ROLE) notZeroAddress(newUpdater) {
        oracleUpdater = newUpdater;
        emit ProtocolConfigChanged(this.setOracleUpdater.selector, "setOracleUpdater(address)", abi.encode(newUpdater));
    }

    /// @notice 设置每个验证者的最小存款金额
    /// @param minDepositPerValidator_ 新的最小存款金额
    function setMinDepositPerValidator(uint256 minDepositPerValidator_) external onlyRole(ORACLE_MANAGER_ROLE) {
        minDepositPerValidator = minDepositPerValidator_;
        emit ProtocolConfigChanged(
            this.setMinDepositPerValidator.selector,
            "setMinDepositPerValidator(uint256)",
            abi.encode(minDepositPerValidator_)
        );
    }

    /// @notice 设置每个验证者的最大存款金额
    /// @param maxDepositPerValidator_ 新的最大存款金额
    function setMaxDepositPerValidator(uint256 maxDepositPerValidator_) external onlyRole(ORACLE_MANAGER_ROLE) {
        maxDepositPerValidator = maxDepositPerValidator_;
        emit ProtocolConfigChanged(
            this.setMaxDepositPerValidator.selector,
            "setMaxDepositPerValidator(uint256)",
            abi.encode(maxDepositPerValidator)
        );
    }

    /// @notice 设置共识层每个区块的最小收益率
    /// @param minConsensusLayerGainPerBlockPPT_ 新的最小收益率(PPT)
    function setMinConsensusLayerGainPerBlockPPT(uint40 minConsensusLayerGainPerBlockPPT_)
    external
    onlyRole(ORACLE_MANAGER_ROLE)
    onlyFractionLeqOne(minConsensusLayerGainPerBlockPPT_, _PPT_DENOMINATOR)
    {
        minConsensusLayerGainPerBlockPPT = minConsensusLayerGainPerBlockPPT_;
        emit ProtocolConfigChanged(
            this.setMinConsensusLayerGainPerBlockPPT.selector,
            "setMinConsensusLayerGainPerBlockPPT(uint40)",
            abi.encode(minConsensusLayerGainPerBlockPPT_)
        );
    }

    /// @notice 设置共识层每个区块的最大收益率
    /// @param maxConsensusLayerGainPerBlockPPT_ 新的最大收益率(PPT)
    function setMaxConsensusLayerGainPerBlockPPT(uint40 maxConsensusLayerGainPerBlockPPT_)
    external
    onlyRole(ORACLE_MANAGER_ROLE)
    onlyFractionLeqOne(maxConsensusLayerGainPerBlockPPT_, _PPT_DENOMINATOR)
    {
        maxConsensusLayerGainPerBlockPPT = maxConsensusLayerGainPerBlockPPT_;
        emit ProtocolConfigChanged(
            this.setMaxConsensusLayerGainPerBlockPPT.selector,
            "setMaxConsensusLayerGainPerBlockPPT(uint40)",
            abi.encode(maxConsensusLayerGainPerBlockPPT_)
        );
    }

    /// @notice 设置共识层的最大损失率
    /// @param maxConsensusLayerLossPPM_ 新的最大损失率(PPM)
    function setMaxConsensusLayerLossPPM(uint24 maxConsensusLayerLossPPM_)
    external
    onlyRole(ORACLE_MANAGER_ROLE)
    onlyFractionLeqOne(maxConsensusLayerLossPPM_, _PPM_DENOMINATOR)
    {
        maxConsensusLayerLossPPM = maxConsensusLayerLossPPM_;
        emit ProtocolConfigChanged(
            this.setMaxConsensusLayerLossPPM.selector,
            "setMaxConsensusLayerLossPPM(uint24)",
            abi.encode(maxConsensusLayerLossPPM_)
        );
    }

    /// @notice 设置最小报告区块数
    /// @param minReportSizeBlocks_ 新的最小报告区块数
    function setMinReportSizeBlocks(uint16 minReportSizeBlocks_) external onlyRole(ORACLE_MANAGER_ROLE) {
        minReportSizeBlocks = minReportSizeBlocks_;
        emit ProtocolConfigChanged(
            this.setMinReportSizeBlocks.selector, "setMinReportSizeBlocks(uint16)", abi.encode(minReportSizeBlocks_)
        );
    }

    /// @notice 确保分数不大于 1
    /// @dev 修饰符,用于验证比率参数的有效性
    /// @param numerator 分子
    /// @param denominator 分母
    modifier onlyFractionLeqOne(uint256 numerator, uint256 denominator) {
        if (numerator > denominator) {
            revert InvalidConfiguration();
        }
        _;
    }
}
