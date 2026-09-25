// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

//! ALC-01 / ALC-05：使用已生效的创世算力，通过签名交易同步提交 Epoch。
//! 创世有五个验证者，用户撤回分配后，仍保留四个背景验证者。
//! 额外启用的池始终不申请加入委员会。

use super::{
    defaults::{installed_at, InstalledSnapshot},
    optional_resource_at_version,
    transactions::{assert_abort, compile_script, execute},
};
use crate::smoke_test_environment::SwarmBuilder;
use aptos_api_types::{AptosErrorCode, UserTransaction, ViewRequest, WriteSetChange};
use aptos_cached_packages::aptos_stdlib;
use aptos_forge::{LocalSwarm, NodeExt, Swarm};
use aptos_genesis::poc::{DeploymentMode, PocGenesisConfiguration, PowerParams};
use aptos_rest_client::{error::RestError, Client};
use aptos_sdk::{transaction_builder::TransactionFactory, types::LocalAccount};
use aptos_types::{
    account_address::AccountAddress,
    account_config::CORE_CODE_ADDRESS,
    on_chain_config::{OnChainChunkyDKGConfig, OnChainRandomnessConfig},
    transaction::{Script, TransactionArgument, TransactionPayload},
};
use once_cell::sync::Lazy;
use serde_json::{json, Value};
use std::{collections::BTreeSet, sync::Arc, time::Duration};

const UNIT_SCALE: u128 = 1 << 16;
const RAW_POWER: u64 = 40;
const USER_UNITS: u128 = RAW_POWER as u128 * UNIT_SCALE;
const ALLOCATION_LIMIT: u64 = (2 << 16) + 4;

static GOVERNANCE: Lazy<Vec<u8>> = Lazy::new(|| {
    compile_script(
        "PoCAllocationLifecycle",
        r#"script {
            use topo_framework::poc_allocation;
            use topo_framework::topo_governance;

            fun main(root: &signer, enable_pool: bool, pool: address) {
                let framework = topo_governance::get_signer_testnet_only(root, @0x1);
                if (enable_pool) {
                    poc_allocation::enable_pool(&framework, pool);
                } else {
                    topo_governance::reconfigure(&framework);
                };
            }
        }"#,
    )
});

fn governance_payload(enable_pool: bool, pool: AccountAddress) -> TransactionPayload {
    TransactionPayload::Script(Script::new(GOVERNANCE.clone(), vec![], vec![
        TransactionArgument::Bool(enable_pool),
        TransactionArgument::Address(pool),
    ]))
}

struct Fixture {
    swarm: LocalSwarm,
    client: Client,
    root: Arc<LocalAccount>,
    user: LocalAccount,
    factory: TransactionFactory,
    background: Vec<AccountAddress>,
    pools: Vec<AccountAddress>,
}

