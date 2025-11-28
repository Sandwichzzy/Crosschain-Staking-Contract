// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    ERC20PermitUpgradeable,
    IERC20Permit
} from "@openzeppelin-upgrades/contracts/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {ERC20Upgradeable, IERC20} from "@openzeppelin-upgrades/contracts/token/ERC20/ERC20Upgradeable.sol";

import {L1Base} from "./L1Base.sol";
import {IDETH} from "../interfaces/IDETH.sol";
import "../../libraries/SafeCall.sol";

/// @title DETH - 质押衍生代币合约
/// @notice dETH 是用户在质押 ETH 后获得的凭证代币,可用于跨链质押场景
/// @dev 继承 ERC20PermitUpgradeable 支持 EIP-2612 签名授权,继承 L1Base 使用 Locator 模式
contract DETH is L1Base, ERC20PermitUpgradeable, IDETH {
    /// @notice L2 上对应的 shares 代币地址
    address public l2ShareAddress;

    /// @notice 桥接合约地址,用于跨链传递转账信息
    address public bridgeAddress;

    /// @notice 初始化参数结构体
    struct Init {
        address admin;           // 管理员地址
        address l2ShareAddress;  // L2 shares 地址
        address bridgeAddress;   // 桥接合约地址
    }

    /*******************************************************************************
                            INITIALIZING FUNCTIONS
    *******************************************************************************/

    constructor() {
        _disableInitializers();
    }

    /// @notice 初始化 dETH 合约
    /// @param init 初始化参数,包含管理员、L2 shares 地址和桥接合约地址
    function initialize(Init memory init) external initializer {
        __L1Base_init(init.admin);

        __ERC20_init("dETH", "dETH");
        __ERC20Permit_init("dETH");

        l2ShareAddress = init.l2ShareAddress;
        bridgeAddress = init.bridgeAddress;
    }

    /// @notice 铸造 dETH 代币
    /// @dev 仅质押管理合约可调用,在用户质押 ETH 时铸造对应的 dETH
    /// @param staker 接收 dETH 的用户地址
    /// @param amount 铸造的 dETH 数量
    function mint(address staker, uint256 amount) external {
        if (msg.sender != getLocator().stakingManager()) {
            revert NotStakingManagerContract();
        }
        _mint(staker, amount);
    }

    /// @notice 批量铸造 dETH 代币
    /// @dev 仅质押管理合约可调用,用于批量处理多个用户的质押
    /// @param batcher 批量铸造信息数组,包含用户地址和铸造数量
    function batchMint(BatchMint[] calldata batcher) external {
        if (msg.sender != getLocator().stakingManager()) {
            revert NotStakingManagerContract();
        }
        for (uint256 i = 0; i < batcher.length; i++) {
            _mint(batcher[i].staker, batcher[i].amount);
        }
    }

    /// @notice 销毁 dETH 代币
    /// @dev 仅解质押请求管理合约可调用,在用户申领解质押时销毁对应的 dETH
    /// @param amount 要销毁的 dETH 数量
    function burn(uint256 amount) external {
        if (msg.sender != getLocator().unStakingRequestsManager()) {
            revert NotUnstakeRequestsManagerContract();
        }
        _burn(msg.sender, amount);
    }

    /// @notice 获取地址的 nonce 值
    /// @dev 用于 EIP-2612 签名授权
    /// @param owner 要查询的地址
    /// @return nonce 值
    function nonces(address owner)
        public
        view
        virtual
        override(ERC20PermitUpgradeable, IERC20Permit)
        returns (uint256)
    {
        return ERC20PermitUpgradeable.nonces(owner);
    }

    /// @notice 重写 transfer 函数,同时将 L2 的 shares 也转移给接收者
    /// @dev 转账 dETH 的同时,通过桥接合约发送消息到 L2 转移对应的 shares,防止重复套娃
    /// @param to 接收地址
    /// @param value 转账数量
    /// @return 转账是否成功
    function transfer(address to, uint256 value) override(ERC20Upgradeable, IERC20) public returns (bool) {
        address owner = _msgSender();
        _transfer(owner, to, value);
        bool success = SafeCall.callWithMinGas(
            bridgeAddress,
            200000,
            0,
            abi.encodeWithSignature("BridgeInitiateStakingMessage(address,address,uint256)", owner, to, value)
        );
        if (!success) {
            revert BridgeStakingMessageInitFailed();
        }
        return true;
    }

    /// @notice 重写 transferFrom 函数,同时将 L2 的 shares 也转移给接收者
    /// @dev 授权转账 dETH 的同时,通过桥接合约发送消息到 L2 转移对应的 shares
    /// @param from 转出地址
    /// @param to 接收地址
    /// @param value 转账数量
    /// @return 转账是否成功
    function transferFrom(address from, address to, uint256 value)
        public
        override(ERC20Upgradeable, IERC20)
        returns (bool)
    {
        address spender = _msgSender();
        _spendAllowance(from, spender, value);
        _transfer(from, to, value);
        bool success = SafeCall.callWithMinGas(
            bridgeAddress,
            200000,
            0,
            abi.encodeWithSignature("BridgeInitiateStakingMessage(address,address,uint256)", from, to, value)
        );
        if (!success) {
            revert BridgeStakingMessageInitFailed();
        }
        return true;
    }
}
