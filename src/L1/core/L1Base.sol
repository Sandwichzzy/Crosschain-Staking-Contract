// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin-upgrades/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-upgrades/contracts/access/extensions/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/IL1Locator.sol";
import {ProtocolEvents} from "../interfaces/ProtocolEvents.sol";
import {IL1Pauser} from "../../access/interface/IL1Pauser.sol";
import {IDETH} from "../interfaces/IDETH.sol";

import {IUnstakeRequestsManager} from "../interfaces/IUnstakeRequestsManager.sol";
import {IStakingManager} from "../interfaces/IStakingManager.sol";
import {IDepositContract} from "../interfaces/IDepositContract.sol";

/// @title L1Base - L1 合约基类
/// @notice 为 L1 层所有核心合约提供基础功能,包括访问控制、服务定位和常用修饰符
/// @dev 使用 Locator 模式获取其他合约地址,继承可升级合约和访问控制功能
abstract contract L1Base is
    Initializable,
    AccessControlEnumerableUpgradeable,
    ReentrancyGuard,
    ProtocolEvents
{
    /// @notice 服务定位器合约地址
    address public locator;

    /// @notice 零地址错误
    error ZeroAddress();

    /// @notice 确保地址不为零地址
    /// @param addr 要检查的地址
    modifier notZeroAddress(address addr) {
        if (addr == address(0)) {
            revert ZeroAddress();
        }
        _;
    }

    /// @notice 确保调用者是中继者
    modifier onlyRelayer() {
        require(msg.sender == getLocator().relayerAddress(), "Not Relayer");
        _;
    }

    /// @notice 初始化 L1Base 基类
    /// @param _admin 管理员地址
    function __L1Base_init(address _admin) internal onlyInitializing {
        __AccessControlEnumerable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    /// @notice 设置服务定位器地址
    /// @dev 仅管理员可调用
    /// @param _locator 新的服务定位器地址
    function setLocator(address _locator) external onlyRole(DEFAULT_ADMIN_ROLE) {
        locator = _locator;
    }

    /// @notice 获取服务定位器合约实例
    /// @return IL1Locator 接口实例
    function getLocator() public view returns (IL1Locator) {
        return IL1Locator(locator);
    }

    /// @notice 获取 L1 暂停器合约实例
    /// @return IL1Pauser 接口实例
    function getL1Pauser() internal view returns (IL1Pauser) {
        return IL1Pauser(getLocator().pauser());
    }

    /// @notice 获取解质押请求管理合约实例
    /// @return IUnstakeRequestsManager 接口实例
    function getUnstakeRequestsManager() internal view returns (IUnstakeRequestsManager) {
        return IUnstakeRequestsManager(getLocator().unStakingRequestsManager());
    }

    /// @notice 获取质押管理合约实例
    /// @return IStakingManager 接口实例
    function getStakingManager() internal view returns (IStakingManager) {
        return IStakingManager(getLocator().stakingManager());
    }

    /// @notice 获取 dETH 代币合约实例
    /// @return IDETH 接口实例
    function getDETH() internal view returns (IDETH) {
        return IDETH(getLocator().dETH());
    }

    /// @notice 获取以太坊信标链存款合约实例
    /// @return IDepositContract 接口实例
    function getDepositContract() internal view returns (IDepositContract) {
        return IDepositContract(getLocator().depositContract());
    }

    // function getStrategyManager()external returns (IStrategyManager){
    //     return IStrategyManager(getLocator().strategyManager());
    // }
}
