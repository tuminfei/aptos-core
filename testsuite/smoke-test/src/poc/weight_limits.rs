// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

//! WGT-01：独立取整的原始算力、保证金、最大权重限幅及整数准入门槛。
//! 使用五个真实 Open 验证者；42 Octa 池在 min_power=17 时被排除，
//! 并通过公开入口补足保证金，期间其余四个背景成员保持在线。
//! 本测试使用明确配置的 A 变体，原生奖励及可分发费用均为零。

use super::{
    defaults::{installed_at, InstalledSnapshot},
    fee_rewards::{
        address, assert_payment, events, integer, ledger_at, pool_at, pool_event, position_at,
        success, view, wide,
    },
    optional_resource_at_version,
    transactions::{assert_abort, compile_script, execute},
};
use crate::smoke_test_environment::SwarmBuilder;
use aptos_api_types::WriteSetChange;
use aptos_cached_packages::aptos_stdlib;
use aptos_forge::{LocalSwarm, NodeExt, Swarm};
use aptos_genesis::poc::{DeploymentMode, PocGenesisConfiguration, PowerParams};
use aptos_rest_client::Client;
use aptos_sdk::{transaction_builder::TransactionFactory, types::LocalAccount};
use aptos_types::{
    account_address::AccountAddress,
    account_config::CORE_CODE_ADDRESS,
    on_chain_config::{OnChainChunkyDKGConfig, OnChainRandomnessConfig, ValidatorSet},
    transaction::{Script, TransactionArgument, TransactionPayload},
    validator_config::ValidatorConfig,
    validator_info::ValidatorInfo,
};
use move_core_types::int256::U256;
use once_cell::sync::Lazy;
use serde_json::{json, Value};
use std::{collections::BTreeMap, sync::Arc, time::Duration};
use tokio::time::{timeout, Instant};

const RAW: u64 = 17;
const UNITS: u128 = (RAW as u128) << 16;
const POWER_PER_OHMP: u128 = 100_000_000;
const BOND_RATIO: u64 = 250_000_000;
const BONDS: [u64; 5] = [42, 43, 100, 100, 100];
const ACCOUNTING: &str = "0x1::poc_accounting::AccountingState";

#[derive(Clone, Copy, Debug, PartialEq)]
struct Params {
    minimum: u64,
    maximum: u64,
}

impl Params {
    fn json(self) -> Value {
        json!({"bond_octa_per_ohmp": BOND_RATIO.to_string(),
            "min_power": self.minimum.to_string(), "max_power": self.maximum.to_string(),
            "min_validators": "4"})
    }

    fn power(self, bond: u64) -> u64 {
        let cap = (bond as u128 * POWER_PER_OHMP) / BOND_RATIO as u128;
        (RAW as u128).min(cap).min(self.maximum as u128) as u64
    }
}

fn reward_base(power: u64) -> u64 {
    (power as u128 * BOND_RATIO as u128 / POWER_PER_OHMP) as u64
}

static GOVERNANCE: Lazy<Vec<u8>> = Lazy::new(|| {
    compile_script(
        "PoCWeightLimits",
        r#"script {
        use std::features;
        use topo_std::fixed_point64;
        use topo_framework::poc_accounting;
        use topo_framework::poc_allocation;
        use topo_framework::reconfiguration;
        use topo_framework::staking_config;
        use topo_framework::topo_governance;
        fun main(root: &signer, operation: u8, minimum: u64, maximum: u64) {
            let framework = topo_governance::get_signer_testnet_only(root, @0x1);
            if (operation == 0) {
                if (features::periodical_reward_rate_decrease_enabled()) {
                    let rate = fixed_point64::create_from_rational(1, 1);
                    staking_config::update_rewards_config(&framework, rate, rate,
                        31536000, fixed_point64::create_from_rational(0, 1));
                } else {
                    staking_config::update_rewards_rate(&framework, 1, 1);
                };
            };
            if (operation == 1 || operation == 3) {
                poc_allocation::schedule_power_params(&framework,
                    poc_accounting::new_power_params(250000000, minimum, maximum, 4),
                    reconfiguration::current_epoch() + 1);
            };
            assert!(operation <= 3, 0);
            if (operation != 1) { topo_governance::reconfigure(&framework); };
        }
    }"#,
    )
});

fn governance(operation: u8, params: Params) -> TransactionPayload {
    TransactionPayload::Script(Script::new(GOVERNANCE.clone(), vec![], vec![
        TransactionArgument::U8(operation),
        TransactionArgument::U64(params.minimum),
        TransactionArgument::U64(params.maximum),
    ]))
}

struct Fixture {
    swarm: LocalSwarm,
    client: Client,
    root: Arc<LocalAccount>,
    owner: LocalAccount,
    factory: TransactionFactory,
    // 按保证金排序：精确覆盖 42/43/100/100 取整算例，另加一个
    // 保证金为 100 Octa 的背景成员；该排序不用于确定共识成员顺序。
    pools: Vec<AccountAddress>,
    bonds: BTreeMap<AccountAddress, u64>,
    configs: BTreeMap<AccountAddress, ValidatorConfig>,
    genesis: ValidatorSet,
}

