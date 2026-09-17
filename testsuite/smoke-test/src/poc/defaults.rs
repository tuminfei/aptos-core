// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

use super::transactions::compile_script;
use crate::smoke_test_environment::SwarmBuilder;
use anyhow::{Context, Result};
use aptos_api_types::{Event, Transaction, UserTransaction, ViewRequest};
use aptos_cached_packages::aptos_stdlib;
use aptos_forge::{LocalSwarm, NodeExt, Swarm, SwarmExt};
use aptos_genesis::poc::PocGenesisConfiguration;
use aptos_rest_client::Client;
use aptos_sdk::{transaction_builder::TransactionFactory, types::LocalAccount};
use aptos_types::{
    account_address::AccountAddress,
    account_config::CORE_CODE_ADDRESS,
    dkg::{chunky_dkg::ChunkyDKGState, DKGState},
    on_chain_config::{
        ChunkyDKGConfigMoveStruct, ConfigurationResource, Features, OnChainChunkyDKGConfig,
        OnChainConfig, OnChainConsensusConfig, OnChainRandomnessConfig, RandomnessConfigMoveStruct,
        ValidatorSet,
    },
    transaction::{Script, TransactionArgument, TransactionPayload},
};
use serde_json::{json, Value};
use std::{sync::Arc, time::Duration};
use tokio::time::{sleep, timeout, Instant};

const OCTA_PER_TOPO: u64 = 100_000_000;
const UNIT_SCALE: u128 = 1 << 32;
const INDEX_SCALE: u128 = 1 << 64;
const GENESIS_UNITS: u128 = OCTA_PER_TOPO as u128 * UNIT_SCALE;
const NEXT_PERIOD_INDEX: u128 = INDEX_SCALE * 9_995 / 10_000;
type RewardContext = (u64, bool, u64, u64, bool, u64);

#[derive(Debug, PartialEq)]
pub(super) struct InstalledSnapshot {
    pub(super) validators: ValidatorSet,
    pub(super) reward_context: RewardContext,
    pub(super) epoch: u64,
    pub(super) reward_split: Value,
}

/// T2 / T2-F：与 vm-genesis::test_genesis_config 一致，T2-F 仅缩短 Epoch 时长。
/// GenesisBuilder 的本地默认成员配置、最高质押和锁仓参数与其不同；
/// SwarmBuilder 默认还会关闭 Chunky DKG。
pub(super) async fn strict_testnet_swarm(epoch_duration_secs: u64) -> LocalSwarm {
    let started = Instant::now();
    let swarm = SwarmBuilder::new_local(2)
        .with_aptos()
        .with_init_genesis_stake(Arc::new(|_, amount| *amount = OCTA_PER_TOPO))
        .with_init_genesis_config(Arc::new(move |config| {
            config.allow_new_validators = true;
            config.epoch_duration_secs = epoch_duration_secs;
            config.is_test = true;
            config.min_stake = 0;
            config.max_stake = 100_000_000_000_000;
            config.min_voting_threshold = 0;
            config.recurring_lockup_duration_secs = 7_200;
            config.required_proposer_stake = 0;
            config.rewards_apy_percentage = 10;
            config.voting_duration_secs = 3_600;
            config.voting_power_increase_limit = 50;
            config.employee_vesting_start = Some(1_663_456_089);
            config.employee_vesting_period_duration = Some(300);
            config.chunky_dkg_config_override = None;
            config.poc_genesis_config = Some(Arc::new(|_| PocGenesisConfiguration::testnet()));
            assert!(config.initial_features_override.is_none());
            assert!(config.randomness_config_override.is_none());
            assert_eq!(
                config.consensus_config,
                OnChainConsensusConfig::default_for_genesis(),
            );
        }))
        .build()
        .await;
    println!(
        "Strict PoC testnet node startup: {:?}; epoch_secs={epoch_duration_secs}, \
         growth=50%, APY=10%, stake_per_pool={OCTA_PER_TOPO}, \
         native_reward_bps=3000, native default features / DKG / Chunky DKG",
        started.elapsed(),
    );
    for node in swarm.validators() {
        assert_default_genesis(&node.rest_client(), epoch_duration_secs).await;
    }
    swarm
}

