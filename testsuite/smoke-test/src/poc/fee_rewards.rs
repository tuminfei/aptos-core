// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

//! REW-01 / REW-07 / REW-08：真实交易费、计算 PoC 奖励指数前的分流、
//! 两个独立领取者，以及生产交易的原子回滚。

use super::{
    defaults::installed_at,
    optional_resource_at_version, resource_at_version,
    transactions::{assert_abort, compile_script, execute},
};
use crate::smoke_test_environment::SwarmBuilder;
use aptos_api_types::{AptosErrorCode, Event, UserTransaction, ViewRequest};
use aptos_cached_packages::aptos_stdlib;
use aptos_forge::{LocalSwarm, NodeExt, Swarm};
use aptos_genesis::poc::{DeploymentMode, PocGenesisConfiguration, PowerParams};
use aptos_rest_client::{error::RestError, Client};
use aptos_sdk::{transaction_builder::TransactionFactory, types::LocalAccount};
use aptos_types::{
    account_address::AccountAddress,
    account_config::CORE_CODE_ADDRESS,
    on_chain_config::{
        FeatureFlag, Features, OnChainChunkyDKGConfig, OnChainExecutionConfig,
        OnChainRandomnessConfig,
    },
    transaction::{
        block_epilogue::{BlockEpiloguePayload, FeeDistribution},
        Script, Transaction, TransactionArgument, TransactionPayload,
    },
};
use move_core_types::int256::U256;
use once_cell::sync::Lazy;
use serde_json::{json, Value};
use std::{sync::Arc, time::Duration};

const RAW_POWER: u64 = 40;
const UNIT_SCALE: u128 = 1 << 16;
const POOL_UNITS: u128 = 40 * UNIT_SCALE;
const POSITION_UNITS: [u128; 2] = [10 * UNIT_SCALE, 30 * UNIT_SCALE];
const FEE_LIMIT: u64 = 39;

static GOVERNANCE: Lazy<Vec<u8>> = Lazy::new(|| {
    compile_script(
        "PoCFeeOnlyRewards",
        r#"script {
            use topo_std::fixed_point64;
            use topo_framework::stake;
            use topo_framework::staking_config;
            use topo_framework::topo_governance;

            fun main(root: &signer, configure: bool) {
                let framework = topo_governance::get_signer_testnet_only(root, @0x1);
                if (configure) {
                    // 创世要求 APY 为正；保留原生功能集合，
                    // 通过支持的公开设置入口安装零奖励率。
                    let zero = fixed_point64::create_from_rational(0, 1);
                    staking_config::update_rewards_config(&framework, zero, zero, 31536000, zero);
                    stake::set_transaction_fee_limit_per_epoch_per_pool(&framework, 39);
                };
                topo_governance::reconfigure(&framework);
            }
        }"#,
    )
});

fn governance_payload(configure: bool) -> TransactionPayload {
    TransactionPayload::Script(Script::new(GOVERNANCE.clone(), vec![], vec![
        TransactionArgument::Bool(configure),
    ]))
}

struct Fixture {
    swarm: LocalSwarm,
    client: Client,
    root: Arc<LocalAccount>,
    users: [LocalAccount; 2],
    pools: Vec<AccountAddress>,
    factory: TransactionFactory,
}

async fn fixture(native_bps: u64) -> Fixture {
    Lazy::force(&GOVERNANCE);
    println!("PoC fee fixture A: nodes=6 (4 background + 2 owners), Open, min_validators=4, min_power=10, max_power=1000, initial_power=40, bond=100 Octa, epoch=3600s, growth=25%, retention=10000, native_bps={native_bps}, fee_max=39, initial_fee_limit=0; ordinary/Chunky DKG=off; zero reward rate installed by public governance");
    let swarm = SwarmBuilder::new_local(6)
        .with_aptos()
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
    super::configure_fixture(&swarm, [4, 4, 32, 8, FEE_LIMIT], native_bps).await;
    let mut pools = swarm
        .validators()
        .map(|node| node.peer_id())
        .collect::<Vec<_>>();
    pools.sort();
    // U1 将算力分配给 U2 后，其池退出委员会；始终通过背景节点提交 REST 交易。
    let client = swarm.validator(pools[2]).unwrap().rest_client();
    let root = swarm.chain_info().root_account();
    let factory = swarm
        .chain_info()
        .transaction_factory()
        .with_gas_unit_price(1)
        .with_max_gas_amount(2_000_000)
        .with_transaction_expiration_time(120);
    let mut public = swarm.chain_info().into_aptos_public_info();
    let mut users = Vec::new();
    for address in &pools[..2] {
        public.mint(*address, 1_000_000_000).await.unwrap();
        let key = swarm
            .validator(*address)
            .unwrap()
            .account_private_key()
            .as_ref()
            .unwrap()
            .private_key();
        let sequence = client
            .get_account(*address)
            .await
            .unwrap()
            .into_inner()
            .sequence_number;
        users.push(LocalAccount::new(*address, key, sequence));
    }
    Fixture {
        swarm,
        client,
        root,
        users: users.try_into().unwrap(),
        pools,
        factory,
    }
}

pub(super) fn success(transaction: UserTransaction) -> UserTransaction {
    assert!(transaction.info.success, "{}", transaction.info.vm_status);
    assert!(transaction.info.gas_used.0 > 0);
    transaction
}

pub(super) fn integer(value: &Value) -> u128 {
    value.as_str().unwrap().parse().unwrap()
}

pub(super) fn address(value: &Value) -> AccountAddress {
    AccountAddress::from_hex_literal(value.as_str().unwrap()).unwrap()
}

pub(super) fn wide(value: &Value) -> U256 {
    value.as_str().unwrap().parse().unwrap()
}

pub(super) fn events<'a>(transaction: &'a UserTransaction, suffix: &str) -> Vec<&'a Event> {
    transaction
        .events
        .iter()
        .filter(|event| event.typ.to_string().ends_with(suffix))
        .collect()
}

pub(super) fn pool_event<'a>(
    transaction: &'a UserTransaction,
    suffix: &str,
    pool: AccountAddress,
) -> &'a Event {
    let matching = events(transaction, suffix)
        .into_iter()
        .filter(|event| address(&event.data["pool"]) == pool)
        .collect::<Vec<_>>();
    assert_eq!(matching.len(), 1, "Expected one {suffix} for pool {pool}");
    matching[0]
}

