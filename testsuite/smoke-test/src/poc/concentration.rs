// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

//! WGT-05 / EPO-02：精确集中度边界与真实区块重试。
//! 签名分配交易使下一期目标不合法时，四个原验证者
//! 仍以已安装委员会继续服务。本测试采用 A 配置变体。

use super::{
    defaults::{installed_at, InstalledSnapshot},
    fee_rewards::position_at,
    optional_resource_at_version,
    transactions::{assert_abort, compile_script, execute},
};
use crate::smoke_test_environment::SwarmBuilder;
use aptos_api_types::{Event, Transaction, UserTransaction, ViewRequest};
use aptos_cached_packages::aptos_stdlib;
use aptos_forge::{LocalSwarm, NodeExt, Swarm, SwarmExt};
use aptos_genesis::poc::{DeploymentLimits, DeploymentMode, PocGenesisConfiguration, PowerParams};
use aptos_rest_client::Client;
use aptos_sdk::{transaction_builder::TransactionFactory, types::LocalAccount};
use aptos_types::{
    account_address::AccountAddress,
    account_config::CORE_CODE_ADDRESS,
    on_chain_config::{OnChainChunkyDKGConfig, OnChainRandomnessConfig},
    transaction::{Script, TransactionArgument, TransactionPayload},
    validator_verifier::ValidatorVerifier,
};
use once_cell::sync::Lazy;
use serde_json::{json, Value};
use std::{collections::BTreeMap, sync::Arc, time::Duration};
use tokio::time::{sleep, timeout, Instant};

const UNIT_SCALE: u128 = 1 << 32;
const INITIAL_POWER: u64 = 10;
const LONG_INTERVAL_US: u64 = 3_600_000_000;
const RETRY_INTERVAL_US: u64 = 1_000_000;
const CONCENTRATION_LIMIT: u64 = 3;
const INSUFFICIENT_VALIDATORS: u64 = 1;
const CONFIGURATION: &str = "0x1::reconfiguration::Configuration";

static GOVERNANCE: Lazy<Vec<u8>> = Lazy::new(|| {
    compile_script(
        "PoCConcentrationGovernance",
        r#"
script {
    use topo_framework::block;
    use topo_framework::reconfiguration;
    use topo_framework::stake;
    use topo_framework::topo_governance;

    fun main(root: &signer, operation: u8, interval_us: u64) {
        let framework = topo_governance::get_signer_testnet_only(root, @0x1);
        if (operation == 0) {
            block::update_epoch_interval_microsecs(&framework, interval_us);
        } else {
            assert!(operation == 1 || operation == 2, 0);
            if (operation == 2) {
                // 后续不合法的换届必须同时回滚此前合法的写入及其事件，
                // 不能仅检查 Epoch 未改变。
                stake::schedule_reward_split(&framework, 6000,
                    reconfiguration::current_epoch() + 1);
            };
            topo_governance::reconfigure(&framework);
        };
    }
}
"#,
    )
});

fn payload(operation: u8, interval_us: u64) -> TransactionPayload {
    TransactionPayload::Script(Script::new(GOVERNANCE.clone(), vec![], vec![
        TransactionArgument::U8(operation),
        TransactionArgument::U64(interval_us),
    ]))
}

struct Fixture {
    swarm: LocalSwarm,
    client: Client,
    root: Arc<LocalAccount>,
    factory: TransactionFactory,
    owners: Vec<LocalAccount>,
    pools: Vec<AccountAddress>,
    open: bool,
}

async fn fixture(open: bool) -> Fixture {
    configured_fixture(open, 4, INITIAL_POWER, 5).await
}