async fn resource(client: &Client, owner: AccountAddress, name: &str, at: u64) -> Value {
    optional_resource_at_version(client, owner, name, at)
        .await
        .unwrap_or_else(|| panic!("Missing {name} at {owner}, version {at}"))
        .data
}

async fn version(f: &Fixture) -> u64 {
    f.client
        .get_ledger_information()
        .await
        .unwrap()
        .into_inner()
        .version
}

async fn fixture() -> Fixture {
    Lazy::force(&GOVERNANCE);
    println!("WGT-01 fixture A: 5 real validators + 1 fullnode, Open/minimum4/capacity6, growth25%, initial raw17, bonds42/43/100/100/100 Octa, 2.5 TOPO/OHMP, initial min16/max100, epoch3600s, retention10000, native_bps0, fee_limit0/fee_max0, ordinary+Chunky DKG off; public governance installs rate1/1; gas100, max_gas2000000");
    let swarm = SwarmBuilder::new_local(5)
        .with_aptos()
        .with_num_fullnodes(1)
        .with_init_genesis_stake(Arc::new(|index, amount| *amount = BONDS[index]))
        .with_init_genesis_config(Arc::new(|config| {
            config.is_test = true;
            config.allow_new_validators = true;
            config.epoch_duration_secs = 3600;
            config.min_stake = 1;
            config.max_stake = 1000;
            config.rewards_apy_percentage = 10;
            config.voting_power_increase_limit = 25;
            config.randomness_config_override = Some(OnChainRandomnessConfig::Off);
            config.chunky_dkg_config_override = Some(OnChainChunkyDKGConfig::default_disabled());
            config.poc_genesis_config = Some(Arc::new(|_| PocGenesisConfiguration {
                params: PowerParams {
                    bond_octa_per_ohmp: BOND_RATIO,
                    min_power: 16,
                    max_power: 100,
                    min_validators: 4,
                },

                deployment_mode: DeploymentMode::Open,
                retention_bps: 10000,
                initial_raw_power: RAW,
            }));
        }))
        .build()
        .await;
    super::configure_fixture(&swarm, [4, 4, 32, 6, 0], 0).await;
    let reader = swarm.validators().next().unwrap().rest_client();
    let genesis = installed_at(&reader, 0).await.validators;
    let mut observed = Vec::new();
    let mut configs = BTreeMap::new();
    for member in &genesis.active_validators {
        let pool = member.account_address;
        let balances = view(&reader, "0x1::stake::get_stake", vec![json!(pool)], 0).await;
        assert_eq!(&balances[1..], &[json!("0"), json!("0"), json!("0")]);
        observed.push((integer(&balances[0]) as u64, pool));
        let config: ValidatorConfig = reader
            .get_account_resource_at_version_bcs(pool, "0x1::stake::ValidatorConfig", 0)
            .await
            .unwrap()
            .into_inner();
        assert_eq!(member.config(), &config);
        assert!(configs.insert(pool, config).is_none());
        let stake = resource(&reader, pool, "0x1::stake::StakePool", 0).await;
        assert_eq!(address(&stake["operator_address"]), pool);
        assert_eq!(address(&stake["delegated_voter"]), pool);
    }
    observed.sort();
    assert_eq!(
        observed.iter().map(|(bond, _)| *bond).collect::<Vec<_>>(),
        BONDS
    );
    let pools = observed.iter().map(|(_, pool)| *pool).collect::<Vec<_>>();
    let bonds = pools.iter().copied().zip(BONDS).collect();
    // 选定的背景节点始终属于每一届已安装委员会。
    let client = swarm
        .validator(pools[4])
        .unwrap()
        .rest_client_with_timeout(Duration::from_secs(10));
    let root = swarm.chain_info().root_account();
    let factory = swarm
        .chain_info()
        .transaction_factory()
        .with_gas_unit_price(100)
        .with_max_gas_amount(2_000_000)
        .with_transaction_expiration_time(120);
    swarm
        .chain_info()
        .into_aptos_public_info()
        .mint(pools[0], 1_000_000_000)
        .await
        .unwrap();
    let owner = LocalAccount::new(
        pools[0],
        swarm
            .validator(pools[0])
            .unwrap()
            .account_private_key()
            .as_ref()
            .unwrap()
            .private_key(),
        client
            .get_account(pools[0])
            .await
            .unwrap()
            .into_inner()
            .sequence_number,
    );
    // 测试创世将 root 钱包余额设为 u64::MAX。提前预留余额空间，
    // 以接收换届事务清理旧费用表或候选表时退还的存储费。
    success(
        execute(
            &client,
            &root,
            &factory,
            aptos_stdlib::topo_coin_transfer(pools[4], 100_000_000),
        )
        .await,
    );
    Fixture {
        swarm,
        client,
        root,
        owner,
        factory,
        pools,
        bonds,
        configs,
        genesis,
    }
}

#[derive(Clone)]
struct Expected {
    params: Params,
    members: Vec<AccountAddress>,
    powers: BTreeMap<AccountAddress, u64>,
}

