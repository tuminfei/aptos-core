// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

//! REW-04 / REW-05：跨真实费用入账 Epoch 验证精确小数奖励。
//! 参考账本独立累积每个 Epoch 的持仓者权益，不依赖 Move 查询。

use super::{
    defaults::installed_at,
    fee_rewards::{
        address, assert_payment, assert_position, assert_transfer_fee_block, checkpoint_at, events,
        integer, ledger_at, pending_fees_at, pool_at, pool_event, position_at, priced_fee_factory,
        recorded_fee, stakes_at, success, wide,
    },
    optional_resource_at_version,
    transactions::{compile_script, execute},
};
use crate::smoke_test_environment::SwarmBuilder;
use aptos_cached_packages::aptos_stdlib;
use aptos_forge::{LocalSwarm, NodeExt, Swarm};
use aptos_genesis::poc::{DeploymentMode, PocGenesisConfiguration, PowerParams};
use aptos_rest_client::Client;
use aptos_sdk::{transaction_builder::TransactionFactory, types::LocalAccount};
use aptos_types::{
    account_address::AccountAddress,
    account_config::CORE_CODE_ADDRESS,
    on_chain_config::{OnChainChunkyDKGConfig, OnChainRandomnessConfig},
    transaction::{Script, TransactionArgument, TransactionPayload},
};
use move_core_types::int256::U256;
use once_cell::sync::Lazy;
use serde_json::{json, Value};
use std::{collections::BTreeSet, sync::Arc, time::Duration};

const S: u128 = 1 << 16;

fn q() -> U256 {
    U256::ONE << U256::from(128_u8)
}

static GOVERNANCE: Lazy<Vec<u8>> = Lazy::new(|| {
    compile_script(
        "PoCFractionalRewardCheckpoints",
        r#"script {
            use topo_std::fixed_point64;
            use topo_framework::stake;
            use topo_framework::staking_config;
            use topo_framework::topo_governance;

            fun main(root: &signer, configure: bool) {
                let framework = topo_governance::get_signer_testnet_only(root, @0x1);
                if (configure) {
                    let zero = fixed_point64::create_from_rational(0, 1);
                    staking_config::update_rewards_config(&framework, zero, zero, 31536000, zero);
                    stake::set_transaction_fee_limit_per_epoch_per_pool(&framework, 1);
                };
                topo_governance::reconfigure(&framework);
            }
        }"#,
    )
});

fn governance(configure: bool) -> TransactionPayload {
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
    raw: u64,
}

impl Fixture {
    fn target(&self) -> AccountAddress {
        self.users[1].address()
    }
}

async fn fixture(raw: u64) -> Fixture {
    Lazy::force(&GOVERNANCE);
    println!("REW-04/05 fixture A: 6 nodes (4 background + 2 owners), Open, min_validators=4, min_power=1, max_power=10, initial_power={raw}, each bond=100 Octa, ratio=1 TOPO/OHMP, epoch=3600s, growth=25%, retention=10000, native_bps=0, fee_max=1, initial_fee_limit=0; ordinary/Chunky DKG=off; governance installs zero inflation; users gas=1, fee workload gas=max(100,burn+1)");
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
                    min_power: 1,
                    max_power: 10,
                    min_validators: 4,
                },

                deployment_mode: DeploymentMode::Open,
                retention_bps: 10000,
                initial_raw_power: raw,
            }));
        }))
        .build()
        .await;
    super::configure_fixture(&swarm, [4, 4, 32, 8, 1], 0).await;
    let mut pools = swarm
        .validators()
        .map(|node| node.peer_id())
        .collect::<Vec<_>>();
    pools.sort();
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
    for owner in &pools[..2] {
        public.mint(*owner, 1_000_000_000).await.unwrap();
        let key = swarm
            .validator(*owner)
            .unwrap()
            .account_private_key()
            .as_ref()
            .unwrap()
            .private_key();
        let sequence = client
            .get_account(*owner)
            .await
            .unwrap()
            .into_inner()
            .sequence_number;
        users.push(LocalAccount::new(*owner, key, sequence));
    }
    Fixture {
        swarm,
        client,
        root,
        users: users.try_into().unwrap(),
        pools,
        factory,
        raw,
    }
}

/// 所有金额预期均来自显式的逐 Epoch 奖励输入和持仓归属。
/// 特别地，池级除法余数不会结转到下一期。
#[derive(Default)]
struct Model {
    index: U256,
    credited: u64,
    paid: u64,
    accrued: [U256; 2],
}

