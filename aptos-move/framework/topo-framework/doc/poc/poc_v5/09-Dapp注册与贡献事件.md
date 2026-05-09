# 09 — Dapp 注册与贡献事件

本文档详细分析 `poc_registry` 和 `poc_contribution` 模块，涵盖 Dapp 应用注册、POC 白名单管理和可信贡献发放路径。

**源文件**：`poc/poc_registry.move`, `poc/poc_contribution.move`

## 9.1 POC 贡献体系总览

```mermaid
graph TB
    subgraph "Dapp 应用"
        APP[应用合约]
        CUSTODY[托管账户<br/>持有股权代币]
    end

    subgraph "链上框架"
        PR[poc_registry<br/>注册中心]
        PC[poc_contribution<br/>可信贡献发放]
    end

    subgraph "链下服务"
        IDX[索引器<br/>扫描 ContributionEvent]
        OP[Operator<br/>计算算力]
        PS[PowerStore<br/>上传算力]
    end

    subgraph "用户"
        U[贡献者]
    end

    APP -->|"1. register_app"| PR
    APP -->|"2. grant_equity_with_contribution"| PC
    PC -->|"3. 校验身份+资格"| PR
    PC -->|"4. 转账股权代币"| U
    PC -->|"5. emit ContributionEvent"| IDX
    IDX -->|"6. 聚合贡献数据"| OP
    OP -->|"7. stage_batch_update"| PS
```

## 9.2 Dapp 注册流程

### 注册入口

```mermaid
sequenceDiagram
    participant ADMIN as App Admin
    participant PR as poc_registry
    participant FA as Fungible Asset

    ADMIN->>PR: register_app(app_address, equity_token, custody, metadata_uri)

    PR->>PR: 校验 admin 未重复注册
    PR->>PR: 校验 app_address 全局唯一
    PR->>PR: 校验 custody_address 全局唯一
    PR->>PR: 校验 equity_token 全局唯一
    PR->>FA: address_to_object<Metadata>(equity_token)
    FA-->>PR: 校验是合法 FA Metadata

    PR->>PR: 创建 AppInfo
    Note over PR: app_state = ACTIVE<br/>poc_listing_status = REGISTERED

    PR->>PR: 写入 4 张映射表
    PR->>PR: emit AppRegisteredEvent
```

### 四维度反查索引

```mermaid
graph LR
    subgraph Registry
        APPS["apps<br/>admin → AppInfo"]
        A2A["app_address_to_admin<br/>合约地址 → admin"]
        C2A["custody_to_admin<br/>托管地址 → admin"]
        E2A["equity_to_admin<br/>代币地址 → admin"]
    end

    Q1["通过 admin 查询"] --> APPS
    Q2["通过合约地址查询"] --> A2A --> APPS
    Q3["通过托管地址查询"] --> C2A --> APPS
    Q4["通过代币地址查询"] --> E2A --> APPS
```

**全局唯一性约束**：
- 一个 admin 只能注册一个应用
- `app_address`、`equity_token_address`、`custody_address` 各自全局唯一
- 防止不同应用共用同一地址导致的身份混淆

## 9.3 应用状态管理

### 双层状态模型

```mermaid
graph TB
    subgraph "应用自身状态（admin 管控）"
        AS1[ACTIVE<br/>运行中]
        AS2[PAUSED<br/>暂停]
        AS3[STOPPED<br/>永久停运]

        AS1 -->|pause_app| AS2
        AS2 -->|resume_app| AS1
        AS1 -->|stop_app| AS3
        AS2 -->|stop_app| AS3
    end

    subgraph "POC 纳入状态（framework/DAO 管控）"
        PS1[REGISTERED<br/>已注册]
        PS2[WHITELISTED<br/>白名单]
        PS3[SUSPENDED<br/>挂起]

        PS1 -->|whitelist_app_for_poc| PS2
        PS2 -->|suspend_poc_listing| PS3
        PS3 -->|set_poc_listing_status| PS2
        PS2 -->|"变更 equity_token"| PS1
    end
```

### POC 资格判定

应用必须同时满足两个条件才有资格发出可信贡献事件：

```move
public fun is_app_eligible_for_poc(app_admin: address): bool {
    let info = get_app_info(app_admin);
    info.app_state == APP_STATE_ACTIVE &&
        info.poc_listing_status == POC_LISTING_STATUS_WHITELISTED
}
```

| app_state | poc_listing_status | 有资格? |
|-----------|-------------------|---------|
| ACTIVE | WHITELISTED | 是 |
| ACTIVE | REGISTERED | 否 |
| ACTIVE | SUSPENDED | 否 |
| PAUSED | WHITELISTED | 否 |
| STOPPED | 任意 | 否 |

### 股权代币变更的安全重置

```mermaid
sequenceDiagram
    participant ADMIN as App Admin
    participant PR as poc_registry

    Note over PR: 当前状态: WHITELISTED

    ADMIN->>PR: update_equity_token_address(new_token)
    PR->>PR: 更新 equity_token 映射
    PR->>PR: poc_listing_status → REGISTERED
    PR->>PR: emit AppEquityTokenUpdatedEvent
    PR->>PR: emit AppPocListingStatusChangedEvent

    Note over PR: 需要 framework 重新审核<br/>才能恢复 WHITELISTED
```

**设计意图**：核心资产标识变了，之前的审计假设可能不再成立。

## 9.4 可信贡献发放

### grant_equity_with_contribution

这是 Dapp 发出平台认可的贡献事件的唯一入口。