impl Expected {
    fn new(
        params: Params,
        candidates: &[AccountAddress],
        bonds: &BTreeMap<AccountAddress, u64>,
    ) -> Self {
        let members = candidates
            .iter()
            .copied()
            .filter(|pool| params.power(bonds[pool]) >= params.minimum)
            .collect::<Vec<_>>();
        let powers = members
            .iter()
            .map(|pool| (*pool, params.power(bonds[pool])))
            .collect();
        Self {
            params,
            members,
            powers,
        }
    }

    fn power(&self, pool: AccountAddress) -> u64 {
        self.powers.get(&pool).copied().unwrap_or(0)
    }

    fn total(&self) -> u128 {
        self.powers.values().map(|power| *power as u128).sum()
    }

    fn validator_set(&self, f: &Fixture, pending: Option<AccountAddress>) -> ValidatorSet {
        let active_validators = self
            .members
            .iter()
            .enumerate()
            .map(|(index, pool)| {
                let mut config = f.configs[pool].clone();
                config.validator_index = index as u64;
                ValidatorInfo::new(*pool, self.power(*pool), config)
            })
            .collect();
        ValidatorSet {
            scheme: f.genesis.scheme,
            active_validators,
            pending_active: pending
                .into_iter()
                .map(|pool| ValidatorInfo::new(pool, 0, f.configs[&pool].clone()))
                .collect(),
            pending_inactive: vec![],
            total_voting_power: self.total(),
            total_joining_power: 0,
        }
    }
}

async fn assert_installed(
    f: &Fixture,
    client: &Client,
    at: u64,
    expected: &Expected,
    pending: Option<AccountAddress>,
) -> InstalledSnapshot {
    let installed = installed_at(client, at).await;
    assert_eq!(installed.validators, expected.validator_set(f, pending));
    assert_eq!(installed.reward_context.0, installed.epoch);
    assert!(installed.reward_context.1);
    assert_eq!(installed.reward_context.5, 0);
    assert_eq!(
        installed.reward_split,
        json!({"installed_epoch": installed.epoch.to_string(),
        "installed_native_reward_bps": "0", "configured_native_reward_bps": "0", "pending_change": {"vec": []}})
    );
    let config = resource(client, CORE_CODE_ADDRESS, ACCOUNTING, at).await;
    assert_eq!(config["config"]["params"], expected.params.json());
    assert_eq!(config["config"]["first_poc_epoch"], json!({"vec": ["1"]}));
    for pool in &f.pools {
        let ledger = pool_at(client, *pool, at).await;
        assert_eq!(integer(&ledger[0]), UNITS);
        assert_eq!(integer(&ledger[1]), UNITS);
        assert_eq!(
            integer(&ledger[2]),
            reward_base(expected.power(*pool)) as u128
        );
        let position = position_at(client, *pool, *pool, at).await;
        assert_eq!(integer(&position[0]), UNITS);
        assert_eq!(position[1], json!([]));
        assert_eq!(
            view(
                client,
                "0x1::poc_power_store::get_accounting_snapshot",
                vec![json!(pool)],
                at
            )
            .await,
            vec![
                json!(UNITS.to_string()),
                json!(UNITS.to_string()),
                json!("0"),
                json!("61")
            ]
        );
        // 原始标准化版本和完整分配均不得被保证金限幅或最大权重
        // 限幅后得到的较小数值替换。
        for name in [
            "0x1::poc_power_store::get_user_power_version",
            "0x1::poc_accounting::get_allocations",
        ] {
            assert_eq!(
                view(client, name, vec![json!(pool)], at).await,
                view(client, name, vec![json!(pool)], 0).await
            );
        }
        let stake = view(client, "0x1::stake::get_stake", vec![json!(pool)], at).await;
        assert_eq!(stake, vec![
            json!(f.bonds[pool].to_string()),
            json!("0"),
            json!("0"),
            json!("0")
        ]);
        let raw = resource(client, *pool, "0x1::stake::StakePool", at).await;
        assert_eq!(address(&raw["operator_address"]), *pool);
        assert_eq!(address(&raw["delegated_voter"]), *pool);
    }
    for name in [
        "0x1::stake::EpochPlan",
        "0x1::stake::PrecomputedValidatorSet",
    ] {
        assert!(
            optional_resource_at_version(client, CORE_CODE_ADDRESS, name, at)
                .await
                .is_none()
        );
    }
    installed
}

