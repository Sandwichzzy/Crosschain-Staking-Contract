// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./StrategyManagerStorage.sol";
import "../../libraries/EIP1271SignatureUtils.sol";
import "../../libraries/ETHAddress.sol";
import { IL2Pauser } from "../../access/interface/IL2Pauser.sol";
import {L2Base} from "./L2Base.sol";

/// @title StrategyManager - L2 策略管理合约
/// @notice 管理用户在各个策略中的份额,处理存款、取款和份额转移
/// @dev 用户通过此合约将资产存入不同的策略(Strategy),获得相应的份额
/// 策略份额可以被委托给运营商,也可以被提取为代币
contract StrategyManager is
    L2Base,
    StrategyManagerStorage
{
    using SafeERC20 for IERC20;

    /// @notice 存款暂停标志位
    uint8 internal constant PAUSED_DEPOSITS = 0;

    /// @notice 合约部署时的原始链 ID,用于域分隔符计算
    uint256 internal immutable ORIGINAL_CHAIN_ID;

    /// @notice 仅策略白名单管理员可调用
    modifier onlyStrategyWhitelister() {
        require(
            msg.sender == strategyWhitelister,
            "StrategyManager.onlyStrategyWhitelister: not the strategyWhitelister"
        );
        _;
    }

    /// @notice 仅白名单策略可调用
    /// @param strategy 策略合约地址
    modifier onlyStrategiesWhitelistedForDeposit(address strategy) {
        require(
            strategyIsWhitelistedForDeposit[strategy],
            "StrategyManager.onlyStrategiesWhitelistedForDeposit: strategy not whitelisted"
        );
        _;
    }
    /*******************************************************************************
                            INITIALIZING FUNCTIONS
    *******************************************************************************/

    /// @notice 构造函数,禁用初始化器并记录原始链 ID
    constructor()  {
        _disableInitializers();
        ORIGINAL_CHAIN_ID = block.chainid;
    }

    /// @notice 初始化策略管理合约
    /// @param initialOwner 初始所有者地址
    /// @param initialStrategyWhitelister 初始策略白名单管理员地址
    function initialize(
        address initialOwner,
        address initialStrategyWhitelister
    ) external initializer {
        _DOMAIN_SEPARATOR = _calculateDomainSeparator();
        _setStrategyWhitelister(initialStrategyWhitelister);
        __L2Base_init(initialOwner);
    }

    /*******************************************************************************
                        EXTERNAL FUNCTIONS
    *******************************************************************************/

    /// @notice 用户存入 WETH 到指定策略
    /// @dev 用户需要先 approve 此合约可以转移其 WETH
    /// @param strategy 策略合约地址
    /// @param weth WETH 代币合约地址
    /// @param amount 存入的 WETH 数量
    /// @return shares 用户获得的策略份额
    function depositWETHIntoStrategy(
        address strategy,
        IERC20 weth,
        uint256 amount
    ) external nonReentrant returns (uint256 shares) {
        require(getL2Pauser().isStrategyDeposit(), "StrategyManager.t.sol:depositWETHIntoStrategy paused");

        shares = _depositWETHIntoStrategy(msg.sender, strategy, weth, amount);
    }

    /// @notice 用户存入 ETH 到指定策略
    /// @dev 用户需要随交易发送 ETH
    /// @param strategy 策略合约地址
    /// @return shares 用户获得的策略份额
    function depositETHIntoStrategy(
        address strategy
    ) external payable nonReentrant returns (uint256 shares) {

        require(getL2Pauser().isStrategyDeposit(), "StrategyManager.t.sol:depositETHIntoStrategy paused");

        shares = _depositETHIntoStrategy(msg.sender, strategy);

    }

    /// @notice 使用签名代表其他用户存入 WETH 到策略
    /// @dev 实现 EIP-712 签名存款,允许第三方代付 gas
    /// @param strategy 策略合约地址
    /// @param weth WETH 代币合约地址
    /// @param amount 存入的 WETH 数量
    /// @param staker 质押者地址(签名者)
    /// @param expiry 签名过期时间戳
    /// @param signature 质押者的签名
    /// @return shares 质押者获得的策略份额
    function depositWETHIntoStrategyWithSignature(
        address strategy,
        IERC20 weth,
        uint256 amount,
        address staker,
        uint256 expiry,
        bytes memory signature
    ) external nonReentrant returns (uint256 shares) {
        require(getL2Pauser().isStrategyDeposit(), "StrategyManager:depositWETHIntoStrategyWithSignature paused");
        require(
            !thirdPartyTransfersForbidden[strategy],
            "StrategyManager.depositIntoStrategyWithSignature: third transfers disabled"
        );
        require(expiry >= block.timestamp, "StrategyManager.depositIntoStrategyWithSignature: signature expired");

        // 获取并递增 nonce
        uint256 nonce = nonces[staker];
        bytes32 structHash = keccak256(abi.encode(DEPOSIT_TYPEHASH, staker, strategy, weth, amount, nonce, expiry));
        unchecked {
            nonces[staker] = nonce + 1;
        }

        // 验证 EIP-712 签名
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));

        EIP1271SignatureUtils.checkSignature_EIP1271(staker, digestHash, signature);

        shares = _depositWETHIntoStrategy(staker, strategy, weth, amount);
    }

    /// @notice 使用签名代表其他用户存入 ETH 到策略
    /// @dev 实现 EIP-712 签名存款,允许第三方代付 gas
    /// @param strategy 策略合约地址
    /// @param amount 存入的 ETH 数量
    /// @param staker 质押者地址(签名者)
    /// @param expiry 签名过期时间戳
    /// @param signature 质押者的签名
    /// @return shares 质押者获得的策略份额
    function depositETHIntoStrategyWithSignature(
        address strategy,
        uint256 amount,
        address staker,
        uint256 expiry,
        bytes memory signature
    ) external nonReentrant returns (uint256 shares) {
        require(getL2Pauser().isStrategyDeposit(), "StrategyManager:depositETHIntoStrategyWithSignature paused");
        require(
            !thirdPartyTransfersForbidden[strategy],
            "StrategyManager.depositIntoStrategyWithSignature: third transfers disabled"
        );
        require(expiry >= block.timestamp, "StrategyManager.depositIntoStrategyWithSignature: signature expired");

        // 获取并递增 nonce
        uint256 nonce = nonces[staker];
        bytes32 structHash = keccak256(abi.encode(DEPOSIT_TYPEHASH, staker, strategy, amount, nonce, expiry));
        unchecked {
            nonces[staker] = nonce + 1;
        }

        // 验证 EIP-712 签名
        bytes32 digestHash = keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));

        EIP1271SignatureUtils.checkSignature_EIP1271(staker, digestHash, signature);

        shares = _depositETHIntoStrategy(staker, strategy);
    }

    /// @notice 移除质押者在策略中的份额
    /// @dev 仅 DelegationManager 可调用,用于提款队列处理
    /// @param staker 质押者地址
    /// @param strategy 策略合约地址
    /// @param shares 要移除的份额数量
    function removeShares(
        address staker,
        address strategy,
        uint256 shares
    ) external onlyDelegationManager {
        _removeShares(staker, strategy, shares);
    }

    /// @notice 增加质押者在策略中的份额
    /// @dev 仅 DelegationManager 可调用,用于完成提款队列时恢复份额
    /// @param staker 质押者地址
    /// @param weth WETH 代币合约地址
    /// @param strategy 策略合约地址
    /// @param shares 要增加的份额数量
    function addShares(
        address staker,
        IERC20 weth,
        address strategy,
        uint256 shares
    ) external onlyDelegationManager {
        _addShares(staker, weth, strategy, shares);
    }

    /// @notice 将份额提取为 WETH 代币
    /// @dev 仅 DelegationManager 可调用,用于完成提款队列
    /// @param recipient 接收 WETH 的地址
    /// @param strategy 策略合约地址
    /// @param shares 要提取的份额数量
    /// @param weth WETH 代币合约地址
    function withdrawSharesAsWeth(
        address recipient,
        address strategy,
        uint256 shares,
        IERC20 weth
    ) external onlyDelegationManager {
        // 检查 L1 返还的份额是否充足
        uint256 l1BackShares = stakerStrategyL1BackShares[recipient][strategy];
        require(
            l1BackShares >= shares,
            "StrategyManager.withdrawSharesAsWeth: The Layer1 of DETH hasn't been completely released yet"
        );
        getStrategy(strategy).withdraw(recipient, weth, shares);
    }

    /// @notice 查询用户在指定策略中的份额
    /// @param user 用户地址
    /// @param strategy 策略合约地址
    /// @return shares 用户的份额数量
    function getStakerStrategyShares(address user, address strategy) external view returns (uint256 shares) {
        return stakerStrategyShares[user][strategy];
    }



    /// @notice 设置策略是否禁止第三方转账
    /// @dev 仅策略白名单管理员可调用
    /// @param strategy 策略合约地址
    /// @param value true 表示禁止,false 表示允许
    function setThirdPartyTransfersForbidden(
        address strategy,
        bool value
    ) external onlyStrategyWhitelister {
        _setThirdPartyTransfersForbidden(strategy, value);
    }

    /// @notice 设置新的策略白名单管理员
    /// @dev 仅所有者可调用
    /// @param newStrategyWhitelister 新的白名单管理员地址
    function setStrategyWhitelister(address newStrategyWhitelister) external onlyOwner {
        _setStrategyWhitelister(newStrategyWhitelister);
    }

    /// @notice 批量添加策略到存款白名单
    /// @dev 仅策略白名单管理员可调用
    /// @param strategiesToWhitelist 要添加的策略地址数组
    /// @param thirdPartyTransfersForbiddenValues 对应的第三方转账禁止标志数组
    function addStrategiesToDepositWhitelist(
        address[] calldata strategiesToWhitelist,
        bool[] calldata thirdPartyTransfersForbiddenValues
    ) external onlyStrategyWhitelister {
        require(
            strategiesToWhitelist.length == thirdPartyTransfersForbiddenValues.length,
            "StrategyManager.addStrategiesToDepositWhitelist: array lengths do not match"
        );
        uint256 strategiesToWhitelistLength = strategiesToWhitelist.length;
        for (uint256 i = 0; i < strategiesToWhitelistLength; ) {
            if (!strategyIsWhitelistedForDeposit[strategiesToWhitelist[i]]) {
                strategyIsWhitelistedForDeposit[strategiesToWhitelist[i]] = true;
                emit StrategyAddedToDepositWhitelist(strategiesToWhitelist[i]);
                _setThirdPartyTransfersForbidden(strategiesToWhitelist[i], thirdPartyTransfersForbiddenValues[i]);
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice 批量从存款白名单中移除策略
    /// @dev 仅策略白名单管理员可调用
    /// @param strategiesToRemoveFromWhitelist 要移除的策略地址数组
    function removeStrategiesFromDepositWhitelist(
        address[] calldata strategiesToRemoveFromWhitelist
    ) external onlyStrategyWhitelister {
        uint256 strategiesToRemoveFromWhitelistLength = strategiesToRemoveFromWhitelist.length;
        for (uint256 i = 0; i < strategiesToRemoveFromWhitelistLength; ) {
            if (strategyIsWhitelistedForDeposit[strategiesToRemoveFromWhitelist[i]]) {
                strategyIsWhitelistedForDeposit[strategiesToRemoveFromWhitelist[i]] = false;
                emit StrategyRemovedFromDepositWhitelist(strategiesToRemoveFromWhitelist[i]);
                _setThirdPartyTransfersForbidden(strategiesToRemoveFromWhitelist[i], false);
            }
            unchecked {
                ++i;
            }
        }
    }

    /*******************************************************************************
                         INTERNAL FUNCTIONS
    *******************************************************************************/

    /// @notice 内部函数: 增加质押者的策略份额
    /// @dev 如果是新策略,会添加到质押者的策略列表中
    /// @param staker 质押者地址
    /// @param weth WETH 代币合约地址(用于事件)
    /// @param strategy 策略合约地址
    /// @param shares 要增加的份额数量
    function _addShares(address staker, IERC20 weth, address strategy, uint256 shares) internal {
        require(staker != address(0), "StrategyManager._addShares: staker cannot be zero address");
        require(shares != 0, "StrategyManager._addShares: shares should not be zero!");

        // 如果是新策略,添加到质押者的策略列表
        if (stakerStrategyShares[staker][strategy] == 0) {
            require(
                stakerStrategyList[staker].length < MAX_STAKER_STRATEGY_LIST_LENGTH,
                "StrategyManager._addShares: deposit would exceed MAX_STAKER_STRATEGY_LIST_LENGTH"
            );
            stakerStrategyList[staker].push(strategy);
        }

        // 增加份额
        stakerStrategyShares[staker][strategy] += shares;

        emit Deposit(staker, weth, strategy, shares);
    }

    /// @notice 内部函数: 存入 WETH 到策略
    /// @dev 转移 WETH 到策略合约,计算并记录份额,更新委托状态
    /// @param staker 质押者地址
    /// @param strategy 策略合约地址
    /// @param weth WETH 代币合约地址
    /// @param amount 存入的 WETH 数量
    /// @return shares 质押者获得的策略份额
    function _depositWETHIntoStrategy(
        address staker,
        address strategy,
        IERC20 weth,
        uint256 amount
    ) internal onlyStrategiesWhitelistedForDeposit(strategy) returns (uint256 shares) {
        // 将 WETH 转到对应策略
        weth.safeTransferFrom(msg.sender, strategy, amount);
        // 将质押的 shares 计算出来,调用对应策略合约的 deposit 方法
        shares = getStrategy(strategy).deposit(weth, amount);
        // 将 shares 加给 staker
        _addShares(staker, weth, strategy, shares);
        // 若 staker 已经 delegate,将 staker 质押 shares 委托给对应的 operator
        getDelegationManager().increaseDelegatedShares(staker, strategy, shares);

        return shares;
    }

    /// @notice 内部函数: 存入 ETH 到策略
    /// @dev 转移 ETH 到策略合约,计算并记录份额,更新委托状态
    /// @param staker 质押者地址
    /// @param strategy 策略合约地址
    /// @return shares 质押者获得的策略份额
    function _depositETHIntoStrategy(
        address staker,
        address strategy
    ) internal onlyStrategiesWhitelistedForDeposit(strategy) returns (uint256 shares) {
        // 将 ETH 转入对应的 strategy
        (bool sent, ) = payable(strategy).call{value: msg.value}("");

        require(sent, "StrategyManager._depositETHIntoStrategy: send eth to strategy fail");
        // 将质押的 shares 计算出来,调用对应策略合约的 deposit 方法
        shares = getStrategy(strategy).deposit(IERC20(ETHAddress.EthAddress), msg.value);

        _addShares(staker, IERC20(ETHAddress.EthAddress), strategy, shares);

        getDelegationManager().increaseDelegatedShares(staker, strategy, shares);

        return shares;
    }

    /// @notice 内部函数: 移除质押者的策略份额
    /// @dev 减少份额,如果份额归零则从策略列表中移除该策略
    /// @param staker 质押者地址
    /// @param strategy 策略合约地址
    /// @param shareAmount 要移除的份额数量
    /// @return 份额是否已归零
    function _removeShares(
        address staker,
        address strategy,
        uint256 shareAmount
    ) internal returns (bool) {
        require(shareAmount != 0, "StrategyManager._removeShares: shareAmount should not be zero!");

        uint256 userShares = stakerStrategyShares[staker][strategy];

        require(shareAmount <= userShares, "StrategyManager._removeShares: shareAmount too high");
        unchecked {
            userShares = userShares - shareAmount;
        }

        stakerStrategyShares[staker][strategy] = userShares;

        // 如果份额归零,从策略列表中移除
        if (userShares == 0) {
            _removeStrategyFromStakerStrategyList(staker, strategy);

            return true;
        }
        return false;
    }

    /// @notice 内部函数: 从质押者的策略列表中移除策略
    /// @dev 使用交换删除法,将最后一个元素移到要删除的位置,然后 pop
    /// @param staker 质押者地址
    /// @param strategy 要移除的策略地址
    function _removeStrategyFromStakerStrategyList(
        address staker,
        address strategy
    ) internal {
        uint256 stratsLength = stakerStrategyList[staker].length;
        uint256 j = 0;
        // 查找策略在列表中的索引
        for (; j < stratsLength; ) {
            if (stakerStrategyList[staker][j] == strategy) {
                // 将最后一个元素移到当前位置
                stakerStrategyList[staker][j] = stakerStrategyList[staker][
                    stakerStrategyList[staker].length - 1
                    ];
                break;
            }
            unchecked { ++j; }
        }
        require(j != stratsLength, "StrategyManager._removeStrategyFromStakerStrategyList: strategy not found");
        // 删除最后一个元素
        stakerStrategyList[staker].pop();
    }

    /// @notice 内部函数: 设置策略的第三方转账禁止标志
    /// @param strategy 策略合约地址
    /// @param value 是否禁止第三方转账
    function _setThirdPartyTransfersForbidden(address strategy, bool value) internal {
        emit UpdatedThirdPartyTransfersForbidden(strategy, value);
        thirdPartyTransfersForbidden[strategy] = value;
    }

    /// @notice 内部函数: 设置策略白名单管理员
    /// @param newStrategyWhitelister 新的白名单管理员地址
    function _setStrategyWhitelister(address newStrategyWhitelister) internal {
        emit StrategyWhitelisterChanged(strategyWhitelister, newStrategyWhitelister);
        strategyWhitelister = newStrategyWhitelister;
    }

    // VIEW FUNCTIONS

    /// @notice 查询质押者的所有策略和对应份额
    /// @param staker 质押者地址
    /// @return 策略地址数组和对应的份额数组
    function getDeposits(address staker) external view returns (address[] memory, uint256[] memory) {
        uint256 strategiesLength = stakerStrategyList[staker].length;
        uint256[] memory shares = new uint256[](strategiesLength);

        for (uint256 i = 0; i < strategiesLength; ) {
            shares[i] = stakerStrategyShares[staker][stakerStrategyList[staker][i]];
            unchecked {
                ++i;
            }
        }
        return (stakerStrategyList[staker], shares);
    }

    /// @notice 查询质押者参与的策略数量
    /// @param staker 质押者地址
    /// @return 策略数量
    function stakerStrategyListLength(address staker) external view returns (uint256) {
        return stakerStrategyList[staker].length;
    }

    /// @notice 获取当前的域分隔符
    /// @dev 如果链 ID 发生变化(如分叉),重新计算域分隔符
    /// @return EIP-712 域分隔符
    function domainSeparator() public view returns (bytes32) {
        if (block.chainid == ORIGINAL_CHAIN_ID) {
            return _DOMAIN_SEPARATOR;
        } else {
            return _calculateDomainSeparator();
        }
    }

    /// @notice 内部函数: 计算 EIP-712 域分隔符
    /// @dev 用于防止跨链签名重放攻击
    /// @return 域分隔符
    function _calculateDomainSeparator() internal view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256(bytes("DappLink")), block.chainid, address(this)));
    }


    /// @notice 迁移 L1 返还的质押者份额
    /// @dev 仅 Relayer 可调用,用于记录从 L1 返还的份额
    /// @param staker 质押者地址
    /// @param strategy 策略合约地址
    /// @param shares 返还的份额数量
    /// @param l1UnStakeMessageNonce L1 解质押消息的 nonce
    /// @return 是否成功
    function migrateRelatedL1StakerShares(address staker, address strategy, uint256 shares, uint256 l1UnStakeMessageNonce) external onlyRelayer returns (bool) {
        stakerStrategyL1BackShares[staker][strategy] += shares;
        emit MigrateRelatedL1StakerShares(staker, strategy, shares, l1UnStakeMessageNonce);
        return true;
    }


    /// @notice 查询质押者的 L1 返还份额
    /// @param staker 质押者地址
    /// @param strategy 策略合约地址
    /// @return L1 返还的份额数量
    function getStakerStrategyL1BackShares(address staker, address strategy) external view returns (uint256) {
        return stakerStrategyL1BackShares[staker][strategy];
    }

    /// @notice 更新质押者的 L1 返还份额
    /// @dev 用于在提款时减少 L1 返还份额
    /// @param staker 质押者地址
    /// @param strategy 策略合约地址
    /// @param shares 要减少的份额数量
    function updateStakerStrategyL1BackShares(address staker, address strategy, uint256 shares) external onlyStrategiesWhitelistedForDeposit(strategy) {
        require(stakerStrategyL1BackShares[staker][strategy] >= shares, "StrategyManager: shares to remove is more than staker has");
        stakerStrategyL1BackShares[staker][strategy] -= shares;
    }


    /// @notice 在质押者之间转移策略份额
    /// @dev 用于处理 dETH 转账时的份额同步
    /// @param strategy 策略合约地址
    /// @param from 转出地址
    /// @param to 转入地址
    /// @param shares 转移的份额数量
    /// @return 是否成功
    function transferStakerStrategyShares(address strategy, address from, address to, uint256 shares) external returns (bool) {
        stakerStrategyShares[from][strategy] -= shares;
        stakerStrategyShares[to][strategy] += shares;
        return true;
    }




}