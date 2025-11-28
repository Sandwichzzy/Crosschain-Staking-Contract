// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "../interfaces/IL1Locator.sol";

/// @title L1Locator - L1 服务定位器
/// @notice 集中管理 L1 层所有核心合约的地址,提供统一的地址查询服务
/// @dev 使用不可变部署,初始化后地址不可更改(除 stakingManager 外),遵循服务定位器模式
contract L1Locator is IL1Locator {
    /// @notice 配置参数结构体
    struct Config {
        address stakingManager;              // 质押管理合约
        address unStakingRequestsManager;    // 解质押请求管理合约
        address dETH;                        // dETH 代币合约
        address pauser;                      // 暂停器合约
        address returnsAggregator;           // 收益聚合器合约
        address oracleManager;               // 预言机管理合约
        address oracleQuorumManager;         // 预言机仲裁管理合约
        address consensusLayerReceiver;      // 共识层收益接收器
        address executionLayerReceiver;      // 执行层收益接收器
        address dapplinkBridge;              // DappLink 桥接合约
        address depositContract;             // 以太坊信标链存款合约
        address relayerAddress;              // 中继者地址
    }

    /// @notice 零地址错误
    error ZeroAddress();

    /// @notice 质押管理合约地址
    address public stakingManager;

    /// @notice 解质押请求管理合约地址
    address public unStakingRequestsManager;

    /// @notice dETH 代币合约地址
    address public dETH;

    /// @notice 暂停器合约地址
    address public pauser;

    /// @notice 收益聚合器合约地址
    address public returnsAggregator;

    /// @notice 预言机管理合约地址
    address public oracleManager;

    /// @notice 预言机仲裁管理合约地址
    address public oracleQuorumManager;

    /// @notice 共识层收益接收器地址
    address public consensusLayerReceiver;

    /// @notice 执行层收益接收器地址
    address public executionLayerReceiver;

    /// @notice DappLink 桥接合约地址
    address public dapplinkBridge;

    /// @notice 以太坊信标链存款合约地址
    address public depositContract;

    /// @notice 中继者地址
    address public relayerAddress;

    /// @notice 构造函数,初始化所有服务地址
    /// @dev 使用结构体参数避免"栈太深"错误,所有地址必须非零
    /// @param _config 配置参数结构体,包含所有核心合约地址
    constructor(Config memory _config) {
        stakingManager = _assertNonZero(_config.stakingManager);
        unStakingRequestsManager = _assertNonZero(_config.unStakingRequestsManager);
        dETH = _assertNonZero(_config.dETH);
        pauser = _assertNonZero(_config.pauser);
        returnsAggregator = _assertNonZero(_config.returnsAggregator);
        oracleManager = _assertNonZero(_config.oracleManager);
        oracleQuorumManager = _assertNonZero(_config.oracleQuorumManager);
        consensusLayerReceiver = _assertNonZero(_config.consensusLayerReceiver);
        executionLayerReceiver = _assertNonZero(_config.executionLayerReceiver);
        dapplinkBridge = _assertNonZero(_config.dapplinkBridge);
        depositContract = _assertNonZero(_config.depositContract);
        relayerAddress = _assertNonZero(_config.relayerAddress);
    }

    /// @notice 断言地址非零
    /// @dev 内部辅助函数,用于构造函数中验证地址
    /// @param _address 要验证的地址
    /// @return 验证通过的地址
    function _assertNonZero(address _address) internal pure returns (address) {
        if (_address == address(0)) revert ZeroAddress();
        return _address;
    }

    /// @notice 设置质押管理合约地址
    /// @dev 这是唯一可以在部署后修改的地址
    /// @param _stakingManager 新的质押管理合约地址
    function setStakingManager(address _stakingManager) external {
        stakingManager = _stakingManager;
    }

    /// @notice 返回所有核心组件地址
    /// @return _stakingManager 质押管理合约地址
    /// @return _unStakingRequestsManager 解质押请求管理合约地址
    /// @return _dETH dETH 代币合约地址
    /// @return _pauser 暂停器合约地址
    /// @return _returnsAggregator 收益聚合器合约地址
    /// @return _oracleManager 预言机管理合约地址
    /// @return _oracleQuorumManager 预言机仲裁管理合约地址
    /// @return _consensusLayerReceiver 共识层收益接收器地址
    /// @return _executionLayerReceiver 执行层收益接收器地址
    /// @return _dapplinkBridge DappLink 桥接合约地址
    /// @return _depositContract 信标链存款合约地址
    /// @return _relayerAddress 中继者地址
    function coreComponents()
        external
        view
        returns (
            address _stakingManager,
            address _unStakingRequestsManager,
            address _dETH,
            address _pauser,
            address _returnsAggregator,
            address _oracleManager,
            address _oracleQuorumManager,
            address _consensusLayerReceiver,
            address _executionLayerReceiver,
            address _dapplinkBridge,
            address _depositContract,
            address _relayerAddress
        )
    {
        return (
            stakingManager,
            unStakingRequestsManager,
            dETH,
            pauser,
            returnsAggregator,
            oracleManager,
            oracleQuorumManager,
            consensusLayerReceiver,
            executionLayerReceiver,
            dapplinkBridge,
            depositContract,
            relayerAddress
        );
    }
}