async fn on_chain_at<T: OnChainConfig>(client: &Client, version: u64) -> T {
    let bytes = client
        .get_account_resource_at_version_bytes(
            CORE_CODE_ADDRESS,
            &T::struct_tag().to_canonical_string(),
            version,
        )
        .await
        .unwrap()
        .into_inner();
    T::deserialize_into_config(&bytes).unwrap()
}

async fn resource_at(client: &Client, resource: &str, version: u64) -> Value {
    client
        .get_account_resource_at_version(CORE_CODE_ADDRESS, resource, version)
        .await
        .unwrap()
        .into_inner()
        .unwrap_or_else(|| panic!("Missing {resource} at ledger version {version}"))
        .data
}

async fn view_at(
    client: &Client,
    function: &str,
    arguments: Vec<Value>,
    version: u64,
) -> Vec<Value> {
    client
        .view(
            &ViewRequest {
                function: function.parse().unwrap(),
                type_arguments: vec![],
                arguments,
            },
            Some(version),
        )
        .await
        .unwrap()
        .into_inner()
}

fn integer(value: &Value) -> u128 {
    value.as_str().unwrap().parse().unwrap()
}

pub(super) async fn installed_at(client: &Client, version: u64) -> InstalledSnapshot {
    let validators = on_chain_at::<ValidatorSet>(client, version).await;
    let configuration = on_chain_at::<ConfigurationResource>(client, version).await;
    let reward_context = client
        .get_account_resource_at_version_bcs::<RewardContext>(
            CORE_CODE_ADDRESS,
            "0x1::stake::InstalledRewardContext",
            version,
        )
        .await
        .unwrap()
        .into_inner();
    let reward_split =
        resource_at(client, "0x1::poc_reward_split::RewardSplitConfig", version).await;
    let epoch = configuration.epoch();
    assert_eq!(reward_context.0, epoch);
    assert_eq!(integer(&reward_split["installed_epoch"]), epoch as u128);
    InstalledSnapshot {
        validators,
        reward_context,
        epoch,
        reward_split,
    }
}

/// 将原生 DKG 启动耗时与交易、恢复超时分别处理。
/// 仅观察 Epoch 推进无法区分 watchdog 完成路径，
/// 因此要求两个已完成的 transcript 均属于当前已安装的 Epoch。
pub(super) async fn wait_for_initial_dkg(client: &Client) -> Result<()> {
    timeout(Duration::from_secs(240), async {
        loop {
            let ledger = client.get_ledger_information().await?.into_inner();
            if ledger.epoch >= 2 {
                let dkg = client
                    .get_account_resource_at_version_bcs::<DKGState>(
                        CORE_CODE_ADDRESS,
                        &DKGState::struct_tag().to_canonical_string(),
                        ledger.version,
                    )
                    .await?
                    .into_inner();
                let chunky = client
                    .get_account_resource_at_version_bcs::<ChunkyDKGState>(
                        CORE_CODE_ADDRESS,
                        &ChunkyDKGState::struct_tag().to_canonical_string(),
                        ledger.version,
                    )
                    .await?
                    .into_inner();
                if let (Some(dkg), Some(chunky)) = (dkg.last_completed, chunky.last_completed) {
                    if dkg.target_epoch() == ledger.epoch
                        && chunky.target_epoch() == ledger.epoch
                        && !dkg.transcript.is_empty()
                        && !chunky.transcript.is_empty()
                    {
                        return Ok(());
                    }
                }
            }
            sleep(Duration::from_secs(1)).await;
        }
    })
    .await
    .context("Strict T2 initial ordinary/Chunky DKG did not complete within 240 seconds")?
}

