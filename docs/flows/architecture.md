# 跨链质押协议 - 系统架构

## 📋 目录

- [整体架构图](#整体架构图)
- [L1 层架构](#l1-层架构)
- [L2 层架构](#l2-层架构)
- [桥接层架构](#桥接层架构)
- [核心数据流](#核心数据流)
- [关键交互流程](#关键交互流程)

---

## 整体架构图

```mermaid
graph TB
    subgraph "L2 层 (Scroll/Arbitrum等)"
        L2User[用户]
        L2PoolManager[L2PoolManager<br/>资金池管理]
        StrategyManager[StrategyManager<br/>策略管理]
        DelegationManager[DelegationManager<br/>委托管理]
        Strategy[Strategy<br/>策略合约]
        L1RewardManager[L1RewardManager<br/>L1收益管理]
        L2RewardManager[L2RewardManager<br/>L2代币奖励]
        L2Pauser[L2Pauser<br/>暂停控制]
        L2Locator[L2Locator<br/>服务定位器]
    end

    subgraph "桥接层"
        L1Bridge[L1 TokenBridge<br/>L1桥接合约]
        L2Bridge[L2 TokenBridge<br/>L2桥接合约]
        MessageManager[MessageManager<br/>消息管理]
        Relayer[Relayer<br/>中继者]
    end

    subgraph "L1 层 (以太坊主网)"
        L1User[用户]
        L1PoolManager[L1PoolManager<br/>资金池管理]
        StakingManager[StakingManager<br/>质押管理]
        DETH[dETH Token<br/>质押凭证]
        UnstakeRequestsManager[UnstakeRequestsManager<br/>解质押管理]
        OracleManager[OracleManager<br/>预言机管理]
        ReturnsAggregator[ReturnsAggregator<br/>收益聚合]
        ReturnsReceiver[ReturnsReceiver<br/>收益接收器]
        L1Pauser[L1Pauser<br/>暂停控制]
        L1Locator[L1Locator<br/>服务定位器]
        DepositContract[Beacon Chain<br/>Deposit Contract<br/>信标链存款合约]
    end

    subgraph "链下服务"
        Oracle[Oracle Updater<br/>预言机更新者]
        ValidatorNode[Validator Nodes<br/>验证者节点]
    end

    %% L2 用户交互
    L2User -->|1. 存入ETH/策略| StrategyManager
    L2User -->|2. 委托| DelegationManager
    L2User -->|3. 解委托| DelegationManager
    L2User -->|4. 申领L1奖励| L1RewardManager
    L2User -->|5. 申领L2奖励| L2RewardManager

    %% L2 内部交互
    StrategyManager --> Strategy
    DelegationManager --> StrategyManager
    DelegationManager --> Strategy
    L1RewardManager --> StrategyManager
    L2RewardManager --> StrategyManager
    L2RewardManager --> DelegationManager

    %% 桥接通信
    L2PoolManager <-->|跨链消息| L2Bridge
    L2Bridge <-->|Relayer中继| Relayer
    Relayer <-->|中继消息| L1Bridge
    L1Bridge <-->|跨链消息| L1PoolManager

    %% L1 用户交互
    L1User -->|存入ETH| L1PoolManager
    L1User -->|转账dETH| DETH

    %% L1 质押流程
    L1PoolManager -->|触发质押| StakingManager
    StakingManager -->|铸造| DETH
    StakingManager -->|分配ETH| DepositContract

    %% 预言机流程
    ValidatorNode -->|验证者状态| Oracle
    Oracle -->|提交记录| OracleManager
    OracleManager -->|验证通过| ReturnsAggregator
    ReturnsReceiver -->|接收提款| ReturnsAggregator

    %% 收益分发
    ReturnsAggregator -->|CL收益| StakingManager
    ReturnsAggregator -->|EL收益桥接| L1Bridge
    L1Bridge -->|中继| Relayer
    Relayer -->|最终化| L2Bridge
    L2Bridge -->|存入| L1RewardManager

    %% 解质押流程
    UnstakeRequestsManager -->|管理请求| StakingManager
    StakingManager -->|销毁dETH| DETH
    StakingManager -->|桥接ETH| L1Bridge

    %% 定位器
    L1Locator -.->|提供地址| StakingManager
    L1Locator -.->|提供地址| OracleManager
    L1Locator -.->|提供地址| ReturnsAggregator
    L2Locator -.->|提供地址| StrategyManager
    L2Locator -.->|提供地址| DelegationManager

    %% 暂停控制
    L1Pauser -.->|暂停| StakingManager
    L1Pauser -.->|暂停| OracleManager
    L2Pauser -.->|暂停| StrategyManager
    L2Pauser -.->|暂停| DelegationManager

    style L2User fill:#e1f5ff
    style L1User fill:#e1f5ff
    style Relayer fill:#fff4e1
    style Oracle fill:#fff4e1
    style ValidatorNode fill:#fff4e1
    style DepositContract fill:#f0f0f0
```

---

## L1 层架构

### 核心合约关系图

```mermaid
graph LR
    subgraph "L1 Core Contracts"
        StakingManager[StakingManager<br/>质押管理中心]
        DETH[dETH Token<br/>ERC20质押凭证]
        UnstakeRequestsManager[UnstakeRequestsManager<br/>解质押请求队列]
        OracleManager[OracleManager<br/>预言机验证]
        ReturnsAggregator[ReturnsAggregator<br/>收益处理中心]
        ReturnsReceiver[ReturnsReceiver<br/>提款接收器]
    end

    subgraph "Infrastructure"
        L1PoolManager[L1PoolManager<br/>资金池]
        L1Pauser[L1Pauser<br/>暂停器]
        L1Locator[L1Locator<br/>地址簿]
        L1Bridge[TokenBridge<br/>跨链桥]
    end

    subgraph "External"
        DepositContract[Beacon Deposit<br/>信标链存款合约]
        ValidatorNodes[Validators<br/>验证者节点群]
    end

    %% 质押流程
    L1PoolManager -->|质押ETH| StakingManager
    StakingManager -->|铸造| DETH
    StakingManager -->|存入32 ETH| DepositContract
    DepositContract -->|激活| ValidatorNodes

    %% 收益流程
    ValidatorNodes -->|提款| ReturnsReceiver
    ReturnsReceiver -->|转发收益| ReturnsAggregator
    OracleManager -->|触发处理| ReturnsAggregator
    ReturnsAggregator -->|CL收益| StakingManager
    ReturnsAggregator -->|EL收益| L1Bridge

    %% 解质押流程
    StakingManager -->|创建请求| UnstakeRequestsManager
    UnstakeRequestsManager -->|分配ETH| StakingManager
    StakingManager -->|销毁| DETH
    StakingManager -->|桥接ETH| L1Bridge

    %% 依赖关系
    StakingManager -.->|查询地址| L1Locator
    OracleManager -.->|查询地址| L1Locator
    ReturnsAggregator -.->|查询地址| L1Locator

    L1Pauser -.->|控制暂停| StakingManager
    L1Pauser -.->|控制暂停| OracleManager

    style StakingManager fill:#ffcccc
    style DETH fill:#ccffcc
    style OracleManager fill:#ccccff
    style ReturnsAggregator fill:#ffccff
```

### L1 合约职责表

| 合约 | 主要职责 | 核心状态变量 |
|------|----------|-------------|
| **StakingManager** | ETH汇聚、dETH铸造/销毁、验证者启动 | `totalDepositedInValidators`<br/>`numInitiatedValidators`<br/>`unallocatedETH`<br/>`allocatedETHForDeposits`<br/>`unStakeMessageNonce` |
| **DETH** | 质押凭证代币、转账触发跨链 | `totalSupply`<br/>`balances`<br/>`dETHToETH` 汇率 |
| **UnstakeRequestsManager** | 解质押请求队列、申领管理 | `l2ChainStrategyAmount`<br/>`dEthLockedAmount`<br/>`l2ChainStrategyBlockNumber`<br/>`allocatedETHForClaims`<br/>`latestCumulativeETHRequested` |
| **OracleManager** | 验证者状态验证、记录管理 | `_records[]`<br/>`hasPendingUpdate`<br/>`finalizationBlockNumberDelta` |
| **ReturnsAggregator** | 收益分类处理、费用收取 | `feesBasisPoints`<br/>`protocolFeesAccrued` |
| **ReturnsReceiver** | 接收验证者提款 | (无状态,纯接收) |
| **L1PoolManager** | 接收用户存款、触发桥接 | 资金池余额 |
| **L1Pauser** | 暂停控制 | 暂停状态位 |
| **L1Locator** | 地址簿 | 所有核心合约地址 |

---

## L2 层架构

### 核心合约关系图

```mermaid
graph TB
    subgraph "L2 Core Contracts"
        StrategyManager[StrategyManager<br/>策略&份额管理]
        DelegationManager[DelegationManager<br/>委托&运营商管理]
        Strategy[Strategy Contracts<br/>策略实现]
        L1RewardManager[L1RewardManager<br/>L1 ETH奖励分配]
        L2RewardManager[L2RewardManager<br/>L2 Token奖励分配]
    end

    subgraph "Infrastructure"
        L2PoolManager[L2PoolManager<br/>资金池]
        L2Pauser[L2Pauser<br/>暂停器]
        L2Locator[L2Locator<br/>地址簿]
        L2Bridge[TokenBridge<br/>跨链桥]
    end

    subgraph "Users & Roles"
        Staker[质押者 Staker]
        Operator[运营商 Operator]
        Admin[管理员]
    end

    %% 用户交互
    Staker -->|存入ETH/WETH| StrategyManager
    Staker -->|委托| DelegationManager
    Operator -->|注册| DelegationManager
    Staker -->|申领L1奖励| L1RewardManager
    Staker -->|申领L2奖励| L2RewardManager
    Operator -->|申领L2奖励| L2RewardManager

    %% 内部交互
    StrategyManager -->|存款/取款| Strategy
    DelegationManager -->|增加份额| StrategyManager
    DelegationManager -->|减少份额| StrategyManager
    DelegationManager -->|记录运营商份额| Strategy

    %% 奖励管理
    L1RewardManager -->|查询份额| Strategy
    L1RewardManager -->|查询份额| StrategyManager
    L2RewardManager -->|查询份额| Strategy
    L2RewardManager -->|查询份额| StrategyManager
    L2RewardManager -->|查询运营商份额| DelegationManager

    %% 跨链通信
    L2PoolManager <-->|桥接消息| L2Bridge
    StrategyManager -->|同步份额| L2Bridge

    %% 依赖关系
    StrategyManager -.->|查询地址| L2Locator
    DelegationManager -.->|查询地址| L2Locator
    L1RewardManager -.->|查询地址| L2Locator
    L2RewardManager -.->|查询地址| L2Locator

    L2Pauser -.->|控制暂停| StrategyManager
    L2Pauser -.->|控制暂停| DelegationManager

    style Staker fill:#e1f5ff
    style Operator fill:#ffe1f5
    style StrategyManager fill:#ffcccc
    style DelegationManager fill:#ccffcc
    style L1RewardManager fill:#ccccff
    style L2RewardManager fill:#ffccff
```

### L2 合约职责表

| 合约 | 主要职责 | 核心状态变量 |
|------|----------|-------------|
| **StrategyManager** | 管理用户在各策略中的份额 | `stakerStrategyShares[staker][strategy]`<br/>`stakerStrategyL1BackShares[staker][strategy]`<br/>`stakerStrategyList[staker][]` |
| **DelegationManager** | 管理委托关系、运营商份额、提款队列 | `delegatedTo[staker]`<br/>`operatorShares[operator][strategy]`<br/>`cumulativeWithdrawalsQueued[staker]`<br/>`pendingWithdrawals[withdrawalRoot]` |
| **Strategy** | 具体策略实现(ETH/WETH/ERC20) | `totalShares`<br/>`shares[user]`<br/>`underlyingToken`<br/>`virtualEthBalance`<br/>`virtualWethBalance` |
| **L1RewardManager** | 分配L1桥接来的ETH奖励 | `L1RewardBalance`<br/>按份额比例分配 |
| **L2RewardManager** | 分配L2 DappLink代币奖励 | `stakerRewards[strategy]`<br/>`operatorRewards[operator]`<br/>`stakerPercent=92%` |
| **L2PoolManager** | 接收L2存款、触发L2→L1桥接 | 资金池余额 |
| **L2Pauser** | 暂停控制 | 暂停状态位 |
| **L2Locator** | 地址簿 | 所有核心合约地址 |

---

## 桥接层架构

### 跨链消息流

```mermaid
sequenceDiagram
    participant L1Contract as L1 合约
    participant L1Bridge as L1 TokenBridge
    participant MessageQueue as 消息队列
    participant Relayer as Relayer (链下)
    participant L2Bridge as L2 TokenBridge
    participant L2Contract as L2 合约

    Note over L1Contract,L2Contract: ETH 桥接 (L1 → L2)
    L1Contract->>L1Bridge: BridgeInitiateETH(to, amount)
    L1Bridge->>MessageQueue: 存储消息
    L1Bridge-->>L1Contract: emit BridgeInitiatedEvent

    Note over Relayer: 监听事件
    Relayer->>MessageQueue: 读取消息
    Relayer->>L2Bridge: claimMessage() + 提供proof
    L2Bridge->>L2Bridge: 验证消息和proof
    L2Bridge->>L2Contract: BridgeFinalizeETH(to, amount)
    L2Bridge-->>Relayer: emit BridgeFinalizedEvent

    Note over L1Contract,L2Contract: 质押消息 (L1 → L2)
    L1Contract->>L1Bridge: BridgeInitiateStakingMessage(staker, shares)
    L1Bridge->>MessageQueue: 存储质押消息
    Relayer->>L2Bridge: claimMessage()
    L2Bridge->>L2Contract: BridgeFinalizeStakingMessage(staker, shares)

    Note over L1Contract,L2Contract: 反向 ETH 桥接 (L2 → L1)
    L2Contract->>L2Bridge: BridgeInitiateETH(to, amount)
    L2Bridge->>MessageQueue: 存储消息
    Relayer->>L1Bridge: claimMessage()
    L1Bridge->>L1Contract: BridgeFinalizeETH(to, amount)
```

### 桥接合约职责

| 合约 | 层级 | 主要职责 |
|------|------|----------|
| **TokenBridgeBase** | 基类 | 提供桥接基础功能、事件定义 |
| **L1 TokenBridge** | L1 | 发起L1→L2消息、接收L2→L1消息 |
| **L2 TokenBridge** | L2 | 接收L1→L2消息、发起L2→L1消息 |
| **MessageManager** | 两侧 | 管理跨链消息队列、验证proof |

### 关键桥接函数

```solidity
// L1 → L2 ETH 桥接
function BridgeInitiateETH(
    uint256 sourceChainId,
    uint256 destChainId,
    address to
) external payable returns (bool);

function BridgeFinalizeETH(
    uint256 sourceChainId,
    uint256 destChainId,
    address to,
    uint256 amount,
    uint256 _fee,
    uint256 _nonce
) external payable onlyRole(ReLayer) returns (bool);

// L1 → L2 质押消息
function BridgeInitiateStakingMessage(
    address from,      // dETH 转出地址
    address to,        // dETH 接收地址
    uint256 shares     // 转移的份额数量
) external returns (bool);

function BridgeFinalizeStakingMessage(
    address shareAddress,      // Strategy 合约地址
    address from,
    address to,
    uint256 shares,
    uint256 stakeMessageNonce,
    uint256 gasLimit
) external returns (bool);

// 消息验证和申领
function claimMessage(
    uint256 sourceChainId,
    uint256 destChainId,
    address to,
    uint256 _fee,
    uint256 _value,
    uint256 _nonce
) external;
```

---

## 核心数据流

### 1. dETH 汇率计算

```mermaid
graph LR
    A[协议总控制 ETH] -->|分子| C[dETH 汇率]
    B[dETH 总供应量] -->|分母| C

    A1[StakingManager.totalDepositedInValidators] --> A
    A2[StakingManager.unallocatedETH] --> A
    A3[UnstakeRequestsManager.unallocatedETH] --> A
    A4[OracleRecord.currentTotalValidatorBalance] --> A

    B1[DETH.totalSupply] --> B

    C -->|应用于| D[质押时铸造 dETH 数量]
    C -->|应用于| E[解质押时销毁 dETH 数量]

    style A fill:#ffcccc
    style B fill:#ccffcc
    style C fill:#ccccff
```

**公式**:
```
dETH汇率 = 协议总控制ETH / dETH总供应量

铸造dETH数量 = 存入ETH数量 * (1 / dETH汇率)
销毁dETH数量 = 取回ETH数量 * (1 / dETH汇率)
```

### 2. L2 份额计算

```mermaid
graph TB
    subgraph "StrategyManager"
        A[用户存入 ETH/WETH]
        B[调用 Strategy.deposit]
        C[Strategy 计算份额]
        D[更新 stakerStrategyShares]
    end

    subgraph "Strategy 内部"
        E[获取当前汇率]
        F[份额 = 存入金额 / 汇率]
        G[更新 totalShares]
        H[更新 shares用户]
    end

    subgraph "DelegationManager"
        I[用户委托给运营商]
        J[增加 operatorShares]
        K[记录 delegatedTo]
    end

    A --> B
    B --> E
    E --> F
    F --> G
    F --> H
    H --> C
    C --> D
    D --> I
    I --> J
    I --> K

    style A fill:#e1f5ff
    style D fill:#ffcccc
    style J fill:#ccffcc
```

**公式**:
```
Strategy汇率 = Strategy持有的基础资产 / totalShares

新增份额 = 存入金额 / Strategy汇率

用户总份额 = stakerStrategyShares[staker][strategy]
运营商总份额 = Σ operatorShares[operator][strategy]
```

### 3. 奖励分配比例

```mermaid
graph TB
    subgraph "L1 收益分配"
        A[验证者奖励]
        B[ReturnsAggregator<br/>收取10%协议费]
        C[CL净收益<br/>90%]
        D[EL收益<br/>90%]
        E[StakingManager<br/>提高dETH汇率]
        F[桥接到L2<br/>L1RewardManager]
        G[用户按份额申领<br/>100%]
    end

    subgraph "L2 收益分配"
        H[DappLink Token充值]
        I[L2RewardManager<br/>按运营商份额计算]
        J[质押者部分<br/>92%]
        K[运营商部分<br/>8%]
        L[质押者按份额申领]
        M[运营商申领]
    end

    A --> B
    B --> C
    B --> D
    C --> E
    D --> F
    F --> G

    H --> I
    I --> J
    I --> K
    J --> L
    K --> M

    style B fill:#ffcccc
    style I fill:#ccffcc
    style J fill:#e1f5ff
    style K fill:#ffe1f5
```

---

## 关键交互流程

### 服务定位器模式 (Locator Pattern)

所有合约通过 Locator 获取其他合约地址,避免硬编码:

```solidity
// L1 合约获取依赖
interface IL1Locator {
    function stakingManager() external view returns (address);
    function dETH() external view returns (address);
    function oracleManager() external view returns (address);
    function returnsAggregator() external view returns (address);
    // ... 其他地址
}

// 使用示例
contract StakingManager is L1Base {
    function getUnstakeRequestsManager() internal view returns (IUnstakeRequestsManager) {
        return IUnstakeRequestsManager(getLocator().unStakingRequestsManager());
    }
}
```

**优点**:
- 解耦合约依赖
- 便于升级和测试
- 集中管理地址

### 暂停机制

```mermaid
graph TB
    subgraph "触发暂停"
        A[管理员手动触发]
        B[预言机检测异常]
        C[合理性检查失败]
    end

    subgraph "L1Pauser"
        D[pauseAll]
        E[质押暂停]
        F[解质押暂停]
        G[验证者启动暂停]
        H[预言机提交暂停]
    end

    subgraph "L2Pauser"
        I[pauseAll]
        J[策略存款暂停]
        K[委托暂停]
        L[解委托暂停]
        M[提款暂停]
    end

    A --> D
    B --> D
    C --> D

    D --> E
    D --> F
    D --> G
    D --> H

    A --> I
    I --> J
    I --> K
    I --> L
    I --> M

    style A fill:#ffcccc
    style B fill:#ffcccc
    style C fill:#ffcccc
    style D fill:#ff9999
    style I fill:#ff9999
```

### 角色权限矩阵

| 角色 | L1权限 | L2权限 | 说明 |
|------|--------|--------|------|
| **用户** | 在L1PoolManager存款 | 存入策略、委托、解委托、申领奖励 | 普通质押用户 |
| **Relayer** | 触发质押、触发申领、中继消息 | 中继消息、同步状态 | 跨链消息中继者 |
| **Oracle Updater** | 提交验证者状态记录 | - | 监控验证者并提交状态 |
| **Admin** | 设置参数、分配ETH、启动验证者、暂停 | 设置参数、暂停、管理运营商 | 系统管理员 |
| **Operator** | - | 注册为运营商、接受委托 | 验证者运营商 |
| **Oracle Manager** | 修改预言机记录 | - | 预言机管理者 |
| **Pending Resolver** | 接受/拒绝待处理更新 | - | 处理异常预言机记录 |

---

## 合约地址配置

### L1Locator 配置

```solidity
struct Config {
    address stakingManager;              // 质押管理合约
    address unStakingRequestsManager;    // 解质押请求管理
    address dETH;                        // dETH 代币
    address pauser;                      // L1 暂停器
    address returnsAggregator;           // 收益聚合器
    address oracleManager;               // 预言机管理
    address oracleQuorumManager;         // 预言机仲裁(暂未使用)
    address consensusLayerReceiver;      // CL 收益接收器
    address executionLayerReceiver;      // EL 收益接收器
    address dapplinkBridge;              // 桥接合约
    address depositContract;             // 信标链存款合约 (0x00000000219ab540356cBB839Cbe05303d7705Fa)
    address relayerAddress;              // Relayer 地址
}
```

### L2Locator 配置

```solidity
struct Config {
    address delegation;                  // 委托管理 (DelegationManager)
    address strategyManager;             // 策略管理
    address dapplinkToken;               // DappLink 代币
    address pauser;                      // L2 暂停器
    address slasher;                     // Slasher 合约
    address relayer;                     // Relayer 地址
    address l1RewardManager;             // L1 奖励管理
    address l2RewardManager;             // L2 奖励管理
}
```

---

## 总结

### 架构特点

1. **分层设计**: L1负责ETH质押和验证者管理,L2负责用户份额和委托管理
2. **服务定位器**: 通过Locator集中管理依赖,降低耦合
3. **桥接通信**: 使用消息桥接实现L1和L2的状态同步
4. **双重奖励**: L1的ETH奖励 + L2的代币奖励
5. **安全机制**: 暂停、预言机双层验证、Finalize检查、重入保护
6. **角色分离**: 用户、运营商、Relayer、预言机、管理员各司其职

### 关键设计模式

- **代理模式**: OpenZeppelin Upgradeable Contracts
- **服务定位器**: L1Locator / L2Locator
- **观察者模式**: 事件驱动的跨链消息
- **策略模式**: 多种Strategy实现(ETH/WETH/ERC20)
- **状态机**: 请求创建 → 等待完成 → 申领
- **RBAC**: 基于角色的访问控制

### 扩展性

- 可添加新的Strategy类型支持更多资产
- 可扩展到多条L2链
- 可接入多个预言机数据源
- 可调整费率和参数适应不同场景

---

**相关文档**:
- [质押流程详解](./1-staking-flow.md)
- [奖励分发详解](./2-rewards-flow.md)
- [解质押流程详解](./3-unstaking-flow.md)
- [取款完成详解](./4-withdrawal-flow.md)