async fn configured_fixture(open: bool, nodes: usize, raw_power: u64, capacity: u64) -> Fixture {
    Lazy::force(&GOVERNANCE);
    let fullnodes = usize::from(nodes > 4);
    println!("PoC concentration fixture A: nodes={nodes}, fullnodes={fullnodes}, open={open}, min_validators=4, min_power=1, initial_power={raw_power}, max_power=100, bond=100 Octa, capacity={capacity}, growth=25%, retention=10000, native_bps=0, initial_fee_limit=0, fee_max=10, epoch=3600s, ordinary/Chunky DKG=off; Deferred observation temporarily uses public epoch interval=1s");
    let swarm = SwarmBuilder::new_local(nodes)
        .with_aptos()
        .with_num_fullnodes(fullnodes)
        .with_init_genesis_stake(Arc::new(|_, stake| *stake = 100))
        .with_init_genesis_config(Arc::new(move |config| {
            config.allow_new_validators = true;
            config.epoch_duration_secs = 3600;
            config.min_stake = 1;
            config.max_stake = 1000;
            config.voting_power_increase_limit = 25;
            config.randomness_config_override = Some(OnChainRandomnessConfig::Off);
            config.chunky_dkg_config_override = Some(OnChainChunkyDKGConfig::default_disabled());
            config.poc_genesis_config = Some(Arc::new(move |_| PocGenesisConfiguration {
                params: PowerParams {
                    bond_octa_per_ohmp: 100_000_000,
                    min_power: 1,
                    max_power: 100,
                    min_validators: 4,
                },
                limits: DeploymentLimits {
                    max_allocations: 4,
                    max_claim_pools: 4,
                    max_upload_users: 32,
                    validator_limit: capacity,
                    max_reward_base_octa: 100,
                    rate_max_num: 1,
                    rate_max_den: 1,
                    fee_max: 10,
                    reward_epoch_limit: 1000,
                },
                deployment_mode: if open {
                    DeploymentMode::Open
                } else {
                    DeploymentMode::Controlled
                },
                retention_bps: 10000,
                max_relative_period: 100,
                initial_raw_power: raw_power,
                native_reward_bps: 0,
            }));
        }))
        .build()
        .await;
    let mut pools = swarm
        .validators()
        .map(|node| node.peer_id())
        .collect::<Vec<_>>();
    pools.sort();
    let client = swarm
        .validator(pools[0])
        .unwrap()
        .rest_client_with_timeout(Duration::from_secs(10));
    let root = swarm.chain_info().root_account();
    let factory = swarm
        .chain_info()
        .transaction_factory()
        .with_gas_unit_price(1)
        .with_max_gas_amount(2_000_000)
        .with_transaction_expiration_time(120);
    let mut public = swarm.chain_info().into_aptos_public_info();
    let mut owners = Vec::new();
    for pool in &pools {
        public.mint(*pool, 100_000_000).await.unwrap();
        let key = swarm
            .validator(*pool)
            .unwrap()
            .account_private_key()
            .as_ref()
            .unwrap()
            .private_key();
        let sequence = client
            .get_account(*pool)
            .await
            .unwrap()
            .into_inner()
            .sequence_number;
        owners.push(LocalAccount::new(*pool, key, sequence));
    }
    Fixture {
        swarm,
        client,
        root,
        factory,
        owners,
        pools,
        open,
    }
}

fn integer(value: &Value) -> u128 {
    value.as_str().unwrap().parse().unwrap()
}

fn address(value: &Value) -> AccountAddress {
    AccountAddress::from_hex_literal(value.as_str().unwrap()).unwrap()
}

async fn resource(client: &Client, account: AccountAddress, name: &str, version: u64) -> Value {
    optional_resource_at_version(client, account, name, version)
        .await
        .unwrap_or_else(|| panic!("Missing {name} at {account}, version {version}"))
        .data
}

async fn view(f: &Fixture, name: &str, arguments: Vec<Value>, version: u64) -> Vec<Value> {
    f.client
        .view(
            &ViewRequest {
                function: name.parse().unwrap(),
                type_arguments: vec![],
                arguments,
            },
            Some(version),
        )
        .await
        .unwrap()
        .into_inner()
}

fn events<'a>(transaction: &'a UserTransaction, suffix: &str) -> Vec<&'a Event> {
    transaction
        .events
        .iter()
        .filter(|event| event.typ.to_string().ends_with(suffix))
        .collect()
}

async fn no_plan(f: &Fixture, version: u64) {
    for name in [
        "0x1::stake::EpochPlan",
        "0x1::stake::PrecomputedValidatorSet",
    ] {
        assert!(
            optional_resource_at_version(&f.client, CORE_CODE_ADDRESS, name, version)
                .await
                .is_none()
        );
    }
}