async fn assert_default_genesis(client: &Client, epoch_duration_secs: u64) {
    let installed = installed_at(client, 0).await;
    assert_eq!(installed.epoch, 1);
    assert_eq!(installed.validators.active_validators.len(), 2);
    assert!(installed.validators.pending_active.is_empty());
    assert!(installed.validators.pending_inactive.is_empty());
    assert_eq!(installed.validators.total_voting_power, 200_000_000);
    assert_eq!(installed.validators.total_joining_power, 0);
    assert!(installed
        .validators
        .active_validators
        .iter()
        .all(|validator| validator.consensus_voting_power() == OCTA_PER_TOPO));
    assert_eq!(
        installed.reward_split,
        json!({
            "installed_epoch": "1",
            "configured_native_reward_bps": "3000",
            "installed_native_reward_bps": "3000",
            "pending_change": {"vec": []},
        }),
    );

    let features = on_chain_at::<Features>(client, 0).await;
    assert_eq!(features, Features::default());
    assert_eq!(
        on_chain_at::<OnChainConsensusConfig>(client, 0).await,
        OnChainConsensusConfig::default_for_genesis(),
    );
    assert_eq!(
        on_chain_at::<RandomnessConfigMoveStruct>(client, 0).await,
        RandomnessConfigMoveStruct::from(OnChainRandomnessConfig::default_for_genesis()),
    );
    assert_eq!(
        on_chain_at::<ChunkyDKGConfigMoveStruct>(client, 0).await,
        ChunkyDKGConfigMoveStruct::from(OnChainChunkyDKGConfig::default_for_genesis()),
    );

    // 用独立整数模型计算原生 10% APY 的创世换算及其定点奖励率，
    // 不使用 PoC 预览生成预期值。
    let rate_num = 100_000_000 / (365 * 24 * 60 * 60 / epoch_duration_secs);
    let fixed_rate = rate_num as u128 * INDEX_SCALE / 1_000_000_000;
    let installed_den = (1_000_000 * INDEX_SCALE / fixed_rate).min(u64::MAX as u128);
    let installed_num = installed_den * fixed_rate / INDEX_SCALE;
    assert_eq!(
        installed.reward_context,
        (
            1,
            true,
            installed_num as u64,
            installed_den as u64,
            features.is_distribute_transaction_fee_enabled(),
            0,
        ),
    );
    assert_eq!(
        resource_at(client, "0x1::staking_config::StakingConfig", 0).await,
        json!({
            "minimum_stake": "0",
            "maximum_stake": "100000000000000",
            "recurring_lockup_duration_secs": "7200",
            "allow_validator_set_change": true,
            "rewards_rate": rate_num.to_string(),
            "rewards_rate_denominator": "1000000000",
            "voting_power_increase_limit": "50",
        }),
    );
    assert_eq!(
        resource_at(client, "0x1::staking_config::StakingRewardsConfig", 0).await,
        json!({
            "rewards_rate": {"value": fixed_rate.to_string()},
            "min_rewards_rate": {"value": "0"},
            "rewards_rate_period_in_secs": "31536000",
            "last_rewards_rate_period_start_in_secs": "0",
            "rewards_rate_decrease_rate": {"value": "0"},
        }),
    );
    assert_eq!(
        resource_at(client, "0x1::topo_governance::GovernanceConfig", 0).await,
        json!({
            "min_voting_threshold": "0",
            "required_proposer_stake": "0",
            "voting_duration_secs": "3600",
        }),
    );
    assert_eq!(
        integer(&resource_at(client, "0x1::block::BlockResource", 0).await["epoch_interval"]),
        epoch_duration_secs as u128 * 1_000_000,
    );
    assert_eq!(
        view_at(client, "0x1::poc_accounting::get_config", vec![], 0).await,
        vec![
            json!("1"),
            json!("1"),
            json!({"vec": ["1"]}),
            json!(0),
            json!({
                "bond_octa_per_ohmp": "100000000",
                "min_power": "1",
                "max_power": "100000000000",
                "min_validators": "2",
            }),
            json!({"vec": []}),
            json!({
                "max_allocations": "4",
                "max_claim_pools": "4",
                "max_upload_users": "32",
                "validator_limit": "128",
                "max_reward_base_octa": "100000000000",
                "rate_max_num": "1",
                "rate_max_den": "100",
                "fee_max": "100000000000",
                "reward_epoch_limit": "600060",
            }),
        ],
    );
    assert_eq!(
        view_at(
            client,
            "0x1::poc_power_store::get_normalization_clock",
            vec![],
            0
        )
        .await,
        vec![
            json!("0"),
            json!("0"),
            json!("61"),
            json!(INDEX_SCALE.to_string()),
            json!({"vec": [NEXT_PERIOD_INDEX.to_string()]}),
            json!("10000"),
        ],
    );
    for (function, expected) in [
        ("get_power_period_in_epochs", "60"),
        ("get_retention_bps_per_period", "9995"),
    ] {
        assert_eq!(
            view_at(
                client,
                &format!("0x1::poc_power_store::{function}"),
                vec![],
                0
            )
            .await,
            vec![json!(expected)],
        );
    }
    let operator = view_at(client, "0x1::poc_power_store::get_operator", vec![], 0).await;
    assert_eq!(
        AccountAddress::from_hex_literal(operator[0].as_str().unwrap()).unwrap(),
        CORE_CODE_ADDRESS,
    );
    for validator in &installed.validators.active_validators {
        let address = validator.account_address;
        let user = json!(address.to_hex_literal());
        assert_eq!(
            view_at(
                client,
                "0x1::poc_power_store::get_accounting_snapshot",
                vec![user.clone()],
                0
            )
            .await,
            vec![
                json!(GENESIS_UNITS.to_string()),
                json!(GENESIS_UNITS.to_string()),
                json!("0"),
                json!("61")
            ],
        );
        assert_eq!(
            view_at(
                client,
                "0x1::poc_power_store::get_user_committed_power",
                vec![user.clone()],
                0
            )
            .await,
            vec![json!(OCTA_PER_TOPO.to_string())],
        );
        let allocations = view_at(
            client,
            "0x1::poc_accounting::get_allocations",
            vec![user.clone()],
            0,
        )
        .await;
        assert_eq!(allocations[0].as_array().unwrap().len(), 1);
        assert_eq!(integer(&allocations[0][0]["bps"]), 10_000);
        assert_eq!(
            AccountAddress::from_hex_literal(allocations[0][0]["pool"].as_str().unwrap()).unwrap(),
            address
        );
        assert_eq!(allocations[1], json!({"vec": []}));
        assert_eq!(
            view_at(
                client,
                "0x1::poc_accounting::get_position",
                vec![user.clone(), user.clone()],
                0
            )
            .await,
            vec![
                json!(GENESIS_UNITS.to_string()),
                json!([]),
                json!("0"),
                json!("0")
            ],
        );
        assert_eq!(
            view_at(
                client,
                "0x1::poc_accounting::get_pool",
                vec![user.clone()],
                0
            )
            .await,
            vec![
                json!(GENESIS_UNITS.to_string()),
                json!(GENESIS_UNITS.to_string()),
                json!(OCTA_PER_TOPO.to_string()),
                json!("0"),
                json!("0")
            ],
        );
        assert_eq!(
            view_at(client, "0x1::stake::get_stake", vec![user], 0).await,
            vec![
                json!(OCTA_PER_TOPO.to_string()),
                json!("0"),
                json!("0"),
                json!("0")
            ],
        );
    }
}