async fn fixture(with_extra_pools: bool) -> Fixture {
    Lazy::force(&GOVERNANCE);
    println!("PoC allocation fixture A: nodes=5, background=4, Open, min_validators=4, min_power=10, max_power=1000, candidate_limit=8, epoch=3600s, ordinary/Chunky DKG=off, initial_power=40, bond=100 Octa, growth=25%, retention=10000, native_bps=0, fee_limit=0, max_allocations=4; extra registered pools={with_extra_pools}");
    let swarm = SwarmBuilder::new_local(5)
        .with_aptos()
        .with_init_genesis_stake(Arc::new(|_, stake| *stake = 100))
        .with_init_genesis_config(Arc::new(|config| {
            config.allow_new_validators = true;
            config.epoch_duration_secs = 3600;
            config.min_stake = 1;
            config.max_stake = 1000;
            config.voting_power_increase_limit = 25;
            config.randomness_config_override = Some(OnChainRandomnessConfig::Off);
            config.chunky_dkg_config_override = Some(OnChainChunkyDKGConfig::default_disabled());
            config.poc_genesis_config = Some(Arc::new(|_| PocGenesisConfiguration {
                params: PowerParams {
                    bond_octa_per_ohmp: 100_000_000,
                    min_power: 10,
                    max_power: 1000,
                    min_validators: 4,
                },

                deployment_mode: DeploymentMode::Open,
                retention_bps: 10000,
                initial_raw_power: RAW_POWER,
            }));
        }))
        .build()
        .await;
    super::configure_fixture(&swarm, [4, 4, 32, 8, 10], 0).await;
    let mut addresses = swarm
        .validators()
        .map(|node| node.peer_id())
        .collect::<Vec<_>>();
    addresses.sort();
    let user_address = addresses[0];
    let background = addresses[1..].to_vec();
    // 用户可能退出委员会，因此通过背景验证者提交交易。
    let client = swarm.validator(background[0]).unwrap().rest_client();
    let key = swarm
        .validator(user_address)
        .unwrap()
        .account_private_key()
        .as_ref()
        .unwrap()
        .private_key();
    let root = swarm.chain_info().root_account();
    let factory = swarm
        .chain_info()
        .transaction_factory()
        .with_gas_unit_price(1)
        .with_max_gas_amount(2_000_000)
        .with_transaction_expiration_time(120);
    let mut public = swarm.chain_info().into_aptos_public_info();
    public.mint(user_address, 1_000_000_000).await.unwrap();
    let sequence = client
        .get_account(user_address)
        .await
        .unwrap()
        .into_inner()
        .sequence_number;
    let user = LocalAccount::new(user_address, key, sequence);

    if with_extra_pools {
        let storage_factory = factory.clone().with_gas_unit_price(100);
        for _ in 0..3 {
            let owner = public
                .create_and_fund_user_account(1_000_000_000)
                .await
                .unwrap();
            // 此公开注册入口创建 StakePool + ValidatorConfig。
            // 不在委员会中的质押所有者池无需提供共识密钥。
            success(
                execute(
                    &client,
                    &owner,
                    &storage_factory,
                    aptos_stdlib::stake_initialize_stake_owner(0, owner.address(), owner.address()),
                )
                .await,
            );
            let enabled = success(
                execute(
                    &client,
                    &root,
                    &storage_factory,
                    governance_payload(true, owner.address()),
                )
                .await,
            );
            let events = event_data(&enabled, "::poc_accounting::PoCPoolEnabled");
            assert_eq!(events.len(), 1);
            assert_eq!(address(&events[0]["pool"]), owner.address());
            addresses.push(owner.address());
        }
        assert_eq!(addresses.len(), 8);
    }
    Fixture {
        swarm,
        client,
        root,
        user,
        factory,
        background,
        pools: addresses,
    }
}

fn success(transaction: UserTransaction) -> UserTransaction {
    assert!(transaction.info.success, "{}", transaction.info.vm_status);
    assert!(transaction.info.gas_used.0 > 0);
    transaction
}

fn address(value: &Value) -> AccountAddress {
    AccountAddress::from_hex_literal(value.as_str().unwrap()).unwrap()
}

fn integer(value: &Value) -> u128 {
    value.as_str().unwrap().parse().unwrap()
}

fn event_data<'a>(transaction: &'a UserTransaction, suffix: &str) -> Vec<&'a Value> {
    transaction
        .events
        .iter()
        .filter(|event| event.typ.to_string().ends_with(suffix))
        .map(|event| &event.data)
        .collect()
}

async fn view(client: &Client, function: &str, args: Vec<Value>, version: u64) -> Vec<Value> {
    client
        .view(
            &ViewRequest {
                function: function.parse().unwrap(),
                type_arguments: vec![],
                arguments: args,
            },
            Some(version),
        )
        .await
        .unwrap()
        .into_inner()
}

async fn pool_handle(client: &Client, version: u64) -> AccountAddress {
    let accounting = optional_resource_at_version(
        client,
        CORE_CODE_ADDRESS,
        "0x1::poc_accounting::AccountingState",
        version,
    )
    .await
    .unwrap();
    address(&accounting.data["pools"]["handle"])
}

async fn ledger(client: &Client, pool: AccountAddress, version: u64) -> Value {
    client
        .get_table_item_at_version(
            pool_handle(client, version).await,
            "address",
            "0x1::poc_accounting::PoolLedger",
            pool.to_hex_literal(),
            version,
        )
        .await
        .unwrap()
        .into_inner()
}