pub(super) async fn view(
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

pub(super) async fn pool_at(client: &Client, pool: AccountAddress, version: u64) -> Vec<Value> {
    view(
        client,
        "0x1::poc_accounting::get_pool",
        vec![json!(pool)],
        version,
    )
    .await
}

pub(super) async fn position_at(
    client: &Client,
    user: AccountAddress,
    pool: AccountAddress,
    version: u64,
) -> Vec<Value> {
    view(
        client,
        "0x1::poc_accounting::get_position",
        vec![json!(user), json!(pool)],
        version,
    )
    .await
}

pub(super) async fn stakes_at(
    client: &Client,
    pools: &[AccountAddress],
    version: u64,
) -> Vec<Vec<Value>> {
    let mut stakes = Vec::new();
    for pool in pools {
        stakes.push(view(client, "0x1::stake::get_stake", vec![json!(pool)], version).await);
    }
    stakes
}

pub(super) async fn ledger_at(client: &Client, pool: AccountAddress, version: u64) -> Value {
    let accounting = optional_resource_at_version(
        client,
        CORE_CODE_ADDRESS,
        "0x1::poc_accounting::AccountingState",
        version,
    )
    .await
    .unwrap();
    client
        .get_table_item_at_version(
            address(&accounting.data["pools"]["handle"]),
            "address",
            "0x1::poc_accounting::PoolLedger",
            pool.to_hex_literal(),
            version,
        )
        .await
        .unwrap()
        .into_inner()
}

pub(super) async fn checkpoint_at(
    client: &Client,
    pool: AccountAddress,
    epoch: u64,
    version: u64,
) -> Option<Value> {
    let ledger = ledger_at(client, pool, version).await;
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
        Err(error) => panic!("Cannot read reward checkpoint {epoch} at {version}: {error}"),
    }
}

/// 每个 Epoch 先按池执行整数除法，再对各持仓金额向下取整。
/// 即使份额恰好为 1:3，先前的指数除法也可能使整数可领额减少 1 Octa。
struct Expected {
    native: u64,
    poc: u64,
    delta: U256,
    claims: [u64; 2],
    remainders: [U256; 2],
}

impl Expected {
    fn new(native_bps: u64) -> Self {
        let native = (FEE_LIMIT as u128 * native_bps as u128 / 10_000) as u64;
        let poc = FEE_LIMIT - native;
        let q = U256::ONE << U256::from(128_u8);
        let delta = U256::checked_div(
            U256::checked_mul(U256::from(poc), q).unwrap(),
            U256::from(POOL_UNITS),
        )
        .unwrap();
        let accrued =
            POSITION_UNITS.map(|units| U256::checked_mul(delta, U256::from(units)).unwrap());
        let claims =
            accrued.map(|amount| u64::try_from(U256::checked_div(amount, q).unwrap()).unwrap());
        let remainders = accrued.map(|amount| U256::checked_rem(amount, q).unwrap());
        assert_eq!(claims, if native_bps == 0 { [9, 29] } else { [6, 20] });
        Self {
            native,
            poc,
            delta,
            claims,
            remainders,
        }
    }
}

pub(super) async fn assert_position(
    client: &Client,
    user: AccountAddress,
    pool: AccountAddress,
    units: u128,
    claimable: u64,
    remainder: U256,
    version: u64,
) {
    let position = position_at(client, user, pool, version).await;
    assert_eq!(integer(&position[0]), units);
    assert_eq!(position[1], json!([]));
    assert_eq!(integer(&position[2]), claimable as u128);
    assert_eq!(wide(&position[3]), remainder);
}

pub(super) async fn assert_payment(client: &Client, transaction: &UserTransaction, amount: u64) {
    let statements = events(transaction, "::transaction_fee::FeeStatement");
    assert_eq!(statements.len(), 1);
    let gas = transaction.info.gas_used.0 * transaction.request.gas_unit_price.0;
    assert!(gas > 0);
    assert_eq!(
        integer(&statements[0].data["total_charge_gas_units"]),
        transaction.info.gas_used.0 as u128
    );
    let refund = integer(&statements[0].data["storage_fee_refund_octas"]);
    let sender = transaction.request.sender.into();
    let version = transaction.info.version.0;
    let before = client
        .view_apt_account_balance_at_version(sender, version - 1)
        .await
        .unwrap()
        .into_inner();
    let after = client
        .view_apt_account_balance_at_version(sender, version)
        .await
        .unwrap()
        .into_inner();
    assert_eq!(
        after as i128 - before as i128,
        amount as i128 - gas as i128 + refund as i128
    );
}

async fn prepare(fixture: &Fixture, native_bps: u64) -> u64 {
    let target = fixture.users[1].address();
    for (user, ratio) in fixture.users.iter().zip([2_500, 7_500]) {
        success(
            execute(
                &fixture.client,
                user,
                &fixture.factory,
                aptos_stdlib::poc_allocation_set_allocations(vec![target], vec![ratio]),
            )
            .await,
        );
    }
    let preparation = success(
        execute(
            &fixture.client,
            &fixture.root,
            &fixture.factory,
            governance_payload(true),
        )
        .await,
    );
    let version = preparation.info.version.0;
    let before = installed_at(&fixture.client, version - 1).await;
    let installed = installed_at(&fixture.client, version).await;
    assert_eq!(installed.epoch, before.epoch + 1);
    assert_eq!(events(&preparation, "::stake::PoCEpochInstalled").len(), 1);
    assert_eq!(installed.validators.active_validators.len(), 5);
    assert_eq!(installed.validators.total_voting_power, 200);
    assert!(installed
        .validators
        .active_validators
        .iter()
        .all(|validator| validator.consensus_voting_power() == 40));
    assert!(before.reward_context.2 > 0);
    assert_eq!(before.reward_context.5, 0);
    assert_eq!(
        installed.reward_context,
        (installed.epoch, true, 0, 1, true, FEE_LIMIT)
    );
    assert_eq!(
        integer(&installed.reward_split["installed_native_reward_bps"]),
        native_bps as u128
    );
    let features = resource_at_version::<Features>(&fixture.client, version).await;
    assert!(features.is_enabled(FeatureFlag::PERIODICAL_REWARD_RATE_DECREASE));
    assert!(features.is_enabled(FeatureFlag::DISTRIBUTE_TRANSACTION_FEE));
    let performance = optional_resource_at_version(
        &fixture.client,
        CORE_CODE_ADDRESS,
        "0x1::stake::ValidatorPerformance",
        version - 1,
    )
    .await
    .unwrap()
    .data;
    // 原生准备配置的 APY 为正，但即使提案成功率为 100%，
    // 仍有 40 Octa * 已安装奖励率 < 1；这些旧期入账须单独核对。
    assert!(
        (RAW_POWER as u128) * (before.reward_context.2 as u128) < before.reward_context.3 as u128
    );
    for validator in &before.validators.active_validators {
        let credit = pool_event(
            &preparation,
            "::stake::PoCRewardCredited",
            validator.account_address,
        );
        assert_eq!(integer(&credit.data["closing_epoch"]), before.epoch as u128);
        assert_eq!(integer(&credit.data["inflation"]), 0);
        assert_eq!(integer(&credit.data["fee"]), 0);
        assert_eq!(wide(&credit.data["delta_index"]), U256::ZERO);
    }
    println!("Fee preparation closes epoch {} using rate={}/{} and fee_limit=0; actual performance={performance}; version={version}", before.epoch, before.reward_context.2, before.reward_context.3);
    let target_pool = pool_at(&fixture.client, target, version).await;
    assert_eq!(target_pool, vec![
        json!(POOL_UNITS.to_string()),
        json!(POOL_UNITS.to_string()),
        json!("40"),
        json!("0"),
        json!("0")
    ]);
    for (user, units) in fixture.users.iter().zip(POSITION_UNITS) {
        assert_position(
            &fixture.client,
            user.address(),
            target,
            units,
            0,
            U256::ZERO,
            version,
        )
        .await;
    }
    for background in &fixture.pools[2..] {
        assert_position(
            &fixture.client,
            *background,
            target,
            0,
            0,
            U256::ZERO,
            version,
        )
        .await;
    }
    assert_eq!(
        view(
            &fixture.client,
            "0x1::stake::get_stake",
            vec![json!(target)],
            version
        )
        .await,
        vec![json!("100"), json!("0"), json!("0"), json!("0")]
    );
    let checkpoint = checkpoint_at(&fixture.client, target, installed.epoch, version)
        .await
        .unwrap();
    assert_eq!(integer(&checkpoint["refs"]), 2);
    assert_eq!(integer(&checkpoint["index"]), 0);
    installed.epoch
}

