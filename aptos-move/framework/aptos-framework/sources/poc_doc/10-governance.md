# 10. 治理投票接口规范

## 10.1 投票模型变更总览

| 维度 | 当前模型 | 新模型 |
|------|---------|--------|
| 投票主体 | stake_pool address | user address |
| 投票权来源 | coin::value(stake) 或 delegated shares | staking_registry::get_effective_power(user) |
| 代投机制 | stake::get_delegated_voter() + delegation_pool::VoteDelegation | 无代投，用户直接投票 |
| 投票记录主键 | RecordKey { stake_pool, proposal_id } | RecordKey { voter, proposal_id } |
| 提案资格 | get_voting_power(stake_pool) >= required_proposer_stake + lockup 检查 | get_effective_power(proposer) >= required_proposer_power |
| 投票资格 | stake_pool_is_eligible_to_vote() (lockup >= proposal_expiration) | get_effective_power(voter) > 0 |
| 早期决议阈值 | coin::supply\<TopoCoin\>() / 2 + 1 | staking_registry::get_total_staked_power() / 2 + 1 |
| 总票权基数 | TopoCoin 总供应量 | active validator backing 的有效算力总和 |

## 10.2 数据结构变更

### RecordKey

```move
// 当前
struct RecordKey has copy, drop, store {
    stake_pool: address,
    proposal_id: u64,
}

// 新
struct RecordKey has copy, drop, store {
    voter: address,         // 用户地址
    proposal_id: u64,
}
```

### VotingRecordsV2

不变，仍为 `SmartTable<RecordKey, u64>`，记录每个 voter 在每个 proposal 上已使用的投票权。

### 废弃的结构

| 结构 | 所在模块 | 处理 |
|------|---------|------|
| `GovernanceRecords` | delegation_pool | 废弃 |
| `VoteDelegation` | delegation_pool | 废弃 |
| `DelegatedVotes` | delegation_pool | 废弃 |

## 10.3 函数签名变更

### vote_internal

```move
// 当前签名
fun vote_internal(
    voter: &signer,
    stake_pool: address,
    proposal_id: u64,
    voting_power: u64,
    should_pass: bool,
)

// 新签名：去掉 stake_pool 参数
fun vote_internal(
    voter: &signer,
    proposal_id: u64,
    voting_power: u64,
    should_pass: bool,
) {
    let voter_address = signer::address_of(voter);

    // 资格检查：有效算力 > 0
    let total_power = staking_registry::get_effective_power(voter_address);
    assert!(total_power > 0, error::invalid_argument(ENO_VOTING_POWER));

    // 剩余投票权 = 有效算力 - 已用投票权
    let record_key = RecordKey { voter: voter_address, proposal_id };
    let used = voting_records_v2.votes.borrow_with_default(record_key, 0);
    let remaining = total_power - *used;
    voting_power = math64::min(voting_power, remaining);
    assert!(voting_power > 0, error::invalid_argument(ENO_VOTING_POWER));

    // 投票
    voting::vote<GovernanceProposal>(@aptos_framework, proposal_id, voting_power, should_pass);

    // 记录已用投票权
    let used_mut = voting_records_v2.votes.borrow_mut_with_default(record_key, 0);
    *used_mut += voting_power;
}
```

### create_proposal_v2_impl

```move
// 当前签名
fun create_proposal_v2_impl(
    proposer: &signer,
    stake_pool: address,
    execution_hash: vector<u8>,
    metadata_location: vector<u8>,
    metadata_hash: vector<u8>,
    is_multi_step_proposal: bool,
)

// 新签名：去掉 stake_pool 参数
fun create_proposal_v2_impl(
    proposer: &signer,
    execution_hash: vector<u8>,
    metadata_location: vector<u8>,
    metadata_hash: vector<u8>,
    is_multi_step_proposal: bool,
) {
    let proposer_addr = signer::address_of(proposer);
    let proposer_power = staking_registry::get_effective_power(proposer_addr);
    assert!(
        proposer_power >= governance_config.required_proposer_stake,
        error::invalid_argument(EINSUFFICIENT_PROPOSER_STAKE)
    );
    // 移除 lockup 检查
    // 移除 stake::get_delegated_voter 检查

    let early_resolution_threshold = option::some(
        (staking_registry::get_total_staked_power() / 2) + 1
    );

    // ... 创建提案
}
```

### entry 函数适配