async fn checkpoint(client: &Client, ledger: &Value, epoch: u64, version: u64) -> Option<Value> {
    match client
        .get_table_item_at_version(
            address(&ledger["checkpoints"]["handle"]),
            "u64",
            "0x1::poc_accounting::Checkpoint",
            epoch.to_string(),
            version,
        )
        .await
    {
        Ok(response) => Some(response.into_inner()),
        Err(RestError::Api(error))
            if error.status_code == reqwest::StatusCode::NOT_FOUND
                && error.error.error_code == AptosErrorCode::TableItemNotFound =>
        {
            None
        },
        Err(error) => panic!("Cannot read checkpoint {epoch} at version {version}: {error}"),
    }
}

#[derive(Debug, PartialEq)]
struct PoolState {
    ledger: Value,
    logical: Vec<Value>,
    user_position: Vec<Value>,
    checkpoints: Vec<Option<Value>>,
}

#[derive(Debug, PartialEq)]
struct State {
    installed: InstalledSnapshot,
    raw_allocation: Value,
    logical_allocations: Vec<Value>,
    power: Vec<Value>,
    pools: Vec<PoolState>,
}

async fn state(
    client: &Client,
    user: AccountAddress,
    pools: &[AccountAddress],
    epochs: &[u64],
    version: u64,
) -> State {
    let mut pool_states = Vec::new();
    for pool in pools {
        let ledger = ledger(client, *pool, version).await;
        let mut checkpoints = Vec::new();
        for epoch in epochs {
            checkpoints.push(checkpoint(client, &ledger, *epoch, version).await);
        }
        pool_states.push(PoolState {
            ledger,
            logical: view(
                client,
                "0x1::poc_accounting::get_pool",
                vec![json!(pool)],
                version,
            )
            .await,
            user_position: view(
                client,
                "0x1::poc_accounting::get_position",
                vec![json!(user), json!(pool)],
                version,
            )
            .await,
            checkpoints,
        });
    }
    State {
        installed: installed_at(client, version).await,
        raw_allocation: optional_resource_at_version(
            client,
            user,
            "0x1::poc_accounting::UserAllocation",
            version,
        )
        .await
        .unwrap()
        .data,
        logical_allocations: view(
            client,
            "0x1::poc_accounting::get_allocations",
            vec![json!(user)],
            version,
        )
        .await,
        power: view(
            client,
            "0x1::poc_power_store::get_accounting_snapshot",
            vec![json!(user)],
            version,
        )
        .await,
        pools: pool_states,
    }
}

async fn assert_committee_state(fixture: &Fixture, epochs: &[u64], version: u64) {
    let expected = state(
        &fixture.client,
        fixture.user.address(),
        &fixture.pools,
        epochs,
        version,
    )
    .await;
    let members = &expected.installed.validators.active_validators;
    assert!(members.len() >= 4);
    for pool in &fixture.background {
        assert!(members.iter().any(|member| member.account_address == *pool));
    }
    for member in members {
        let client = fixture
            .swarm
            .validator(member.account_address)
            .unwrap()
            .rest_client();
        tokio::time::timeout(Duration::from_secs(30), client.wait_for_version(version))
            .await
            .expect("Allocation state catchup exceeded 30 seconds")
            .unwrap();
        assert_eq!(
            state(
                &client,
                fixture.user.address(),
                &fixture.pools,
                epochs,
                version
            )
            .await,
            expected,
            "Allocation state differs at version {version}"
        );
    }
}