impl Model {
    fn credit(&mut self, units: [u128; 2]) -> U256 {
        let total = units.iter().sum::<u128>();
        let delta = U256::checked_div(q(), U256::from(total)).unwrap();
        self.index = U256::checked_add(self.index, delta).unwrap();
        self.credited += 1;
        for (accrued, units) in self.accrued.iter_mut().zip(units) {
            *accrued = U256::checked_add(
                *accrued,
                U256::checked_mul(delta, U256::from(units)).unwrap(),
            )
            .unwrap();
        }
        delta
    }

    fn claimable(&self, user: usize) -> u64 {
        u64::try_from(U256::checked_div(self.accrued[user], q()).unwrap()).unwrap()
    }

    fn fraction(&self, user: usize) -> U256 {
        U256::checked_rem(self.accrued[user], q()).unwrap()
    }

    fn claim(&mut self, user: usize) -> u64 {
        let amount = self.claimable(user);
        self.accrued[user] = self.fraction(user);
        self.paid += amount;
        amount
    }
}

async fn allocate(f: &Fixture, user: usize, ratio: u64) -> u64 {
    let (pools, ratios) = if ratio == 0 {
        (vec![], vec![])
    } else {
        (vec![f.target()], vec![ratio])
    };
    let transaction = success(
        execute(
            &f.client,
            &f.users[user],
            &f.factory,
            aptos_stdlib::poc_allocation_set_allocations(pools, ratios),
        )
        .await,
    );
    let version = transaction.info.version.0;
    let scheduled = events(&transaction, "::poc_accounting::AllocationScheduled");
    assert_eq!(scheduled.len(), 1);
    assert_eq!(address(&scheduled[0].data["user"]), f.users[user].address());
    assert_eq!(
        integer(&scheduled[0].data["effective_epoch"]),
        (installed_at(&f.client, version).await.epoch + 1) as u128
    );
    assert_eq!(
        scheduled[0].data["pools"]
            .as_array()
            .unwrap()
            .iter()
            .map(address)
            .collect::<Vec<_>>(),
        if ratio == 0 { vec![] } else { vec![f.target()] }
    );
    assert_eq!(
        scheduled[0].data["bps"],
        if ratio == 0 {
            json!([])
        } else {
            json!([ratio.to_string()])
        }
    );
    assert!(events(&transaction, "::poc_accounting::PoCRewardClaimed").is_empty());
    assert_payment(&f.client, &transaction, 0).await;
    assert_eq!(
        installed_at(&f.client, version - 1).await,
        installed_at(&f.client, version).await
    );
    assert_eq!(
        stakes_at(&f.client, &f.pools, version - 1).await,
        stakes_at(&f.client, &f.pools, version).await
    );
    let before = pool_at(&f.client, f.target(), version - 1).await;
    let after = pool_at(&f.client, f.target(), version).await;
    assert_eq!(
        before[3..],
        after[3..],
        "Allocation must not change the vault or reward index"
    );
    version
}

async fn prepare(f: &Fixture, ratios: [u64; 2]) -> u64 {
    for (user, ratio) in ratios.into_iter().enumerate() {
        allocate(f, user, ratio).await;
    }
    let transaction = success(execute(&f.client, &f.root, &f.factory, governance(true)).await);
    let version = transaction.info.version.0;
    let before = installed_at(&f.client, version - 1).await;
    let after = installed_at(&f.client, version).await;
    assert_eq!(after.epoch, before.epoch + 1);
    assert_eq!(after.reward_context, (after.epoch, true, 0, 1, true, 1));
    assert_eq!(
        integer(&after.reward_split["installed_native_reward_bps"]),
        0
    );
    assert_eq!(after.validators.active_validators.len(), 5);
    assert_eq!(after.validators.total_voting_power, 5 * f.raw as u128);
    assert!(after
        .validators
        .active_validators
        .iter()
        .all(|v| v.consensus_voting_power() == f.raw));
    assert!(!after
        .validators
        .active_validators
        .iter()
        .any(|v| v.account_address == f.users[0].address()));
    assert_eq!(before.reward_context.5, 0);
    assert!((f.raw as u128) * (before.reward_context.2 as u128) < before.reward_context.3 as u128);
    for validator in &before.validators.active_validators {
        let credit = pool_event(
            &transaction,
            "::stake::PoCRewardCredited",
            validator.account_address,
        );
        assert_eq!(integer(&credit.data["inflation"]), 0);
        assert_eq!(integer(&credit.data["fee"]), 0);
        assert_eq!(wide(&credit.data["delta_index"]), U256::ZERO);
    }
    let units = ratios.map(|ratio| f.raw as u128 * S * ratio as u128 / 10_000);
    assert_state(f, &Model::default(), units, version).await;
    println!(
        "REW-04/05 preparation: version={version}, epoch={}, target={}, units={units:?}",
        after.epoch,
        f.target()
    );
    version
}