async fn protected_state(f: &Fixture, at: u64) -> BTreeMap<String, Value> {
    let mut result = BTreeMap::new();
    for name in [
        ACCOUNTING,
        "0x1::poc_power_store::PowerStore",
        "0x1::poc_power_store::PeriodClock",
        "0x1::poc_reward_split::RewardSplitConfig",
        "0x1::stake::InstalledRewardContext",
        "0x1::stake::ValidatorSet",
        "0x1::reconfiguration::Configuration",
        "0x1::reconfiguration_state::State",
        "0x1::staking_config::StakingConfig",
        "0x1::staking_config::StakingRewardsConfig",
        "0x1::config_buffer::PendingConfigs",
        "0x1::stake::ValidatorPerformance",
        "0x1::stake::PendingTransactionFee",
        "0x1::stake::EpochPlan",
        "0x1::stake::PrecomputedValidatorSet",
    ] {
        result.insert(
            name.to_owned(),
            json!(
                optional_resource_at_version(&f.client, CORE_CODE_ADDRESS, name, at)
                    .await
                    .map(|r| r.data)
            ),
        );
    }
    for pool in &f.pools {
        for name in [
            "0x1::stake::StakePool",
            "0x1::stake::ValidatorConfig",
            "0x1::poc_accounting::UserAllocation",
        ] {
            result.insert(
                format!("{pool}/{name}"),
                resource(&f.client, *pool, name, at).await,
            );
        }
        result.insert(
            format!("{pool}/ledger"),
            ledger_at(&f.client, *pool, at).await,
        );
        result.insert(
            format!("{pool}/position"),
            json!(position_at(&f.client, *pool, *pool, at).await),
        );
        result.insert(
            format!("{pool}/power"),
            json!(
                view(
                    &f.client,
                    "0x1::poc_power_store::get_user_power_version",
                    vec![json!(pool)],
                    at
                )
                .await
            ),
        );
    }
    result
}

async fn schedule(f: &Fixture, params: Params) {
    let tx = success(execute(&f.client, &f.root, &f.factory, governance(1, params)).await);
    let at = tx.info.version.0;
    let epoch = installed_at(&f.client, at).await.epoch;
    let mut expected = protected_state(f, at - 1).await;
    expected.get_mut(ACCOUNTING).unwrap()["config"]["pending_params"] =
        json!({"vec": [{"epoch": (epoch + 1).to_string(), "params": params.json()}]});
    assert_eq!(protected_state(f, at).await, expected);
    assert_eq!(
        installed_at(&f.client, at - 1).await,
        installed_at(&f.client, at).await
    );
    assert!(tx.events.iter().all(|event| {
        let typ = event.typ.to_string();
        !typ.contains("::stake::")
            && !typ.contains("::poc_")
            && !typ.contains("::reconfiguration::")
    }));
    assert_payment(&f.client, &tx, 0).await;
}

async fn assert_preview(
    f: &Fixture,
    at: u64,
    old: &Expected,
    next: &Expected,
    joining: Option<AccountAddress>,
) {
    let installed = installed_at(&f.client, at).await;
    let time = resource(
        &f.client,
        CORE_CODE_ADDRESS,
        "0x1::timestamp::CurrentTimeMicroseconds",
        at,
    )
    .await;
    let cutoff = integer(&time["microseconds"]) / 1_000_000;
    let preview = view(
        &f.client,
        "0x1::stake::preview_epoch_transition",
        vec![
            json!((installed.epoch + 1).to_string()),
            json!(cutoff.to_string()),
        ],
        at,
    )
    .await;
    assert_eq!(preview.len(), 1);
    let preview = &preview[0];
    assert_eq!(integer(&preview["reason"]), 0);
    assert_eq!(integer(&preview["epoch"]), (installed.epoch + 1) as u128);
    assert_eq!(integer(&preview["cutoff_secs"]), cutoff);
    assert_eq!(integer(&preview["period"]), 0);
    assert_eq!(integer(&preview["period_index"]), 1u128 << 64);
    assert_eq!(preview["params"], next.params.json());
    assert_eq!(preview["poc_enabled"], json!(true));
    assert_eq!(preview["is_liveness_fallback"], json!(false));
    assert_eq!(
        preview["closing_rewards"],
        resource(
            &f.client,
            CORE_CODE_ADDRESS,
            "0x1::stake::InstalledRewardContext",
            at
        )
        .await["context"]
    );
    let set = &preview["validator_set"];
    assert_eq!(set["pending_active"], json!([]));
    assert_eq!(set["pending_inactive"], json!([]));
    assert_eq!(integer(&set["total_joining_power"]), 0);
    assert_eq!(integer(&set["total_voting_power"]), next.total());
    let members = set["active_validators"].as_array().unwrap();
    assert_eq!(members.len(), next.members.len());
    let mut increase = 0u128;
    for (index, pool) in next.members.iter().enumerate() {
        let member = &members[index];
        assert_eq!(address(&member["addr"]), *pool);
        assert_eq!(integer(&member["voting_power"]), next.power(*pool) as u128);
        let mut config = resource(&f.client, *pool, "0x1::stake::ValidatorConfig", 0).await;
        config["validator_index"] = json!(index.to_string());
        assert_eq!(
            member["config"], config,
            "Public key and both network addresses remain unchanged"
        );
        increase += next.power(*pool).saturating_sub(old.power(*pool)) as u128;
    }
    assert!(increase <= old.total() * 25 / 100);
    let candidates = old
        .members
        .iter()
        .copied()
        .chain(joining)
        .collect::<Vec<_>>();
    let targets = preview["targets"].as_array().unwrap();
    assert_eq!(targets.len(), candidates.len());
    for (target, pool) in targets.iter().zip(candidates) {
        assert_eq!(
            target,
            &json!({"pool": pool.to_hex_literal(), "units": UNITS.to_string(),
            "power": next.power(pool).to_string(), "reward_base_octa": reward_base(next.power(pool)).to_string()})
        );
    }
}

