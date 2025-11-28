// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;


import "@openzeppelin/contracts/utils/math/Math.sol";

import {L1Base} from "./L1Base.sol";
import {IDETH} from "../interfaces/IDETH.sol";
import {IOracleReadRecord} from "../interfaces/IOracleManager.sol";
import {
IUnstakeRequestsManager,
IUnstakeRequestsManagerWrite,
IUnstakeRequestsManagerRead
} from "../interfaces/IUnstakeRequestsManager.sol";
import {IStakingManagerReturnsWrite} from "../interfaces/IStakingManager.sol";
import "../../libraries/SafeCall.sol";

/// @title UnstakeRequestsManager - 解质押请求管理合约
/// @notice 管理用户的解质押请求,包括请求创建、申领和资金分配
/// @dev 使用映射按目标链 ID 和 L2 策略地址跟踪解质押请求
contract UnstakeRequestsManager is
    L1Base,
    IUnstakeRequestsManager
{
    /// @notice 管理员角色,可以设置合约参数
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    /// @notice 请求取消者角色,可以取消待处理的解质押请求
    bytes32 public constant REQUEST_CANCELLER_ROLE = keccak256("REQUEST_CANCELLER_ROLE");

    /// @notice 已分配用于处理申领的 ETH 数量
    uint256 public allocatedETHForClaims;

    /// @notice 已申领的 ETH 总量
    uint256 public totalClaimed;

    /// @notice 请求完成所需的区块数
    uint256 public numberOfBlocksToFinalize;

    /// @notice 最新的累计请求 ETH 数量
    uint256 public latestCumulativeETHRequested;

    /// @notice 按目标链 ID 和 L2 策略地址跟踪请求的 ETH 数量
    /// @dev mapping(目标链ID => mapping(L2策略地址 => 请求的ETH数量))
    mapping(uint256 => mapping(address => uint256)) public l2ChainStrategyAmount;

    /// @notice 按目标链 ID 和 L2 策略地址跟踪锁定的 dETH 数量
    mapping(uint256 => mapping(address => uint256)) public dEthLockedAmount;

    /// @notice 按目标链 ID 和 L2 策略地址跟踪请求创建的区块号
    mapping(uint256 => mapping(address => uint256)) public l2ChainStrategyBlockNumber;

    /// @notice 按目标链 ID 和 L2 策略地址跟踪当前累计请求的 ETH
    mapping(uint256 => mapping(address => uint256)) public currentRequestedCumulativeETH;


    /// @notice 初始化参数结构体
    struct Init {
        address admin;                        // 管理员地址
        address manager;                      // 管理者地址
        address requestCanceller;             // 请求取消者地址
        uint256 numberOfBlocksToFinalize;    // 完成所需的区块数
    }

    constructor() {
        _disableInitializers();
    }

    /// @notice 初始化解质押请求管理合约
    /// @param init 初始化参数
    function initialize(Init memory init) external initializer {
        __L1Base_init(init.admin);
        _grantRole(MANAGER_ROLE, init.manager);
        _grantRole(REQUEST_CANCELLER_ROLE, init.requestCanceller);

        numberOfBlocksToFinalize = init.numberOfBlocksToFinalize;
    }

    /// @notice 创建解质押请求
    /// @dev 仅质押合约可调用,记录用户的解质押请求信息
    /// @param requester 请求者地址
    /// @param l2Strategy L2 策略合约地址
    /// @param dETHLocked 锁定的 dETH 数量
    /// @param ethRequested 请求的 ETH 数量
    /// @param destChainId 目标链 ID
    function create(address requester, address l2Strategy, uint256 dETHLocked, uint256 ethRequested, uint256 destChainId)
        external
        onlyStakingContract
    {
        uint256 currentCumulativeETHRequested = latestCumulativeETHRequested + ethRequested;

        l2ChainStrategyAmount[destChainId][l2Strategy] += ethRequested;
        dEthLockedAmount[destChainId][l2Strategy] += dETHLocked;
        l2ChainStrategyBlockNumber[destChainId][l2Strategy] = block.number;
        currentRequestedCumulativeETH[destChainId][l2Strategy] = currentCumulativeETHRequested;

        latestCumulativeETHRequested = currentCumulativeETHRequested;

        emit UnstakeRequestCreated(
            requester, l2Strategy, dETHLocked, ethRequested, currentCumulativeETHRequested, block.number, destChainId
        );
    }

    /// @notice 批量申领解质押请求
    /// @dev 仅质押合约可调用,处理多个解质押请求的申领
    /// @param requests 请求信息数组
    /// @param sourceChainId 源链 ID
    /// @param destChainId 目标链 ID
    /// @param gasLimit 桥接交易的 Gas 限制
    function claim(requestsInfo[] memory requests, uint256 sourceChainId, uint256 destChainId, uint256 gasLimit) external onlyStakingContract {
        if (requests.length == 0) {
            revert NoRequests();
        }

        for (uint256 i = 0; i < requests.length; i++) {
            address requester = requests[i].requestAddress;
            uint256 unStakeMessageNonce  = requests[i].unStakeMessageNonce;
            _claim(requester, unStakeMessageNonce, sourceChainId, destChainId, gasLimit);
        }
    }

    /// @notice 处理单个解质押请求的申领
    /// @dev 内部函数,验证请求、销毁 dETH 并通过桥接合约发送 ETH 到目标链
    /// @param requester 请求者地址(L2 策略地址)
    /// @param unStakeMessageNonce 解质押消息的 nonce
    /// @param sourceChainId 源链 ID
    /// @param destChainId 目标链 ID
    /// @param gasLimit 桥接交易的 Gas 限制
    function _claim(address requester, uint256 unStakeMessageNonce, uint256 sourceChainId, uint256 destChainId, uint256 gasLimit) private {

        uint256 csBlockNumber = l2ChainStrategyBlockNumber[destChainId][requester];
        uint256 ethRequested = l2ChainStrategyAmount[destChainId][requester];
        uint256 dETHLocked = dEthLockedAmount[destChainId][requester];

        delete l2ChainStrategyAmount[destChainId][requester];
        delete dEthLockedAmount[destChainId][requester];
        delete l2ChainStrategyBlockNumber[destChainId][requester];

        // Todo: Will addresses it in the future
        // if (!_isFinalized(csBlockNumber)) {
        //     revert NotFinalized();
        // }

        emit UnstakeRequestClaimed({
            l2strategy: requester,
            ethRequested: ethRequested,
            dETHLocked: dETHLocked,
            destChainId: destChainId,
            csBlockNumber: csBlockNumber,
            bridgeAddress: getLocator().dapplinkBridge(),
            unStakeMessageNonce: unStakeMessageNonce
        });
        getDETH().burn(dETHLocked);
        bool success = SafeCall.callWithMinGas(
            getLocator().dapplinkBridge(),
            gasLimit,
            ethRequested,
            abi.encodeWithSignature("BridgeInitiateETH(uint256,uint256,address)", sourceChainId, destChainId, requester)
        );
        if (!success) {
            revert BridgeInitiateETHFailed();
        }
    }

    /// @notice 分配 ETH 用于处理申领
    /// @dev 仅质押合约可调用,接收 ETH 并增加可用于申领的余额
    function allocateETH() external payable onlyStakingContract {
        allocatedETHForClaims += msg.value;
    }

    /// @notice 提取已分配 ETH 的盈余
    /// @dev 仅质押合约可调用,将超额分配的 ETH 返还给质押管理合约
    function withdrawAllocatedETHSurplus() external onlyStakingContract {
        uint256 toSend = allocatedETHSurplus();
        if (toSend == 0) {
            return;
        }
        allocatedETHForClaims -= toSend;
        IStakingManagerReturnsWrite(getLocator().stakingManager()).receiveFromUnstakeRequestsManager{value: toSend}();
    }

    /// @notice 根据 ID 查询解质押请求
    /// @param destChainId 目标链 ID
    /// @param l2Strategy L2 策略地址
    /// @return ethRequested 请求的 ETH 数量
    /// @return dETHLocked 锁定的 dETH 数量
    /// @return csBlockNumber 请求创建的区块号
    function requestByID(uint256 destChainId, address l2Strategy) external view returns (uint256, uint256, uint256){
        uint256 csBlockNumber = l2ChainStrategyBlockNumber[destChainId][l2Strategy];
        uint256 ethRequested = l2ChainStrategyAmount[destChainId][l2Strategy];
        uint256 dETHLocked = dEthLockedAmount[destChainId][l2Strategy];
        return(ethRequested, dETHLocked, csBlockNumber);
    }

    /// @notice 查询解质押请求信息
    /// @param destChainId 目标链 ID
    /// @param l2Strategy L2 策略地址
    /// @return isFinalized 请求是否已完成
    /// @return claimableAmount 可申领的 ETH 数量
    function requestInfo(uint256 destChainId, address l2Strategy) external view returns (bool, uint256) {
        uint256 csBlockNumber = l2ChainStrategyBlockNumber[destChainId][l2Strategy];
        uint256 ethRequested = l2ChainStrategyAmount[destChainId][l2Strategy];
        uint256 dETHLocked = dEthLockedAmount[destChainId][l2Strategy];
        uint256 cumulativeETHRequested = currentRequestedCumulativeETH[destChainId][l2Strategy];

        bool isFinalized = _isFinalized(csBlockNumber);
        uint256 claimableAmount = 0;

        uint256 allocatedEthRequired = cumulativeETHRequested - ethRequested;
        if (allocatedEthRequired < allocatedETHForClaims) {
            claimableAmount = Math.min(allocatedETHForClaims - allocatedEthRequired,  ethRequested);
        }
        return (isFinalized, claimableAmount);
    }

    /// @notice 计算已分配 ETH 的盈余
    /// @return 盈余 ETH 数量
    function allocatedETHSurplus() public view returns (uint256) {
        if (allocatedETHForClaims > latestCumulativeETHRequested) {
            return allocatedETHForClaims - latestCumulativeETHRequested;
        }
        return 0;
    }

    /// @notice 计算已分配 ETH 的赤字
    /// @return 赤字 ETH 数量
    function allocatedETHDeficit() external view returns (uint256) {
        if (latestCumulativeETHRequested > allocatedETHForClaims) {
            return latestCumulativeETHRequested - allocatedETHForClaims;
        }
        return 0;
    }

    /// @notice 获取合约当前持有的可用 ETH 余额
    /// @return 可用 ETH 余额
    function balance() external view returns (uint256) {
        if (allocatedETHForClaims > totalClaimed) {
            return allocatedETHForClaims - totalClaimed;
        }
        return 0;
    }

    /// @notice 设置请求完成所需的区块数
    /// @param numberOfBlocksToFinalize_ 新的区块数
    function setNumberOfBlocksToFinalize(uint256 numberOfBlocksToFinalize_) external onlyRole(MANAGER_ROLE) {
        numberOfBlocksToFinalize = numberOfBlocksToFinalize_;
        emit ProtocolConfigChanged(
            this.setNumberOfBlocksToFinalize.selector,
            "setNumberOfBlocksToFinalize(uint256)",
            abi.encode(numberOfBlocksToFinalize_)
        );
    }

    /// @notice 检查请求是否已完成
    /// @dev 内部函数,通过比较区块号与预言机记录判断请求是否已完成
    /// @param blockNumber 请求创建的区块号
    /// @return 请求是否已完成
    function _isFinalized(uint256 blockNumber) internal view returns (bool) {
        return (blockNumber + numberOfBlocksToFinalize) <= IOracleReadRecord(getLocator().oracleManager()).latestRecord().updateEndBlock;
    }

    /// @notice 确保调用者是质押管理合约
    modifier onlyStakingContract() {
        if (msg.sender != getLocator().stakingManager()) {
            revert NotStakingManagerContract();
        }
        _;
    }
    // receive() external payable {
    //     revert DoesNotReceiveETH();
    // }

    // fallback() external payable {
    //     revert DoesNotReceiveETH();
    // }
}
