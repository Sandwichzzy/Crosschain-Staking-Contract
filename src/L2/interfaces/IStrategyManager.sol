// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IStrategyManager
 * @notice 策略管理器接口，定义质押策略的存款、提款和份额管理
 * @dev 管理用户在不同策略中的资产存款和份额(eth,和weth)
 */
interface IStrategyManager {

    /// @notice 当用户存入代币到策略时触发
    /// @param staker 质押者地址
    /// @param weth 存入的weth代币合约
    /// @param strategy 目标策略合约
    /// @param shares 获得的份额数量
    event Deposit(address staker, IERC20 weth, address strategy, uint256 shares);

    /// @notice 当策略的第三方转账限制被更新时触发
    /// @param strategy 策略合约
    /// @param value 新的限制值（true=禁止第三方转账，false=允许）
    event UpdatedThirdPartyTransfersForbidden(address strategy, bool value);

    /// @notice 当策略白名单管理员地址变更时触发
    /// @param previousAddress 之前的管理员地址
    /// @param newAddress 新的管理员地址
    event StrategyWhitelisterChanged(address previousAddress, address newAddress);

    /// @notice 当策略被添加到存款白名单时触发
    /// @param strategy 被添加的策略合约
    event StrategyAddedToDepositWhitelist(address strategy);

    /// @notice 当策略从存款白名单中移除时触发
    /// @param strategy 被移除的策略合约
    event StrategyRemovedFromDepositWhitelist(address strategy);

    /**
     * @notice 将weth代币存入指定策略
     * @param strategy 目标策略合约
     * @param weth 要存入的weth代币合约地址
     * @param amount 存入金额
     * @return shares 获得的策略份额数量
     * @dev 调用者需要先授权代币给本合约
     */
    function depositWETHIntoStrategy(address strategy, IERC20 weth, uint256 amount) external returns (uint256 shares);

    /**
     * @notice 将ETH存入指定策略
     * @param strategy 目标策略合约
     * @return shares 获得的策略份额数量
     */
    function depositETHIntoStrategy(address strategy) external payable returns (uint256 shares);


    /**
     * @notice 通过签名代表质押者存入weth代币（元交易）
     * @param strategy 目标策略合约
     * @param weth 要存入的weth代币合约地址
     * @param amount 存入金额
     * @param staker 质押者地址
     * @param expiry 签名过期时间戳
     * @param signature 质押者的EIP712签名
     * @return shares 获得的策略份额数量
     * @dev 允许第三方代表用户执行存款，用户需提供有效签名
     */
    function depositWETHIntoStrategyWithSignature(
        address strategy,
        IERC20 weth,
        uint256 amount,
        address staker,
        uint256 expiry,
        bytes memory signature
    ) external returns (uint256 shares);


    /**
    * @notice 通过签名代表质押者存入ETH
     * @param strategy 目标策略合约
     * @param amount 存入ETH金额
     * @param staker 质押者地址
     * @param expiry 签名过期时间戳
     * @param signature 质押者的EIP712签名
     * @return shares 获得的策略份额数量
     * @dev 允许第三方代表用户执行存款，用户需提供有效签名
     */
    function depositETHIntoStrategyWithSignature(
        address strategy,
        uint256 amount,
        address staker,
        uint256 expiry,
        bytes memory signature
    ) external returns (uint256 shares);

    /**
     * @notice 移除质押者在策略中的份额（仅限内部调用）
     * @param staker 质押者地址
     * @param strategy 策略合约
     * @param shares 要移除的份额数量
     * @dev 通常在提款或取消委托时调用
     */
    function removeShares(address staker, address strategy, uint256 shares) external;

    /**
     * @notice 为质押者增加策略份额（仅限内部调用）
     * @param staker 质押者地址
     * @param weth 代币合约
     * @param strategy 策略合约
     * @param shares 要增加的份额数量
     * @dev 通常在完成提款或迁移时调用
     */
    function addShares(address staker, IERC20 weth, address strategy, uint256 shares) external;

    /**
     * @notice 将策略份额提取为代币
     * @param recipient 接收代币的地址
     * @param strategy 策略合约
     * @param shares 要提取的份额数量
     * @param weth 要提取的weth代币合约地址
     * @dev 立即从策略中赎回份额并发送代币给接收者
     */
    function withdrawSharesAsWeth(address recipient, address strategy, uint256 shares, IERC20 weth) external;

    /**
     * @notice 查询质押者在特定策略中的份额
     * @param user 质押者地址
     * @param strategy 策略合约
     * @return shares 份额数量
     */
    function getStakerStrategyShares(address user, address strategy) external view returns (uint256 shares);

    /**
     * @notice 获取质押者的所有存款信息（策略和对应份额）
     * @param staker 质押者地址
     * @return 策略合约地址数组和对应的份额数量数组
     */
    function getDeposits(address staker) external view returns (address[] memory, uint256[] memory);


    /**
     * @notice 获取质押者参与的策略数量
     * @param staker 质押者地址
     * @return 策略数量
     */
    function stakerStrategyListLength(address staker) external view returns (uint256);

    /**
     * @notice 将策略添加到存款白名单（仅限白名单管理员）
     * @param strategiesToWhitelist 要添加的策略数组
     * @param thirdPartyTransfersForbiddenValues 每个策略是否禁止第三方转账
     */
    function addStrategiesToDepositWhitelist(
        address[] calldata strategiesToWhitelist,
        bool[] calldata thirdPartyTransfersForbiddenValues
    ) external;

    /**
     * @notice 从存款白名单中移除策略（仅限白名单管理员）
     * @param strategiesToRemoveFromWhitelist 要移除的策略数组
     */
    function removeStrategiesFromDepositWhitelist(address[] calldata strategiesToRemoveFromWhitelist) external;

    /**
     * @notice 获取策略白名单管理员地址
     * @return 管理员地址
     */
    function strategyWhitelister() external view returns (address);


    /**
     * @notice 查询策略是否禁止第三方转账
     * @param strategy 策略合约
     * @return 如果禁止第三方转账返回true，否则返回false
     */
    function thirdPartyTransfersForbidden(address strategy) external view returns (bool);



    function migrateRelatedL1StakerShares(address staker, address strategy, uint256 shares, uint256 l1UnStakeMessageNonce) external returns (bool);

    function getStakerStrategyL1BackShares(address staker, address strategy) external returns (uint256);

    function updateStakerStrategyL1BackShares(address staker, address strategy, uint256 shares) external;

    function transferStakerStrategyShares(address strategy, address from, address to, uint256 shares) external returns (bool);
}