/// 旧期结算金额按已安装奖励率、旧验证者索引及独立计算的基数推导，
/// 不使用生产预览函数提供的金额作为预期。
async fn rewards_at(f: &Fixture, at: u64, expected: &Expected) -> BTreeMap<AccountAddress, u64> {
    let installed = installed_at(&f.client, at).await;
    let (_, enabled, numerator, denominator, _, fee_limit) = installed.reward_context;
    assert!(enabled && denominator > 0);
    assert_eq!(fee_limit, 0);
    let stats = resource(
        &f.client,
        CORE_CODE_ADDRESS,
        "0x1::stake::ValidatorPerformance",
        at,
    )
    .await;
    assert_eq!(
        stats["validators"].as_array().unwrap().len(),
        expected.members.len()
    );
    expected
        .members
        .iter()
        .enumerate()
        .map(|(index, pool)| {
            let counters = &stats["validators"][index];
            let successes = integer(&counters["successful_proposals"]);
            let total = successes + integer(&counters["failed_proposals"]);
            let reward = if total == 0 {
                0
            } else {
                let amount = U256::from(reward_base(expected.power(*pool))).repr()
                    * U256::from(successes).repr()
                    * U256::from(numerator).repr()
                    / (U256::from(total).repr() * U256::from(denominator).repr());
                u64::try_from(amount).unwrap()
            };
            (*pool, reward)
        })
        .collect()
}

async fn wait_for_positive_rewards(f: &Fixture, expected: &Expected) {
    let start = Instant::now();
    timeout(Duration::from_secs(60), async {
        loop {
            let at = version(f).await;
            let installed = installed_at(&f.client, at).await;
            assert_eq!(installed.reward_context.2, installed.reward_context.3);
            if rewards_at(f, at, expected).await.values().all(|amount| *amount > 0) {
                println!("Every closing voter has a positive independent reward after {:?}, version={at}", start.elapsed());
                return;
            }
            success(execute(&f.client, &f.root, &f.factory,
                aptos_stdlib::topo_coin_transfer(f.pools[4], 1)).await);
        }
    }).await.expect("Positive proposal reward preparation exceeded 60 seconds");
}

async fn assert_progress(
    f: &Fixture,
    expected: &Expected,
    installed: &InstalledSnapshot,
    committed: u64,
) {
    // 这笔签名转账在安装后提交，必须由新委员会完成共识提交。
    // 读取状态时始终使用在任节点。
    let progress = success(
        execute(
            &f.client,
            &f.root,
            &f.factory,
            aptos_stdlib::topo_coin_transfer(f.pools[4], 1),
        )
        .await,
    );
    let at = progress.info.version.0;
    assert!(at > committed);
    assert_eq!(installed_at(&f.client, at).await, *installed);
    let mut ledgers = BTreeMap::new();
    let mut positions = BTreeMap::new();
    for pool in &f.pools {
        let ledger = ledger_at(&f.client, *pool, at).await;
        assert_eq!(ledger, ledger_at(&f.client, *pool, committed).await);
        ledgers.insert(*pool, ledger);
        positions.insert(*pool, position_at(&f.client, *pool, *pool, at).await);
    }
    for pool in &expected.members {
        let client = f
            .swarm
            .validator(*pool)
            .unwrap()
            .rest_client_with_timeout(Duration::from_secs(10));
        timeout(Duration::from_secs(30), client.wait_for_version(at))
            .await
            .expect("Current committee catchup exceeded 30 seconds")
            .unwrap();
        assert_eq!(
            assert_installed(f, &client, at, expected, None).await,
            *installed
        );
        for candidate in &f.pools {
            assert_eq!(ledger_at(&client, *candidate, at).await, ledgers[candidate]);
            assert_eq!(
                position_at(&client, *candidate, *candidate, at).await,
                positions[candidate]
            );
        }
    }
}