async fn submit(
    client: &Client,
    account: &LocalAccount,
    factory: &TransactionFactory,
    payload: TransactionPayload,
) -> UserTransaction {
    let signed = account.sign_with_transaction_builder(factory.payload(payload));
    let Transaction::UserTransaction(transaction) =
        tokio::time::timeout(Duration::from_secs(60), client.submit_and_wait(&signed))
            .await
            .expect("Strict T2 user transaction timed out")
            .unwrap()
            .into_inner()
    else {
        panic!("Expected a committed user transaction")
    };
    assert!(transaction.info.success, "{}", transaction.info.vm_status);
    println!(
        "T2 transaction: hash={}, version={}, gas_used={}, gas_unit_price={}",
        transaction.info.hash,
        transaction.info.version.0,
        transaction.info.gas_used.0,
        transaction.request.gas_unit_price.0,
    );
    transaction
}

fn event<'a>(transaction: &'a UserTransaction, suffix: &str) -> &'a Event {
    let events = transaction
        .events
        .iter()
        .filter(|event| event.typ.to_string().ends_with(suffix))
        .collect::<Vec<_>>();
    assert_eq!(events.len(), 1, "Expected one {suffix}: {transaction:?}");
    events[0]
}

fn fees(transaction: &UserTransaction) -> (u64, u64) {
    let statement = event(transaction, "::transaction_fee::FeeStatement");
    assert!(transaction.info.gas_used.0 > 0);
    assert_eq!(
        integer(&statement.data["total_charge_gas_units"]),
        transaction.info.gas_used.0 as u128,
    );
    let charge = transaction.info.gas_used.0 * transaction.request.gas_unit_price.0;
    assert!(charge > 0);
    (
        charge,
        integer(&statement.data["storage_fee_refund_octas"]) as u64,
    )
}