/// 普通区块可更新时间、表现统计和累计交易费。
/// 此快照完整保留 PoC 业务状态、池未来变化及检查点引用的原始表项、
/// 分配、原生质押和已安装快照。
async fn protected_state(f: &Fixture, version: u64) -> BTreeMap<String, Value> {
    let mut state = BTreeMap::new();
    for name in [
        CONFIGURATION,
        "0x1::poc_power_store::PowerStore",
        "0x1::poc_power_store::PeriodClock",
        "0x1::poc_accounting::AccountingState",
        "0x1::poc_reward_split::RewardSplitConfig",
        "0x1::stake::InstalledRewardContext",
        "0x1::stake::ValidatorSet",
        "0x1::reconfiguration_state::State",
    ] {
        state.insert(
            name.to_owned(),
            resource(&f.client, CORE_CODE_ADDRESS, name, version).await,
        );
    }
    no_plan(f, version).await;
    let handle = address(&state["0x1::poc_accounting::AccountingState"]["pools"]["handle"]);
    for pool in &f.pools {
        for name in [
            "0x1::stake::StakePool",
            "0x1::poc_accounting::UserAllocation",
        ] {
            state.insert(
                format!("{name}:{pool}"),
                resource(&f.client, *pool, name, version).await,
            );
        }
        let ledger = f
            .client
            .get_table_item_at_version(
                handle,
                "address",
                "0x1::poc_accounting::PoolLedger",
                pool.to_hex_literal(),
                version,
            )
            .await
            .unwrap()
            .into_inner();
        state.insert(format!("ledger:{pool}"), ledger);
        for name in [
            "0x1::poc_accounting::get_pool",
            "0x1::poc_power_store::get_accounting_snapshot",
        ] {
            state.insert(
                format!("{name}:{pool}"),
                json!(view(f, name, vec![json!(pool)], version).await),
            );
        }
        for target in &f.pools {
            state.insert(
                format!("position:{pool}:{target}"),
                json!(position_at(&f.client, *pool, *target, version).await),
            );
        }
    }
    state
}

async fn assert_preview<const N: usize>(f: &Fixture, version: u64, powers: [u64; N], reason: u64) {
    let installed = installed_at(&f.client, version).await;
    let timestamp = resource(
        &f.client,
        CORE_CODE_ADDRESS,
        "0x1::timestamp::CurrentTimeMicroseconds",
        version,
    )
    .await;
    let cutoff_secs = integer(&timestamp["microseconds"]) / 1_000_000;
    let result = view(
        f,
        "0x1::stake::preview_epoch_transition",
        vec![
            json!((installed.epoch + 1).to_string()),
            json!(cutoff_secs.to_string()),
        ],
        version,
    )
    .await;
    assert_eq!(result.len(), 1);
    let preview = &result[0];
    assert_eq!(integer(&preview["reason"]), reason as u128);
    assert_eq!(integer(&preview["epoch"]), installed.epoch as u128 + 1);
    assert_eq!(integer(&preview["period"]), 0);
    assert_eq!(integer(&preview["period_index"]), 1u128 << 64);
    assert_eq!(
        integer(&preview["closing_rewards"]["epoch"]),
        installed.epoch as u128
    );
    assert_eq!(integer(&preview["cutoff_secs"]), cutoff_secs);
    assert_eq!(preview["poc_enabled"], json!(true));
    assert_eq!(preview["is_liveness_fallback"], json!(false));
    let targets = preview["targets"].as_array().unwrap();
    assert_eq!(targets.len(), N);
    assert_eq!(f.pools.len(), N);
    for (pool, power) in f.pools.iter().zip(powers) {
        let target = targets
            .iter()
            .find(|target| address(&target["pool"]) == *pool)
            .unwrap();
        assert_eq!(integer(&target["units"]), power as u128 * UNIT_SCALE);
        assert_eq!(integer(&target["power"]), power as u128);
        assert_eq!(integer(&target["reward_base_octa"]), power as u128);
    }
    let total: u128 = powers.into_iter().map(u128::from).sum();
    let selected = preview["validator_set"]["active_validators"]
        .as_array()
        .unwrap();
    assert_eq!(
        selected.len(),
        powers.into_iter().filter(|power| *power > 0).count()
    );
    assert_eq!(
        integer(&preview["validator_set"]["total_voting_power"]),
        total
    );
    for member in selected {
        let index = f
            .pools
            .iter()
            .position(|pool| *pool == address(&member["addr"]))
            .unwrap();
        assert_eq!(integer(&member["voting_power"]), powers[index] as u128);
    }
    assert_eq!(integer(&preview["validator_set"]["total_joining_power"]), 0);
    no_plan(f, version).await;
    println!("Concentration preview: open={}, epoch={}, version={version}, powers={powers:?}, total={total}, reason={reason}", f.open, installed.epoch);
}