async fn commit(
    f: &Fixture,
    old: &Expected,
    next: &Expected,
    setup_rate: bool,
    joining: Option<AccountAddress>,
) -> u64 {
    if !setup_rate {
        wait_for_positive_rewards(f, old).await;
    }
    let intended = version(f).await;
    let intended_install = assert_installed(f, &f.client, intended, old, joining).await;
    assert_preview(f, intended, old, next, joining).await;
    let tx = success(
        execute(
            &f.client,
            &f.root,
            &f.factory,
            governance(if setup_rate { 0 } else { 2 }, next.params),
        )
        .await,
    );
    let at = tx.info.version.0;
    let before = assert_installed(f, &f.client, at - 1, old, joining).await;
    assert_eq!(
        before, intended_install,
        "No unsolicited epoch installation during preparation"
    );
    let after = assert_installed(f, &f.client, at, next, None).await;
    assert_eq!(after.epoch, before.epoch + 1);
    assert!(
        after.epoch < 61,
        "Keep all phases in the original power period"
    );
    assert_eq!(after.reward_context.2, after.reward_context.3);
    assert!(after.reward_context.3 > 0);
    let mut config = resource(&f.client, CORE_CODE_ADDRESS, ACCOUNTING, at - 1).await;
    config["epoch"] = json!(after.epoch.to_string());
    config["config"]["params"] = next.params.json();
    config["config"]["pending_params"] = json!({"vec": []});
    assert_eq!(
        resource(&f.client, CORE_CODE_ADDRESS, ACCOUNTING, at).await,
        config
    );
    let mut clock = resource(
        &f.client,
        CORE_CODE_ADDRESS,
        "0x1::poc_power_store::PeriodClock",
        at - 1,
    )
    .await;
    clock["last_epoch"] = json!((integer(&clock["last_epoch"]) + 1).to_string());
    clock["epochs_until_next_power_period"] =
        json!((integer(&clock["epochs_until_next_power_period"]) - 1).to_string());
    assert_eq!(
        resource(
            &f.client,
            CORE_CODE_ADDRESS,
            "0x1::poc_power_store::PeriodClock",
            at
        )
        .await,
        clock
    );
    assert_eq!(
        resource(
            &f.client,
            CORE_CODE_ADDRESS,
            "0x1::poc_power_store::PowerStore",
            at
        )
        .await,
        resource(
            &f.client,
            CORE_CODE_ADDRESS,
            "0x1::poc_power_store::PowerStore",
            at - 1
        )
        .await
    );
    let rewards = rewards_at(f, at - 1, old).await;
    assert_eq!(
        events(&tx, "::stake::PoCRewardCredited").len(),
        old.members.len()
    );
    assert_eq!(
        events(&tx, "::stake::PoCRewardSplit").len(),
        old.members.len()
    );
    if !setup_rate {
        assert!(
            rewards.values().all(|amount| *amount > 0),
            "Each old voter must actually retain a positive reward"
        );
    }
    for pool in &f.pools {
        let amount = rewards.get(pool).copied().unwrap_or(0);
        let delta = (U256::from(amount).repr() << 128u32) / U256::from(UNITS).repr();
        let prior = pool_at(&f.client, *pool, at - 1).await;
        let current = pool_at(&f.client, *pool, at).await;
        assert_eq!(integer(&current[3]) - integer(&prior[3]), amount as u128);
        assert_eq!(wide(&current[4]).repr() - wide(&prior[4]).repr(), delta);
        let prior_position = position_at(&f.client, *pool, *pool, at - 1).await;
        let current_position = position_at(&f.client, *pool, *pool, at).await;
        let accrued = |position: &[Value]| {
            (U256::from(integer(&position[2])).repr() << 128u32) + wide(&position[3]).repr()
        };
        assert_eq!(
            accrued(&current_position) - accrued(&prior_position),
            U256::from(UNITS).repr() * delta
        );
        // 此前未发生领取；全部 PoC 入账（包括取整余量）仍在金库中，
        // 不会转为原生保证金本金。
        assert_eq!(
            view(&f.client, "0x1::stake::get_stake", vec![json!(pool)], at).await,
            view(
                &f.client,
                "0x1::stake::get_stake",
                vec![json!(pool)],
                at - 1
            )
            .await
        );
        if rewards.contains_key(pool) {
            assert_eq!(
                pool_event(&tx, "::stake::PoCRewardCredited", *pool).data,
                json!({"pool": pool.to_hex_literal(), "closing_epoch": before.epoch.to_string(),
                    "reward_base_octa": reward_base(old.power(*pool)).to_string(), "inflation": amount.to_string(),
                    "fee": "0", "delta_index": delta.to_string()})
            );
            assert_eq!(
                pool_event(&tx, "::stake::PoCRewardSplit", *pool).data,
                json!({"pool": pool.to_hex_literal(), "closing_epoch": before.epoch.to_string(),
                    "native_reward_bps": "0", "total_inflation_octa": amount.to_string(),
                    "active_native_reward_octa": "0", "pending_inactive_native_reward_octa": "0",
                    "poc_inflation_octa": amount.to_string()})
            );
        } else {
            for suffix in ["::stake::PoCRewardCredited", "::stake::PoCRewardSplit"] {
                assert!(events(&tx, suffix)
                    .iter()
                    .all(|event| address(&event.data["pool"]) != *pool));
            }
        }
    }
    for suffix in [
        "::stake::DistributeRewards",
        "::stake::DistributeTransactionFee",
        "::poc_power_store::PowerPeriodCommittedEvent",
        "::poc_power_store::PowerNormalized",
        "::poc_accounting::AllocationScheduled",
        "::poc_accounting::PoCRewardClaimed",
    ] {
        assert!(events(&tx, suffix).is_empty());
    }
    let epoch_events = events(&tx, "::stake::PoCEpochInstalled");
    assert_eq!(epoch_events.len(), 1);
    assert_eq!(
        epoch_events[0].data,
        json!({"epoch": after.epoch.to_string(), "period": "0",
        "selected_count": next.members.len().to_string(), "total_power": next.total().to_string()})
    );
    assert_eq!(events(&tx, "::reconfiguration::NewEpochEvent").len(), 1);
    let split_events = events(&tx, "::poc_reward_split::RewardSplitInstalled");
    assert_eq!(split_events.len(), 1);
    assert_eq!(
        split_events[0].data,
        json!({"epoch": after.epoch.to_string(), "poc_enabled": true, "native_reward_bps": "0"})
    );
    assert_payment(&f.client, &tx, 0).await;
    assert_progress(f, next, &after, at).await;
    println!("Weight install: epoch{}->{}, min={}, max={}, current_members={}, total_power={}, old_rewards={rewards:?}, version={at}",
        before.epoch, after.epoch, next.params.minimum, next.params.maximum, next.members.len(), next.total());
    at
}