async fn set_allocations(
    fixture: &Fixture,
    pools: &[AccountAddress],
    ratios: &[u64],
) -> UserTransaction {
    let transaction = success(
        execute(
            &fixture.client,
            &fixture.user,
            &fixture.factory,
            aptos_stdlib::poc_allocation_set_allocations(pools.to_vec(), ratios.to_vec()),
        )
        .await,
    );
    let version = transaction.info.version.0;
    let before = installed_at(&fixture.client, version - 1).await;
    assert_eq!(installed_at(&fixture.client, version).await, before);
    let scheduled = event_data(&transaction, "::poc_accounting::AllocationScheduled");
    assert_eq!(scheduled.len(), 1);
    assert_eq!(address(&scheduled[0]["user"]), fixture.user.address());
    assert_eq!(
        integer(&scheduled[0]["effective_epoch"]),
        before.epoch as u128 + 1
    );
    assert_eq!(
        scheduled[0]["pools"]
            .as_array()
            .unwrap()
            .iter()
            .map(address)
            .collect::<Vec<_>>(),
        pools
    );
    assert_eq!(
        scheduled[0]["bps"]
            .as_array()
            .unwrap()
            .iter()
            .map(integer)
            .collect::<Vec<_>>(),
        ratios
            .iter()
            .map(|ratio| *ratio as u128)
            .collect::<Vec<_>>()
    );
    transaction
}

async fn install_next_epoch(fixture: &Fixture) -> UserTransaction {
    let transaction = success(
        execute(
            &fixture.client,
            &fixture.root,
            &fixture.factory,
            governance_payload(false, CORE_CODE_ADDRESS),
        )
        .await,
    );
    let version = transaction.info.version.0;
    let before = installed_at(&fixture.client, version - 1).await;
    let after = installed_at(&fixture.client, version).await;
    assert_eq!(after.epoch, before.epoch + 1);
    let events = event_data(&transaction, "::stake::PoCEpochInstalled");
    assert_eq!(events.len(), 1);
    assert_eq!(integer(&events[0]["epoch"]), after.epoch as u128);
    assert_eq!(integer(&events[0]["period"]), 0);
    assert_eq!(after.reward_context.0, after.epoch);
    assert_eq!(
        integer(&after.reward_split["installed_native_reward_bps"]),
        0
    );
    for resource in [
        "0x1::stake::EpochPlan",
        "0x1::stake::PrecomputedValidatorSet",
    ] {
        assert!(optional_resource_at_version(
            &fixture.client,
            CORE_CODE_ADDRESS,
            resource,
            version
        )
        .await
        .is_none());
    }
    transaction
}

async fn assert_units(fixture: &Fixture, user_units: &[u128], next_units: &[u128], version: u64) {
    assert_eq!(user_units.len(), fixture.pools.len());
    assert_eq!(next_units.len(), fixture.pools.len());
    let power = view(
        &fixture.client,
        "0x1::poc_power_store::get_accounting_snapshot",
        vec![json!(fixture.user.address())],
        version,
    )
    .await;
    assert_eq!(integer(&power[0]), USER_UNITS);
    assert_eq!(integer(&power[1]), USER_UNITS);
    assert_eq!(integer(&power[2]), 0);
    assert_eq!(integer(&power[3]), 61);
    assert!(user_units.iter().sum::<u128>() <= USER_UNITS);
    assert!(next_units.iter().sum::<u128>() <= USER_UNITS);
    let installed = installed_at(&fixture.client, version).await;
    let total = installed.validators.total_voting_power;
    assert_eq!(
        total,
        installed
            .validators
            .active_validators
            .iter()
            .map(|member| member.consensus_voting_power() as u128)
            .sum::<u128>()
    );
    for member in &installed.validators.active_validators {
        let index = fixture
            .pools
            .iter()
            .position(|pool| *pool == member.account_address)
            .unwrap();
        let background = if fixture.background.contains(&member.account_address) {
            USER_UNITS
        } else {
            0
        };
        let expected = ((background + user_units[index]) / UNIT_SCALE).min(100) as u64;
        assert_eq!(member.consensus_voting_power(), expected);
        assert!(
            3 * (expected as u128) < total,
            "Open committee concentration failed"
        );
    }
    for ((pool, current), next) in fixture.pools.iter().zip(user_units).zip(next_units) {
        let background = if fixture.background.contains(pool) {
            USER_UNITS
        } else {
            0
        };
        let logical = view(
            &fixture.client,
            "0x1::poc_accounting::get_pool",
            vec![json!(pool)],
            version,
        )
        .await;
        let position = view(
            &fixture.client,
            "0x1::poc_accounting::get_position",
            vec![json!(fixture.user.address()), json!(pool)],
            version,
        )
        .await;
        assert_eq!(integer(&position[0]), *current);
        if background != 0 {
            let own_position = view(
                &fixture.client,
                "0x1::poc_accounting::get_position",
                vec![json!(pool), json!(pool)],
                version,
            )
            .await;
            assert_eq!(integer(&own_position[0]), USER_UNITS);
        }
        assert_eq!(integer(&logical[0]), background + current);
        assert_eq!(integer(&logical[1]), background + next);
        assert!(position[1].as_array().unwrap().len() <= 2);
        // 计奖基数至多为 50 Octa，原生配置为 10% APY / 1 小时 Epoch，且 fee=0，
        // 因此每个待结束 Epoch 的通胀和 PoC 入账金额均恰好为零。
        assert_eq!(integer(&logical[3]), 0);
        assert_eq!(integer(&logical[4]), 0);
    }
}