```move
// 当前
public entry fun vote(voter: &signer, stake_pool: address, proposal_id: u64, should_pass: bool)
public entry fun create_proposal(proposer: &signer, stake_pool: address, ...)
public entry fun create_proposal_v2(proposer: &signer, stake_pool: address, ...)
public entry fun partial_vote(voter: &signer, stake_pool: address, proposal_id: u64, voting_power: u64, should_pass: bool)

// 新：去掉 stake_pool 参数
public entry fun vote(voter: &signer, proposal_id: u64, should_pass: bool)
public entry fun create_proposal(proposer: &signer, ...)
public entry fun create_proposal_v2(proposer: &signer, ...)
public entry fun partial_vote(voter: &signer, proposal_id: u64, voting_power: u64, should_pass: bool)
```

### get_voting_power

```move
// 当前
public fun get_voting_power(stake_pool: address): u64

// 新
public fun get_voting_power(user: address): u64 {
    staking_registry::get_effective_power(user)
}
```

### get_remaining_voting_power

```move
// 当前
public fun get_remaining_voting_power(stake_pool: address, proposal_id: u64): u64

// 新
public fun get_remaining_voting_power(voter: address, proposal_id: u64): u64 {
    let total = staking_registry::get_effective_power(voter);
    let record_key = RecordKey { voter, proposal_id };
    let used = voting_records_v2.votes.borrow_with_default(record_key, 0);
    total - *used
}
```

## 10.4 事件结构变更

```move
// 当前
#[event]
struct Vote has drop, store {
    proposal_id: u64,
    voter: address,
    stake_pool: address,    // 移除
    num_votes: u64,
    should_pass: bool,
}

#[event]
struct CreateProposal has drop, store {
    proposer: address,
    stake_pool: address,    // 移除
    proposal_id: u64,
    execution_hash: vector<u8>,
    proposal_metadata: SimpleMap<String, vector<u8>>,
}

// 新
#[event]
struct Vote has drop, store {
    proposal_id: u64,
    voter: address,
    num_votes: u64,
    should_pass: bool,
}

#[event]
struct CreateProposal has drop, store {
    proposer: address,
    proposal_id: u64,
    execution_hash: vector<u8>,
    proposal_metadata: SimpleMap<String, vector<u8>>,
}
```

## 10.5 总票权基数定义域

`total_staked_power` 和投票资格的定义域必须一致：

```
total_staked_power = Σ get_effective_power(member)
                     for validator in active_validators
                     for member in validator.delegator_list
```

投票资格 = `get_effective_power(user) > 0`，而 `get_effective_power` 要求 `delegated_to != 0x0`。

只有委托到 active validator 的用户才会被 `distribute_epoch_rewards` 遍历到，因此 `total_staked_power` 天然只包含 active validator backing 的有效算力。

如果用户委托到一个 **非 active** validator（已被踢出或尚未加入 ValidatorSet），其 `delegated_to != 0x0` 但不在任何 active validator 的 delegator_list 中。此时：
- `get_effective_power()` 返回 > 0（因为 delegated_to != 0x0）
- 但该用户不在 `total_staked_power` 统计范围内

这会导致投票资格和总票权基数不一致。

### 解决方案

`get_effective_power()` 增加一个检查：`delegated_to` 必须是 active validator：

```move
public fun get_effective_power(user: address): u64 {
    // ... 省略 registry/info 获取
    if (info.delegated_to == @0x0) return 0;

    // 新增：delegated_to 必须是已注册的 validator
    // 且该 validator 必须在 active set 中（通过 stake::get_validator_state 检查）
    if (!registry.validators.contains(info.delegated_to)) return 0;
    if (stake::get_validator_state(info.delegated_to) != VALIDATOR_STATUS_ACTIVE
        && stake::get_validator_state(info.delegated_to) != VALIDATOR_STATUS_PENDING_INACTIVE) {
        return 0
    };

    let committed_power = poc_power_store::get_user_committed_power(user);
    if (committed_power == 0) return 0;

    let deposit_octas = coin::value(&info.deposit);
    let deposit_covers = deposit_octas / registry.config.octas_per_power;
    math64::min(committed_power, deposit_covers)
}
```

治理读取的也是当前 power period committed snapshot；周期中途 stage 到 `pending_updates` 的算力不会提前进入投票权。

这样 `get_effective_power` 和 `total_staked_power` 的定义域完全一致：都只包含委托到 active/pending_inactive validator 的用户。

## 10.6 废弃的治理入口

| 当前入口 | 处理 |
|---------|------|
| `delegation_pool::create_proposal()` | 废弃，用户直接调 `topo_governance::create_proposal()` |
| `delegation_pool::vote()` | 废弃，用户直接调 `topo_governance::vote()` |
| `stake::set_delegated_voter()` | 不再用于治理（operator 语义保留，voter 语义废弃） |
| `staking_proxy::set_stake_pool_voter()` | 废弃 |
| `staking_proxy::set_staking_contract_voter()` | 废弃 |
| `staking_proxy::set_vesting_contract_voter()` | 废弃 |