async fn reject_empty_target(f: &Fixture, installed: &Expected) {
    let invalid = Params {
        minimum: RAW + 1,
        maximum: 100,
    };
    assert!(f
        .pools
        .iter()
        .all(|pool| invalid.power(f.bonds[pool]) < invalid.minimum));
    let tx = execute(&f.client, &f.root, &f.factory, governance(3, invalid)).await;
    assert_abort(
        &f.client,
        &tx,
        "reconfiguration_with_dkg",
        0x30001,
        &f.pools,
        &f.pools,
    )
    .await;
    let at = tx.info.version.0;
    assert_eq!(
        protected_state(f, at).await,
        protected_state(f, at - 1).await
    );
    assert_installed(f, &f.client, at, installed, None).await;
    assert_eq!(
        resource(&f.client, CORE_CODE_ADDRESS, ACCOUNTING, at).await["config"]["pending_params"],
        json!({"vec": []})
    );
    let is_business = |name: &str| {
        name.contains("::stake::")
            || name.contains("::staking_config::")
            || name.contains("::poc_")
            || name.contains("::reconfiguration")
            || name.contains("::config_buffer::")
    };
    assert!(tx
        .events
        .iter()
        .all(|event| !is_business(&event.typ.to_string())));
    for change in &tx.info.changes {
        match change {
            WriteSetChange::WriteResource(change) => {
                assert!(!is_business(&change.data.typ.to_string()))
            },
            WriteSetChange::DeleteResource(change) => {
                assert!(!is_business(&change.resource.to_string()))
            },
            // 上面的 assert_abort 已检查所有跟踪的分配、池、
            // 检查点及 PowerStore 表句柄。
            WriteSetChange::WriteTableItem(_) | WriteSetChange::DeleteTableItem(_) => {},
            WriteSetChange::WriteModule(_) | WriteSetChange::DeleteModule(_) => {
                panic!("Module changed on abort")
            },
        }
    }
    assert_payment(&f.client, &tx, 0).await;
}

async fn repair_bond_and_join(f: &mut Fixture, current: &Expected) {
    let pool = f.owner.address();
    assert_eq!(pool, f.pools[0]);
    assert_eq!(f.bonds[&pool], 42);
    assert_eq!(current.power(pool), 0);
    let added = success(
        execute(
            &f.client,
            &f.owner,
            &f.factory,
            aptos_stdlib::stake_add_stake(1),
        )
        .await,
    );
    let at = added.info.version.0;
    let mut expected = protected_state(f, at - 1).await;
    expected
        .get_mut(&format!("{pool}/0x1::stake::StakePool"))
        .unwrap()["active"]["value"] = json!("43");
    assert_eq!(
        protected_state(f, at).await,
        expected,
        "Only the inactive candidate's bonded active principal increases"
    );
    assert_eq!(
        installed_at(&f.client, at - 1).await,
        installed_at(&f.client, at).await
    );
    let added_events = events(&added, "::stake::AddStake");
    assert_eq!(added_events.len(), 1);
    assert_eq!(
        added_events[0].data,
        json!({"pool_address": pool.to_hex_literal(), "amount_added": "1"})
    );
    assert!(added
        .events
        .iter()
        .all(|event| !event.typ.to_string().contains("::poc_")));
    let statement = events(&added, "::transaction_fee::FeeStatement");
    assert_eq!(statement.len(), 1);
    assert_eq!(
        integer(&statement[0].data["total_charge_gas_units"]),
        added.info.gas_used.0 as u128
    );
    let refund = integer(&statement[0].data["storage_fee_refund_octas"]);
    let wallet_before = f
        .client
        .view_apt_account_balance_at_version(pool, at - 1)
        .await
        .unwrap()
        .into_inner();
    let wallet_after = f
        .client
        .view_apt_account_balance_at_version(pool, at)
        .await
        .unwrap()
        .into_inner();
    assert_eq!(
        wallet_after as i128 - wallet_before as i128,
        -1 - added.info.gas_used.0 as i128 * added.request.gas_unit_price.0 as i128
            + refund as i128
    );
    f.bonds.insert(pool, 43);
    assert_installed(f, &f.client, at, current, None).await;
    let joined = success(
        execute(
            &f.client,
            &f.owner,
            &f.factory,
            aptos_stdlib::stake_join_validator_set(pool),
        )
        .await,
    );
    let at = joined.info.version.0;
    let mut expected = protected_state(f, at - 1).await;
    let mut info = resource(&f.client, CORE_CODE_ADDRESS, "0x1::stake::ValidatorSet", 0).await
        ["active_validators"]
        .as_array()
        .unwrap()
        .iter()
        .find(|info| address(&info["addr"]) == pool)
        .unwrap()
        .clone();
    info["voting_power"] = json!("0");
    expected.get_mut("0x1::stake::ValidatorSet").unwrap()["pending_active"] = json!([info]);
    assert_eq!(protected_state(f, at).await, expected);
    assert_installed(f, &f.client, at, current, Some(pool)).await;
    let joined_events = events(&joined, "::stake::JoinValidatorSet");
    assert_eq!(joined_events.len(), 1);
    assert_eq!(
        joined_events[0].data,
        json!({"pool_address": pool.to_hex_literal()})
    );
    assert!(joined
        .events
        .iter()
        .all(|event| !event.typ.to_string().contains("::poc_")));
    assert_payment(&f.client, &joined, 0).await;
}