async fn fill_fee(f: &Fixture) {
    let version = f
        .client
        .get_ledger_information()
        .await
        .unwrap()
        .into_inner()
        .version;
    let epoch = installed_at(&f.client, version).await.epoch;
    assert!(pending_fees_at(&f.client, version)
        .await
        .iter()
        .all(|fee| *fee == 0));
    let (priced, burn) = priced_fee_factory(&f.client, &f.factory, version).await;
    assert!(
        burn >= 1,
        "Ordinary gas=1 operations must not contribute distributable fees"
    );
    tokio::time::timeout(Duration::from_secs(90), async {
        loop {
            let transfer = success(
                execute(
                    &f.client,
                    &f.users[0],
                    &priced,
                    aptos_stdlib::topo_coin_transfer(f.target(), 1_000),
                )
                .await,
            );
            let (version, _, distributable) =
                assert_transfer_fee_block(&f.client, &transfer, burn, epoch, 1).await;
            assert!(distributable > 1);
            if recorded_fee(&f.client, f.target(), version).await == 1 {
                break;
            }
        }
    })
    .await
    .expect("The target's one-Octa fee cap was not reached within 90 seconds");
}

async fn close(
    f: &Fixture,
    model: &mut Model,
    closing_units: [u128; 2],
    next_units: [u128; 2],
) -> u64 {
    let transaction = success(execute(&f.client, &f.root, &f.factory, governance(false)).await);
    let version = transaction.info.version.0;
    let before = installed_at(&f.client, version - 1).await;
    let after = installed_at(&f.client, version).await;
    assert_eq!(after.epoch, before.epoch + 1);
    assert_eq!(after.validators, before.validators);
    assert_eq!(before.reward_context, (before.epoch, true, 0, 1, true, 1));
    assert_eq!(after.reward_context, (after.epoch, true, 0, 1, true, 1));
    assert_eq!(
        integer(&after.reward_split["installed_native_reward_bps"]),
        0
    );
    assert_eq!(events(&transaction, "::stake::PoCEpochInstalled").len(), 1);
    assert!(events(&transaction, "::stake::DistributeRewards").is_empty());
    assert!(events(&transaction, "::stake::DistributeTransactionFee").is_empty());
    assert_eq!(recorded_fee(&f.client, f.target(), version - 1).await, 1);
    assert_eq!(
        stakes_at(&f.client, &f.pools, version - 1).await,
        stakes_at(&f.client, &f.pools, version).await
    );
    let delta = model.credit(closing_units);
    let credit = pool_event(&transaction, "::stake::PoCRewardCredited", f.target());
    assert_eq!(integer(&credit.data["closing_epoch"]), before.epoch as u128);
    assert_eq!(integer(&credit.data["reward_base_octa"]), f.raw as u128);
    assert_eq!(integer(&credit.data["inflation"]), 0);
    assert_eq!(integer(&credit.data["fee"]), 1);
    assert_eq!(wide(&credit.data["delta_index"]), delta);
    assert_eq!(
        integer(&ledger_at(&f.client, f.target(), version).await["reward_epoch"]),
        before.epoch as u128
    );
    let split = pool_event(&transaction, "::stake::PoCRewardSplit", f.target());
    assert_eq!(integer(&split.data["native_reward_bps"]), 0);
    for field in [
        "total_inflation_octa",
        "active_native_reward_octa",
        "pending_inactive_native_reward_octa",
        "poc_inflation_octa",
    ] {
        assert_eq!(integer(&split.data[field]), 0);
    }
    for resource in [
        "0x1::stake::EpochPlan",
        "0x1::stake::PrecomputedValidatorSet",
    ] {
        assert!(
            optional_resource_at_version(&f.client, CORE_CODE_ADDRESS, resource, version)
                .await
                .is_none()
        );
    }
    assert_state(f, model, next_units, version).await;
    println!("REW-04/05 closing: epoch={}, version={version}, fee=1, delta={delta:?}, model_index={:?}, closing_units={closing_units:?}, next_units={next_units:?}, credited={}, paid={}", before.epoch, model.index, model.credited, model.paid);
    version
}