async fn assert_change(
    fixture: &Fixture,
    pool: AccountAddress,
    epoch: u64,
    previous: u128,
    next: u128,
    version: u64,
) {
    let position = view(
        &fixture.client,
        "0x1::poc_accounting::get_position",
        vec![json!(fixture.user.address()), json!(pool)],
        version,
    )
    .await;
    let ledger = ledger(&fixture.client, pool, version).await;
    if previous == next {
        assert_eq!(position[1], json!([]));
        assert_eq!(ledger["changes"], json!([]));
    } else {
        assert_eq!(
            position[1],
            json!([{"epoch": epoch.to_string(), "units": next.to_string()}])
        );
        assert_eq!(
            ledger["changes"],
            json!([{
                "epoch": epoch.to_string(), "remove_units": previous.to_string(),
                "add_units": next.to_string(), "refs": "1",
            }])
        );
    }
    assert!(checkpoint(&fixture.client, &ledger, epoch, version)
        .await
        .is_none());
}

async fn settle(
    fixture: &Fixture,
    pools: &[AccountAddress],
    epoch: u64,
    changed: bool,
) -> UserTransaction {
    let before_version = fixture
        .client
        .get_ledger_information()
        .await
        .unwrap()
        .into_inner()
        .version;
    for pool in pools {
        let stored = ledger(&fixture.client, *pool, before_version).await;
        // 委员会外的池可能因惰性推进而仍保留已成熟的变化。
        // 两种存储形式都必须恰好保留该持仓的一份引用。
        if let Some(checkpoint) = checkpoint(&fixture.client, &stored, epoch, before_version).await
        {
            assert!(changed, "Unchanged units created a checkpoint");
            assert_eq!(integer(&checkpoint["refs"]), 1);
            assert_eq!(integer(&checkpoint["index"]), 0);
        } else if let Some(change) = stored["changes"]
            .as_array()
            .unwrap()
            .iter()
            .find(|change| integer(&change["epoch"]) == epoch as u128)
        {
            assert!(changed, "Unchanged units created a mature change");
            assert_eq!(integer(&change["refs"]), 1);
        } else {
            assert!(
                !changed,
                "A mature allocation lost its checkpoint reference"
            );
        }
    }
    let transaction = success(
        execute(
            &fixture.client,
            &fixture.user,
            &fixture.factory,
            aptos_stdlib::poc_allocation_claim_rewards(pools.to_vec()),
        )
        .await,
    );
    assert!(event_data(&transaction, "::poc_accounting::PoCRewardClaimed").is_empty());
    for pool in pools {
        let stored = ledger(&fixture.client, *pool, transaction.info.version.0).await;
        assert_eq!(stored["changes"], json!([]));
        assert!(
            checkpoint(&fixture.client, &stored, epoch, transaction.info.version.0)
                .await
                .is_none()
        );
        let position = view(
            &fixture.client,
            "0x1::poc_accounting::get_position",
            vec![json!(fixture.user.address()), json!(pool)],
            transaction.info.version.0,
        )
        .await;
        assert_eq!(position[1], json!([]));
        assert_eq!(integer(&stored["epoch"]), epoch as u128);
    }
    transaction
}