#[tokio::test]
async fn poc_weight_limits_preserve_full_units_and_enforce_integer_admission() {
    let mut f = fixture().await;
    let genesis_order = f
        .genesis
        .active_validators
        .iter()
        .map(|member| member.account_address)
        .collect::<Vec<_>>();
    let original = Expected::new(
        Params {
            minimum: 16,
            maximum: 100,
        },
        &genesis_order,
        &f.bonds,
    );
    assert_eq!(
        f.pools[..4]
            .iter()
            .map(|pool| original.power(*pool))
            .collect::<Vec<_>>(),
        [16, 17, 17, 17]
    );
    assert_eq!(
        f.pools[..4]
            .iter()
            .map(|pool| reward_base(original.power(*pool)))
            .collect::<Vec<_>>(),
        [40, 42, 42, 42]
    );
    // 独立验证严格最小项：首池受保证金限制；100 Octa 池的
    // bond_cap=40、max=100，因此只有 raw=17 构成限幅。
    assert_eq!(42u128 * POWER_PER_OHMP / BOND_RATIO as u128, 16);
    assert_eq!(43u128 * POWER_PER_OHMP / BOND_RATIO as u128, 17);
    assert_eq!(100u128 * POWER_PER_OHMP / BOND_RATIO as u128, 40);
    assert_installed(&f, &f.client, 0, &original, None).await;
    assert_installed(&f, &f.client, version(&f).await, &original, None).await;
    commit(&f, &original, &original, true, None).await;

    let capped = Expected::new(
        Params {
            minimum: 16,
            maximum: 16,
        },
        &genesis_order,
        &f.bonds,
    );
    assert_eq!(capped.members.len(), 5);
    assert!(f.pools.iter().all(|pool| capped.power(*pool) == 16));
    assert!(
        capped.params.maximum < RAW
            && (capped.params.maximum as u128) < 100u128 * POWER_PER_OHMP / BOND_RATIO as u128
    );
    schedule(&f, capped.params).await;
    commit(&f, &original, &capped, false, None).await;

    let threshold = Expected::new(
        Params {
            minimum: 17,
            maximum: 100,
        },
        &capped.members,
        &f.bonds,
    );
    assert_eq!(threshold.members.len(), 4);
    assert_eq!(threshold.params.power(42), threshold.params.minimum - 1);
    assert!(!threshold.members.contains(&f.pools[0]));
    assert!(threshold
        .members
        .iter()
        .all(|pool| threshold.power(*pool) == 17));
    schedule(&f, threshold.params).await;
    let excluded_at = commit(&f, &capped, &threshold, false, None).await;
    let excluded = pool_at(&f.client, f.pools[0], excluded_at).await;
    assert_eq!(integer(&excluded[0]), UNITS);
    assert_eq!(integer(&excluded[2]), 0);
    assert!(integer(&excluded[3]) > 0);
    reject_empty_target(&f, &threshold).await;

    repair_bond_and_join(&mut f, &threshold).await;
    let candidates = threshold
        .members
        .iter()
        .copied()
        .chain([f.pools[0]])
        .collect::<Vec<_>>();
    let repaired = Expected::new(threshold.params, &candidates, &f.bonds);
    assert_eq!(repaired.members.len(), 5);
    assert_eq!(repaired.power(f.pools[0]), repaired.params.minimum);
    assert_eq!(
        repaired.power(f.pools[0]) as u128,
        threshold.total() * 25 / 100
    );
    let repaired_at = commit(&f, &threshold, &repaired, false, Some(f.pools[0])).await;
    let rejoined = pool_at(&f.client, f.pools[0], repaired_at).await;
    assert_eq!(integer(&rejoined[0]), UNITS);
    assert_eq!(integer(&rejoined[2]), 42);
    assert_eq!(
        &rejoined[3..],
        &excluded[3..],
        "The returning pool retains old rewards and receives none for its excluded epoch"
    );
}