pub(super) async fn recorded_fee(client: &Client, target: AccountAddress, version: u64) -> u64 {
    let installed = installed_at(client, version).await;
    let validator = installed
        .validators
        .active_validators
        .iter()
        .find(|validator| validator.account_address == target)
        .unwrap();
    let fees = pending_fees_at(client, version).await;
    assert_eq!(fees.len(), installed.validators.active_validators.len());
    fees[validator.config().validator_index as usize]
}

pub(super) async fn pending_fees_at(client: &Client, version: u64) -> Vec<u64> {
    let fees = view(
        client,
        "0x1::stake::get_pending_transaction_fee",
        vec![],
        version,
    )
    .await;
    fees[0]
        .as_array()
        .unwrap()
        .iter()
        .map(|value| u64::try_from(integer(value)).unwrap())
        .collect()
}

/// 存储押金不可分发，应从最终总收费中推导可用 gas 费用，
/// 因为分别取整的执行和 IO gas 可能高估该金额。
fn distributable_fee(transaction: &UserTransaction, gas_price_to_burn: u64) -> u64 {
    let statements = events(transaction, "::transaction_fee::FeeStatement");
    assert_eq!(statements.len(), 1);
    let total_units = integer(&statements[0].data["total_charge_gas_units"]);
    assert_eq!(total_units, transaction.info.gas_used.0 as u128);
    let price = transaction.request.gas_unit_price.0 as u128;
    assert!(price > 0);
    let storage = integer(&statements[0].data["storage_fee_octas"]);
    let storage_units = storage.div_ceil(price);
    let available_units = total_units.saturating_sub(storage_units);
    let distributable = available_units * price.saturating_sub(gas_price_to_burn as u128);
    println!("Fee statement: version={}, gas_price={price}, burn_price={gas_price_to_burn}, total_gas_units={total_units}, storage_octa={storage}, storage_gas_units={storage_units}, available_gas_units={available_units}, distributable_octa={distributable}", transaction.info.version.0);
    u64::try_from(distributable).unwrap()
}

/// 费用记录发生在所在区块的收尾交易中，其版本晚于用户交易。
/// 应在该处同时核对实际分配及受限额约束的账本变化；
/// 仅凭用户交易版本的快照不能证明费用已记录。
pub(super) async fn assert_transfer_fee_block(
    client: &Client,
    transfer: &UserTransaction,
    gas_price_to_burn: u64,
    epoch: u64,
    fee_limit: u64,
) -> (u64, Vec<u64>, u64) {
    let distributable = distributable_fee(transfer, gas_price_to_burn);
    let block = client
        .get_block_by_version_bcs(transfer.info.version.0, true)
        .await
        .unwrap()
        .into_inner();
    let transactions = block.transactions.unwrap();
    let user_versions = transactions
        .iter()
        .filter(|transaction| transaction.transaction.try_as_signed_user_txn().is_some())
        .map(|transaction| transaction.version)
        .collect::<Vec<_>>();
    // 每次提交均等待交易及其完整区块提交后，再提交下一笔；
    // 该隔离测试网络没有其他用户负载。
    assert_eq!(user_versions, vec![transfer.info.version.0]);
    let epilogue = transactions.last().unwrap();
    assert_eq!(epilogue.version, block.last_version);
    assert!(epilogue.version > transfer.info.version.0);
    let amounts = match &epilogue.transaction {
        Transaction::BlockEpilogue(BlockEpiloguePayload::V1 {
            fee_distribution: FeeDistribution::V0 { amount },
            ..
        })
        | Transaction::BlockEpilogue(BlockEpiloguePayload::V2 {
            fee_distribution: FeeDistribution::V0 { amount },
            ..
        }) => amount,
        other => panic!("Expected an epilogue with fee distribution, got {other:?}"),
    };
    assert_eq!(
        amounts.values().map(|amount| *amount as u128).sum::<u128>(),
        distributable as u128
    );
    let installed = installed_at(client, epilogue.version).await;
    assert_eq!(installed.epoch, epoch);
    let before = pending_fees_at(client, epilogue.version - 1).await;
    let after = pending_fees_at(client, epilogue.version).await;
    assert_eq!(before.len(), installed.validators.active_validators.len());
    assert_eq!(after.len(), before.len());
    assert!(amounts.keys().all(|index| (*index as usize) < before.len()));
    for (index, (old, new)) in before.iter().zip(&after).enumerate() {
        assert!(*old <= fee_limit);
        let distributed = amounts.get(&(index as u64)).copied().unwrap_or(0);
        assert_eq!(
            *new as u128,
            (*old as u128 + distributed as u128).min(fee_limit as u128)
        );
    }
    println!("Fee epilogue: version={}, epoch={epoch}, distribution={amounts:?}, before={before:?}, after={after:?}", epilogue.version);
    (epilogue.version, after, distributable)
}