```mermaid
flowchart TD
    A["grant_equity_with_contribution<br/>(app_signer, custody_actor, contributor, amount)"] --> B{amount > 0?}
    B -->|否| ERR["abort EZERO_AMOUNT"]
    B -->|是| C[从 registry 读取 equity_token]

    C --> D["transfer_assert_minimum_deposit<br/>custody → contributor"]
    D --> E{转账成功?}
    E -->|否| ABORT["交易失败（abort）"]
    E -->|是| F{"is_app_eligible_for_poc(admin)?"}

    F -->|否| DONE1["转账完成，不发事件"]
    F -->|是| G{"custody_actor == registered_custody?"}
    G -->|否| DONE1
    G -->|是| H["emit ContributionEvent"]
    H --> DONE2["转账完成 + 事件发出"]
```

### 核心设计原则：不干涉应用主业务

```
转账失败 → 交易失败（转账本身的错误仍会 abort）
转账成功但校验不通过 → 转账生效，不发事件
转账成功且校验通过 → 转账生效，发出 ContributionEvent
```

**为什么这样设计**：
- 股权代币转账是应用的核心业务，不应因 POC 校验失败而阻断
- ContributionEvent 只是 POC 算力体系的信号，不影响实际资产流转
- 应用可以在不满足 POC 条件时正常运营，只是贡献不计入算力

### transfer_assert_minimum_deposit

```move
primary_fungible_store::transfer_assert_minimum_deposit(
    custody_actor,  // 转出方签名者
    metadata,       // 股权代币 Metadata
    contributor,    // 接收方地址
    equity_amount,  // 转账金额
    equity_amount,  // 最小到账金额断言
);
```

**为什么使用 minimum_deposit 断言**：
- 某些 FA 可能带 dispatchable hook、手续费或特殊存取逻辑
- 平台认可的贡献金额必须等于用户实际收到的最小金额
- 防止 `ContributionEvent.equity_amount` 大于真实到账量

### ContributionEvent

```move
struct ContributionEvent has drop, store {
    contributor: address,           // 贡献者地址
    equity_token: Object<Metadata>, // 股权代币对象
    equity_amount: u64,             // 发放金额
    app_address: address,           // 应用合约地址
}
```

**可信性来源**：
1. 事件由 `poc_contribution` 模块发出（非应用自行 emit）
2. 事件只在真实转账成功后发出
3. 关键资产参数由注册表给出，非外部传入
4. 链下索引器可通过同交易的 FA 转账事实做交叉验证

## 9.5 调用方式设计

`grant_equity_with_contribution` 是 `public fun`（而非 `entry fun`），Dapp 需要在自己的 entry fun 中调用：

```mermaid
sequenceDiagram
    participant U as 用户
    participant APP as Dapp Entry Fun
    participant PC as poc_contribution

    U->>APP: 调用应用业务入口
    APP->>APP: 完成自身业务校验
    APP->>APP: 生成 app_signer（资源账户）
    APP->>APP: 生成 custody_actor（托管账户）
    APP->>PC: grant_equity_with_contribution<br/>(app_signer, custody_actor, user, amount)
    PC->>PC: 转账 + 校验 + 条件发事件
```

**为什么不是 entry fun**：
- 链下索引器可以通过交易 payload 的入口模块地址做应用归因
- 如果是 entry fun，所有应用的贡献交易都会显示为 `poc_contribution::grant_equity_with_contribution`
- 作为 public fun，交易入口是应用自己的模块，便于区分不同应用的贡献

## 9.6 信息变更接口

| 函数 | 调用者 | 效果 |
|------|--------|------|
| `update_app_address(new)` | admin | 更新合约部署地址 |
| `update_equity_token_address(new)` | admin | 更新股权代币地址 + 重置 POC 状态 |
| `update_custody_address(new)` | admin | 更新托管地址 |
| `pause_app()` | admin | 暂停应用 |
| `resume_app()` | admin | 恢复应用（STOPPED 不可恢复） |
| `stop_app()` | admin | 永久停运（不可逆） |
| `whitelist_app_for_poc(admin)` | framework | 加入 POC 白名单 |
| `suspend_poc_listing(admin)` | framework | 挂起 POC 资格 |
| `set_poc_listing_status(admin, status)` | framework | 设置任意 POC 状态 |

## 9.7 事件索引

| 事件 | 触发时机 | 关键字段 |
|------|---------|---------|
| `AppRegisteredEvent` | `register_app` | admin, app_address, equity_token, custody |
| `AppAddressUpdatedEvent` | `update_app_address` | admin, old, new |
| `AppEquityTokenUpdatedEvent` | `update_equity_token_address` | admin, old, new |
| `AppCustodyUpdatedEvent` | `update_custody_address` | admin, old, new |
| `AppStateChangedEvent` | `pause/resume/stop_app` | admin, old_state, new_state |
| `AppPocListingStatusChangedEvent` | POC 状态变更 | admin, old_status, new_status |
| `ContributionEvent` | `grant_equity_with_contribution` | contributor, equity_token, amount, app_address |

## 9.8 从贡献到算力的完整链路

```mermaid
graph LR
    subgraph "链上"
        CE[ContributionEvent<br/>contributor, amount, app]
    end

    subgraph "链下索引器"
        IDX[扫描 ContributionEvent]
        AGG[按用户聚合贡献]
        CALC[算力计算引擎]
    end

    subgraph "链上算力存储"
        PS[PowerStore]
        SR[StakingRegistry]
    end

    CE --> IDX
    IDX --> AGG
    AGG --> CALC
    CALC -->|"stage_batch_update"| PS
    PS -->|"get_user_committed_power"| SR
    SR -->|"effective_power"| VP[验证者投票权]
```

**链下计算的灵活性**：
- 算力计算逻辑完全在链下，可以灵活调整
- 不同应用的贡献可以有不同的权重
- 可以引入时间衰减、反作弊等复杂逻辑
- 链上只存储最终结果，保持简洁