async fn assert_state(f: &Fixture, model: &Model, units: [u128; 2], version: u64) {
    let pool = pool_at(&f.client, f.target(), version).await;
    assert_eq!(integer(&pool[0]), units.iter().sum::<u128>());
    assert_eq!(integer(&pool[1]), units.iter().sum::<u128>());
    assert_eq!(integer(&pool[2]), f.raw as u128);
    assert_eq!(integer(&pool[3]), (model.credited - model.paid) as u128);
    assert_eq!(wide(&pool[4]), model.index);
    for (user, units) in units.into_iter().enumerate() {
        assert_position(
            &f.client,
            f.users[user].address(),
            f.target(),
            units,
            model.claimable(user),
            model.fraction(user),
            version,
        )
        .await;
    }
}

async fn raw_position(f: &Fixture, user: usize, version: u64) -> Value {
    let allocation = optional_resource_at_version(
        &f.client,
        f.users[user].address(),
        "0x1::poc_accounting::UserAllocation",
        version,
    )
    .await
    .unwrap()
    .data;
    f.client
        .get_table_item_at_version(
            address(&allocation["positions"]["handle"]),
            "address",
            "0x1::poc_accounting::Position",
            f.target().to_hex_literal(),
            version,
        )
        .await
        .unwrap()
        .into_inner()
}

async fn assert_readonly(f: &Fixture, model: &Model, units: [u128; 2], version: u64) {
    let before = [
        raw_position(f, 0, version).await,
        raw_position(f, 1, version).await,
    ];
    let ledger = ledger_at(&f.client, f.target(), version).await;
    let installed = installed_at(&f.client, version).await;
    let checkpoint_epochs = before
        .iter()
        .flat_map(|position| {
            position["changes"]
                .as_array()
                .unwrap()
                .iter()
                .map(|change| u64::try_from(integer(&change["epoch"])).unwrap())
        })
        .collect::<BTreeSet<_>>();
    let mut checkpoints = Vec::new();
    for epoch in checkpoint_epochs {
        checkpoints.push((
            epoch,
            checkpoint_at(&f.client, f.target(), epoch, version).await,
        ));
    }
    for _ in 0..2 {
        assert_state(f, model, units, version).await;
    }
    let latest = f
        .client
        .get_ledger_information()
        .await
        .unwrap()
        .into_inner()
        .version;
    assert_eq!(installed_at(&f.client, latest).await, installed);
    assert_eq!(ledger_at(&f.client, f.target(), latest).await, ledger);
    for (user, expected) in before.into_iter().enumerate() {
        assert_eq!(raw_position(f, user, latest).await, expected);
    }
    for (epoch, expected) in checkpoints {
        assert_eq!(
            checkpoint_at(&f.client, f.target(), epoch, latest).await,
            expected,
            "Read-only reward queries consumed checkpoint references"
        );
    }
}

async fn claim(f: &Fixture, model: &mut Model, user: usize, units: [u128; 2]) -> u64 {
    let amount = model.claim(user);
    let transaction = success(
        execute(
            &f.client,
            &f.users[user],
            &f.factory,
            aptos_stdlib::poc_allocation_claim_rewards(vec![f.target()]),
        )
        .await,
    );
    let version = transaction.info.version.0;
    let claims = events(&transaction, "::poc_accounting::PoCRewardClaimed");
    assert_eq!(claims.len(), usize::from(amount > 0));
    if amount > 0 {
        assert_eq!(address(&claims[0].data["user"]), f.users[user].address());
        assert_eq!(address(&claims[0].data["pool"]), f.target());
        assert_eq!(integer(&claims[0].data["amount"]), amount as u128);
    }
    assert_payment(&f.client, &transaction, amount).await;
    assert_eq!(
        installed_at(&f.client, version - 1).await,
        installed_at(&f.client, version).await
    );
    assert_eq!(
        stakes_at(&f.client, &f.pools, version - 1).await,
        stakes_at(&f.client, &f.pools, version).await
    );
    let before_allocation = optional_resource_at_version(
        &f.client,
        f.users[user].address(),
        "0x1::poc_accounting::UserAllocation",
        version - 1,
    )
    .await
    .unwrap();
    let after_allocation = optional_resource_at_version(
        &f.client,
        f.users[user].address(),
        "0x1::poc_accounting::UserAllocation",
        version,
    )
    .await
    .unwrap();
    assert_eq!(
        before_allocation.data, after_allocation.data,
        "Claim must not change allocation ratios or schedules"
    );
    assert_state(f, model, units, version).await;
    println!(
        "REW-04/05 claim: user={user}, amount={amount}, fractional={:?}, version={version}",
        model.fraction(user)
    );
    version
}