async fn allocations(f: &Fixture, powers: [u64; 4]) -> u64 {
    let initial = f
        .client
        .get_ledger_information()
        .await
        .unwrap()
        .into_inner();
    let installed = installed_at(&f.client, initial.version).await;
    let mut version = initial.version;
    for ((owner, pool), power) in f.owners.iter().zip(&f.pools).zip(powers) {
        assert!(power <= INITIAL_POWER);
        let (pools, ratios) = if power == 0 {
            (vec![], vec![])
        } else {
            (vec![*pool], vec![power * 1000])
        };
        let transaction = execute(
            &f.client,
            owner,
            &f.factory,
            aptos_stdlib::poc_allocation_set_allocations(pools, ratios),
        )
        .await;
        assert!(transaction.info.success, "{}", transaction.info.vm_status);
        version = transaction.info.version.0;
        assert_eq!(installed_at(&f.client, version).await, installed);
        let scheduled = events(&transaction, "::poc_accounting::AllocationScheduled");
        assert_eq!(scheduled.len(), 1);
        assert_eq!(address(&scheduled[0].data["user"]), *pool);
        assert_eq!(
            integer(&scheduled[0].data["effective_epoch"]),
            installed.epoch as u128 + 1
        );
        assert!(events(&transaction, "::stake::PoCEpochInstalled").is_empty());
    }
    version
}

async fn reject_governance<const N: usize>(f: &Fixture, powers: [u64; N], reason: u64) {
    let transaction = execute(&f.client, &f.root, &f.factory, payload(2, 0)).await;
    assert_abort(
        &f.client,
        &transaction,
        "reconfiguration_with_dkg",
        0x30001,
        &f.pools,
        &f.pools,
    )
    .await;
    let version = transaction.info.version.0;
    assert_eq!(
        protected_state(f, version - 1).await,
        protected_state(f, version).await
    );
    assert_preview(f, version, powers, reason).await;
}

async fn interval(f: &Fixture, interval_us: u64) -> u64 {
    let transaction = execute(&f.client, &f.root, &f.factory, payload(0, interval_us)).await;
    assert!(transaction.info.success, "{}", transaction.info.vm_status);
    let version = transaction.info.version.0;
    assert_eq!(
        protected_state(f, version - 1).await,
        protected_state(f, version).await
    );
    let updated = events(&transaction, "::block::UpdateEpochInterval");
    assert_eq!(updated.len(), 1);
    assert_eq!(
        integer(&updated[0].data["new_epoch_interval"]),
        interval_us as u128
    );
    assert_eq!(
        integer(
            &resource(
                &f.client,
                CORE_CODE_ADDRESS,
                "0x1::block::BlockResource",
                version
            )
            .await["epoch_interval"]
        ),
        interval_us as u128,
    );
    version
}

fn assert_no_settlement(events: &[Event]) {
    for event in events {
        let name = event.typ.to_string();
        assert!(
            !name.contains("::poc_")
                && !name.ends_with("::stake::PoCEpochInstalled")
                && !name.ends_with("::stake::PoCRewardCredited")
                && !name.ends_with("::stake::PoCRewardSplit")
                && !name.ends_with("::stake::DistributeRewards")
                && !name.ends_with("::stake::DistributeTransactionFee")
                && !name.contains("::reconfiguration::"),
            "Deferred block emitted a business event: {event:?}"
        );
    }
}