/// ALC-01：全额、部分和空分配均仅在下一 Epoch 正式安装后生效，
/// 当前算力保持不变。
/// 退出后恢复全额分配只改变池的逻辑 units，
/// 不会替已退出的验证者申请重新加入委员会。
#[tokio::test]
async fn poc_allocation_full_partial_empty_install_and_release_checkpoints() {
    let fixture = fixture(false).await;
    let pool = fixture.user.address();
    let mut current = USER_UNITS;
    let mut epochs = Vec::new();
    for ratio in [10_000, 2_500, 0, 10_000] {
        let (pools, ratios) = if ratio == 0 {
            (vec![], vec![])
        } else {
            (vec![pool], vec![ratio])
        };
        let scheduled = set_allocations(&fixture, &pools, &ratios).await;
        let version = scheduled.info.version.0;
        let epoch = installed_at(&fixture.client, version).await.epoch + 1;
        let next = USER_UNITS * ratio as u128 / 10_000;
        let mut active_units = vec![0; fixture.pools.len()];
        let mut future_units = active_units.clone();
        active_units[0] = current;
        future_units[0] = next;
        assert_units(&fixture, &active_units, &future_units, version).await;
        assert_change(&fixture, pool, epoch, current, next, version).await;
        let allocations = view(
            &fixture.client,
            "0x1::poc_accounting::get_allocations",
            vec![json!(pool)],
            version,
        )
        .await;
        assert_eq!(integer(&allocations[1]["vec"][0]["epoch"]), epoch as u128);
        let installed = install_next_epoch(&fixture).await;
        assert_eq!(
            installed_at(&fixture.client, installed.info.version.0)
                .await
                .epoch,
            epoch
        );
        assert_units(
            &fixture,
            &future_units,
            &future_units,
            installed.info.version.0,
        )
        .await;
        let allocations = view(
            &fixture.client,
            "0x1::poc_accounting::get_allocations",
            vec![json!(pool)],
            installed.info.version.0,
        )
        .await;
        assert_eq!(allocations[1], json!({"vec": []}));
        assert_eq!(allocations[0].as_array().unwrap().len(), pools.len());
        if ratio != 0 {
            assert_eq!(integer(&allocations[0][0]["bps"]), ratio as u128);
        }
        let settled = settle(&fixture, &[pool], epoch, current != next).await;
        epochs.push(epoch);
        assert_committee_state(&fixture, &epochs, settled.info.version.0).await;
        current = next;
    }
}