async fn compare_members(f: &Fixture, version: u64, released_checkpoints: &[u64]) {
    let installed = installed_at(&f.client, version).await;
    let reference_pool = pool_at(&f.client, f.target(), version).await;
    let reference_ledger = ledger_at(&f.client, f.target(), version).await;
    let reference_stake = stakes_at(&f.client, &f.pools, version).await;
    let positions = [
        position_at(&f.client, f.users[0].address(), f.target(), version).await,
        position_at(&f.client, f.users[1].address(), f.target(), version).await,
    ];
    for validator in &installed.validators.active_validators {
        let client = f
            .swarm
            .validator(validator.account_address)
            .unwrap()
            .rest_client();
        tokio::time::timeout(Duration::from_secs(30), client.wait_for_version(version))
            .await
            .expect("Reward checkpoint state catchup exceeded 30 seconds")
            .unwrap();
        assert_eq!(installed_at(&client, version).await, installed);
        assert_eq!(pool_at(&client, f.target(), version).await, reference_pool);
        assert_eq!(
            ledger_at(&client, f.target(), version).await,
            reference_ledger
        );
        assert_eq!(stakes_at(&client, &f.pools, version).await, reference_stake);
        for epoch in released_checkpoints {
            assert!(
                checkpoint_at(&client, f.target(), *epoch, version)
                    .await
                    .is_none(),
                "A released reward checkpoint remains on a current member"
            );
        }
        for (user, expected) in positions.iter().enumerate() {
            assert_eq!(
                &position_at(&client, f.users[user].address(), f.target(), version).await,
                expected
            );
        }
    }
}

#[tokio::test]
async fn poc_fractional_rewards_survive_zero_claim_and_allocation_replacement() {
    let f = fixture(2).await;
    let units = [S, S];
    let prepared = prepare(&f, [5_000, 5_000]).await;
    let prepared_epoch = installed_at(&f.client, prepared).await.epoch;
    let mut model = Model::default();
    fill_fee(&f).await;
    let first = close(&f, &mut model, units, units).await;
    assert_eq!(
        model.accrued,
        [U256::checked_div(q(), U256::from(2_u8)).unwrap(); 2]
    );
    assert_readonly(&f, &model, units, first).await;
    for user in 0..2 {
        assert_eq!(model.claimable(user), 0);
        let version = claim(&f, &mut model, user, units).await;
        let checkpoint = checkpoint_at(&f.client, f.target(), prepared_epoch, version).await;
        if user == 0 {
            assert_eq!(integer(&checkpoint.unwrap()["refs"]), 1);
        } else {
            assert!(checkpoint.is_none());
        }
    }
    for user in 0..2 {
        let half = allocate(&f, user, 2_500).await;
        let next_epoch = installed_at(&f.client, half).await.epoch + 1;
        let position = position_at(&f.client, f.users[user].address(), f.target(), half).await;
        assert_eq!(integer(&position[0]), S);
        assert_eq!(
            position[1],
            json!([{"epoch":next_epoch.to_string(),"units":(S/2).to_string()}])
        );
        assert_eq!(integer(&position[2]), 0);
        assert_eq!(wide(&position[3]), model.fraction(user));
        let half_pool = pool_at(&f.client, f.target(), half).await;
        assert_eq!(integer(&half_pool[0]), 2 * S);
        assert_eq!(integer(&half_pool[1]), 3 * S / 2);
        let half_changes = ledger_at(&f.client, f.target(), half).await["changes"]
            .as_array()
            .unwrap()
            .clone();
        assert_eq!(half_changes.len(), 1);
        assert_eq!(integer(&half_changes[0]["refs"]), 1);
        let version = allocate(&f, user, 5_000).await;
        assert_state(&f, &model, units, version).await;
        assert_eq!(
            ledger_at(&f.client, f.target(), version).await["changes"],
            json!([])
        );
        assert_eq!(raw_position(&f, user, version).await["changes"], json!([]));
        assert!(checkpoint_at(&f.client, f.target(), next_epoch, version)
            .await
            .is_none());
    }
    fill_fee(&f).await;
    let second = close(&f, &mut model, units, units).await;
    assert_eq!(model.accrued, [q(), q()]);
    assert_readonly(&f, &model, units, second).await;
    let mut last = second;
    for user in 0..2 {
        assert_eq!(model.claimable(user), 1);
        claim(&f, &mut model, user, units).await;
        assert_eq!(model.claimable(user), 0);
        last = claim(&f, &mut model, user, units).await;
    }
    assert_eq!((model.credited, model.paid), (2, 2));
    assert_eq!(model.accrued, [U256::ZERO; 2]);
    compare_members(&f, last, &[prepared_epoch]).await;
}