pub(super) async fn priced_fee_factory(
    client: &Client,
    factory: &TransactionFactory,
    version: u64,
) -> (TransactionFactory, u64) {
    let config_bytes = client
        .get_account_resource_at_version_bcs::<Vec<u8>>(
            CORE_CODE_ADDRESS,
            "0x1::execution_config::ExecutionConfig",
            version,
        )
        .await
        .unwrap()
        .into_inner();
    let execution_config: OnChainExecutionConfig = bcs::from_bytes(&config_bytes).unwrap();
    let gas_price_to_burn = execution_config
        .gas_price_to_burn()
        .expect("The native genesis execution config must explicitly set its burn price");
    assert_eq!(
        Some(gas_price_to_burn),
        OnChainExecutionConfig::default_for_genesis().gas_price_to_burn()
    );
    let features = resource_at_version::<Features>(client, version).await;
    assert!(features.is_enabled(FeatureFlag::CALCULATE_TRANSACTION_FEE_FOR_DISTRIBUTION));
    assert!(features.is_enabled(FeatureFlag::DISTRIBUTE_TRANSACTION_FEE));
    let priced_factory = factory
        .clone()
        .with_gas_unit_price(100.max(gas_price_to_burn.checked_add(1).unwrap()));
    println!("Fee execution config: version={version}, config={execution_config:?}, CALCULATE_TRANSACTION_FEE_FOR_DISTRIBUTION=true, DISTRIBUTE_TRANSACTION_FEE=true");

    (priced_factory, gas_price_to_burn)
}

async fn fill_fee_limit(fixture: &Fixture, epoch: u64) {
    let target = fixture.users[1].address();
    let version = fixture
        .client
        .get_ledger_information()
        .await
        .unwrap()
        .into_inner()
        .version;
    let (priced_factory, gas_price_to_burn) =
        priced_fee_factory(&fixture.client, &fixture.factory, version).await;

    // 准备及治理交易的 gas 单价为 1，低于原生销毁单价。
    // 支付小费前先保留一组低单价对照，并核对区块收尾交易。
    let initial_fees = pending_fees_at(&fixture.client, version).await;
    assert!(initial_fees.iter().all(|fee| *fee == 0));
    let low_price_transfer = success(
        execute(
            &fixture.client,
            &fixture.users[0],
            &fixture.factory,
            aptos_stdlib::topo_coin_transfer(target, 1_000),
        )
        .await,
    );
    assert_eq!(low_price_transfer.request.gas_unit_price.0, 1);
    assert!(low_price_transfer.request.gas_unit_price.0 <= gas_price_to_burn);
    let (control_version, control_fees, control_distributable) = assert_transfer_fee_block(
        &fixture.client,
        &low_price_transfer,
        gas_price_to_burn,
        epoch,
        FEE_LIMIT,
    )
    .await;
    assert_eq!(control_distributable, 0);
    assert_eq!(control_fees, initial_fees);
    println!("Low-price fee control: transaction_version={}, epilogue_version={control_version}, gas_price=1, charged_gas_octa={}, distributable_octa=0, pending_fees={control_fees:?}", low_price_transfer.info.version.0, low_price_transfer.info.gas_used.0);

    // 使用真实提案者选择结果，持续提交付费转账，
    // 直到目标池已安装的费用累加器达到上限，不预设由哪个节点提案。
    let (count, gas, distributed, version) = tokio::time::timeout(Duration::from_secs(90), async {
        let mut count = 0;
        let mut gas = 0;
        let mut distributed = 0;
        loop {
            let transfer = success(
                execute(
                    &fixture.client,
                    &fixture.users[0],
                    &priced_factory,
                    aptos_stdlib::topo_coin_transfer(target, 1_000),
                )
                .await,
            );
            count += 1;
            gas += transfer.info.gas_used.0 * transfer.request.gas_unit_price.0;
            let (version, _, distributable) = assert_transfer_fee_block(
                &fixture.client,
                &transfer,
                gas_price_to_burn,
                epoch,
                FEE_LIMIT,
            )
            .await;
            assert!(distributable > FEE_LIMIT);
            distributed += distributable;
            let recorded = recorded_fee(&fixture.client, target, version).await;
            assert!(recorded <= FEE_LIMIT);
            if recorded == FEE_LIMIT {
                break (count, gas, distributed, version);
            }
        }
    })
    .await
    .expect("Real transfers did not fill the target validator's fee cap within 90 seconds");
    assert!(gas > FEE_LIMIT);
    assert!(distributed > FEE_LIMIT);
    println!("Fee workload: target={target}, epoch={epoch}, transfers={count}, charged_gas_octa={gas}, distributable_octa={distributed}, capped_recorded_fee={FEE_LIMIT}, version={version}");
}