/// ALC-05：active A + pending B 涉及八个池，必须中止。active 配置为空时，
/// 将 pending A 替换为 pending B 是合法操作，
/// 可在同一笔生产交易中撤销并重建全部八个池的账本变化。
#[tokio::test]
async fn poc_allocation_four_pool_union_and_eight_pool_pending_replacement() {
    let fixture = fixture(true).await;
    let group_a = fixture.background.clone();
    let group_b = vec![
        fixture.user.address(),
        fixture.pools[5],
        fixture.pools[6],
        fixture.pools[7],
    ];
    let ratios = vec![2_500; 4];
    let empty = vec![0; fixture.pools.len()];

    // 撤回用户原先分给本池的算力，同时让四个背景池
    // 保留全部创世 units 并继续出块。
    set_allocations(&fixture, &[], &[]).await;
    let installed = install_next_epoch(&fixture).await;
    let cleared_epoch = installed_at(&fixture.client, installed.info.version.0)
        .await
        .epoch;
    settle(&fixture, &[fixture.user.address()], cleared_epoch, true).await;
    set_allocations(&fixture, &group_a, &ratios).await;
    let installed = install_next_epoch(&fixture).await;
    let active_epoch = installed_at(&fixture.client, installed.info.version.0)
        .await
        .epoch;
    let settled = settle(&fixture, &group_a, active_epoch, true).await;
    let mut active_a = empty.clone();
    for pool in &group_a {
        active_a[fixture
            .pools
            .iter()
            .position(|candidate| candidate == pool)
            .unwrap()] = USER_UNITS / 4;
    }
    assert_units(&fixture, &active_a, &active_a, settled.info.version.0).await;

    let denied = execute(
        &fixture.client,
        &fixture.user,
        &fixture.factory,
        aptos_stdlib::poc_allocation_set_allocations(group_b.clone(), ratios.clone()),
    )
    .await;
    assert_abort(
        &fixture.client,
        &denied,
        "poc_accounting",
        ALLOCATION_LIMIT,
        &[fixture.user.address()],
        &fixture.pools,
    )
    .await;
    assert_eq!(
        state(
            &fixture.client,
            fixture.user.address(),
            &fixture.pools,
            &[cleared_epoch, active_epoch],
            denied.info.version.0 - 1
        )
        .await,
        state(
            &fixture.client,
            fixture.user.address(),
            &fixture.pools,
            &[cleared_epoch, active_epoch],
            denied.info.version.0
        )
        .await
    );
    assert_committee_state(
        &fixture,
        &[cleared_epoch, active_epoch],
        denied.info.version.0,
    )
    .await;

    set_allocations(&fixture, &[], &[]).await;
    let installed = install_next_epoch(&fixture).await;
    let empty_epoch = installed_at(&fixture.client, installed.info.version.0)
        .await
        .epoch;
    let settled = settle(&fixture, &group_a, empty_epoch, true).await;
    assert_units(&fixture, &empty, &empty, settled.info.version.0).await;

    let first = set_allocations(&fixture, &group_a, &ratios).await;
    let target_epoch = installed_at(&fixture.client, first.info.version.0)
        .await
        .epoch
        + 1;
    assert_units(&fixture, &empty, &active_a, first.info.version.0).await;
    for pool in &group_a {
        assert_change(
            &fixture,
            *pool,
            target_epoch,
            0,
            USER_UNITS / 4,
            first.info.version.0,
        )
        .await;
    }
    let replacement = set_allocations(&fixture, &group_b, &ratios).await;
    let version = replacement.info.version.0;
    assert_eq!(
        installed_at(&fixture.client, version).await.epoch,
        empty_epoch
    );
    let mut active_b = empty.clone();
    for pool in &group_b {
        active_b[fixture
            .pools
            .iter()
            .position(|candidate| candidate == pool)
            .unwrap()] = USER_UNITS / 4;
    }
    assert_units(&fixture, &empty, &active_b, version).await;
    for pool in &group_a {
        assert_change(&fixture, *pool, target_epoch, 0, 0, version).await;
    }
    for pool in &group_b {
        assert_change(&fixture, *pool, target_epoch, 0, USER_UNITS / 4, version).await;
    }

    let handle = pool_handle(&fixture.client, version).await;
    let touched = replacement
        .info
        .changes
        .iter()
        .filter_map(|change| {
            if let WriteSetChange::WriteTableItem(change) = change {
                if AccountAddress::from_bytes(change.handle.inner()).unwrap() == handle {
                    return Some(bcs::from_bytes::<AccountAddress>(change.key.inner()).unwrap());
                }
            }
            None
        })
        .collect::<BTreeSet<_>>();
    assert_eq!(
        touched,
        fixture.pools.iter().copied().collect::<BTreeSet<_>>(),
        "Replacing two disjoint pending allocations must write all eight pool ledgers"
    );
    let installed = install_next_epoch(&fixture).await;
    assert_eq!(
        installed_at(&fixture.client, installed.info.version.0)
            .await
            .epoch,
        target_epoch
    );
    assert_units(&fixture, &active_b, &active_b, installed.info.version.0).await;
    let settled = settle(&fixture, &group_b, target_epoch, true).await;
    for pool in &group_a {
        let stored = ledger(&fixture.client, *pool, settled.info.version.0).await;
        assert!(checkpoint(
            &fixture.client,
            &stored,
            target_epoch,
            settled.info.version.0
        )
        .await
        .is_none());
    }
    assert_committee_state(
        &fixture,
        &[cleared_epoch, active_epoch, empty_epoch, target_epoch],
        settled.info.version.0,
    )
    .await;
}