/// 统计时间戳满足生产重试条件的实际区块前置交易次数。
/// 单独预览、HTTP 轮询或用户交易均不能计为重试。
async fn observe_deferred_blocks<const N: usize>(f: &Fixture, powers: [u64; N]) {
    let start_version = interval(f, RETRY_INTERVAL_US).await;
    let baseline = protected_state(f, start_version).await;
    let epoch = integer(&baseline[CONFIGURATION]["epoch"]) as u64;
    let last_reconfiguration = integer(&baseline[CONFIGURATION]["last_reconfiguration_time"]);
    let started = Instant::now();
    let last_version = timeout(Duration::from_secs(90), async {
        let mut cursor = start_version + 1;
        let mut attempts = 0;
        loop {
            let latest = f.client.get_ledger_information().await.unwrap().into_inner();
            while cursor <= latest.version {
                let limit = (latest.version - cursor + 1).min(100) as u16;
                let transactions = f.client.get_transactions(Some(cursor), Some(limit)).await.unwrap().into_inner();
                assert!(!transactions.is_empty());
                for transaction in transactions {
                    assert_eq!(transaction.version(), Some(cursor));
                    cursor += 1;
                    match transaction {
                        Transaction::BlockMetadataTransaction(block) => {
                            assert!(block.info.success);
                            assert_eq!(block.epoch.0, epoch);
                            assert_no_settlement(&block.events);
                            assert!(block.events.iter().any(|event| event.typ.to_string().ends_with("::block::NewBlockEvent")));
                            if block.timestamp.0 as u128 >= last_reconfiguration + RETRY_INTERVAL_US as u128 {
                                let version = block.info.version.0;
                                assert_eq!(protected_state(f, version).await, baseline);
                                assert_preview(f, version, powers, CONCENTRATION_LIMIT).await;
                                attempts += 1;
                                println!("Concentration Deferred block: attempt={attempts}, epoch={epoch}, version={version}, round={}, timestamp_us={}, elapsed_ms={}", block.round.0, block.timestamp.0, started.elapsed().as_millis());
                                if attempts == 16 {
                                    return version;
                                }
                            }
                        },
                        Transaction::UserTransaction(transaction) => assert_no_settlement(&transaction.events),
                        Transaction::ValidatorTransaction(transaction) => assert_no_settlement(transaction.events()),
                        Transaction::StateCheckpointTransaction(_) | Transaction::BlockEpilogueTransaction(_) => {},
                        Transaction::GenesisTransaction(_) | Transaction::PendingTransaction(_) => {
                            panic!("Unexpected transaction in running committed history")
                        },
                    }
                }
            }
            sleep(Duration::from_millis(100)).await;
        }
    })
    .await
    .expect("Sixteen actual Deferred block prologues did not commit within 90 seconds");
    assert!(last_version > start_version);
    // 趁目标仍不合法时恢复长间隔，避免修复操作及随后一次显式治理提交
    // 与自动换届发生竞态。
    let restored = interval(f, LONG_INTERVAL_US).await;
    assert_eq!(protected_state(f, restored).await, baseline);
    println!("Concentration Deferred observation complete: powers={powers:?}, first_version={start_version}, last_version={last_version}, restored_version={restored}, elapsed_ms={}", started.elapsed().as_millis());
}

fn assert_weights(f: &Fixture, installed: &InstalledSnapshot, powers: [u64; 4]) {
    let set = &installed.validators;
    assert_eq!(set.active_validators.len(), 4);
    assert!(set.pending_active.is_empty());
    assert!(set.pending_inactive.is_empty());
    let total: u128 = powers.into_iter().map(u128::from).sum();
    assert!(total > 0);
    assert_eq!(set.total_voting_power, total);
    assert_eq!(set.total_joining_power, 0);
    for (pool, power) in f.pools.iter().zip(powers) {
        let member = set
            .active_validators
            .iter()
            .find(|member| member.account_address == *pool)
            .unwrap();
        assert_eq!(member.consensus_voting_power(), power);
        if f.open {
            assert!(3 * (power as u128) < total);
        }
    }
    // Controlled 模式仍将这些权重交给原生 quorum 验证器。
    let verifier = ValidatorVerifier::from(set);
    assert_eq!(verifier.quorum_voting_power(), total * 2 / 3 + 1);
    assert_eq!(installed.reward_context.0, installed.epoch);
    assert_eq!(
        integer(&installed.reward_split["installed_epoch"]),
        installed.epoch as u128
    );
    assert_eq!(
        integer(&installed.reward_split["installed_native_reward_bps"]),
        0
    );
}