async fn close_fee_epoch(
    fixture: &Fixture,
    native_bps: u64,
    expected: &Expected,
    epoch: u64,
) -> u64 {
    let target = fixture.users[1].address();
    let closing = success(
        execute(
            &fixture.client,
            &fixture.root,
            &fixture.factory,
            governance_payload(false),
        )
        .await,
    );
    let version = closing.info.version.0;
    let before = installed_at(&fixture.client, version - 1).await;
    let after = installed_at(&fixture.client, version).await;
    assert_eq!(before.epoch, epoch);
    assert_eq!(after.epoch, epoch + 1);
    assert_eq!(events(&closing, "::stake::PoCEpochInstalled").len(), 1);
    assert_eq!(after.validators, before.validators);
    assert_eq!(
        after.reward_context,
        (epoch + 1, true, 0, 1, true, FEE_LIMIT)
    );
    assert_eq!(
        integer(&after.reward_split["installed_native_reward_bps"]),
        native_bps as u128
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
    assert_eq!(before.reward_context, (epoch, true, 0, 1, true, FEE_LIMIT));
    assert_eq!(
        recorded_fee(&fixture.client, target, version - 1).await,
        FEE_LIMIT
    );
    let credit = pool_event(&closing, "::stake::PoCRewardCredited", target);
    assert_eq!(integer(&credit.data["closing_epoch"]), epoch as u128);
    assert_eq!(integer(&credit.data["reward_base_octa"]), 40);
    assert_eq!(integer(&credit.data["inflation"]), 0);
    assert_eq!(integer(&credit.data["fee"]), expected.poc as u128);
    assert_eq!(wide(&credit.data["delta_index"]), expected.delta);
    let split = pool_event(&closing, "::stake::PoCRewardSplit", target);
    assert_eq!(integer(&split.data["closing_epoch"]), epoch as u128);
    assert_eq!(
        integer(&split.data["native_reward_bps"]),
        native_bps as u128
    );
    for field in [
        "total_inflation_octa",
        "active_native_reward_octa",
        "pending_inactive_native_reward_octa",
        "poc_inflation_octa",
    ] {
        assert_eq!(integer(&split.data[field]), 0);
    }
    let native_fees = events(&closing, "::stake::DistributeTransactionFee")
        .into_iter()
        .filter(|event| address(&event.data["pool_address"]) == target)
        .collect::<Vec<_>>();
    assert_eq!(native_fees.len(), usize::from(expected.native > 0));
    if expected.native > 0 {
        assert_eq!(
            integer(&native_fees[0].data["fee_amount"]),
            expected.native as u128
        );
    }
    assert!(events(&closing, "::stake::DistributeRewards").is_empty());
    let before_pool = pool_at(&fixture.client, target, version - 1).await;
    let after_pool = pool_at(&fixture.client, target, version).await;
    assert_eq!(integer(&before_pool[3]), 0);
    assert_eq!(wide(&before_pool[4]), U256::ZERO);
    assert_eq!(integer(&after_pool[3]), expected.poc as u128);
    assert_eq!(wide(&after_pool[4]), expected.delta);
    let before_stake = view(
        &fixture.client,
        "0x1::stake::get_stake",
        vec![json!(target)],
        version - 1,
    )
    .await;
    let after_stake = view(
        &fixture.client,
        "0x1::stake::get_stake",
        vec![json!(target)],
        version,
    )
    .await;
    assert_eq!(before_stake, vec![
        json!("100"),
        json!("0"),
        json!("0"),
        json!("0")
    ]);
    assert_eq!(after_stake, vec![
        json!((100 + expected.native).to_string()),
        json!("0"),
        json!("0"),
        json!("0")
    ]);
    assert_eq!(
        integer(&after_pool[3]) + integer(&after_stake[0]) - integer(&before_stake[0]),
        FEE_LIMIT as u128
    );
    for (index, user) in fixture.users.iter().enumerate() {
        assert_position(
            &fixture.client,
            user.address(),
            target,
            POSITION_UNITS[index],
            expected.claims[index],
            expected.remainders[index],
            version,
        )
        .await;
    }
    println!("Fee credit: closing_epoch={epoch}, native_bps={native_bps}, native={}, poc={}, delta={:?}, claims={:?}, fractional={:?}, version={version}", expected.native, expected.poc, expected.delta, expected.claims, expected.remainders);
    version
}

async fn rejected_claim(
    fixture: &Fixture,
    inputs: Vec<AccountAddress>,
    code: u64,
    checkpoint_epoch: u64,
) {
    let transaction = execute(
        &fixture.client,
        &fixture.users[0],
        &fixture.factory,
        aptos_stdlib::poc_allocation_claim_rewards(inputs),
    )
    .await;
    assert_abort(
        &fixture.client,
        &transaction,
        "poc_accounting",
        code,
        &[fixture.users[0].address(), fixture.users[1].address()],
        &fixture.pools,
    )
    .await;
    assert_payment(&fixture.client, &transaction, 0).await;
    let version = transaction.info.version.0;
    assert_eq!(
        stakes_at(&fixture.client, &fixture.pools, version - 1).await,
        stakes_at(&fixture.client, &fixture.pools, version).await
    );
    let before = checkpoint_at(
        &fixture.client,
        fixture.users[1].address(),
        checkpoint_epoch,
        version - 1,
    )
    .await
    .unwrap();
    let after = checkpoint_at(
        &fixture.client,
        fixture.users[1].address(),
        checkpoint_epoch,
        version,
    )
    .await
    .unwrap();
    assert_eq!(integer(&before["refs"]), 2);
    assert_eq!(
        after, before,
        "Failed claim consumed a historical checkpoint reference"
    );
}

async fn claim(fixture: &Fixture, user: usize, amount: u64) -> u64 {
    let target = fixture.users[1].address();
    let transaction = success(
        execute(
            &fixture.client,
            &fixture.users[user],
            &fixture.factory,
            aptos_stdlib::poc_allocation_claim_rewards(vec![target]),
        )
        .await,
    );
    let claims = events(&transaction, "::poc_accounting::PoCRewardClaimed");
    assert_eq!(claims.len(), usize::from(amount > 0));
    if amount > 0 {
        assert_eq!(
            address(&claims[0].data["user"]),
            fixture.users[user].address()
        );
        assert_eq!(address(&claims[0].data["pool"]), target);
        assert_eq!(integer(&claims[0].data["amount"]), amount as u128);
    }
    assert_payment(&fixture.client, &transaction, amount).await;
    let version = transaction.info.version.0;
    assert_eq!(
        installed_at(&fixture.client, version - 1).await,
        installed_at(&fixture.client, version).await
    );
    assert_eq!(
        stakes_at(&fixture.client, &fixture.pools, version - 1).await,
        stakes_at(&fixture.client, &fixture.pools, version).await,
        "PoC claims must not compound native stake"
    );
    let before = pool_at(&fixture.client, target, version - 1).await;
    let after = pool_at(&fixture.client, target, version).await;
    assert_eq!(integer(&before[3]) - integer(&after[3]), amount as u128);
    assert_eq!(before[4], after[4]);
    version
}

async fn snapshot(fixture: &Fixture, client: &Client, version: u64) -> Vec<Value> {
    let target = fixture.users[1].address();
    let mut result = vec![
        json!(pool_at(client, target, version).await),
        ledger_at(client, target, version).await,
        json!(stakes_at(client, &fixture.pools, version).await),
    ];
    for user in &fixture.users {
        result.push(json!(
            position_at(client, user.address(), target, version).await
        ));
        result.push(
            optional_resource_at_version(
                client,
                user.address(),
                "0x1::poc_accounting::UserAllocation",
                version,
            )
            .await
            .unwrap()
            .data,
        );
    }
    result
}

async fn run_fee_scenario(native_bps: u64) {
    let fixture = fixture(native_bps).await;
    let expected = Expected::new(native_bps);
    let target = fixture.users[1].address();
    let fee_epoch = prepare(&fixture, native_bps).await;
    fill_fee_limit(&fixture, fee_epoch).await;
    close_fee_epoch(&fixture, native_bps, &expected, fee_epoch).await;
    // 首项原本会支付非零奖励并消耗一份检查点引用；
    // 重复的第二项必须将这两项效果一起原子回滚。
    rejected_claim(&fixture, vec![target, target], 0x10003, fee_epoch).await;
    let five_pools = std::iter::once(target)
        .chain(fixture.pools[2..].iter().copied())
        .collect();
    rejected_claim(&fixture, five_pools, 0x20004, fee_epoch).await;
    let mut last_version = 0;
    for (index, units) in POSITION_UNITS.iter().copied().enumerate() {
        last_version = claim(&fixture, index, expected.claims[index]).await;
        assert_position(
            &fixture.client,
            fixture.users[index].address(),
            target,
            units,
            0,
            expected.remainders[index],
            last_version,
        )
        .await;
        let checkpoint = checkpoint_at(&fixture.client, target, fee_epoch, last_version).await;
        if index == 0 {
            assert_eq!(integer(&checkpoint.unwrap()["refs"]), 1);
        } else {
            assert!(checkpoint.is_none());
        }
        last_version = claim(&fixture, index, 0).await;
        assert_position(
            &fixture.client,
            fixture.users[index].address(),
            target,
            units,
            0,
            expected.remainders[index],
            last_version,
        )
        .await;
    }
    let vault = expected.poc - expected.claims.iter().sum::<u64>();
    assert_eq!(vault, if native_bps == 0 { 1 } else { 2 });
    let final_pool = pool_at(&fixture.client, target, last_version).await;
    assert_eq!(integer(&final_pool[0]), POOL_UNITS);
    assert_eq!(integer(&final_pool[3]), vault as u128);
    assert_eq!(wide(&final_pool[4]), expected.delta);
    let installed = installed_at(&fixture.client, last_version).await;
    let reference = snapshot(&fixture, &fixture.client, last_version).await;
    for validator in &installed.validators.active_validators {
        let client = fixture
            .swarm
            .validator(validator.account_address)
            .unwrap()
            .rest_client();
        tokio::time::timeout(
            Duration::from_secs(30),
            client.wait_for_version(last_version),
        )
        .await
        .expect("Fee reward snapshot catchup exceeded 30 seconds")
        .unwrap();
        assert_eq!(installed_at(&client, last_version).await, installed);
        assert_eq!(snapshot(&fixture, &client, last_version).await, reference);
        assert!(checkpoint_at(&client, target, fee_epoch, last_version)
            .await
            .is_none());
    }
    println!("REW fee-only completed: native_bps={native_bps}, fee={FEE_LIMIT}, native={}, claims={:?}, vault={vault}, final_version={last_version}", expected.native, expected.claims);
}

static REW03_GOVERNANCE: Lazy<Vec<u8>> = Lazy::new(|| {
    compile_script(
        "PoCRewardInputsAndFeeSwitch",
        r#"script {
            use std::features;
            use topo_std::fixed_point64;
            use topo_framework::stake;
            use topo_framework::staking_config;
            use topo_framework::topo_governance;

            fun main(root: &signer, feature_operation: u8, fee_limit: u64) {
                let framework = topo_governance::get_signer_testnet_only(root, @0x1);
                let rate = fixed_point64::create_from_rational(1, 2);
                let zero = fixed_point64::create_from_rational(0, 1);
                staking_config::update_rewards_config(
                    &framework, rate, rate, 31536000, zero);
                stake::set_transaction_fee_limit_per_epoch_per_pool(&framework, fee_limit);
                if (feature_operation == 1) {
                    features::change_feature_flags_for_next_epoch(
                        &framework, vector[],
                        vector[features::get_distribute_transaction_fee_feature()]);
                } else if (feature_operation == 2) {
                    features::change_feature_flags_for_next_epoch(
                        &framework,
                        vector[features::get_distribute_transaction_fee_feature()], vector[]);
                } else {
                    assert!(feature_operation == 0, 0);
                };
                topo_governance::reconfigure(&framework);
            }
        }"#,
    )
});