async fn balance_at(client: &Client, address: AccountAddress, version: u64) -> u64 {
    client
        .view_apt_account_balance_at_version(address, version)
        .await
        .unwrap()
        .into_inner()
}

/// SYS-01：严格 T2 默认配置、十笔收费转账、一次框架授权上传，
/// 以及一次 owner 分配变更。未来算力不会提前改变已安装的投票权重。
#[tokio::test]
async fn poc_testnet_defaults_transfer_upload_and_allocate() {
    let upload_script = compile_script(
        "strict_t2_upload",
        r#"script {
            use 0x1::topo_governance;
            use 0x1::poc_power_store;
            fun main(core_resources: &signer, user: address, period: u64, power: u64) {
                let framework = topo_governance::get_signer_testnet_only(core_resources, @0x1);
                poc_power_store::stage_batch_update(&framework, period, vector[user], vector[power]);
            }
        }"#,
    );
    let swarm = strict_testnet_swarm(3_600).await;
    let client = swarm.validators().next().unwrap().rest_client();
    let initial_set = installed_at(&client, 0).await.validators;
    let owner_address = initial_set.active_validators[0].account_address;
    let receiver_address = initial_set.active_validators[1].account_address;
    let owner_key = swarm
        .validator(owner_address)
        .unwrap()
        .account_private_key()
        .as_ref()
        .unwrap()
        .private_key();
    let Transaction::GenesisTransaction(genesis) = client
        .get_transaction_by_version(0)
        .await
        .unwrap()
        .into_inner()
    else {
        panic!("Ledger version zero must contain genesis")
    };
    assert_eq!(
        genesis
            .events
            .iter()
            .filter(|event| event
                .typ
                .to_string()
                .ends_with("::stake::PoCEpochInstalled"))
            .count(),
        1
    );
    for suffix in [
        "::stake::PoCRewardCredited",
        "::stake::PoCRewardSplit",
        "::stake::DistributeRewards",
        "::stake::DistributeTransactionFee",
    ] {
        assert!(
            !genesis
                .events
                .iter()
                .any(|event| event.typ.to_string().ends_with(suffix)),
            "Genesis must not reward epoch zero: {suffix}",
        );
    }

    // 首个区块从创世时间推进，并启动首批真实 DKG 会话。
    // 将该启动耗时与交易耗时分别记录。
    let bootstrap_started = Instant::now();
    wait_for_initial_dkg(&client)
        .await
        .expect("Strict T2 initial DKG / Chunky DKG did not complete");
    println!(
        "T2 first epoch install with native DKG / Chunky DKG defaults: {:?}",
        bootstrap_started.elapsed()
    );
    swarm
        .chain_info()
        .into_aptos_public_info()
        .mint(owner_address, OCTA_PER_TOPO)
        .await
        .unwrap();
    let chain = swarm.chain_info();
    let factory = chain
        .transaction_factory()
        .with_gas_unit_price(1)
        .with_max_gas_amount(2_000_000)
        .with_transaction_expiration_time(120);
    let root = chain.root_account();
    let sequence = client
        .get_account(owner_address)
        .await
        .unwrap()
        .into_inner()
        .sequence_number;
    let owner = LocalAccount::new(owner_address, owner_key, sequence);
    let before = client.get_ledger_information().await.unwrap().into_inner();
    let sender_before = balance_at(&client, owner_address, before.version).await;
    let receiver_before = balance_at(&client, receiver_address, before.version).await;
    let mut gas = 0;
    let mut refunds = 0;
    let mut last_version = before.version;
    for _ in 0..10 {
        let transaction = submit(
            &client,
            &owner,
            &factory,
            aptos_stdlib::topo_coin_transfer(receiver_address, 1_000),
        )
        .await;
        let (charge, refund) = fees(&transaction);
        gas += charge;
        refunds += refund;
        last_version = transaction.info.version.0;
    }
    assert_eq!(
        balance_at(&client, receiver_address, last_version).await,
        receiver_before + 10_000
    );
    assert_eq!(
        balance_at(&client, owner_address, last_version).await as i128,
        sender_before as i128 - 10_000 - gas as i128 + refunds as i128
    );

    let installed_before = installed_at(&client, last_version).await;
    let clock_before = view_at(
        &client,
        "0x1::poc_power_store::get_normalization_clock",
        vec![],
        last_version,
    )
    .await;
    assert_eq!(clock_before[1], json!("0"));
    assert_eq!(clock_before[2], json!("61"));
    assert!(installed_before.epoch + 1 < 61);
    let raw_power = 2 * OCTA_PER_TOPO;
    let next_units = raw_power as u128 * UNIT_SCALE * INDEX_SCALE / NEXT_PERIOD_INDEX;
    let upload = submit(
        &client,
        &root,
        &factory,
        TransactionPayload::Script(Script::new(upload_script, vec![], vec![
            TransactionArgument::Address(owner_address),
            TransactionArgument::U64(1),
            TransactionArgument::U64(raw_power),
        ])),
    )
    .await;
    fees(&upload);
    let normalized = event(&upload, "::poc_power_store::PowerNormalized");
    let staged = event(&upload, "::poc_power_store::PowerUpdateStagedEvent");
    for emitted in [normalized, staged] {
        assert_eq!(
            AccountAddress::from_hex_literal(emitted.data["user"].as_str().unwrap()).unwrap(),
            owner_address
        );
        assert_eq!(integer(&emitted.data["effective_period"]), 1);
    }
    assert_eq!(integer(&normalized.data["units"]), next_units);
    assert_eq!(integer(&staged.data["power"]), raw_power as u128);
    assert_eq!(integer(&staged.data["target_period"]), 1);
    assert_eq!(
        installed_at(&client, upload.info.version.0).await,
        installed_before
    );
    let user = json!(owner_address.to_hex_literal());
    let expected_snapshot = vec![
        json!(GENESIS_UNITS.to_string()),
        json!(next_units.to_string()),
        json!("0"),
        json!("61"),
    ];
    assert_eq!(
        view_at(
            &client,
            "0x1::poc_power_store::get_accounting_snapshot",
            vec![user.clone()],
            upload.info.version.0
        )
        .await,
        expected_snapshot
    );

    let allocation = submit(
        &client,
        &owner,
        &factory,
        aptos_stdlib::poc_allocation_set_allocations(vec![owner_address], vec![5_000]),
    )
    .await;
    fees(&allocation);
    let scheduled = event(&allocation, "::poc_accounting::AllocationScheduled");
    assert_eq!(
        AccountAddress::from_hex_literal(scheduled.data["user"].as_str().unwrap()).unwrap(),
        owner_address
    );
    assert_eq!(
        integer(&scheduled.data["effective_epoch"]),
        installed_before.epoch as u128 + 1
    );
    assert_eq!(scheduled.data["bps"], json!(["5000"]));
    assert_eq!(scheduled.data["pools"].as_array().unwrap().len(), 1);
    assert_eq!(
        AccountAddress::from_hex_literal(scheduled.data["pools"][0].as_str().unwrap()).unwrap(),
        owner_address,
    );
    let version = allocation.info.version.0;
    let expected_changes = json!([
        {"epoch": (installed_before.epoch + 1).to_string(), "units": (GENESIS_UNITS / 2).to_string()},
        {"epoch": "61", "units": (next_units / 2).to_string()},
    ]);
    let position = view_at(
        &client,
        "0x1::poc_accounting::get_position",
        vec![user.clone(), user.clone()],
        version,
    )
    .await;
    assert_eq!(integer(&position[0]), GENESIS_UNITS);
    assert_eq!(position[1], expected_changes);
    let pool = view_at(
        &client,
        "0x1::poc_accounting::get_pool",
        vec![user.clone()],
        version,
    )
    .await;
    assert_eq!(integer(&pool[0]), GENESIS_UNITS);
    assert_eq!(integer(&pool[1]), GENESIS_UNITS / 2);
    assert_eq!(integer(&pool[2]), OCTA_PER_TOPO as u128);
    let allocations = view_at(
        &client,
        "0x1::poc_accounting::get_allocations",
        vec![user.clone()],
        version,
    )
    .await;
    assert_eq!(integer(&allocations[0][0]["bps"]), 10_000);
    assert_eq!(
        integer(&allocations[1]["vec"][0]["epoch"]),
        installed_before.epoch as u128 + 1
    );
    assert_eq!(
        integer(&allocations[1]["vec"][0]["ratios"][0]["bps"]),
        5_000
    );

    swarm
        .wait_for_all_nodes_to_catchup_to_version(version, Duration::from_secs(30))
        .await
        .unwrap();
    for node in swarm.validators() {
        let client = node.rest_client();
        assert_eq!(installed_at(&client, version).await, installed_before);
        assert_eq!(
            view_at(
                &client,
                "0x1::poc_power_store::get_normalization_clock",
                vec![],
                version
            )
            .await,
            clock_before
        );
        assert_eq!(
            view_at(
                &client,
                "0x1::poc_power_store::get_accounting_snapshot",
                vec![user.clone()],
                version
            )
            .await,
            expected_snapshot
        );
        assert_eq!(
            view_at(
                &client,
                "0x1::poc_accounting::get_position",
                vec![user.clone(), user.clone()],
                version
            )
            .await,
            position
        );
        assert_eq!(
            view_at(
                &client,
                "0x1::poc_accounting::get_pool",
                vec![user.clone()],
                version
            )
            .await,
            pool
        );
        assert_eq!(
            view_at(
                &client,
                "0x1::poc_accounting::get_allocations",
                vec![user.clone()],
                version
            )
            .await,
            allocations
        );
        assert_eq!(
            client
                .get_transaction_by_version(upload.info.version.0)
                .await
                .unwrap()
                .into_inner(),
            Transaction::UserTransaction(upload.clone())
        );
        assert_eq!(
            client
                .get_transaction_by_version(version)
                .await
                .unwrap()
                .into_inner(),
            Transaction::UserTransaction(allocation.clone())
        );
    }
    println!("SYS-01 T2: 10 transfers, upload, allocation, and both-node snapshot at version {version}; transfer gas={gas}, refunds={refunds}");
}