#[tokio::test]
async fn poc_pool_division_dust_does_not_follow_replacement_positions() {
    let f = fixture(3).await;
    let old_units = [3 * S, 0];
    let new_units = [0, 3 * S];
    prepare(&f, [10_000, 0]).await;
    let mut model = Model::default();
    fill_fee(&f).await;
    allocate(&f, 0, 0).await;
    let pending = allocate(&f, 1, 10_000).await;
    let epoch = installed_at(&f.client, pending).await.epoch;
    let changes = ledger_at(&f.client, f.target(), pending).await["changes"]
        .as_array()
        .unwrap()
        .clone();
    assert_eq!(changes.len(), 1);
    assert_eq!(integer(&changes[0]["epoch"]), (epoch + 1) as u128);
    assert_eq!(integer(&changes[0]["remove_units"]), 3 * S);
    assert_eq!(integer(&changes[0]["add_units"]), 3 * S);
    assert_eq!(integer(&changes[0]["refs"]), 2);
    let first = close(&f, &mut model, old_units, new_units).await;
    let delta = U256::checked_div(q(), U256::from(3 * S)).unwrap();
    let old_fraction = U256::checked_sub(q(), U256::from(S)).unwrap();
    assert_eq!(model.accrued, [old_fraction, U256::ZERO]);
    let checkpoint = checkpoint_at(&f.client, f.target(), epoch + 1, first)
        .await
        .unwrap();
    assert_eq!(wide(&checkpoint["index"]), delta);
    assert_eq!(integer(&checkpoint["refs"]), 2);
    assert_readonly(&f, &model, new_units, first).await;
    assert_eq!(
        ledger_at(&f.client, f.target(), first).await["changes"],
        json!([])
    );

    fill_fee(&f).await;
    close(&f, &mut model, new_units, new_units).await;
    assert_eq!(model.accrued, [old_fraction, old_fraction]);
    let old_claim = claim(&f, &mut model, 0, new_units).await;
    assert_eq!(
        integer(
            &checkpoint_at(&f.client, f.target(), epoch + 1, old_claim)
                .await
                .unwrap()["refs"]
        ),
        1
    );
    let new_claim = claim(&f, &mut model, 1, new_units).await;
    assert!(checkpoint_at(&f.client, f.target(), epoch + 1, new_claim)
        .await
        .is_none());
    assert_eq!(model.accrued, [old_fraction, old_fraction]);

    // 当 U=3*S 时，Q mod U=S。必须观察到第三期：只有此时，
    // 错误结转池级余量才会令指数多 1，并向 U2 多支付。
    fill_fee(&f).await;
    let third = close(&f, &mut model, new_units, new_units).await;
    assert_eq!(
        model.index,
        U256::checked_mul(delta, U256::from(3_u8)).unwrap()
    );
    let combined = U256::checked_div(
        U256::checked_mul(q(), U256::from(3_u8)).unwrap(),
        U256::from(3 * S),
    )
    .unwrap();
    assert_eq!(U256::checked_add(model.index, U256::ONE).unwrap(), combined);
    assert_eq!(model.accrued[0], old_fraction);
    assert_eq!(model.claimable(0), 0);
    assert_eq!(model.claimable(1), 1);
    assert_readonly(&f, &model, new_units, third).await;
    claim(&f, &mut model, 1, new_units).await;
    assert_eq!(
        model.accrued[1],
        U256::checked_sub(q(), U256::from(2 * S)).unwrap()
    );
    claim(&f, &mut model, 1, new_units).await;
    let last = claim(&f, &mut model, 0, new_units).await;
    assert_eq!((model.credited, model.paid), (3, 1));
    assert_eq!(model.claimable(0) + model.claimable(1), 0);
    assert_eq!(integer(&pool_at(&f.client, f.target(), last).await[3]), 2);
    compare_members(&f, last, &[epoch + 1]).await;
}