fn rew03_governance(feature_operation: u8, fee_limit: u64) -> TransactionPayload {
    TransactionPayload::Script(Script::new(REW03_GOVERNANCE.clone(), vec![], vec![
        TransactionArgument::U8(feature_operation),
        TransactionArgument::U64(fee_limit),
    ]))
}

async fn rew03_counts(
    client: &Client,
    installed: &super::defaults::InstalledSnapshot,
    version: u64,
) -> Vec<(AccountAddress, u128, u128)> {
    let mut result = Vec::new();
    for validator in &installed.validators.active_validators {
        let counts = view(
            client,
            "0x1::stake::get_current_epoch_proposal_counts",
            vec![json!(validator.config().validator_index.to_string())],
            version,
        )
        .await;
        result.push((
            validator.account_address,
            integer(&counts[0]),
            integer(&counts[1]),
        ));
    }
    result
}

/// 使用待结束 Epoch 的已安装上下文和真实提案计数独立计算每池奖励。
/// 返回的计数用于证明无提案及成功/失败提案比例分支确实被执行。
async fn assert_rew03_close(
    fixture: &Fixture,
    closing: &UserTransaction,
    expected_fee_switch: bool,
    expected_fee_limit: u64,
) -> Vec<(AccountAddress, u128, u128)> {
    assert!(closing.info.success, "{}", closing.info.vm_status);
    let version = closing.info.version.0;
    let before = installed_at(&fixture.client, version - 1).await;
    let after = installed_at(&fixture.client, version).await;
    assert_eq!(after.epoch, before.epoch + 1);
    assert_eq!(after.validators, before.validators);
    assert_eq!(events(closing, "::stake::PoCEpochInstalled").len(), 1);
    assert_eq!(before.reward_context.0, before.epoch);
    assert_eq!(before.reward_context.1, true);
    assert_eq!(before.reward_context.4, expected_fee_switch);
    assert_eq!(before.reward_context.5, expected_fee_limit);
    assert!(before.reward_context.2 > 0);
    assert!(before.reward_context.3 > 0);
    assert_eq!(
        integer(&before.reward_split["installed_native_reward_bps"]),
        0
    );
    let counts = rew03_counts(&fixture.client, &before, version - 1).await;
    let pending = pending_fees_at(&fixture.client, version - 1).await;
    assert_eq!(pending.len(), counts.len());
    let q = U256::ONE << U256::from(128_u8);

    for (pool, successful, failed) in &counts {
        let validator = before
            .validators
            .active_validators
            .iter()
            .find(|validator| validator.account_address == *pool)
            .unwrap();
        let index = validator.config().validator_index as usize;
        let pool_before = pool_at(&fixture.client, *pool, version - 1).await;
        let pool_after = pool_at(&fixture.client, *pool, version).await;
        let units = integer(&pool_before[0]);
        let reward_base = integer(&pool_before[2]);
        assert!(units > 0, "生产委员会成员必须具有非零有效 units");
        let total = successful + failed;
        let inflation = if total == 0 {
            0
        } else {
            reward_base * *successful * before.reward_context.2 as u128
                / (total * before.reward_context.3 as u128)
        };
        let fee = if expected_fee_switch {
            pending[index] as u128
        } else {
            0
        };
        let reward = inflation + fee;
        let delta = U256::checked_div(
            U256::checked_mul(U256::from(reward), q).unwrap(),
            U256::from(units),
        )
        .unwrap();
        let credit = pool_event(closing, "::stake::PoCRewardCredited", *pool);
        assert_eq!(integer(&credit.data["closing_epoch"]), before.epoch as u128);
        assert_eq!(integer(&credit.data["reward_base_octa"]), reward_base);
        assert_eq!(integer(&credit.data["inflation"]), inflation);
        assert_eq!(integer(&credit.data["fee"]), fee);
        assert_eq!(wide(&credit.data["delta_index"]), delta);
        let split = pool_event(closing, "::stake::PoCRewardSplit", *pool);
        assert_eq!(integer(&split.data["total_inflation_octa"]), inflation);
        assert_eq!(integer(&split.data["poc_inflation_octa"]), inflation);
        assert_eq!(integer(&split.data["active_native_reward_octa"]), 0);
        assert_eq!(
            integer(&split.data["pending_inactive_native_reward_octa"]),
            0
        );
        assert_eq!(integer(&pool_after[3]) - integer(&pool_before[3]), reward);
        assert_eq!(
            wide(&pool_after[4]),
            U256::checked_add(wide(&pool_before[4]), delta).unwrap()
        );
    }
    assert!(events(closing, "::stake::DistributeRewards").is_empty());
    assert!(events(closing, "::stake::DistributeTransactionFee").is_empty());
    assert!(pending_fees_at(&fixture.client, version)
        .await
        .iter()
        .all(|fee| *fee == 0));
    counts
}