async fn install_once(f: &Fixture, powers: [u64; 4], staged_version: u64) -> u64 {
    let expected_before = installed_at(&f.client, staged_version).await;
    let transaction = execute(&f.client, &f.root, &f.factory, payload(1, 0)).await;
    assert!(transaction.info.success, "{}", transaction.info.vm_status);
    let version = transaction.info.version.0;
    let before = installed_at(&f.client, version - 1).await;
    let after = installed_at(&f.client, version).await;
    assert_eq!(
        before, expected_before,
        "The repaired target must not install before the intended governance transaction"
    );
    assert_eq!(after.epoch, before.epoch + 1);
    assert_weights(f, &after, powers);
    let installed = events(&transaction, "::stake::PoCEpochInstalled");
    assert_eq!(installed.len(), 1);
    assert_eq!(integer(&installed[0].data["epoch"]), after.epoch as u128);
    assert_eq!(integer(&installed[0].data["selected_count"]), 4);
    assert_eq!(
        integer(&installed[0].data["total_power"]),
        after.validators.total_voting_power
    );
    assert_eq!(
        events(&transaction, "::reconfiguration::NewEpochEvent").len(),
        1
    );
    for suffix in ["::stake::PoCRewardCredited", "::stake::PoCRewardSplit"] {
        let observed = events(&transaction, suffix);
        assert_eq!(observed.len(), 4);
        for pool in &f.pools {
            let matching = observed
                .iter()
                .filter(|event| address(&event.data["pool"]) == *pool)
                .collect::<Vec<_>>();
            assert_eq!(matching.len(), 1);
            assert_eq!(
                integer(&matching[0].data["closing_epoch"]),
                before.epoch as u128
            );
        }
    }
    no_plan(f, version).await;
    for (pool, power) in f.pools.iter().zip(powers) {
        let ledger = view(
            f,
            "0x1::poc_accounting::get_pool",
            vec![json!(pool)],
            version,
        )
        .await;
        assert_eq!(integer(&ledger[0]), power as u128 * UNIT_SCALE);
        assert_eq!(integer(&ledger[2]), power as u128);
        let raw = view(
            f,
            "0x1::poc_power_store::get_accounting_snapshot",
            vec![json!(pool)],
            version,
        )
        .await;
        assert_eq!(integer(&raw[0]), INITIAL_POWER as u128 * UNIT_SCALE);
        assert_eq!(integer(&raw[1]), INITIAL_POWER as u128 * UNIT_SCALE);
    }
    f.swarm
        .wait_for_all_nodes_to_catchup_to_version(version, Duration::from_secs(30))
        .await
        .unwrap();
    for node in f.swarm.validators() {
        assert_eq!(
            installed_at(
                &node.rest_client_with_timeout(Duration::from_secs(10)),
                version
            )
            .await,
            after
        );
    }
    println!("Concentration target installed once: open={}, old_epoch={}, new_epoch={}, powers={powers:?}, total={}, quorum={}, version={version}", f.open, before.epoch, after.epoch, after.validators.total_voting_power, after.validators.total_voting_power * 2 / 3 + 1);
    version
}

#[tokio::test]
async fn poc_open_concentration_boundaries_defer_sixteen_blocks_and_repair() {
    let f = fixture(true).await;
    let valid = [10, 10, 5, 6];
    let staged = allocations(&f, valid).await;
    assert_preview(&f, staged, valid, 0).await;
    install_once(&f, valid, staged).await;
    for powers in [[10, 10, 5, 5], [10, 9, 5, 5]] {
        let staged = allocations(&f, powers).await;
        assert_preview(&f, staged, powers, CONCENTRATION_LIMIT).await;
        reject_governance(&f, powers, CONCENTRATION_LIMIT).await;
        observe_deferred_blocks(&f, powers).await;
        let repaired = allocations(&f, valid).await;
        assert_preview(&f, repaired, valid, 0).await;
        install_once(&f, valid, repaired).await;
    }
}

#[tokio::test]
async fn poc_controlled_concentration_boundaries_preserve_membership_and_total_checks() {
    let f = fixture(false).await;
    for powers in [[10, 10, 5, 6], [10, 10, 5, 5], [10, 9, 5, 5]] {
        let staged = allocations(&f, powers).await;
        assert_preview(&f, staged, powers, 0).await;
        install_once(&f, powers, staged).await;
    }
    for powers in [[10, 9, 5, 0], [0, 0, 0, 0]] {
        let staged = allocations(&f, powers).await;
        // 合法配置 min_power=1 会在验证前剔除零权重候选。
        // 因此，三成员和总权重为零两种目标均返回 reason=1；
        // 此处不宣称覆盖需要隔离构造的 ZERO_TARGET_POWER 分支。
        assert_preview(&f, staged, powers, INSUFFICIENT_VALIDATORS).await;
        reject_governance(&f, powers, INSUFFICIENT_VALIDATORS).await;
        let repaired = allocations(&f, [10, 9, 5, 5]).await;
        assert_preview(&f, repaired, [10, 9, 5, 5], 0).await;
        install_once(&f, [10, 9, 5, 5], repaired).await;
    }
}