async fn rew03_transfer_block(
    fixture: &Fixture,
    transfer: &UserTransaction,
    burn_price: u64,
    fee_switch: bool,
    fee_limit: u64,
) -> (u64, u64) {
    let distributable = distributable_fee(transfer, burn_price);
    assert!(distributable > fee_limit);
    let statement = events(transfer, "::transaction_fee::FeeStatement");
    assert_eq!(statement.len(), 1);
    let refund = integer(&statement[0].data["storage_fee_refund_octas"]);
    let sender = transfer.request.sender.into();
    let balance_before = fixture
        .client
        .view_apt_account_balance_at_version(sender, transfer.info.version.0 - 1)
        .await
        .unwrap()
        .into_inner();
    let balance_after = fixture
        .client
        .view_apt_account_balance_at_version(sender, transfer.info.version.0)
        .await
        .unwrap()
        .into_inner();
    let gas = transfer.info.gas_used.0 * transfer.request.gas_unit_price.0;
    assert_eq!(
        balance_after as i128 - balance_before as i128,
        -1_000 - gas as i128 + refund as i128
    );
    let block = fixture
        .client
        .get_block_by_version_bcs(transfer.info.version.0, true)
        .await
        .unwrap()
        .into_inner();
    let transactions = block.transactions.unwrap();
    let epilogue = transactions.last().unwrap();
    let amounts = match &epilogue.transaction {
        Transaction::BlockEpilogue(BlockEpiloguePayload::V1 {
            fee_distribution: FeeDistribution::V0 { amount },
            ..
        })
        | Transaction::BlockEpilogue(BlockEpiloguePayload::V2 {
            fee_distribution: FeeDistribution::V0 { amount },
            ..
        }) => amount,
        other => panic!("预期区块收尾交易包含费用分配，实际为 {other:?}"),
    };
    let before = pending_fees_at(&fixture.client, epilogue.version - 1).await;
    let after = pending_fees_at(&fixture.client, epilogue.version).await;
    let features = resource_at_version::<Features>(&fixture.client, epilogue.version).await;
    assert_eq!(
        features.is_enabled(FeatureFlag::DISTRIBUTE_TRANSACTION_FEE),
        fee_switch
    );
    // 分发开关属于 Epoch 结算快照；关闭时 VM 仍计算费用归属，
    // 区块收尾仍按当前限额记录，结奖时才将该期可分发费用置零。
    assert_eq!(
        amounts.values().map(|amount| *amount as u128).sum::<u128>(),
        distributable as u128
    );
    for (index, (old, new)) in before.iter().zip(&after).enumerate() {
        let distributed = amounts.get(&(index as u64)).copied().unwrap_or(0);
        assert_eq!(
            *new as u128,
            (*old as u128 + distributed as u128).min(fee_limit as u128)
        );
    }
    (epilogue.version, distributable)
}

async fn rew03_wait_counts(
    fixture: &Fixture,
    pool: AccountAddress,
    require_success: bool,
    require_failure: bool,
) -> (u128, u128, u64) {
    tokio::time::timeout(Duration::from_secs(90), async {
        loop {
            let ledger = fixture
                .client
                .get_ledger_information()
                .await
                .unwrap()
                .into_inner();
            let installed = installed_at(&fixture.client, ledger.version).await;
            let (_, successful, failed) = rew03_counts(&fixture.client, &installed, ledger.version)
                .await
                .into_iter()
                .find(|(address, _, _)| *address == pool)
                .unwrap();
            if (!require_success || successful > 0) && (!require_failure || failed > 0) {
                break (successful, failed, ledger.version);
            }
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
    })
    .await
    .expect("等待真实成功/失败提案计数超时")
}

/// REW-03：在一个 3600 秒 Epoch 的生产节点链上依次验证限额零、费用开关关闭、
/// 正限额封顶，以及无提案和成功/失败提案比例。零 units 无法由合法委员会入口构造：
/// 预检会先排除零权重池，因此该分支继续由隔离状态测试负责。
#[tokio::test]
async fn poc_positive_inflation_fee_switch_limits_and_performance() {
    Lazy::force(&REW03_GOVERNANCE);
    let mut fixture = fixture(0).await;
    let target = fixture.users[1].address();
    let prepared_epoch = prepare(&fixture, 0).await;
    let prepared_version = fixture
        .client
        .get_ledger_information()
        .await
        .unwrap()
        .into_inner()
        .version;
    assert_eq!(
        integer(
            &optional_resource_at_version(
                &fixture.client,
                CORE_CODE_ADDRESS,
                "0x1::block::BlockResource",
                prepared_version,
            )
            .await
            .unwrap()
            .data["epoch_interval"],
        ),
        3_600_000_000
    );
    let (priced_factory, burn_price) =
        priced_fee_factory(&fixture.client, &fixture.factory, prepared_version).await;

    // 安装 1/2 奖励率和零费用限额；创世正 APY 的旧期先由既有准备断言结算。
    success(
        execute(
            &fixture.client,
            &fixture.root,
            &fixture.factory,
            rew03_governance(0, 0),
        )
        .await,
    );
    // 不插入查询或付费负载，紧邻结束刚安装的 Epoch；委员会成员数大于
    // 该间隔内的真实提案者数，从交易前快照证明至少一池走无提案分支。
    let close_no_proposal = success(
        execute(
            &fixture.client,
            &fixture.root,
            &fixture.factory,
            rew03_governance(0, 0),
        )
        .await,
    );
    let no_proposal_counts = assert_rew03_close(&fixture, &close_no_proposal, true, 0).await;
    assert_eq!(
        installed_at(&fixture.client, close_no_proposal.info.version.0)
            .await
            .epoch,
        prepared_epoch + 2
    );
    assert!(no_proposal_counts
        .iter()
        .any(|(_, successful, failed)| *successful == 0 && *failed == 0));
    assert!(events(&close_no_proposal, "::stake::PoCRewardCredited")
        .iter()
        .any(|event| integer(&event.data["inflation"]) > 0));

    // 第二个零限额 Epoch 提交真实转账；收费和可分发费用计算保持开启，
    // 但每池累加器仍严格保持为零，通胀在结奖时照常计算。
    let zero_limit_transfer = success(
        execute(
            &fixture.client,
            &fixture.users[0],
            &priced_factory,
            aptos_stdlib::topo_coin_transfer(target, 1_000),
        )
        .await,
    );
    let (zero_limit_fee_version, zero_limit_distributable) =
        rew03_transfer_block(&fixture, &zero_limit_transfer, burn_price, true, 0).await;
    assert!(zero_limit_transfer.info.gas_used.0 > 0);
    assert!(zero_limit_distributable > 0);
    assert!(pending_fees_at(&fixture.client, zero_limit_fee_version)
        .await
        .iter()
        .all(|fee| *fee == 0));

    // 关闭费用功能并把目标期限额改为 17；待结束期仍按已安装的零限额结算。
    let disable_fee = success(
        execute(
            &fixture.client,
            &fixture.root,
            &fixture.factory,
            rew03_governance(1, 17),
        )
        .await,
    );
    assert_rew03_close(&fixture, &disable_fee, true, 0).await;
    assert!(events(&disable_fee, "::stake::PoCRewardCredited")
        .iter()
        .any(|event| integer(&event.data["inflation"]) > 0));
    let disabled = installed_at(&fixture.client, disable_fee.info.version.0).await;
    assert_eq!(disabled.reward_context.4, false);
    assert_eq!(disabled.reward_context.5, 17);

    // 停止目标节点直到它错过真实提案，再恢复并等待同一 Epoch 成功提案。
    fixture.swarm.validator_mut(target).unwrap().stop();
    let (_, failed_before_restart, _) = rew03_wait_counts(&fixture, target, false, true).await;
    assert!(failed_before_restart > 0);
    fixture
        .swarm
        .validator_mut(target)
        .unwrap()
        .start()
        .unwrap();
    let (successful, failed, recovered_version) =
        rew03_wait_counts(&fixture, target, true, true).await;
    assert!(successful > 0 && failed >= failed_before_restart);
    fixture
        .client
        .wait_for_version(recovered_version)
        .await
        .unwrap();
    let disabled_transfer = success(
        execute(
            &fixture.client,
            &fixture.users[0],
            &priced_factory,
            aptos_stdlib::topo_coin_transfer(target, 1_000),
        )
        .await,
    );
    rew03_transfer_block(&fixture, &disabled_transfer, burn_price, false, 17).await;
    assert!(disabled_transfer.info.gas_used.0 > 0);

    // 重新启用费用功能；关闭的 Epoch 只结算通胀，且按真实成功/失败比例取整。
    let enable_fee = success(
        execute(
            &fixture.client,
            &fixture.root,
            &fixture.factory,
            rew03_governance(2, 17),
        )
        .await,
    );
    let mixed_counts = assert_rew03_close(&fixture, &enable_fee, false, 17).await;
    let target_counts = mixed_counts
        .iter()
        .find(|(pool, _, _)| *pool == target)
        .unwrap();
    assert!(target_counts.1 > 0 && target_counts.2 > 0);
    assert!(
        integer(&pool_event(&enable_fee, "::stake::PoCRewardCredited", target).data["inflation"])
            > 0
    );
    let enabled = installed_at(&fixture.client, enable_fee.info.version.0).await;
    assert_eq!(enabled.reward_context.4, true);
    assert_eq!(enabled.reward_context.5, 17);

    // 单笔可分发额超过 17，累加器只能记录 17；结奖同时保留正通胀。
    let capped_transfer = success(
        execute(
            &fixture.client,
            &fixture.users[0],
            &priced_factory,
            aptos_stdlib::topo_coin_transfer(target, 1_000),
        )
        .await,
    );
    let (capped_version, distributable) =
        rew03_transfer_block(&fixture, &capped_transfer, burn_price, true, 17).await;
    assert!(distributable > 17);
    assert!(pending_fees_at(&fixture.client, capped_version)
        .await
        .iter()
        .any(|fee| *fee == 17));
    let close_capped = success(
        execute(
            &fixture.client,
            &fixture.root,
            &fixture.factory,
            rew03_governance(0, 17),
        )
        .await,
    );
    assert_rew03_close(&fixture, &close_capped, true, 17).await;
    assert!(events(&close_capped, "::stake::PoCRewardCredited")
        .iter()
        .any(|event| integer(&event.data["inflation"]) > 0));
    assert!(events(&close_capped, "::stake::PoCRewardCredited")
        .iter()
        .any(|event| integer(&event.data["fee"]) == 17));
    let final_version = close_capped.info.version.0;
    let reference = installed_at(&fixture.client, final_version).await;
    for validator in &reference.validators.active_validators {
        let client = fixture
            .swarm
            .validator(validator.account_address)
            .unwrap()
            .rest_client();
        client.wait_for_version(final_version).await.unwrap();
        assert_eq!(installed_at(&client, final_version).await, reference);
        assert_eq!(
            pool_at(&client, validator.account_address, final_version).await,
            pool_at(&fixture.client, validator.account_address, final_version).await
        );
    }
}

#[tokio::test]
async fn poc_fee_only_zero_native_split_claims_and_rollback() {
    run_fee_scenario(0).await;
}

#[tokio::test]
async fn poc_fee_only_default_native_split_claims_and_rollback() {
    run_fee_scenario(3000).await;
}
