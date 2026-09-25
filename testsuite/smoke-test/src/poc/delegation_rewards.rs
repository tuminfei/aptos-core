// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

//! REW-10：真实委员会中的委托池，覆盖追加、解锁、临时入池费份额、
//! 原生佣金、仅交易费收益，以及独立计算的 PoC 权益。

use super::{
    assert_targets,
    defaults::installed_at,
    fee_rewards::{
        address, assert_payment, assert_transfer_fee_block, events, integer, ledger_at,
        pending_fees_at, pool_at, pool_event, priced_fee_factory, recorded_fee, success, view,
        wide,
    },
    frozen_context_at, optional_resource_at_version, resource_at_version,
    transactions::{assert_abort, compile_script, execute},
};
use crate::smoke_test_environment::SwarmBuilder;
use aptos_api_types::{
    AptosErrorCode, Transaction, TransactionData, UserTransaction, WriteSetChange,
};
use aptos_cached_packages::aptos_stdlib;
use aptos_config::config::{
    Identity, IdentityBlob, InitialSafetyRulesConfig, OverrideNodeConfig, PersistableConfig,
    SecureBackend,
};
use aptos_crypto::bls12381;
use aptos_forge::{LocalSwarm, NodeExt, Swarm};
use aptos_genesis::poc::{DeploymentMode, PocGenesisConfiguration, PowerParams};
use aptos_rest_client::{error::RestError, Client};
use aptos_sdk::{transaction_builder::TransactionFactory, types::LocalAccount};
use aptos_types::{
    account_address::AccountAddress,
    account_config::CORE_CODE_ADDRESS,
    dkg::DKGState,
    on_chain_config::{
        FeatureFlag, Features, OnChainChunkyDKGConfig, OnChainRandomnessConfig, ValidatorSet,
    },
    transaction::{ExecutionStatus, Script, TransactionArgument, TransactionPayload},
    validator_config::ValidatorConfig,
};
use move_core_types::{int256::U256, vm_status::AbortLocation};
use once_cell::sync::Lazy;
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    sync::Arc,
    time::{Duration, Instant},
};

const OCTA: u64 = 100_000_000;
const INITIAL_BOND: u64 = 1000 * OCTA;
const DEPOSIT: u64 = 100 * OCTA;
const PARTIAL_UNLOCK: u64 = 50 * OCTA;
const POWER: u64 = 400;
const REWARD_BASE: u64 = POWER * OCTA;
const POWER_UNITS: u128 = (POWER as u128) << 16;
const SHARE_SCALE: u128 = 10_000_000_000_000_000;
const DEFAULT_COMMISSION_BPS: u64 = 3735;
const NULL: AccountAddress = AccountAddress::ZERO;

static GOVERNANCE: Lazy<Vec<u8>> = Lazy::new(|| {
    compile_script(
        "PoCDelegationRewards",
        r#"script {
        use topo_std::fixed_point64;
        use topo_framework::poc_allocation;
        use topo_framework::stake;
        use topo_framework::staking_config;
        use topo_framework::topo_governance;
        fun main(root: &signer, operation: u8, pool: address, fee_limit: u64) {
            let framework = topo_governance::get_signer_testnet_only(root, @0x1);
            if (operation == 0) {
                poc_allocation::enable_pool(&framework, pool);
            } else {
                assert!(operation <= 4, 0);
                if (operation == 1 || operation == 2 || operation == 4) {
                    let zero = fixed_point64::create_from_rational(0, 1);
                    let rate = if (operation == 2) fixed_point64::create_from_rational(1, 100) else zero;
                    staking_config::update_rewards_config(&framework, rate, rate, 31536000, zero);
                    stake::set_transaction_fee_limit_per_epoch_per_pool(&framework, if (operation == 4) fee_limit else 0);
                };
                topo_governance::reconfigure(&framework);
            };
        }
    }"#,
    )
});

fn governance(operation: u8, pool: AccountAddress) -> TransactionPayload {
    governance_with_fee_limit(operation, pool, 0)
}

fn governance_with_fee_limit(
    operation: u8,
    pool: AccountAddress,
    fee_limit: u64,
) -> TransactionPayload {
    TransactionPayload::Script(Script::new(GOVERNANCE.clone(), vec![], vec![
        TransactionArgument::U8(operation),
        TransactionArgument::Address(pool),
        TransactionArgument::U64(fee_limit),
    ]))
}

pub(super) struct Fixture {
    pub(super) swarm: LocalSwarm,
    pub(super) client: Client,
    pub(super) root: Arc<LocalAccount>,
    pub(super) owner: LocalAccount,
    pub(super) operator: LocalAccount,
    delegator: LocalAccount,
    pub(super) power_user: LocalAccount,
    pub(super) pool: AccountAddress,
    original_pools: Vec<AccountAddress>,
    // Forge 缓存原 peer id，同一进程随后使用 pool 作为实际验证者身份；
    // 查询当前成员时均显式映射到对应节点。
    pub(super) node_key: AccountAddress,
    pub(super) factory: TransactionFactory,
    commission_bps: u64,
    /// Epoch-closing transactions used while replacing the retired genesis pool.
    /// Long-running tests replay their formulas instead of seeding expected vaults
    /// from the resulting on-chain balances.
    pub(super) setup_closings: Vec<UserTransaction>,
}

impl Fixture {
    fn holders(&self) -> [AccountAddress; 5] {
        [
            self.owner.address(),
            self.operator.address(),
            self.delegator.address(),
            self.power_user.address(),
            NULL,
        ]
    }

    pub(super) fn client_for_member(&self, member: AccountAddress) -> Client {
        let node_key = if member == self.pool {
            self.node_key
        } else {
            member
        };
        self.swarm.validator(node_key).unwrap().rest_client()
    }
}

async fn resource(client: &Client, owner: AccountAddress, name: &str, version: u64) -> Value {
    optional_resource_at_version(client, owner, name, version)
        .await
        .unwrap()
        .data
}

async fn latest_version(client: &Client) -> u64 {
    client
        .get_ledger_information()
        .await
        .unwrap()
        .into_inner()
        .version
}

async fn native_stake(client: &Client, pool: AccountAddress, version: u64) -> Vec<Value> {
    view(client, "0x1::stake::get_stake", vec![json!(pool)], version).await
}

async fn table_entry(
    client: &Client,
    handle: AccountAddress,
    key_type: &str,
    value_type: &str,
    key: Value,
    version: u64,
) -> Option<Value> {
    match client
        .get_table_item_at_version(handle, key_type, value_type, key, version)
        .await
    {
        Ok(response) => Some(response.into_inner()),
        Err(RestError::Api(error))
            if error.status_code == reqwest::StatusCode::NOT_FOUND
                && error.error.error_code == AptosErrorCode::TableItemNotFound =>
        {
            None
        },
        Err(error) => panic!("Cannot read delegation table at {version}: {error}"),
    }
}

fn mul_div(x: u128, y: u128, denominator: u128) -> u128 {
    u128::try_from(
        U256::checked_div(
            U256::checked_mul(U256::from(x), U256::from(y)).unwrap(),
            U256::from(denominator),
        )
        .unwrap(),
    )
    .unwrap()
}

fn poc_index(amount: u64) -> U256 {
    let q = U256::ONE << U256::from(128_u8);
    U256::checked_div(
        U256::checked_mul(U256::from(amount), q).unwrap(),
        U256::from(POWER_UNITS),
    )
    .unwrap()
}

/// 独立份额账本。所有操作均使用整数金额，每次份额换算分别向下取整；
/// 不使用链上余额或报价生成预期结果。
#[derive(Clone, Debug, PartialEq)]
struct Shares {
    coins: u64,
    total: u128,
    holders: BTreeMap<AccountAddress, u128>,
}

impl Shares {
    fn new(owner: AccountAddress) -> Self {
        let mut state = Self {
            coins: 0,
            total: 0,
            holders: BTreeMap::new(),
        };
        state.buy(owner, INITIAL_BOND);
        state
    }

    fn shares(&self, user: AccountAddress) -> u128 {
        self.holders.get(&user).copied().unwrap_or(0)
    }

    fn balance(&self, user: AccountAddress) -> u64 {
        if self.total == 0 {
            0
        } else {
            mul_div(self.shares(user), self.coins as u128, self.total) as u64
        }
    }

    fn buy(&mut self, user: AccountAddress, amount: u64) {
        if amount == 0 {
            return;
        }
        let shares = if self.total == 0 || self.coins == 0 {
            amount as u128 * SHARE_SCALE
        } else {
            mul_div(amount as u128, self.total, self.coins as u128)
        };
        assert!(shares > 0);
        self.coins += amount;
        self.total += shares;
        *self.holders.entry(user).or_default() += shares;
    }

    fn deposit(&mut self, user: AccountAddress, amount: u64, fee: u64) {
        self.buy(user, amount - fee);
        self.buy(NULL, fee);
    }

    fn redeem_partial(&mut self, user: AccountAddress, amount: u64) -> u64 {
        assert!(amount > 0 && amount < self.balance(user));
        let shares = mul_div(amount as u128, self.total, self.coins as u128);
        let redeemed = mul_div(shares, self.coins as u128, self.total) as u64;
        assert!(shares > 0 && shares < self.shares(user));
        *self.holders.get_mut(&user).unwrap() -= shares;
        self.total -= shares;
        self.coins -= redeemed;
        redeemed
    }

    fn settle(&mut self, native_reward: u64, commission_bps: u64, operator: AccountAddress) -> u64 {
        let commission = (native_reward as u128 * commission_bps as u128 / 10000) as u64;
        let native_total = self.coins + native_reward;
        let released_coins = self.balance(NULL);
        let released_shares = self.holders.remove(&NULL).unwrap_or(0);
        self.coins -= released_coins;
        self.total -= released_shares;
        // 将临时入池费金额和旧持有人应得的原生净收益恢复到池中，
        // 再按此时的份额价格为运营者发行份额。
        self.coins = native_total - commission;
        self.buy(operator, commission);
        commission
    }
}

async fn assert_physical_shares(f: &Fixture, model: &Shares, version: u64) {
    let delegation = resource(
        &f.client,
        f.pool,
        "0x1::delegation_pool::DelegationPool",
        version,
    )
    .await;
    assert_eq!(
        integer(&delegation["operator_commission_percentage"]),
        f.commission_bps as u128
    );
    assert_eq!(integer(&delegation["observed_lockup_cycle"]["index"]), 0);
    assert_eq!(integer(&delegation["total_coins_inactive"]), 0);
    let active = &delegation["active_shares"];
    assert_eq!(integer(&active["total_coins"]), model.coins as u128);
    assert_eq!(integer(&active["total_shares"]), model.total);
    assert_eq!(integer(&active["scaling_factor"]), SHARE_SCALE);
    assert_eq!(
        integer(&active["shares"]["length"]),
        model.holders.len() as u128
    );
    let handle = address(&active["shares"]["inner"]["handle"]);
    for holder in f.holders() {
        let actual =
            table_entry(&f.client, handle, "address", "u128", json!(holder), version).await;
        assert_eq!(
            actual.as_ref().map(integer).unwrap_or(0),
            model.shares(holder)
        );
        assert_eq!(actual.is_some(), model.shares(holder) > 0);
        assert!(table_entry(
            &f.client,
            address(&delegation["pending_withdrawals"]["handle"]),
            "address",
            "0x1::delegation_pool::ObservedLockupCycle",
            json!(holder),
            version
        )
        .await
        .is_none());
    }
    let inactive = table_entry(
        &f.client,
        address(&delegation["inactive_shares"]["handle"]),
        "0x1::delegation_pool::ObservedLockupCycle",
        "0x1::pool_u64_unbound::Pool",
        json!({"index": "0"}),
        version,
    )
    .await
    .unwrap();
    assert_eq!(integer(&inactive["total_coins"]), 0);
    assert_eq!(integer(&inactive["total_shares"]), 0);
    assert_eq!(integer(&inactive["shares"]["length"]), 0);
}

async fn assert_balances(f: &Fixture, model: &Shares, version: u64) {
    for holder in f.holders() {
        let stake = view(
            &f.client,
            "0x1::delegation_pool::get_stake",
            vec![json!(f.pool), json!(holder)],
            version,
        )
        .await;
        assert_eq!(stake, vec![
            json!(model.balance(holder).to_string()),
            json!("0"),
            json!("0")
        ]);
    }
}

async fn wallet_delta(f: &Fixture, tx: &UserTransaction, business: i128) {
    let version = tx.info.version.0;
    let sender = tx.request.sender.into();
    let before = f
        .client
        .view_apt_account_balance_at_version(sender, version - 1)
        .await
        .unwrap()
        .into_inner();
    let after = f
        .client
        .view_apt_account_balance_at_version(sender, version)
        .await
        .unwrap()
        .into_inner();
    let statements = events(tx, "::transaction_fee::FeeStatement");
    assert_eq!(statements.len(), 1);
    let gas = tx.info.gas_used.0 as i128 * tx.request.gas_unit_price.0 as i128;
    let refund = integer(&statements[0].data["storage_fee_refund_octas"]) as i128;
    assert_eq!(after as i128 - before as i128, business - gas + refund);
}

async fn assert_committee(f: &Fixture, version: u64) {
    let installed = installed_at(&f.client, version).await;
    let mut expected = f
        .original_pools
        .iter()
        .copied()
        .filter(|pool| *pool != f.node_key)
        .collect::<Vec<_>>();
    expected.push(f.pool);
    expected.sort();
    let mut actual = installed
        .validators
        .active_validators
        .iter()
        .map(|validator| validator.account_address)
        .collect::<Vec<_>>();
    actual.sort();
    assert_eq!(actual, expected);
    assert_eq!(installed.validators.total_voting_power, 5 * POWER as u128);
    assert!(installed
        .validators
        .active_validators
        .iter()
        .all(|validator| validator.consensus_voting_power() == POWER));
    for member in actual {
        let client = f.client_for_member(member);
        tokio::time::timeout(Duration::from_secs(30), client.wait_for_version(version))
            .await
            .expect("Delegation committee member did not catch up within 30 seconds")
            .unwrap();
        assert_eq!(installed_at(&client, version).await, installed);
    }
}

pub(super) async fn wait_for_real_proposals(f: &Fixture, epoch: u64, minimum: u64) -> u64 {
    tokio::time::timeout(Duration::from_secs(90), async {
        loop {
            let version = latest_version(&f.client).await;
            let installed = installed_at(&f.client, version).await;
            assert_eq!(installed.epoch, epoch);
            let validator = installed.validators.active_validators.iter().find(|v| v.account_address == f.pool).unwrap();
            let counts = view(&f.client, "0x1::stake::get_current_epoch_proposal_counts",
                vec![json!(validator.config().validator_index.to_string())], version).await;
            if integer(&counts[0]) >= minimum as u128 {
                println!("Delegation pool real proposals: pool={}, epoch={epoch}, version={version}, successes={}, failures={}", f.pool, counts[0], counts[1]);
                return version;
            }
            success(execute(&f.client, &f.power_user, &f.factory,
                aptos_stdlib::topo_coin_transfer(f.owner.address(), 1)).await);
        }
    }).await.expect("The new delegation pool did not produce actual proposals within 90 seconds")
}

/// 仅在旧池退出已安装委员会后，才为隔离测试节点重新绑定身份。
/// 公开注册入口已经验证现有密钥的持有证明；
/// 网络密钥和共识密钥均保持原值。
async fn rebind_node(f: &mut Fixture, install_version: u64) {
    let installed = installed_at(&f.client, install_version).await;
    assert!(installed
        .validators
        .active_validators
        .iter()
        .all(|v| v.account_address != f.node_key));
    let target = installed
        .validators
        .active_validators
        .iter()
        .find(|v| v.account_address == f.pool)
        .unwrap();
    let node = f.swarm.validator_mut(f.node_key).unwrap();
    let rules = &node.config().consensus.safety_rules;
    let SecureBackend::OnDiskStorage(old_backend) = &rules.backend else {
        panic!("Expected the native Forge on-disk safety backend")
    };
    assert!(rules.test.is_none());
    let old_safety_path = old_backend.path();
    assert!(old_safety_path.starts_with(node.base_dir()));
    let new_safety_path = node.base_dir().join("delegation_pool_safety_storage.json");
    assert_ne!(old_safety_path, new_safety_path);
    assert!(!new_safety_path.exists());
    let mut new_backend = old_backend.clone();
    new_backend.path = new_safety_path.clone();
    let InitialSafetyRulesConfig::FromFile {
        identity_blob_path,
        overriding_identity_paths,
        ..
    } = &rules.initial_safety_rules_config
    else {
        panic!("Expected the native Forge identity file")
    };
    assert!(overriding_identity_paths.is_empty());
    let Identity::FromFile(network_identity) =
        &node.config().validator_network.as_ref().unwrap().identity
    else {
        panic!("Expected the native Forge network identity file")
    };
    assert_eq!(network_identity.path, *identity_blob_path);
    assert!(identity_blob_path.starts_with(node.base_dir()));
    let identity_blob_path = identity_blob_path.clone();
    let mut identity = IdentityBlob::from_file(&identity_blob_path).unwrap();
    assert_eq!(identity.account_address, Some(f.node_key));
    assert_eq!(
        bls12381::PublicKey::from(identity.consensus_private_key.as_ref().unwrap()),
        target.config().consensus_public_key
    );
    let original_network_key = identity.network_private_key.public_key();
    node.stop();
    let old_safety_bytes = fs::read(&old_safety_path).unwrap();
    identity.account_address = Some(f.pool);
    fs::write(
        &identity_blob_path,
        serde_yaml::to_string(&identity).unwrap(),
    )
    .unwrap();
    // 新安装的池对应新的 safety-rules author。沿现有 identity/waypoint
    // 初始化路径建立独立磁盘存储，同时完整保留
    // 已退任 author 的持久化安全数据。
    let config_path = node.config_path();
    let mut config = OverrideNodeConfig::load_config(&config_path).unwrap();
    config.override_config_mut().consensus.safety_rules.backend =
        SecureBackend::OnDiskStorage(new_backend.clone());
    config.save_config(&config_path).unwrap();
    node.config_mut().consensus.safety_rules.backend =
        SecureBackend::OnDiskStorage(new_backend.clone());
    let saved_config = OverrideNodeConfig::load_config(&config_path).unwrap();
    let SecureBackend::OnDiskStorage(saved_backend) = &saved_config
        .override_config()
        .consensus
        .safety_rules
        .backend
    else {
        panic!("The restarted pool must retain the on-disk safety backend")
    };
    assert_eq!(saved_backend.path(), new_safety_path);
    assert_eq!(saved_backend.namespace, new_backend.namespace);
    assert_eq!(
        node.config().validator_network.as_ref().unwrap().peer_id(),
        f.pool
    );
    assert_eq!(
        node.config()
            .validator_network
            .as_ref()
            .unwrap()
            .identity_key()
            .public_key(),
        original_network_key
    );
    assert_eq!(
        node.config()
            .consensus
            .safety_rules
            .initial_safety_rules_config
            .identity_blob()
            .unwrap()
            .account_address,
        Some(f.pool)
    );
    node.start().unwrap();
    node.wait_until_healthy(Instant::now() + Duration::from_secs(30))
        .await
        .unwrap();
    assert!(
        fs::read(&old_safety_path).unwrap() == old_safety_bytes,
        "The retired author's safety storage must remain unchanged"
    );
    let version = wait_for_real_proposals(f, installed.epoch, 1).await;
    // REST 健康检查可能早于共识服务完成存储初始化；
    // 以真实提案证明新 author 已能正常工作。
    assert!(new_safety_path.is_file());
    assert!(
        fs::read(&old_safety_path).unwrap() == old_safety_bytes,
        "New-pool proposals must not modify the retired author's safety storage"
    );
    assert_committee(f, version).await;
    println!("Delegation node identity installed: retired_pool={}, current_pool={}, version={version}; Forge handle remains the retired pool key", f.node_key, f.pool);
}

async fn fixture(native_bps: u64, commission_bps: u64) -> (Fixture, u64) {
    fixture_with_fee_limit(native_bps, commission_bps, None, 1000 * OCTA).await
}

async fn fixture_with_fee_limit(
    native_bps: u64,
    commission_bps: u64,
    fee_limit: Option<u64>,
    delegator_funding: u64,
) -> (Fixture, u64) {
    fixture_with_options(
        native_bps,
        commission_bps,
        fee_limit,
        delegator_funding,
        None,
        false,
    )
    .await
}

async fn controlled_fixture(native_bps: u64, commission_bps: u64) -> (Fixture, u64) {
    fixture_with_options(native_bps, commission_bps, None, 1000 * OCTA, None, true).await
}

async fn fixture_with_options(
    native_bps: u64,
    commission_bps: u64,
    fee_limit: Option<u64>,
    delegator_funding: u64,
    initial_lockup_secs: Option<u64>,
    controlled: bool,
) -> (Fixture, u64) {
    let deployment_fee_max = fee_limit.unwrap_or(0);
    fixture_with_genesis_options(
        native_bps,
        commission_bps,
        fee_limit,
        deployment_fee_max,
        delegator_funding,
        initial_lockup_secs,
        controlled,
        10000,
        POWER,
        POWER,
    )
    .await
}

/// Long-running reward tests retain real power decay without forcing the
/// background validators below the minimum.
pub(super) async fn churn_fixture(
    native_bps: u64,
    commission_bps: u64,
    retention_bps: u64,
) -> (Fixture, u64) {
    fixture_with_genesis_options(
        native_bps,
        commission_bps,
        Some(0),
        17,
        1000 * OCTA,
        Some(3),
        false,
        retention_bps,
        10,
        1000,
    )
    .await
}

async fn fixture_with_genesis_options(
    native_bps: u64,
    commission_bps: u64,
    fee_limit: Option<u64>,
    deployment_fee_max: u64,
    delegator_funding: u64,
    initial_lockup_secs: Option<u64>,
    controlled: bool,
    retention_bps: u64,
    min_power: u64,
    max_power: u64,
) -> (Fixture, u64) {
    assert!(native_bps <= 10000 && commission_bps <= 10000);
    let fee_max = deployment_fee_max;
    Lazy::force(&GOVERNANCE);
    println!("REW-10/GOV-03 fixture: 5 nodes, mode={}, min_validators=4, initial_power=400, min/max power={min_power}/{max_power}, each bond=1000 TOPO, ratio=100000000 TOPO/OHMP, growth=25%, epoch=3600s, retention={retention_bps}, native_bps={native_bps}, commission={commission_bps}, fee_max={fee_max}, fee_only_limit={fee_limit:?} (None=1% inflation/fee0), delegator_funding={delegator_funding}, transaction_gas_price=100, ordinary/Chunky DKG=off; real 5-to-5 resource-pool replacement with separate on-disk safety storage", if controlled { "Controlled" } else { "Open" });
    let swarm = SwarmBuilder::new_local(5)
        .with_aptos()
        .with_init_config(Arc::new(move |_, config, _| {
            if initial_lockup_secs.is_some() {
                config.api.failpoints_enabled = true;
            }
        }))
        .with_init_genesis_stake(Arc::new(|_, stake| *stake = INITIAL_BOND))
        .with_init_genesis_config(Arc::new(move |config| {
            config.allow_new_validators = true;
            config.epoch_duration_secs = 3600;
            config.min_stake = 1;
            config.max_stake = 1_000_000 * OCTA;
            config.voting_power_increase_limit = 25;
            if initial_lockup_secs.is_some() {
                config.consensus_config.enable_validator_txns();
            }
            config.randomness_config_override = Some(OnChainRandomnessConfig::Off);
            config.chunky_dkg_config_override = Some(OnChainChunkyDKGConfig::default_disabled());
            config.poc_genesis_config = Some(Arc::new(move |_| PocGenesisConfiguration {
                params: PowerParams {
                    bond_octa_per_ohmp: OCTA * 100_000_000,
                    min_power,
                    max_power,
                    min_validators: 4,
                },

                deployment_mode: if controlled {
                    DeploymentMode::Controlled
                } else {
                    DeploymentMode::Open
                },
                retention_bps,
                initial_raw_power: POWER,
            }));
        }))
        .build()
        .await;
    super::configure_fixture(&swarm, [4, 4, 32, 6, fee_max], native_bps).await;
    let mut original_pools = swarm
        .validators()
        .map(|node| node.peer_id())
        .collect::<Vec<_>>();
    original_pools.sort();
    let node_key = original_pools[0];
    let client = swarm.validator(original_pools[1]).unwrap().rest_client();
    let root = swarm.chain_info().root_account();
    let factory = swarm
        .chain_info()
        .transaction_factory()
        // 创建池和首次写入委托表需要足够的 Octa 支付存储费用；
        // 注册期间已安装的费用分发限额始终为零。
        .with_gas_unit_price(100)
        .with_max_gas_amount(2_000_000)
        .with_transaction_expiration_time(120);
    let mut public = swarm.chain_info().into_aptos_public_info();
    let owner = public
        .create_and_fund_user_account(10_000 * OCTA)
        .await
        .unwrap();
    let operator = public
        .create_and_fund_user_account(100 * OCTA)
        .await
        .unwrap();
    let delegator = public
        .create_and_fund_user_account(delegator_funding)
        .await
        .unwrap();
    public.mint(node_key, 100 * OCTA).await.unwrap();
    let node = swarm.validator(node_key).unwrap();
    let power_user = LocalAccount::new(
        node_key,
        node.account_private_key().as_ref().unwrap().private_key(),
        client
            .get_account(node_key)
            .await
            .unwrap()
            .into_inner()
            .sequence_number,
    );
    if let Some(lockup_secs) = initial_lockup_secs {
        // 仅此变体在资源账户池加入前，通过公开治理设置短锁仓期；
        // 原有九个 fixture 继续使用
        // 原创世锁仓和共识配置。
        success(
            execute(
                &client,
                &root,
                &factory,
                freeze_governance_with_lockup(0, lockup_secs),
            )
            .await,
        );
    }
    success(
        execute(
            &client,
            &owner,
            &factory,
            aptos_stdlib::delegation_pool_initialize_delegation_pool(
                commission_bps,
                b"poc-reward-shares".to_vec(),
            ),
        )
        .await,
    );
    let version = latest_version(&client).await;
    let pool = address(
        &view(
            &client,
            "0x1::delegation_pool::get_owned_pool_address",
            vec![json!(owner.address())],
            version,
        )
        .await[0],
    );
    let initial_add = success(
        execute(
            &client,
            &owner,
            &factory,
            aptos_stdlib::delegation_pool_add_stake(pool, INITIAL_BOND),
        )
        .await,
    );
    assert_eq!(
        integer(&events(&initial_add, "::delegation_pool::AddStake")[0].data["add_stake_fee"]),
        0
    );
    success(
        execute(
            &client,
            &owner,
            &factory,
            aptos_stdlib::delegation_pool_set_operator(operator.address()),
        )
        .await,
    );
    let old_config: ValidatorConfig = client
        .get_account_resource_at_version_bcs(node_key, "0x1::stake::ValidatorConfig", version)
        .await
        .unwrap()
        .into_inner();
    let proof = {
        let identity = node
            .config()
            .consensus
            .safety_rules
            .initial_safety_rules_config
            .identity_blob()
            .unwrap();
        let key = identity.consensus_private_key.unwrap();
        assert_eq!(
            bls12381::PublicKey::from(&key),
            old_config.consensus_public_key
        );
        bls12381::ProofOfPossession::create(&key)
            .to_bytes()
            .to_vec()
    };
    success(
        execute(
            &client,
            &operator,
            &factory,
            aptos_stdlib::stake_rotate_consensus_key(
                pool,
                old_config.consensus_public_key.to_bytes().to_vec(),
                proof,
            ),
        )
        .await,
    );
    success(
        execute(
            &client,
            &operator,
            &factory,
            aptos_stdlib::stake_update_network_and_fullnode_addresses(
                pool,
                old_config.validator_network_addresses,
                old_config.fullnode_network_addresses,
            ),
        )
        .await,
    );
    success(execute(&client, &root, &factory, governance(0, pool)).await);
    success(
        execute(
            &client,
            &power_user,
            &factory,
            aptos_stdlib::poc_allocation_set_allocations(vec![pool], vec![10000]),
        )
        .await,
    );
    success(
        execute(
            &client,
            &operator,
            &factory,
            aptos_stdlib::stake_join_validator_set(pool),
        )
        .await,
    );
    let joined = success(execute(&client, &root, &factory, governance(1, pool)).await);
    let joined_version = joined.info.version.0;
    let before = installed_at(&client, joined_version - 1).await;
    let joined_state = installed_at(&client, joined_version).await;
    let mut old_members = before
        .validators
        .active_validators
        .iter()
        .map(|validator| validator.account_address)
        .collect::<Vec<_>>();
    old_members.sort();
    assert_eq!(old_members, original_pools);
    assert_eq!(before.validators.pending_active.len(), 1);
    assert_eq!(before.validators.pending_active[0].account_address, pool);
    assert_eq!(
        before.validators.pending_active[0].consensus_voting_power(),
        0
    );
    assert_eq!(before.validators.total_joining_power, 0);
    assert!(joined_state.validators.pending_active.is_empty());
    assert!(joined_state.validators.pending_inactive.is_empty());
    assert_eq!(joined_state.epoch, before.epoch + 1);
    assert_eq!(
        joined_state.reward_context,
        (joined_state.epoch, true, 0, 1, true, 0)
    );
    assert_eq!(events(&joined, "::stake::PoCEpochInstalled").len(), 1);
    let mut f = Fixture {
        swarm,
        client,
        root,
        owner,
        operator,
        delegator,
        power_user,
        pool,
        original_pools,
        node_key,
        factory,
        commission_bps,
        setup_closings: vec![],
    };
    f.setup_closings.push(joined.clone());
    assert_eq!(
        f.holders().iter().copied().collect::<BTreeSet<_>>().len(),
        5
    );
    rebind_node(&mut f, joined_version).await;
    let (payload, install_factory) = if let Some(limit) = fee_limit {
        // 低 gas 单价的安装交易不会向新 Epoch 的费用累加器计入可分发费用。
        (
            governance_with_fee_limit(4, pool, limit),
            f.factory.clone().with_gas_unit_price(1),
        )
    } else {
        (governance(2, pool), f.factory.clone())
    };
    let enabled = success(execute(&f.client, &f.root, &install_factory, payload).await);
    f.setup_closings.push(enabled.clone());
    let version = enabled.info.version.0;
    let state = installed_at(&f.client, version).await;
    assert_eq!(state.epoch, joined_state.epoch + 1);
    let (numerator, denominator) = if fee_limit.is_some() {
        (0, 1)
    } else {
        let raw = (1u128 << 64) / 100;
        let denominator = 1_000_000u128 * (1u128 << 64) / raw;
        (denominator * raw / (1u128 << 64), denominator)
    };
    assert_eq!(
        state.reward_context,
        (
            state.epoch,
            true,
            numerator as u64,
            denominator as u64,
            true,
            fee_limit.unwrap_or(0)
        )
    );
    assert_eq!(
        integer(&state.reward_split["installed_native_reward_bps"]),
        native_bps as u128
    );
    let credit = pool_event(&enabled, "::stake::PoCRewardCredited", pool);
    assert_eq!(integer(&credit.data["inflation"]), 0);
    assert_eq!(integer(&credit.data["fee"]), 0);
    assert_eq!(pool_at(&f.client, pool, version).await, vec![
        json!(POWER_UNITS.to_string()),
        json!(POWER_UNITS.to_string()),
        json!(REWARD_BASE.to_string()),
        json!("0"),
        json!("0")
    ]);
    assert_eq!(native_stake(&f.client, pool, version).await, vec![
        json!(INITIAL_BOND.to_string()),
        json!("0"),
        json!("0"),
        json!("0")
    ]);
    assert_eq!(
        address(
            &resource(&f.client, pool, "0x1::stake::StakePool", version).await["operator_address"]
        ),
        f.operator.address()
    );
    assert_eq!(
        address(
            &resource(
                &f.client,
                f.owner.address(),
                "0x1::delegation_pool::DelegationPoolOwnership",
                version
            )
            .await["pool_address"]
        ),
        pool
    );
    assert_committee(&f, version).await;
    (f, version)
}

async fn expected_add_fee(f: &Fixture, native_bps: u64, version: u64, amount: u64) -> u64 {
    let state = installed_at(&f.client, version).await;
    assert_eq!(
        integer(&state.reward_split["installed_native_reward_bps"]),
        native_bps as u128
    );
    let (_, enabled, rate, denominator, distribute_fee, fee_limit) = state.reward_context;
    assert!(enabled && distribute_fee);
    assert_eq!((rate, denominator), (999999, 100000000));
    assert_eq!(fee_limit, 0);
    let inflation_upper = REWARD_BASE as u128 * rate as u128 / denominator as u128;
    let native_upper = inflation_upper * native_bps as u128 / 10000;
    let commission_lower = native_upper * f.commission_bps as u128 / 10000;
    // 佣金为 100% 时，全部原生收益归运营者，
    // 因此新增资金无需补偿现有委托人的奖励。
    // 此分支必须先于部分佣金时预留 1 Octa 的逻辑处理。
    let net_upper = if f.commission_bps == 10000 {
        0
    } else {
        native_upper - commission_lower + u128::from(commission_lower > 0)
    };
    let fee = (amount as u128 * net_upper).div_ceil(INITIAL_BOND as u128 + net_upper) as u64;
    if native_bps == 0 || f.commission_bps == 10000 {
        assert_eq!(fee, 0);
    } else {
        assert!(fee > 0);
    }
    fee
}

async fn governance_weights(client: &Client, pool: AccountAddress, version: u64) -> (u64, u64) {
    let consensus = view(
        client,
        "0x1::stake::get_current_epoch_voting_power",
        vec![json!(pool)],
        version,
    )
    .await;
    let governance = view(
        client,
        "0x1::topo_governance::get_voting_power",
        vec![json!(pool)],
        version,
    )
    .await;
    (
        integer(&consensus[0]) as u64,
        integer(&governance[0]) as u64,
    )
}

async fn deposit(f: &Fixture, native_bps: u64, epoch: u64, model: &mut Shares, already_added: u64) {
    let tx = success(
        execute(
            &f.client,
            &f.delegator,
            &f.factory,
            aptos_stdlib::delegation_pool_add_stake(f.pool, DEPOSIT),
        )
        .await,
    );
    let version = tx.info.version.0;
    let fee = expected_add_fee(f, native_bps, version - 1, DEPOSIT).await;
    assert_eq!(installed_at(&f.client, version - 1).await.epoch, epoch);
    assert_eq!(installed_at(&f.client, version).await.epoch, epoch);
    assert_eq!(
        installed_at(&f.client, version - 1).await,
        installed_at(&f.client, version).await
    );
    let quoted = view(
        &f.client,
        "0x1::delegation_pool::get_add_stake_fee",
        vec![json!(f.pool), json!(DEPOSIT.to_string())],
        version - 1,
    )
    .await;
    assert_eq!(integer(&quoted[0]), fee as u128);
    let added = events(&tx, "::delegation_pool::AddStake");
    assert_eq!(added.len(), 1);
    assert_eq!(address(&added[0].data["pool_address"]), f.pool);
    assert_eq!(
        address(&added[0].data["delegator_address"]),
        f.delegator.address()
    );
    assert_eq!(integer(&added[0].data["amount_added"]), DEPOSIT as u128);
    assert_eq!(integer(&added[0].data["add_stake_fee"]), fee as u128);
    assert_eq!(native_stake(&f.client, f.pool, version - 1).await, vec![
        json!(INITIAL_BOND.to_string()),
        json!("0"),
        json!(already_added.to_string()),
        json!("0")
    ]);
    assert_eq!(native_stake(&f.client, f.pool, version).await, vec![
        json!(INITIAL_BOND.to_string()),
        json!("0"),
        json!((already_added + DEPOSIT).to_string()),
        json!("0")
    ]);
    model.deposit(f.delegator.address(), DEPOSIT, fee);
    assert_physical_shares(f, model, version).await;
    assert_balances(f, model, version).await;
    let commission = events(&tx, "::delegation_pool::DistributeCommission");
    assert_eq!(commission.len(), 1);
    assert_eq!(integer(&commission[0].data["commission_active"]), 0);
    assert_eq!(
        integer(&commission[0].data["commission_pending_inactive"]),
        0
    );
    assert_eq!(
        pool_at(&f.client, f.pool, version - 1).await,
        pool_at(&f.client, f.pool, version).await
    );
    wallet_delta(f, &tx, -(DEPOSIT as i128)).await;
    println!("Delegation deposit: epoch={epoch}, version={version}, native_bps={native_bps}, commission_bps={}, amount={DEPOSIT}, add_fee={fee}, pending_active={}, NULL_shares={}, total_shares={}", f.commission_bps, already_added + DEPOSIT, model.shares(NULL), model.total);
}

fn collect_handles(value: &Value, handles: &mut BTreeSet<AccountAddress>) {
    match value {
        Value::Object(fields) => {
            for (key, value) in fields {
                if key == "handle" {
                    handles.insert(address(value));
                } else {
                    collect_handles(value, handles);
                }
            }
        },
        Value::Array(items) => {
            for value in items {
                collect_handles(value, handles);
            }
        },
        Value::Null | Value::Bool(_) | Value::Number(_) | Value::String(_) => {},
    }
}

async fn rejected_tiny_deposit(f: &Fixture, native_bps: u64, model: &Shares) {
    let tx = execute(
        &f.client,
        &f.power_user,
        &f.factory,
        aptos_stdlib::delegation_pool_add_stake(f.pool, 1),
    )
    .await;
    assert_abort(
        &f.client,
        &tx,
        "delegation_pool",
        0x10008,
        &f.holders()[..4],
        &[f.pool],
    )
    .await;
    let version = tx.info.version.0;
    let fee = expected_add_fee(f, native_bps, version - 1, 1).await;
    assert_eq!(fee, u64::from(native_bps > 0 && f.commission_bps < 10000));
    assert_eq!(
        view(
            &f.client,
            "0x1::delegation_pool::get_add_stake_fee",
            vec![json!(f.pool), json!("1")],
            version - 1,
        )
        .await,
        vec![json!(fee.to_string())]
    );
    let mut handles = BTreeSet::new();
    for name in [
        "0x1::stake::StakePool",
        "0x1::delegation_pool::DelegationPool",
        "0x1::delegation_pool::GovernanceRecords",
    ] {
        let before = resource(&f.client, f.pool, name, version - 1).await;
        let after = resource(&f.client, f.pool, name, version).await;
        assert_eq!(before, after);
        collect_handles(&before, &mut handles);
    }
    for change in &tx.info.changes {
        match change {
            WriteSetChange::WriteTableItem(item) => {
                assert!(!handles.contains(&AccountAddress::from_bytes(item.handle.inner()).unwrap()))
            },
            WriteSetChange::DeleteTableItem(item) => {
                assert!(!handles.contains(&AccountAddress::from_bytes(item.handle.inner()).unwrap()))
            },
            WriteSetChange::WriteResource(item) => {
                assert!(!item.data.typ.to_string().contains("::delegation_pool::"))
            },
            WriteSetChange::DeleteResource(item) => {
                assert!(!item.resource.to_string().contains("::delegation_pool::"))
            },
            WriteSetChange::WriteModule(_) | WriteSetChange::DeleteModule(_) => {
                panic!("Unexpected module change")
            },
        }
    }
    assert!(tx.events.iter().all(
        |event| !event.typ.to_string().contains("::delegation_pool::")
            && !event.typ.to_string().contains("::stake::")
    ));
    assert_physical_shares(f, model, version - 1).await;
    assert_physical_shares(f, model, version).await;
    assert_payment(&f.client, &tx, 0).await;
}

async fn same_epoch_sync(f: &Fixture, epoch: u64, model: &Shares) {
    let tx = success(
        execute(
            &f.client,
            &f.owner,
            &f.factory,
            aptos_stdlib::delegation_pool_synchronize_delegation_pool(f.pool),
        )
        .await,
    );
    let version = tx.info.version.0;
    assert_eq!(installed_at(&f.client, version).await.epoch, epoch);
    assert_eq!(
        installed_at(&f.client, version - 1).await,
        installed_at(&f.client, version).await
    );
    assert_physical_shares(f, model, version).await;
    assert_balances(f, model, version).await;
    let events = events(&tx, "::delegation_pool::DistributeCommission");
    assert_eq!(events.len(), 1);
    assert_eq!(integer(&events[0].data["commission_active"]), 0);
    assert_eq!(integer(&events[0].data["commission_pending_inactive"]), 0);
    assert_payment(&f.client, &tx, 0).await;
}

async fn close_and_synchronize(
    f: &Fixture,
    native_bps: u64,
    epoch: u64,
    model: &mut Shares,
) -> (u64, u64) {
    wait_for_real_proposals(f, epoch, 4).await;
    let tx = success(execute(&f.client, &f.root, &f.factory, governance(3, f.pool)).await);
    let version = tx.info.version.0;
    let before = installed_at(&f.client, version - 1).await;
    let after = installed_at(&f.client, version).await;
    assert_eq!(before.epoch, epoch);
    assert_eq!(after.epoch, epoch + 1);
    assert_eq!(after.validators, before.validators);
    assert_eq!(
        before.reward_context,
        (epoch, true, 999999, 100000000, true, 0)
    );
    assert_eq!(
        after.reward_context,
        (epoch + 1, true, 999999, 100000000, true, 0)
    );
    assert_eq!(
        integer(&before.reward_split["installed_epoch"]),
        epoch as u128
    );
    assert_eq!(
        integer(&after.reward_split["installed_epoch"]),
        (epoch + 1) as u128
    );
    assert_eq!(
        integer(&before.reward_split["installed_native_reward_bps"]),
        native_bps as u128
    );
    assert_eq!(
        integer(&after.reward_split["installed_native_reward_bps"]),
        native_bps as u128
    );
    assert_eq!(events(&tx, "::stake::PoCEpochInstalled").len(), 1);
    let validator = before
        .validators
        .active_validators
        .iter()
        .find(|v| v.account_address == f.pool)
        .unwrap();
    let counts = view(
        &f.client,
        "0x1::stake::get_current_epoch_proposal_counts",
        vec![json!(validator.config().validator_index.to_string())],
        version - 1,
    )
    .await;
    let successful = integer(&counts[0]);
    let failed = integer(&counts[1]);
    assert!(successful > 0);
    let inflation = (REWARD_BASE as u128 * successful * before.reward_context.2 as u128
        / ((successful + failed) * before.reward_context.3 as u128)) as u64;
    assert!(inflation > 0);
    let native = (inflation as u128 * native_bps as u128 / 10000) as u64;
    let poc = inflation - native;
    if native_bps > 0 {
        assert!(
            native > 0,
            "The native commission cases need actual rewards"
        );
    }
    if native_bps == 10000 {
        assert_eq!(native, inflation);
        assert_eq!(poc, 0);
    }
    let credit = pool_event(&tx, "::stake::PoCRewardCredited", f.pool);
    assert_eq!(integer(&credit.data["closing_epoch"]), epoch as u128);
    assert_eq!(
        integer(&credit.data["reward_base_octa"]),
        REWARD_BASE as u128
    );
    assert_eq!(integer(&credit.data["inflation"]), poc as u128);
    assert_eq!(integer(&credit.data["fee"]), 0);
    assert_eq!(wide(&credit.data["delta_index"]), poc_index(poc));
    let split = pool_event(&tx, "::stake::PoCRewardSplit", f.pool);
    assert_eq!(
        integer(&split.data["native_reward_bps"]),
        native_bps as u128
    );
    assert_eq!(
        integer(&split.data["total_inflation_octa"]),
        inflation as u128
    );
    assert_eq!(
        integer(&split.data["active_native_reward_octa"]),
        native as u128
    );
    assert_eq!(
        integer(&split.data["pending_inactive_native_reward_octa"]),
        0
    );
    assert_eq!(integer(&split.data["poc_inflation_octa"]), poc as u128);
    let native_events = events(&tx, "::stake::DistributeRewards")
        .into_iter()
        .filter(|event| address(&event.data["pool_address"]) == f.pool)
        .collect::<Vec<_>>();
    assert_eq!(native_events.len(), usize::from(native > 0));
    if native > 0 {
        assert_eq!(
            integer(&native_events[0].data["rewards_amount"]),
            native as u128
        );
    }
    assert!(events(&tx, "::stake::DistributeTransactionFee").is_empty());
    assert_eq!(native_stake(&f.client, f.pool, version - 1).await, vec![
        json!(INITIAL_BOND.to_string()),
        json!("0"),
        json!((2 * DEPOSIT).to_string()),
        json!("0")
    ]);
    assert_eq!(native_stake(&f.client, f.pool, version).await, vec![
        json!((INITIAL_BOND + 2 * DEPOSIT + native).to_string()),
        json!("0"),
        json!("0"),
        json!("0")
    ]);
    let pool = pool_at(&f.client, f.pool, version).await;
    assert_eq!(integer(&pool[0]), POWER_UNITS);
    assert_eq!(integer(&pool[3]), poc as u128);
    assert_eq!(wide(&pool[4]), poc_index(poc));
    assert_eq!(poc + native, inflation);
    assert_physical_shares(f, model, version).await;
    let commission = (native as u128 * f.commission_bps as u128 / 10000) as u64;
    // 只读余额查询会计入已成熟的临时入池费，但不实际删除其份额；
    // 运营者佣金按换算为份额之前的金额报价。
    let shares_without_null = model.total - model.shares(NULL);
    for holder in f.holders() {
        let balance = if holder == NULL {
            0
        } else {
            mul_div(
                model.shares(holder),
                (model.coins + native - commission) as u128,
                shares_without_null,
            ) as u64
                + if holder == f.operator.address() {
                    commission
                } else {
                    0
                }
        };
        let actual = view(
            &f.client,
            "0x1::delegation_pool::get_stake",
            vec![json!(f.pool), json!(holder)],
            version,
        )
        .await;
        assert_eq!(actual, vec![
            json!(balance.to_string()),
            json!("0"),
            json!("0")
        ]);
    }
    let sync = success(
        execute(
            &f.client,
            &f.owner,
            &f.factory,
            aptos_stdlib::delegation_pool_synchronize_delegation_pool(f.pool),
        )
        .await,
    );
    let sync_version = sync.info.version.0;
    assert_eq!(
        model.settle(native, f.commission_bps, f.operator.address()),
        commission
    );
    assert_physical_shares(f, model, sync_version).await;
    assert_balances(f, model, sync_version).await;
    let commissions = events(&sync, "::delegation_pool::DistributeCommission");
    assert_eq!(commissions.len(), 1);
    assert_eq!(
        address(&commissions[0].data["operator"]),
        f.operator.address()
    );
    assert_eq!(
        address(&commissions[0].data["beneficiary"]),
        f.operator.address()
    );
    assert_eq!(
        integer(&commissions[0].data["commission_active"]),
        commission as u128
    );
    assert_eq!(
        integer(&commissions[0].data["commission_pending_inactive"]),
        0
    );
    assert_eq!(model.coins, INITIAL_BOND + 2 * DEPOSIT + native);
    assert_eq!(model.shares(NULL), 0);
    if f.commission_bps == 0 {
        assert_eq!(commission, 0);
        assert_eq!(model.shares(f.operator.address()), 0);
        assert_eq!(model.balance(f.operator.address()), 0);
    } else if f.commission_bps == 10000 {
        // 未发行临时入池费份额，本金的份额价格不变，
        // 因此运营者可精确获得全部原生收益。
        assert_eq!(commission, native);
        assert_eq!(model.balance(f.owner.address()), INITIAL_BOND);
        assert_eq!(model.balance(f.delegator.address()), 2 * DEPOSIT);
        assert_eq!(model.balance(f.operator.address()), native);
    }
    assert!(
        model.balance(f.delegator.address()) <= 2 * DEPOSIT,
        "New deposits inherited old-epoch rewards"
    );
    assert!(model.balance(f.owner.address()) >= INITIAL_BOND + native - commission);
    assert!(model.balance(f.operator.address()) <= commission);
    assert!(commission - model.balance(f.operator.address()) <= 1);
    let accounted: u64 = model
        .holders
        .keys()
        .map(|holder| model.balance(*holder))
        .sum();
    assert!(model.coins - accounted < model.holders.len() as u64);
    assert_eq!(
        native_stake(&f.client, f.pool, sync_version - 1).await,
        native_stake(&f.client, f.pool, sync_version).await
    );
    assert_eq!(
        f.client
            .view_apt_account_balance_at_version(f.operator.address(), sync_version - 1)
            .await
            .unwrap()
            .into_inner(),
        f.client
            .view_apt_account_balance_at_version(f.operator.address(), sync_version)
            .await
            .unwrap()
            .into_inner(),
        "Operator commission must be reinvested as native shares"
    );
    assert_eq!(
        pool_at(&f.client, f.pool, sync_version - 1).await,
        pool_at(&f.client, f.pool, sync_version).await
    );
    assert_payment(&f.client, &sync, 0).await;
    same_epoch_sync(f, epoch + 1, model).await;
    println!("Delegation settled: closing_epoch={epoch}, close_version={version}, sync_version={sync_version}, successes={successful}, failures={failed}, rate={}/{}, inflation={inflation}, native={native}, poc={poc}, commission={commission}, owner_stake={}, added_stake={}, operator_stake={}, NULL_shares=0, share_rounding_dust={}", before.reward_context.2, before.reward_context.3, model.balance(f.owner.address()), model.balance(f.delegator.address()), model.balance(f.operator.address()), model.coins - accounted);
    (poc, sync_version)
}

async fn claim_power_reward(f: &Fixture, model: &Shares, poc: u64) -> u64 {
    let q = U256::ONE << U256::from(128_u8);
    let delta = poc_index(poc);
    let accrued = U256::checked_mul(delta, U256::from(POWER_UNITS)).unwrap();
    let claim = u64::try_from(U256::checked_div(accrued, q).unwrap()).unwrap();
    let fraction = U256::checked_rem(accrued, q).unwrap();
    for expected in [claim, 0] {
        let tx = success(
            execute(
                &f.client,
                &f.power_user,
                &f.factory,
                aptos_stdlib::poc_allocation_claim_rewards(vec![f.pool]),
            )
            .await,
        );
        let version = tx.info.version.0;
        let payments = events(&tx, "::poc_accounting::PoCRewardClaimed");
        assert_eq!(payments.len(), usize::from(expected > 0));
        if expected > 0 {
            assert_eq!(integer(&payments[0].data["amount"]), expected as u128);
            assert_eq!(address(&payments[0].data["pool"]), f.pool);
            assert_eq!(address(&payments[0].data["user"]), f.power_user.address());
        }
        assert_payment(&f.client, &tx, expected).await;
        assert_physical_shares(f, model, version).await;
        assert_balances(f, model, version).await;
        assert_eq!(
            native_stake(&f.client, f.pool, version - 1).await,
            native_stake(&f.client, f.pool, version).await
        );
        let pool = pool_at(&f.client, f.pool, version).await;
        assert_eq!(integer(&pool[3]), (poc - claim) as u128);
        assert_eq!(wide(&pool[4]), delta);
        let position = view(
            &f.client,
            "0x1::poc_accounting::get_position",
            vec![json!(f.power_user.address()), json!(f.pool)],
            version,
        )
        .await;
        assert_eq!(integer(&position[0]), POWER_UNITS);
        assert_eq!(integer(&position[2]), 0);
        assert_eq!(wide(&position[3]), fraction);
        for user in [
            f.owner.address(),
            f.delegator.address(),
            f.operator.address(),
        ] {
            let position = view(
                &f.client,
                "0x1::poc_accounting::get_position",
                vec![json!(user), json!(f.pool)],
                version,
            )
            .await;
            assert_eq!(integer(&position[0]), 0);
            assert_eq!(integer(&position[2]), 0);
        }
    }
    let version = latest_version(&f.client).await;
    println!("Delegation PoC payout: actual_credit={poc}, full_power_claim={claim}, vault_dust={}, fraction={fraction:?}, PoC_operator_commission=0, version={version}", poc - claim);
    version
}

async fn run(native_bps: u64, commission_bps: u64) {
    let (f, version) = fixture(native_bps, commission_bps).await;
    let epoch = installed_at(&f.client, version).await.epoch;
    let mut model = Shares::new(f.owner.address());
    assert_physical_shares(&f, &model, version).await;
    assert_balances(&f, &model, version).await;
    deposit(&f, native_bps, epoch, &mut model, 0).await;
    rejected_tiny_deposit(&f, native_bps, &model).await;
    deposit(&f, native_bps, epoch, &mut model, DEPOSIT).await;
    if native_bps == 0 || commission_bps == 10000 {
        assert_eq!(model.shares(NULL), 0);
    } else {
        assert!(model.shares(NULL) > 0);
    }
    same_epoch_sync(&f, epoch, &model).await;
    let (poc, sync_version) = close_and_synchronize(&f, native_bps, epoch, &mut model).await;
    if native_bps == 10000 {
        assert_eq!(poc, 0);
        assert_eq!(pool_at(&f.client, f.pool, sync_version).await, vec![
            json!(POWER_UNITS.to_string()),
            json!(POWER_UNITS.to_string()),
            json!(REWARD_BASE.to_string()),
            json!("0"),
            json!("0")
        ]);
    }
    let version = claim_power_reward(&f, &model, poc).await;
    assert_committee(&f, version).await;
    let expected_delegation = resource(
        &f.client,
        f.pool,
        "0x1::delegation_pool::DelegationPool",
        version,
    )
    .await;
    let expected_stake = native_stake(&f.client, f.pool, version).await;
    let expected_poc = pool_at(&f.client, f.pool, version).await;
    let installed = installed_at(&f.client, version).await;
    for validator in &installed.validators.active_validators {
        let client = f.client_for_member(validator.account_address);
        assert_eq!(
            resource(
                &client,
                f.pool,
                "0x1::delegation_pool::DelegationPool",
                version
            )
            .await,
            expected_delegation
        );
        assert_eq!(native_stake(&client, f.pool, version).await, expected_stake);
        assert_eq!(pool_at(&client, f.pool, version).await, expected_poc);
        let handle = address(&expected_delegation["active_shares"]["shares"]["inner"]["handle"]);
        for holder in f.holders() {
            let shares =
                table_entry(&client, handle, "address", "u128", json!(holder), version).await;
            assert_eq!(
                shares.as_ref().map(integer).unwrap_or(0),
                model.shares(holder)
            );
        }
    }
    println!("REW-10 repeated deposits completed: native_bps={native_bps}, commission={commission_bps}, owner={}, operator={}, delegator={}, power_user={}, delegation_pool={}, final_version={version}", f.owner.address(), f.operator.address(), f.delegator.address(), f.power_user.address(), f.pool);
}

#[tokio::test]
async fn poc_delegation_zero_native_repeated_adds_preserve_old_rewards() {
    run(0, DEFAULT_COMMISSION_BPS).await;
}

#[tokio::test]
async fn poc_delegation_default_native_repeated_adds_preserve_old_rewards() {
    run(3000, DEFAULT_COMMISSION_BPS).await;
}

#[tokio::test]
async fn poc_controlled_delegation_positive_quote_keeps_native_governance_weight() {
    let (f, version) = controlled_fixture(3000, DEFAULT_COMMISSION_BPS).await;
    let accounting = resource(
        &f.client,
        CORE_CODE_ADDRESS,
        "0x1::poc_accounting::AccountingState",
        version,
    )
    .await;
    assert_eq!(accounting["config"]["deployment_mode"], json!(0));
    assert_eq!(
        governance_weights(&f.client, f.pool, version).await,
        (POWER, INITIAL_BOND)
    );

    // 报价金额由已安装的 1% 收益上限、30% 原生分流和 37.35% 佣金
    // 逐步计算；随后用完全相同的公开追加交易核对事件和临时份额。
    let expected_fee = expected_add_fee(&f, 3000, version, DEPOSIT).await;
    assert_eq!(expected_fee, 7_512_345);
    let quoted = view(
        &f.client,
        "0x1::delegation_pool::get_add_stake_fee",
        vec![json!(f.pool), json!(DEPOSIT.to_string())],
        version,
    )
    .await;
    assert_eq!(integer(&quoted[0]), expected_fee as u128);
    let epoch = installed_at(&f.client, version).await.epoch;
    let mut model = Shares::new(f.owner.address());
    deposit(&f, 3000, epoch, &mut model, 0).await;
    let added_version = latest_version(&f.client).await;
    assert_eq!(
        governance_weights(&f.client, f.pool, added_version).await,
        (POWER, INITIAL_BOND + DEPOSIT)
    );

    let installed = installed_at(&f.client, added_version).await;
    let expected_pool = resource(
        &f.client,
        f.pool,
        "0x1::delegation_pool::DelegationPool",
        added_version,
    )
    .await;
    for validator in &installed.validators.active_validators {
        let client = f.client_for_member(validator.account_address);
        assert_eq!(installed_at(&client, added_version).await, installed);
        assert_eq!(
            resource(
                &client,
                f.pool,
                "0x1::delegation_pool::DelegationPool",
                added_version,
            )
            .await,
            expected_pool
        );
        assert_eq!(
            governance_weights(&client, f.pool, added_version).await,
            (POWER, INITIAL_BOND + DEPOSIT)
        );
    }
}

#[tokio::test]
async fn poc_delegation_zero_commission_repeated_adds_preserve_old_rewards() {
    run(3000, 0).await;
}

#[tokio::test]
async fn poc_delegation_full_commission_repeated_adds_preserve_old_rewards() {
    run(3000, 10000).await;
}

#[tokio::test]
async fn poc_delegation_all_native_repeated_adds_preserve_old_rewards() {
    run(10000, DEFAULT_COMMISSION_BPS).await;
}

#[tokio::test]
async fn poc_delegation_zero_native_zero_commission_preserves_old_rewards() {
    run(0, 0).await;
}

#[tokio::test]
async fn poc_delegation_zero_native_full_commission_preserves_old_rewards() {
    run(0, 10000).await;
}

#[tokio::test]
async fn poc_delegation_all_native_zero_commission_preserves_old_rewards() {
    run(10000, 0).await;
}

#[tokio::test]
async fn poc_delegation_all_native_full_commission_preserves_old_rewards() {
    run(10000, 10000).await;
}

/// active 池与 pending-inactive 池分别定价并发行运营者份额；
/// 后者仍处于 observed lockup cycle 0。
struct UnlockModel {
    active: Shares,
    pending: Shares,
    deposits: u64,
    unlocked: u64,
}

impl UnlockModel {
    fn new(owner: AccountAddress) -> Self {
        Self {
            active: Shares::new(owner),
            pending: Shares {
                coins: 0,
                total: 0,
                holders: BTreeMap::new(),
            },
            deposits: 0,
            unlocked: 0,
        }
    }

    fn closing_principal(&self) -> [u64; 4] {
        [
            INITIAL_BOND - self.unlocked,
            0,
            self.deposits,
            self.unlocked,
        ]
    }
}

async fn assert_native_balances(f: &Fixture, amounts: [u64; 4], version: u64) {
    assert_eq!(
        native_stake(&f.client, f.pool, version).await,
        amounts.map(|amount| json!(amount.to_string())).to_vec()
    );
}

async fn assert_shares_table(
    client: &Client,
    table: &Value,
    expected: &Shares,
    holders: &[AccountAddress; 5],
    version: u64,
) {
    assert_eq!(integer(&table["total_coins"]), expected.coins as u128);
    assert_eq!(integer(&table["total_shares"]), expected.total);
    assert_eq!(integer(&table["scaling_factor"]), SHARE_SCALE);
    assert_eq!(
        integer(&table["shares"]["length"]),
        expected.holders.len() as u128
    );
    let handle = address(&table["shares"]["inner"]["handle"]);
    for holder in holders {
        let actual = table_entry(client, handle, "address", "u128", json!(holder), version).await;
        assert_eq!(
            actual.as_ref().map(integer).unwrap_or(0),
            expected.shares(*holder)
        );
        assert_eq!(actual.is_some(), expected.shares(*holder) > 0);
    }
}

async fn assert_unlock_shares(f: &Fixture, client: &Client, model: &UnlockModel, version: u64) {
    let delegation = resource(
        client,
        f.pool,
        "0x1::delegation_pool::DelegationPool",
        version,
    )
    .await;
    assert_eq!(
        integer(&delegation["operator_commission_percentage"]),
        f.commission_bps as u128
    );
    assert_eq!(integer(&delegation["observed_lockup_cycle"]["index"]), 0);
    assert_eq!(integer(&delegation["total_coins_inactive"]), 0);
    let holders = f.holders();
    assert_shares_table(
        client,
        &delegation["active_shares"],
        &model.active,
        &holders,
        version,
    )
    .await;
    let pending = table_entry(
        client,
        address(&delegation["inactive_shares"]["handle"]),
        "0x1::delegation_pool::ObservedLockupCycle",
        "0x1::pool_u64_unbound::Pool",
        json!({"index": "0"}),
        version,
    )
    .await
    .unwrap();
    assert_shares_table(client, &pending, &model.pending, &holders, version).await;
    for holder in holders {
        let withdrawal = table_entry(
            client,
            address(&delegation["pending_withdrawals"]["handle"]),
            "address",
            "0x1::delegation_pool::ObservedLockupCycle",
            json!(holder),
            version,
        )
        .await;
        assert_eq!(
            withdrawal,
            (model.pending.shares(holder) > 0).then(|| json!({"index": "0"}))
        );
    }
}

async fn assert_unlock_balances(f: &Fixture, client: &Client, model: &UnlockModel, version: u64) {
    for holder in f.holders() {
        assert_eq!(
            view(
                client,
                "0x1::delegation_pool::get_stake",
                vec![json!(f.pool), json!(holder)],
                version
            )
            .await,
            vec![
                json!(model.active.balance(holder).to_string()),
                json!("0"),
                json!(model.pending.balance(holder).to_string())
            ]
        );
        assert_eq!(
            view(
                client,
                "0x1::delegation_pool::get_pending_withdrawal",
                vec![json!(f.pool), json!(holder)],
                version
            )
            .await,
            vec![
                json!(false),
                json!(model.pending.balance(holder).to_string())
            ]
        );
    }
}

fn assert_commission(f: &Fixture, transaction: &UserTransaction, active: u64, pending: u64) {
    let commissions = events(transaction, "::delegation_pool::DistributeCommission");
    assert_eq!(commissions.len(), 1);
    let data = &commissions[0].data;
    assert_eq!(address(&data["pool_address"]), f.pool);
    assert_eq!(address(&data["operator"]), f.operator.address());
    assert_eq!(address(&data["beneficiary"]), f.operator.address());
    assert_eq!(integer(&data["commission_active"]), active as u128);
    assert_eq!(
        integer(&data["commission_pending_inactive"]),
        pending as u128
    );
}

async fn assert_no_poc_change(f: &Fixture, transaction: &UserTransaction) {
    let version = transaction.info.version.0;
    assert_eq!(
        installed_at(&f.client, version - 1).await,
        installed_at(&f.client, version).await
    );
    assert_eq!(
        pool_at(&f.client, f.pool, version - 1).await,
        pool_at(&f.client, f.pool, version).await
    );
    assert!(events(transaction, "::stake::PoCRewardCredited").is_empty());
    assert!(events(transaction, "::poc_accounting::PoCRewardClaimed").is_empty());
}

async fn assert_add_fee_quote(f: &Fixture, native_bps: u64, version: u64) -> u64 {
    let fee = expected_add_fee(f, native_bps, version, DEPOSIT).await;
    assert_eq!(
        view(
            &f.client,
            "0x1::delegation_pool::get_add_stake_fee",
            vec![json!(f.pool), json!(DEPOSIT.to_string())],
            version
        )
        .await,
        vec![json!(fee.to_string())]
    );
    fee
}

async fn partial_unlock(f: &Fixture, native_bps: u64, model: &mut UnlockModel) {
    // 剩余 active 质押和新增 pending 质押均超过框架的最低 10 TOPO 要求，
    // 因此不应触发最低余额调整。
    assert!(model.active.balance(f.delegator.address()) - PARTIAL_UNLOCK >= 10 * OCTA);
    assert!(model.pending.balance(f.delegator.address()) + PARTIAL_UNLOCK >= 10 * OCTA);
    let transaction = success(
        execute(
            &f.client,
            &f.delegator,
            &f.factory,
            aptos_stdlib::delegation_pool_unlock(f.pool, PARTIAL_UNLOCK),
        )
        .await,
    );
    let version = transaction.info.version.0;
    assert_native_balances(f, model.closing_principal(), version - 1).await;
    assert_unlock_shares(f, &f.client, model, version - 1).await;
    let fee_before = assert_add_fee_quote(f, native_bps, version - 1).await;
    let redeemed = model
        .active
        .redeem_partial(f.delegator.address(), PARTIAL_UNLOCK);
    assert_eq!(redeemed, PARTIAL_UNLOCK);
    model.pending.buy(f.delegator.address(), redeemed);
    model.unlocked += redeemed;
    assert_native_balances(f, model.closing_principal(), version).await;
    assert_eq!(
        model.closing_principal()[0] + model.closing_principal()[3],
        INITIAL_BOND
    );
    assert_eq!(model.closing_principal()[2], DEPOSIT);
    assert_unlock_shares(f, &f.client, model, version).await;
    assert_unlock_balances(f, &f.client, model, version).await;
    assert_eq!(
        assert_add_fee_quote(f, native_bps, version).await,
        fee_before
    );
    for event_type in ["::delegation_pool::UnlockStake", "::stake::UnlockStake"] {
        let unlocked = events(&transaction, event_type);
        assert_eq!(unlocked.len(), 1);
        assert_eq!(address(&unlocked[0].data["pool_address"]), f.pool);
        assert_eq!(
            integer(&unlocked[0].data["amount_unlocked"]),
            redeemed as u128
        );
        if event_type == "::delegation_pool::UnlockStake" {
            assert_eq!(
                address(&unlocked[0].data["delegator_address"]),
                f.delegator.address()
            );
        }
    }
    assert_commission(f, &transaction, 0, 0);
    assert_no_poc_change(f, &transaction).await;
    assert_payment(&f.client, &transaction, 0).await;
    println!("REW-10 partial unlock: native_bps={native_bps}, amount={redeemed}, version={version}, active={}, pending_active={}, pending_inactive={}, add_fee_before_and_after={fee_before}", INITIAL_BOND - redeemed, model.deposits, redeemed);
}

async fn add_after_unlock(f: &Fixture, native_bps: u64, model: &mut UnlockModel) {
    let transaction = success(
        execute(
            &f.client,
            &f.delegator,
            &f.factory,
            aptos_stdlib::delegation_pool_add_stake(f.pool, DEPOSIT),
        )
        .await,
    );
    let version = transaction.info.version.0;
    let fee = assert_add_fee_quote(f, native_bps, version - 1).await;
    assert_native_balances(f, model.closing_principal(), version - 1).await;
    assert_unlock_shares(f, &f.client, model, version - 1).await;
    model.active.deposit(f.delegator.address(), DEPOSIT, fee);
    model.deposits += DEPOSIT;
    assert_eq!(model.deposits, 2 * DEPOSIT);
    assert_native_balances(f, model.closing_principal(), version).await;
    assert_unlock_shares(f, &f.client, model, version).await;
    assert_unlock_balances(f, &f.client, model, version).await;
    assert_eq!(assert_add_fee_quote(f, native_bps, version).await, fee);
    let added = events(&transaction, "::delegation_pool::AddStake");
    assert_eq!(added.len(), 1);
    assert_eq!(address(&added[0].data["pool_address"]), f.pool);
    assert_eq!(
        address(&added[0].data["delegator_address"]),
        f.delegator.address()
    );
    assert_eq!(integer(&added[0].data["amount_added"]), DEPOSIT as u128);
    assert_eq!(integer(&added[0].data["add_stake_fee"]), fee as u128);
    assert_commission(f, &transaction, 0, 0);
    assert_no_poc_change(f, &transaction).await;
    wallet_delta(f, &transaction, -(DEPOSIT as i128)).await;
    println!("REW-10 add after unlock: native_bps={native_bps}, version={version}, amount={DEPOSIT}, fee={fee}, temporary_shares={}, active_share_coins={}, pending_share_coins={}", model.active.shares(NULL), model.active.coins, model.pending.coins);
}

async fn sync_unlock_without_reward(f: &Fixture, model: &UnlockModel) -> u64 {
    let transaction = success(
        execute(
            &f.client,
            &f.owner,
            &f.factory,
            aptos_stdlib::delegation_pool_synchronize_delegation_pool(f.pool),
        )
        .await,
    );
    let version = transaction.info.version.0;
    assert_unlock_shares(f, &f.client, model, version - 1).await;
    assert_unlock_shares(f, &f.client, model, version).await;
    assert_unlock_balances(f, &f.client, model, version).await;
    assert_eq!(
        native_stake(&f.client, f.pool, version - 1).await,
        native_stake(&f.client, f.pool, version).await
    );
    assert_commission(f, &transaction, 0, 0);
    assert_no_poc_change(f, &transaction).await;
    assert_payment(&f.client, &transaction, 0).await;
    version
}

async fn close_unlock_epoch(
    f: &Fixture,
    native_bps: u64,
    epoch: u64,
    model: &mut UnlockModel,
) -> u64 {
    wait_for_real_proposals(f, epoch, 4).await;
    let transaction = success(execute(&f.client, &f.root, &f.factory, governance(3, f.pool)).await);
    let version = transaction.info.version.0;
    let before = installed_at(&f.client, version - 1).await;
    let after = installed_at(&f.client, version).await;
    assert_eq!(
        before.reward_context,
        (epoch, true, 999999, 100000000, true, 0)
    );
    assert_eq!(
        after.reward_context,
        (epoch + 1, true, 999999, 100000000, true, 0)
    );
    assert_eq!(before.epoch, epoch);
    assert_eq!(after.epoch, epoch + 1);
    assert_eq!(before.validators, after.validators);
    assert_eq!(
        integer(&before.reward_split["installed_epoch"]),
        epoch as u128
    );
    assert_eq!(
        integer(&after.reward_split["installed_epoch"]),
        (epoch + 1) as u128
    );
    for state in [&before, &after] {
        assert_eq!(
            integer(&state.reward_split["installed_native_reward_bps"]),
            native_bps as u128
        );
    }
    assert_eq!(events(&transaction, "::stake::PoCEpochInstalled").len(), 1);
    let validator = before
        .validators
        .active_validators
        .iter()
        .find(|v| v.account_address == f.pool)
        .unwrap();
    let counts = view(
        &f.client,
        "0x1::stake::get_current_epoch_proposal_counts",
        vec![json!(validator.config().validator_index.to_string())],
        version - 1,
    )
    .await;
    let successful = integer(&counts[0]);
    let failed = integer(&counts[1]);
    assert!(successful > 0);
    let inflation = (REWARD_BASE as u128 * successful * before.reward_context.2 as u128
        / ((successful + failed) * before.reward_context.3 as u128)) as u64;
    assert!(inflation > 0);
    let native = (inflation as u128 * native_bps as u128 / 10000) as u64;
    let poc = inflation - native;
    // 分母不包含 pending active：解锁仅将原 active 资金转入 pending inactive，
    // 不改变当期可计奖的总余额。
    let principal = model.closing_principal();
    assert_eq!(principal, [
        INITIAL_BOND - PARTIAL_UNLOCK,
        0,
        2 * DEPOSIT,
        PARTIAL_UNLOCK
    ]);
    assert_native_balances(f, principal, version - 1).await;
    assert_eq!(principal[0] + principal[3], INITIAL_BOND);
    let remaining_lockup = view(
        &f.client,
        "0x1::stake::get_remaining_lockup_secs",
        vec![json!(f.pool)],
        version - 1,
    )
    .await;
    assert!(
        integer(&remaining_lockup[0]) > 0,
        "The pending shares must stay in the current lockup cycle"
    );
    let native_pending = (native as u128 * principal[3] as u128 / INITIAL_BOND as u128) as u64;
    let native_active = native - native_pending;
    let commission_active = (native_active as u128 * f.commission_bps as u128 / 10000) as u64;
    let commission_pending = (native_pending as u128 * f.commission_bps as u128 / 10000) as u64;
    if native_bps == 0 {
        assert_eq!(
            [
                native_active,
                native_pending,
                commission_active,
                commission_pending
            ],
            [0; 4]
        );
    } else {
        assert!(native_active > 0 && native_pending > 0);
        assert!(commission_active > 0 && commission_pending > 0);
    }
    assert_native_balances(
        f,
        [
            principal[0] + principal[2] + native_active,
            0,
            0,
            principal[3] + native_pending,
        ],
        version,
    )
    .await;
    let credited = pool_event(&transaction, "::stake::PoCRewardCredited", f.pool);
    assert_eq!(integer(&credited.data["closing_epoch"]), epoch as u128);
    assert_eq!(
        integer(&credited.data["reward_base_octa"]),
        REWARD_BASE as u128
    );
    assert_eq!(integer(&credited.data["inflation"]), poc as u128);
    assert_eq!(integer(&credited.data["fee"]), 0);
    assert_eq!(wide(&credited.data["delta_index"]), poc_index(poc));
    let split = pool_event(&transaction, "::stake::PoCRewardSplit", f.pool);
    assert_eq!(integer(&split.data["closing_epoch"]), epoch as u128);
    assert_eq!(
        integer(&split.data["native_reward_bps"]),
        native_bps as u128
    );
    assert_eq!(
        integer(&split.data["total_inflation_octa"]),
        inflation as u128
    );
    assert_eq!(
        integer(&split.data["active_native_reward_octa"]),
        native_active as u128
    );
    assert_eq!(
        integer(&split.data["pending_inactive_native_reward_octa"]),
        native_pending as u128
    );
    assert_eq!(integer(&split.data["poc_inflation_octa"]), poc as u128);
    let native_events = events(&transaction, "::stake::DistributeRewards")
        .into_iter()
        .filter(|event| address(&event.data["pool_address"]) == f.pool)
        .collect::<Vec<_>>();
    assert_eq!(native_events.len(), usize::from(native > 0));
    if native > 0 {
        assert_eq!(
            integer(&native_events[0].data["rewards_amount"]),
            native as u128
        );
    }
    assert!(events(&transaction, "::stake::DistributeTransactionFee").is_empty());
    assert_eq!(pool_at(&f.client, f.pool, version).await, vec![
        json!(POWER_UNITS.to_string()),
        json!(POWER_UNITS.to_string()),
        json!(REWARD_BASE.to_string()),
        json!(poc.to_string()),
        json!(poc_index(poc).to_string()),
    ]);
    assert_eq!(native_active + native_pending + poc, inflation);

    // 委员会安装会更新原生代币余额；两个份额表在同步时才推进，
    // 只读查询则反映尚未落盘的余额变化。
    assert_unlock_shares(f, &f.client, model, version).await;
    let active_total = model.active.total - model.active.shares(NULL);
    for holder in f.holders() {
        let active = if holder == NULL {
            0
        } else {
            mul_div(
                model.active.shares(holder),
                (model.active.coins + native_active - commission_active) as u128,
                active_total,
            ) as u64
                + if holder == f.operator.address() {
                    commission_active
                } else {
                    0
                }
        };
        let pending = mul_div(
            model.pending.shares(holder),
            (model.pending.coins + native_pending - commission_pending) as u128,
            model.pending.total,
        ) as u64
            + if holder == f.operator.address() {
                commission_pending
            } else {
                0
            };
        assert_eq!(
            view(
                &f.client,
                "0x1::delegation_pool::get_stake",
                vec![json!(f.pool), json!(holder)],
                version
            )
            .await,
            vec![
                json!(active.to_string()),
                json!("0"),
                json!(pending.to_string())
            ]
        );
    }
    let sync = success(
        execute(
            &f.client,
            &f.owner,
            &f.factory,
            aptos_stdlib::delegation_pool_synchronize_delegation_pool(f.pool),
        )
        .await,
    );
    let sync_version = sync.info.version.0;
    assert_eq!(
        model
            .active
            .settle(native_active, f.commission_bps, f.operator.address()),
        commission_active
    );
    assert_eq!(
        model
            .pending
            .settle(native_pending, f.commission_bps, f.operator.address()),
        commission_pending
    );
    assert_commission(f, &sync, commission_active, commission_pending);
    assert_unlock_shares(f, &f.client, model, sync_version).await;
    assert_unlock_balances(f, &f.client, model, sync_version).await;
    assert_eq!(
        model.active.coins + model.pending.coins,
        INITIAL_BOND + 2 * DEPOSIT + native
    );
    assert_eq!(model.active.shares(NULL), 0);
    assert_eq!(model.pending.shares(NULL), 0);
    let new_principal =
        model.active.balance(f.delegator.address()) + model.pending.balance(f.delegator.address());
    assert!(
        new_principal <= 2 * DEPOSIT,
        "Pending deposits inherited rewards from the old principal"
    );
    assert!(model.active.balance(f.owner.address()) >= INITIAL_BOND);
    assert_eq!(model.pending.balance(f.owner.address()), 0);
    for (shares, commission) in [
        (&model.active, commission_active),
        (&model.pending, commission_pending),
    ] {
        let operator_balance = shares.balance(f.operator.address());
        assert!(operator_balance <= commission);
        // 购买运营者份额时向下取整一次；以上表项和余额的精确比较
        // 同时验证该换算，不使用容差。
        assert!(commission - operator_balance <= 1);
        let accounted: u64 = shares
            .holders
            .keys()
            .map(|holder| shares.balance(*holder))
            .sum();
        assert!(shares.coins - accounted < shares.holders.len() as u64);
    }
    if native_bps == 0 {
        assert_eq!(model.active.balance(f.owner.address()), INITIAL_BOND);
        assert_eq!(new_principal, 2 * DEPOSIT);
        assert_eq!(model.active.balance(f.operator.address()), 0);
        assert_eq!(model.pending.balance(f.operator.address()), 0);
    }
    assert_native_balances(
        f,
        [model.active.coins, 0, 0, model.pending.coins],
        sync_version,
    )
    .await;
    assert_eq!(
        native_stake(&f.client, f.pool, sync_version - 1).await,
        native_stake(&f.client, f.pool, sync_version).await
    );
    assert_eq!(
        f.client
            .view_apt_account_balance_at_version(f.operator.address(), sync_version - 1)
            .await
            .unwrap()
            .into_inner(),
        f.client
            .view_apt_account_balance_at_version(f.operator.address(), sync_version)
            .await
            .unwrap()
            .into_inner(),
        "Both commission components must stay in native shares"
    );
    assert_no_poc_change(f, &sync).await;
    assert_payment(&f.client, &sync, 0).await;
    sync_unlock_without_reward(f, model).await;
    let combined_commission = (native as u128 * f.commission_bps as u128 / 10000) as u64;
    assert!(combined_commission - commission_active - commission_pending <= 1);
    println!("REW-10 add/unlock settled: native_bps={native_bps}, closing_epoch={epoch}, close_version={version}, sync_version={sync_version}, successes={successful}, failures={failed}, rate={}/{}, inflation={inflation}, native_active={native_active}, native_pending={native_pending}, commission_active={commission_active}, commission_pending={commission_pending}, commission_if_combined={combined_commission}, poc={poc}, owner_active={}, delegator_active={}, delegator_pending={}, operator_active={}, operator_pending={}", before.reward_context.2, before.reward_context.3, model.active.balance(f.owner.address()), model.active.balance(f.delegator.address()), model.pending.balance(f.delegator.address()), model.active.balance(f.operator.address()), model.pending.balance(f.operator.address()));
    poc
}

async fn claim_unlock_power_reward(f: &Fixture, model: &UnlockModel, poc: u64) -> u64 {
    let delta = poc_index(poc);
    let accrued = U256::checked_mul(delta, U256::from(POWER_UNITS)).unwrap();
    let claim = u64::try_from(U256::checked_div(accrued, U256::ONE << U256::from(128_u8)).unwrap())
        .unwrap();
    let fraction = U256::checked_rem(accrued, U256::ONE << U256::from(128_u8)).unwrap();
    let mut last_version = 0;
    for expected in [claim, 0] {
        let transaction = success(
            execute(
                &f.client,
                &f.power_user,
                &f.factory,
                aptos_stdlib::poc_allocation_claim_rewards(vec![f.pool]),
            )
            .await,
        );
        let version = transaction.info.version.0;
        let payments = events(&transaction, "::poc_accounting::PoCRewardClaimed");
        assert_eq!(payments.len(), usize::from(expected > 0));
        if expected > 0 {
            assert_eq!(integer(&payments[0].data["amount"]), expected as u128);
            assert_eq!(address(&payments[0].data["pool"]), f.pool);
            assert_eq!(address(&payments[0].data["user"]), f.power_user.address());
        }
        assert_payment(&f.client, &transaction, expected).await;
        assert_eq!(
            installed_at(&f.client, version - 1).await,
            installed_at(&f.client, version).await
        );
        assert_unlock_shares(f, &f.client, model, version).await;
        assert_unlock_balances(f, &f.client, model, version).await;
        assert_native_balances(f, [model.active.coins, 0, 0, model.pending.coins], version).await;
        assert_eq!(
            native_stake(&f.client, f.pool, version - 1).await,
            native_stake(&f.client, f.pool, version).await
        );
        assert!(events(&transaction, "::delegation_pool::DistributeCommission").is_empty());
        let pool = pool_at(&f.client, f.pool, version).await;
        assert_eq!(integer(&pool[0]), POWER_UNITS);
        assert_eq!(integer(&pool[1]), POWER_UNITS);
        assert_eq!(integer(&pool[2]), REWARD_BASE as u128);
        assert_eq!(integer(&pool[3]), (poc - claim) as u128);
        assert_eq!(wide(&pool[4]), delta);
        let position = view(
            &f.client,
            "0x1::poc_accounting::get_position",
            vec![json!(f.power_user.address()), json!(f.pool)],
            version,
        )
        .await;
        assert_eq!(integer(&position[0]), POWER_UNITS);
        assert_eq!(position[1], json!([]));
        assert_eq!(integer(&position[2]), 0);
        assert_eq!(wide(&position[3]), fraction);
        for holder in [
            f.owner.address(),
            f.delegator.address(),
            f.operator.address(),
        ] {
            assert_eq!(
                view(
                    &f.client,
                    "0x1::poc_accounting::get_position",
                    vec![json!(holder), json!(f.pool)],
                    version
                )
                .await,
                vec![json!("0"), json!([]), json!("0"), json!("0")]
            );
        }
        last_version = version;
    }
    println!("REW-10 add/unlock PoC claim: pool={}, actual_credit={poc}, claim={claim}, vault={}, fraction={fraction:?}, PoC_commission=0, version={last_version}", f.pool, poc - claim);
    last_version
}

async fn run_add_unlock(native_bps: u64) {
    let (f, version) = fixture(native_bps, DEFAULT_COMMISSION_BPS).await;
    let epoch = installed_at(&f.client, version).await.epoch;
    let mut model = UnlockModel::new(f.owner.address());
    assert_unlock_shares(&f, &f.client, &model, version).await;
    assert_unlock_balances(&f, &f.client, &model, version).await;
    deposit(&f, native_bps, epoch, &mut model.active, 0).await;
    model.deposits = DEPOSIT;
    partial_unlock(&f, native_bps, &mut model).await;
    add_after_unlock(&f, native_bps, &mut model).await;
    let pending = sync_unlock_without_reward(&f, &model).await;
    assert_eq!(installed_at(&f.client, pending).await.epoch, epoch);
    assert_native_balances(&f, model.closing_principal(), pending).await;
    if native_bps == 0 {
        assert_eq!(model.active.shares(NULL), 0);
    } else {
        assert!(
            model.active.shares(NULL) > 0,
            "Same-epoch synchronization released the temporary fees"
        );
    }
    let poc = close_unlock_epoch(&f, native_bps, epoch, &mut model).await;
    let version = claim_unlock_power_reward(&f, &model, poc).await;
    assert_committee(&f, version).await;
    let expected_delegation = resource(
        &f.client,
        f.pool,
        "0x1::delegation_pool::DelegationPool",
        version,
    )
    .await;
    let expected_stake = native_stake(&f.client, f.pool, version).await;
    let expected_poc = pool_at(&f.client, f.pool, version).await;
    let installed = installed_at(&f.client, version).await;
    for validator in &installed.validators.active_validators {
        let client = f.client_for_member(validator.account_address);
        assert_eq!(
            resource(
                &client,
                f.pool,
                "0x1::delegation_pool::DelegationPool",
                version
            )
            .await,
            expected_delegation
        );
        assert_eq!(native_stake(&client, f.pool, version).await, expected_stake);
        assert_eq!(pool_at(&client, f.pool, version).await, expected_poc);
        assert_unlock_shares(&f, &client, &model, version).await;
        assert_unlock_balances(&f, &client, &model, version).await;
    }
    println!("REW-10 add/unlock completed: native_bps={native_bps}, commission=3735, first_add={DEPOSIT}, unlock={PARTIAL_UNLOCK}, second_add={DEPOSIT}, final_version={version}");
}

#[tokio::test]
async fn poc_delegation_zero_native_add_unlock_preserves_old_rewards() {
    run_add_unlock(0).await;
}

#[tokio::test]
async fn poc_delegation_default_native_add_unlock_preserves_old_rewards() {
    run_add_unlock(3000).await;
}

struct FeeIncome {
    limit: u64,
    deposit: u64,
    native: u64,
    commission: u64,
    net_upper: u64,
    add_fee: u64,
    poc: u64,
}

impl FeeIncome {
    fn new(limit: u64, deposit: u64) -> Self {
        let native = (limit as u128 * 3000 / 10000) as u64;
        let commission = (native as u128 * DEFAULT_COMMISSION_BPS as u128 / 10000) as u64;
        // 已安装参数下的报价为 active/pending-inactive 分别计算佣金
        // 可能产生的取整差异预留 1 Octa。费用为 39 时，上界为
        // 11 - 4 + 1 = 8，尽管本期仅有 active，实际净收益为 7。
        // 原生奖励为 1 Octa 时佣金为 0，净收益仍为完整的 1 Octa；
        // 若直接乘以未按整数规则取整的佣金后比例，会低估报价。
        let net_upper = native - commission + u64::from(commission > 0);
        let add_fee = (deposit as u128 * net_upper as u128)
            .div_ceil(INITIAL_BOND as u128 + net_upper as u128) as u64;
        assert!(native > 0 && add_fee > 0);
        Self {
            limit,
            deposit,
            native,
            commission,
            net_upper,
            add_fee,
            poc: limit - native,
        }
    }
}

async fn assert_fee_income_context(f: &Fixture, expected: &FeeIncome, version: u64) -> u64 {
    let installed = installed_at(&f.client, version).await;
    assert_eq!(
        installed.reward_context,
        (installed.epoch, true, 0, 1, true, expected.limit)
    );
    assert_eq!(
        integer(&installed.reward_split["installed_native_reward_bps"]),
        3000
    );
    assert_eq!(
        integer(&installed.reward_split["installed_epoch"]),
        installed.epoch as u128
    );
    assert_eq!(f.commission_bps, DEFAULT_COMMISSION_BPS);
    installed.epoch
}

async fn assert_fee_income_quote(f: &Fixture, expected: &FeeIncome, version: u64) {
    assert_fee_income_context(f, expected, version).await;
    let stake = native_stake(&f.client, f.pool, version).await;
    assert_eq!(integer(&stake[0]), INITIAL_BOND as u128);
    assert_eq!(integer(&stake[1]), 0);
    assert_eq!(integer(&stake[3]), 0);
    assert_eq!(
        view(
            &f.client,
            "0x1::delegation_pool::get_add_stake_fee",
            vec![json!(f.pool), json!(expected.deposit.to_string())],
            version
        )
        .await,
        vec![json!(expected.add_fee.to_string())]
    );
}

async fn collect_fee_income(f: &Fixture, expected: &FeeIncome) -> u64 {
    let version = latest_version(&f.client).await;
    let epoch = assert_fee_income_context(f, expected, version).await;
    let initial_fees = pending_fees_at(&f.client, version).await;
    assert!(initial_fees.iter().all(|fee| *fee == 0));
    let (priced_factory, burn) = priced_fee_factory(&f.client, &f.factory, version).await;
    let low_factory = f.factory.clone().with_gas_unit_price(1);
    let low = success(
        execute(
            &f.client,
            &f.power_user,
            &low_factory,
            aptos_stdlib::topo_coin_transfer(f.owner.address(), 1000),
        )
        .await,
    );
    let (_, low_fees, low_distributable) =
        assert_transfer_fee_block(&f.client, &low, burn, epoch, expected.limit).await;
    assert_eq!(low_distributable, 0);
    assert_eq!(low_fees, initial_fees);
    let version = tokio::time::timeout(Duration::from_secs(90), async {
        loop {
            let transfer = success(
                execute(
                    &f.client,
                    &f.power_user,
                    &priced_factory,
                    aptos_stdlib::topo_coin_transfer(f.owner.address(), 1000),
                )
                .await,
            );
            let (version, _, distributable) =
                assert_transfer_fee_block(&f.client, &transfer, burn, epoch, expected.limit).await;
            assert!(distributable > expected.limit);
            if recorded_fee(&f.client, f.pool, version).await == expected.limit {
                return version;
            }
        }
    })
    .await
    .expect("Real delegation fee income did not reach the cap within 90 seconds");
    assert_eq!(assert_fee_income_context(f, expected, version).await, epoch);
    assert_fee_income_quote(f, expected, version).await;
    println!("REW-10 fee income before deposit: epoch={epoch}, version={version}, recorded_fee={}, native_upper={}, net_upper={}, deposit={}, add_fee={}", expected.limit, expected.native, expected.net_upper, expected.deposit, expected.add_fee);
    version
}

async fn deposit_after_fee_income(f: &Fixture, expected: &FeeIncome, model: &mut Shares) -> u64 {
    let transaction = success(
        execute(
            &f.client,
            &f.delegator,
            &f.factory,
            aptos_stdlib::delegation_pool_add_stake(f.pool, expected.deposit),
        )
        .await,
    );
    let version = transaction.info.version.0;
    assert_fee_income_quote(f, expected, version - 1).await;
    assert_native_balances(f, [INITIAL_BOND, 0, 0, 0], version - 1).await;
    assert_eq!(
        recorded_fee(&f.client, f.pool, version - 1).await,
        expected.limit
    );
    assert_physical_shares(f, model, version - 1).await;
    model.deposit(f.delegator.address(), expected.deposit, expected.add_fee);
    assert_native_balances(f, [INITIAL_BOND, 0, expected.deposit, 0], version).await;
    assert_fee_income_quote(f, expected, version).await;
    assert_physical_shares(f, model, version).await;
    assert_balances(f, model, version).await;
    assert_eq!(model.balance(NULL), expected.add_fee);
    assert_eq!(model.balance(f.owner.address()), INITIAL_BOND);
    assert_eq!(
        model.balance(f.delegator.address()),
        expected.deposit - expected.add_fee
    );
    let added = events(&transaction, "::delegation_pool::AddStake");
    assert_eq!(added.len(), 1);
    assert_eq!(address(&added[0].data["pool_address"]), f.pool);
    assert_eq!(
        address(&added[0].data["delegator_address"]),
        f.delegator.address()
    );
    assert_eq!(
        integer(&added[0].data["amount_added"]),
        expected.deposit as u128
    );
    assert_eq!(
        integer(&added[0].data["add_stake_fee"]),
        expected.add_fee as u128
    );
    assert_commission(f, &transaction, 0, 0);
    assert_no_poc_change(f, &transaction).await;
    wallet_delta(f, &transaction, -(expected.deposit as i128)).await;
    println!("REW-10 deposit after earned fees: version={version}, amount={}, add_fee={}, pending_active={}, NULL_shares={}", expected.deposit, expected.add_fee, expected.deposit, model.shares(NULL));
    version
}

async fn close_fee_income(
    f: &Fixture,
    expected: &FeeIncome,
    epoch: u64,
    model: &mut Shares,
) -> u64 {
    wait_for_real_proposals(f, epoch, 1).await;
    let low_factory = f.factory.clone().with_gas_unit_price(1);
    let transaction =
        success(execute(&f.client, &f.root, &low_factory, governance(3, f.pool)).await);
    let version = transaction.info.version.0;
    let before = installed_at(&f.client, version - 1).await;
    let after = installed_at(&f.client, version).await;
    assert_eq!(
        assert_fee_income_context(f, expected, version - 1).await,
        epoch
    );
    assert_eq!(
        assert_fee_income_context(f, expected, version).await,
        epoch + 1
    );
    assert_eq!(before.validators, after.validators);
    assert_eq!(events(&transaction, "::stake::PoCEpochInstalled").len(), 1);
    assert_eq!(
        recorded_fee(&f.client, f.pool, version - 1).await,
        expected.limit
    );
    assert_native_balances(f, [INITIAL_BOND, 0, expected.deposit, 0], version - 1).await;
    assert_native_balances(
        f,
        [INITIAL_BOND + expected.deposit + expected.native, 0, 0, 0],
        version,
    )
    .await;
    assert!(events(&transaction, "::stake::DistributeRewards").is_empty());
    let fees = events(&transaction, "::stake::DistributeTransactionFee")
        .into_iter()
        .filter(|event| address(&event.data["pool_address"]) == f.pool)
        .collect::<Vec<_>>();
    assert_eq!(fees.len(), 1);
    assert_eq!(
        integer(&fees[0].data["fee_amount"]),
        expected.native as u128
    );
    let credit = pool_event(&transaction, "::stake::PoCRewardCredited", f.pool);
    assert_eq!(integer(&credit.data["closing_epoch"]), epoch as u128);
    assert_eq!(
        integer(&credit.data["reward_base_octa"]),
        REWARD_BASE as u128
    );
    assert_eq!(integer(&credit.data["inflation"]), 0);
    assert_eq!(integer(&credit.data["fee"]), expected.poc as u128);
    assert_eq!(wide(&credit.data["delta_index"]), poc_index(expected.poc));
    let split = pool_event(&transaction, "::stake::PoCRewardSplit", f.pool);
    assert_eq!(integer(&split.data["closing_epoch"]), epoch as u128);
    assert_eq!(integer(&split.data["native_reward_bps"]), 3000);
    for field in [
        "total_inflation_octa",
        "active_native_reward_octa",
        "pending_inactive_native_reward_octa",
        "poc_inflation_octa",
    ] {
        assert_eq!(integer(&split.data[field]), 0);
    }
    assert_eq!(expected.native + expected.poc, expected.limit);
    assert_eq!(pool_at(&f.client, f.pool, version).await, vec![
        json!(POWER_UNITS.to_string()),
        json!(POWER_UNITS.to_string()),
        json!(REWARD_BASE.to_string()),
        json!(expected.poc.to_string()),
        json!(poc_index(expected.poc).to_string()),
    ]);
    assert_physical_shares(f, model, version).await;
    let real_shares = model.total - model.shares(NULL);
    for holder in f.holders() {
        let quoted = if holder == NULL {
            0
        } else {
            mul_div(
                model.shares(holder),
                (model.coins + expected.native - expected.commission) as u128,
                real_shares,
            ) as u64
                + if holder == f.operator.address() {
                    expected.commission
                } else {
                    0
                }
        };
        assert_eq!(
            view(
                &f.client,
                "0x1::delegation_pool::get_stake",
                vec![json!(f.pool), json!(holder)],
                version
            )
            .await,
            vec![json!(quoted.to_string()), json!("0"), json!("0")]
        );
    }
    let sync = success(
        execute(
            &f.client,
            &f.owner,
            &f.factory,
            aptos_stdlib::delegation_pool_synchronize_delegation_pool(f.pool),
        )
        .await,
    );
    let sync_version = sync.info.version.0;
    assert_eq!(
        model.settle(expected.native, f.commission_bps, f.operator.address()),
        expected.commission
    );
    assert_physical_shares(f, model, sync_version).await;
    assert_balances(f, model, sync_version).await;
    assert_commission(f, &sync, expected.commission, 0);
    assert_eq!(
        model.balance(f.owner.address()),
        INITIAL_BOND + expected.native - expected.commission
    );
    assert_eq!(model.balance(f.delegator.address()), expected.deposit - 1);
    assert_eq!(
        model.balance(f.operator.address()),
        expected.commission.saturating_sub(1)
    );
    assert_eq!(model.shares(NULL), 0);
    assert_eq!(
        model.coins,
        INITIAL_BOND + expected.deposit + expected.native
    );
    let owned: u64 = model
        .holders
        .keys()
        .map(|holder| model.balance(*holder))
        .sum();
    assert_eq!(
        model.coins - owned,
        if expected.commission == 0 { 1 } else { 2 }
    );
    assert_eq!(
        native_stake(&f.client, f.pool, sync_version - 1).await,
        native_stake(&f.client, f.pool, sync_version).await
    );
    assert_eq!(
        f.client
            .view_apt_account_balance_at_version(f.operator.address(), sync_version - 1)
            .await
            .unwrap()
            .into_inner(),
        f.client
            .view_apt_account_balance_at_version(f.operator.address(), sync_version)
            .await
            .unwrap()
            .into_inner()
    );
    assert_no_poc_change(f, &sync).await;
    assert_payment(&f.client, &sync, 0).await;
    same_epoch_sync(f, epoch + 1, model).await;
    println!("REW-10 fee-only settled: epoch={epoch}, close_version={version}, sync_version={sync_version}, inflation=0, fee={}, native_fee={}, poc_fee={}, commission={}, owner={}, delegator={}, operator={}, native_share_dust={}", expected.limit, expected.native, expected.poc, expected.commission, model.balance(f.owner.address()), model.balance(f.delegator.address()), model.balance(f.operator.address()), model.coins - owned);
    sync_version
}

async fn run_fee_income(expected: FeeIncome) {
    let (f, version) = fixture_with_fee_limit(
        3000,
        DEFAULT_COMMISSION_BPS,
        Some(expected.limit),
        expected.deposit + 100 * OCTA,
    )
    .await;
    let epoch = assert_fee_income_context(&f, &expected, version).await;
    let mut model = Shares::new(f.owner.address());
    assert_physical_shares(&f, &model, version).await;
    assert_balances(&f, &model, version).await;
    assert_fee_income_quote(&f, &expected, version).await;
    collect_fee_income(&f, &expected).await;
    deposit_after_fee_income(&f, &expected, &mut model).await;
    same_epoch_sync(&f, epoch, &model).await;
    assert_eq!(model.balance(NULL), expected.add_fee);
    close_fee_income(&f, &expected, epoch, &mut model).await;
    let version = claim_power_reward(&f, &model, expected.poc).await;
    assert_committee(&f, version).await;
    let expected_delegation = resource(
        &f.client,
        f.pool,
        "0x1::delegation_pool::DelegationPool",
        version,
    )
    .await;
    let expected_stake = native_stake(&f.client, f.pool, version).await;
    let expected_poc = pool_at(&f.client, f.pool, version).await;
    let installed = installed_at(&f.client, version).await;
    for member in &installed.validators.active_validators {
        let client = f.client_for_member(member.account_address);
        assert_eq!(
            resource(
                &client,
                f.pool,
                "0x1::delegation_pool::DelegationPool",
                version
            )
            .await,
            expected_delegation
        );
        assert_eq!(native_stake(&client, f.pool, version).await, expected_stake);
        assert_eq!(pool_at(&client, f.pool, version).await, expected_poc);
        assert_shares_table(
            &client,
            &expected_delegation["active_shares"],
            &model,
            &f.holders(),
            version,
        )
        .await;
        for holder in f.holders() {
            assert_eq!(
                view(
                    &client,
                    "0x1::delegation_pool::get_stake",
                    vec![json!(f.pool), json!(holder)],
                    version
                )
                .await,
                vec![
                    json!(model.balance(holder).to_string()),
                    json!("0"),
                    json!("0")
                ]
            );
        }
    }
    println!("REW-10 fee-income complete: fee_limit={}, native_fee={}, deposit={}, add_fee={}, native_bps=3000, commission_bps=3735, version={version}", expected.limit, expected.native, expected.deposit, expected.add_fee);
}

#[tokio::test]
async fn poc_delegation_fee_only_preserves_commission_and_old_shares() {
    let expected = FeeIncome::new(39, DEPOSIT);
    assert_eq!(
        (
            expected.native,
            expected.commission,
            expected.net_upper,
            expected.add_fee,
            expected.poc
        ),
        (11, 4, 8, 1, 28)
    );
    run_fee_income(expected).await;
}

#[tokio::test]
async fn poc_delegation_one_octa_native_fee_survives_large_mid_epoch_add() {
    // 这 1 Octa 来自真实可分发费用 4 Octa，通胀为零；
    // 不能将此用例计为 1 Octa 通胀奖励的验收证据。
    let expected = FeeIncome::new(4, 50_000 * OCTA);
    assert_eq!(
        (
            expected.native,
            expected.commission,
            expected.net_upper,
            expected.add_fee,
            expected.poc
        ),
        (1, 0, 1, 50, 3)
    );
    run_fee_income(expected).await;
}

const ONE_OCTA_INFLATION_DEPOSIT: u64 = 50_000 * OCTA;
const ONE_OCTA_INFLATION_NOT_READY: u64 = 0x70001;

static ONE_OCTA_INFLATION_GOVERNANCE: Lazy<Vec<u8>> = Lazy::new(|| {
    compile_script(
        "PoCDelegationOneOctaInflation",
        r#"script {
        use topo_std::fixed_point64;
        use topo_framework::reconfiguration;
        use topo_framework::stake;
        use topo_framework::staking_config;
        use topo_framework::topo_governance;
        fun main(root: &signer, pool: address, expected_epoch: u64, install_rate: bool, minimum_successes: u64) {
            let framework = topo_governance::get_signer_testnet_only(root, @0x1);
            assert!(reconfiguration::current_epoch() == expected_epoch, 0x70002);
            if (install_rate) {
                let rate = fixed_point64::create_from_rational(1, 6000000000);
                let zero = fixed_point64::create_from_rational(0, 1);
                staking_config::update_rewards_config(&framework, rate, rate, 31536000, zero);
                stake::set_transaction_fee_limit_per_epoch_per_pool(&framework, 0);
            } else {
                // 在提交事务内检查真实表现，避免链下查询与换届之间的区块竞态。
                let (successes, failures) = stake::get_current_epoch_proposal_counts(
                    stake::get_validator_index(pool));
                assert!(successes > 0 && successes >= minimum_successes
                    && (successes as u128) >= 10 * (failures as u128), 0x70001);
            };
            topo_governance::reconfigure(&framework);
        }
    }"#,
    )
});

fn one_octa_inflation_governance(
    pool: AccountAddress,
    epoch: u64,
    install_rate: bool,
    minimum_successes: u64,
) -> TransactionPayload {
    TransactionPayload::Script(Script::new(
        ONE_OCTA_INFLATION_GOVERNANCE.clone(),
        vec![],
        vec![
            TransactionArgument::Address(pool),
            TransactionArgument::U64(epoch),
            TransactionArgument::Bool(install_rate),
            TransactionArgument::U64(minimum_successes),
        ],
    ))
}

async fn one_octa_inflation_context(f: &Fixture, version: u64) -> u64 {
    // 独立重现两次取整，不能将输入的有理数直接视为已安装奖励率。
    let scale = 1u128 << 64;
    let raw = scale / 6_000_000_000;
    let denominator = 1_000_000 * scale / raw;
    let numerator = denominator * raw / scale;
    assert_eq!(
        (raw, numerator, denominator),
        (3_074_457_345, 999_999, 6_000_000_001_206_571)
    );
    let installed = installed_at(&f.client, version).await;
    assert_eq!(
        installed.reward_context,
        (
            installed.epoch,
            true,
            numerator as u64,
            denominator as u64,
            true,
            0
        )
    );
    assert_eq!(
        integer(&installed.reward_split["installed_epoch"]),
        installed.epoch as u128
    );
    assert_eq!(
        integer(&installed.reward_split["installed_native_reward_bps"]),
        3000
    );
    assert_eq!(f.commission_bps, DEFAULT_COMMISSION_BPS);
    let features = resource_at_version::<Features>(&f.client, version).await;
    assert!(features.is_enabled(FeatureFlag::PERIODICAL_REWARD_RATE_DECREASE));
    let config = resource(
        &f.client,
        CORE_CODE_ADDRESS,
        "0x1::staking_config::StakingRewardsConfig",
        version,
    )
    .await;
    assert_eq!(integer(&config["rewards_rate"]["value"]), raw);
    assert_eq!(integer(&config["min_rewards_rate"]["value"]), raw);
    assert_eq!(integer(&config["rewards_rate_decrease_rate"]["value"]), 0);
    assert_eq!(integer(&config["rewards_rate_period_in_secs"]), 31_536_000);
    let pool = pool_at(&f.client, f.pool, version).await;
    assert_eq!(integer(&pool[0]), POWER_UNITS);
    assert_eq!(integer(&pool[1]), POWER_UNITS);
    assert_eq!(integer(&pool[2]), REWARD_BASE as u128);
    // s >= 10*f 时，最差表现为 10/11；上下界取整均为 6 Octa。
    assert_eq!(REWARD_BASE as u128 * numerator * 10 / (denominator * 11), 6);
    assert_eq!(REWARD_BASE as u128 * numerator / denominator, 6);
    installed.epoch
}

async fn one_octa_inflation_quote(f: &Fixture, version: u64) -> u64 {
    one_octa_inflation_context(f, version).await;
    let context = installed_at(&f.client, version).await.reward_context;
    let inflation_upper = REWARD_BASE as u128 * context.2 as u128 / context.3 as u128;
    let native_upper = inflation_upper * 3000 / 10000;
    let commission = native_upper * f.commission_bps as u128 / 10000;
    let net_upper = native_upper - commission + u128::from(commission > 0);
    assert_eq!(
        (inflation_upper, native_upper, commission, net_upper),
        (6, 1, 0, 1)
    );
    let stake = native_stake(&f.client, f.pool, version).await;
    assert_eq!(integer(&stake[0]), INITIAL_BOND as u128);
    assert_eq!(integer(&stake[1]), 0);
    assert_eq!(integer(&stake[3]), 0);
    let fee = (ONE_OCTA_INFLATION_DEPOSIT as u128 * net_upper)
        .div_ceil(INITIAL_BOND as u128 + net_upper) as u64;
    assert_eq!(fee, 50);
    assert_eq!(
        view(
            &f.client,
            "0x1::delegation_pool::get_add_stake_fee",
            vec![json!(f.pool), json!(ONE_OCTA_INFLATION_DEPOSIT.to_string())],
            version
        )
        .await,
        vec![json!(fee.to_string())]
    );
    fee
}

async fn one_octa_inflation_counts(f: &Fixture, version: u64) -> (u128, u128) {
    let installed = installed_at(&f.client, version).await;
    let validator = installed
        .validators
        .active_validators
        .iter()
        .find(|validator| validator.account_address == f.pool)
        .unwrap();
    let counts = view(
        &f.client,
        "0x1::stake::get_current_epoch_proposal_counts",
        vec![json!(validator.config().validator_index.to_string())],
        version,
    )
    .await;
    (integer(&counts[0]), integer(&counts[1]))
}

async fn one_octa_inflation_guard_rejected(
    f: &Fixture,
    tx: &UserTransaction,
    model: &Shares,
    minimum_successes: u64,
) {
    assert!(!tx.info.success);
    let version = tx.info.version.0;
    let TransactionData::OnChain(committed) = f
        .client
        .get_transaction_by_version_bcs(version)
        .await
        .unwrap()
        .into_inner()
    else {
        panic!("Expected committed BCS transaction");
    };
    let ExecutionStatus::MoveAbort { location, code, .. } = committed.info.status() else {
        panic!(
            "Expected readiness guard abort: {:?}",
            committed.info.status()
        );
    };
    assert_eq!(location, &AbortLocation::Script);
    assert_eq!(*code, ONE_OCTA_INFLATION_NOT_READY);
    let (successful, failed) = one_octa_inflation_counts(f, version - 1).await;
    assert!(successful == 0 || successful < minimum_successes as u128 || successful < 10 * failed);
    assert_eq!(
        one_octa_inflation_counts(f, version).await,
        (successful, failed)
    );
    assert_no_poc_change(f, tx).await;
    assert_physical_shares(f, model, version - 1).await;
    assert_physical_shares(f, model, version).await;
    assert_balances(f, model, version).await;
    assert_native_balances(f, [INITIAL_BOND, 0, ONE_OCTA_INFLATION_DEPOSIT, 0], version).await;
    let mut handles = BTreeSet::new();
    for (owner, name) in [
        (
            CORE_CODE_ADDRESS,
            "0x1::staking_config::StakingRewardsConfig",
        ),
        (CORE_CODE_ADDRESS, "0x1::poc_accounting::AccountingState"),
        (CORE_CODE_ADDRESS, "0x1::poc_power_store::PeriodClock"),
        (CORE_CODE_ADDRESS, "0x1::stake::ValidatorPerformance"),
        (CORE_CODE_ADDRESS, "0x1::stake::PendingTransactionFee"),
        (f.pool, "0x1::stake::StakePool"),
        (f.pool, "0x1::delegation_pool::DelegationPool"),
        (f.pool, "0x1::delegation_pool::GovernanceRecords"),
    ] {
        let before = resource(&f.client, owner, name, version - 1).await;
        assert_eq!(resource(&f.client, owner, name, version).await, before);
        collect_handles(&before, &mut handles);
    }
    let ledger = ledger_at(&f.client, f.pool, version - 1).await;
    assert_eq!(ledger_at(&f.client, f.pool, version).await, ledger);
    collect_handles(&ledger, &mut handles);
    for change in &tx.info.changes {
        match change {
            WriteSetChange::WriteResource(item) => {
                let typ = item.data.typ.to_string();
                assert!(
                    !typ.contains("::poc_")
                        && !typ.contains("::stake::")
                        && !typ.contains("::delegation_pool::")
                );
            },
            WriteSetChange::DeleteResource(item) => {
                let typ = item.resource.to_string();
                assert!(
                    !typ.contains("::poc_")
                        && !typ.contains("::stake::")
                        && !typ.contains("::delegation_pool::")
                );
            },
            WriteSetChange::WriteTableItem(item) => {
                assert!(
                    !handles.contains(&AccountAddress::from_bytes(item.handle.inner()).unwrap())
                );
            },
            WriteSetChange::DeleteTableItem(item) => {
                assert!(
                    !handles.contains(&AccountAddress::from_bytes(item.handle.inner()).unwrap())
                );
            },
            WriteSetChange::WriteModule(_) | WriteSetChange::DeleteModule(_) => {
                panic!("Unexpected module change");
            },
        }
    }
    assert!(tx.events.iter().all(|event| {
        let typ = event.typ.to_string();
        !typ.contains("::poc_")
            && !typ.contains("::stake::")
            && !typ.contains("::delegation_pool::")
            && !typ.contains("::reconfiguration::")
    }));
    let before = resource(
        &f.client,
        f.root.address(),
        "0x1::account::Account",
        version - 1,
    )
    .await;
    let after = resource(
        &f.client,
        f.root.address(),
        "0x1::account::Account",
        version,
    )
    .await;
    assert_eq!(
        integer(&before["sequence_number"]),
        tx.request.sequence_number.0 as u128
    );
    assert_eq!(
        integer(&after["sequence_number"]),
        integer(&before["sequence_number"]) + 1
    );
    assert_payment(&f.client, tx, 0).await;
    println!("REW-10 inflation readiness rejected: version={version}, Script/0x70001, minimum_successes={minimum_successes}, successes={successful}, failures={failed}, business state unchanged");
}

async fn close_one_octa_inflation(f: &Fixture, epoch: u64, model: &Shares) -> UserTransaction {
    let factory = f.factory.clone().with_gas_unit_price(1);
    tokio::time::timeout(Duration::from_secs(90), async {
        // 提高同一守卫的成功次数门槛，确定性覆盖拒绝与业务回滚；
        // 正式提交恢复为 1，仍须在事务内满足 s > 0 且 s >= 10*f。
        let forced = execute(
            &f.client,
            &f.root,
            &factory,
            one_octa_inflation_governance(f.pool, epoch, false, u64::MAX),
        )
        .await;
        one_octa_inflation_guard_rejected(f, &forced, model, u64::MAX).await;
        assert_eq!(
            one_octa_inflation_context(f, forced.info.version.0).await,
            epoch
        );
        let mut rejected = 1;
        loop {
            let tx = execute(
                &f.client,
                &f.root,
                &factory,
                one_octa_inflation_governance(f.pool, epoch, false, 1),
            )
            .await;
            if tx.info.success {
                assert!(rejected >= 1);
                println!("REW-10 inflation readiness accepted: version={}, rejected_transactions={rejected}", tx.info.version.0);
                return tx;
            }
            one_octa_inflation_guard_rejected(f, &tx, model, 1).await;
            rejected += 1;
            assert_eq!(
                one_octa_inflation_context(f, tx.info.version.0).await,
                epoch
            );
        }
    })
    .await
    .expect("Delegation inflation did not satisfy its atomic proposal guard within 90 seconds")
}

async fn wait_for_one_octa_inflation(f: &Fixture, epoch: u64) {
    let factory = f.factory.clone().with_gas_unit_price(1);
    tokio::time::timeout(Duration::from_secs(90), async {
        loop {
            let version = latest_version(&f.client).await;
            assert_eq!(installed_at(&f.client, version).await.epoch, epoch);
            let (successful, failed) = one_octa_inflation_counts(f, version).await;
            if successful > 0 && successful >= 10 * failed {
                println!("REW-10 inflation before deposit: epoch={epoch}, version={version}, successes={successful}, failures={failed}");
                return;
            }
            success(execute(&f.client, &f.power_user, &factory,
                aptos_stdlib::topo_coin_transfer(f.owner.address(), 1)).await);
        }
    }).await.expect("Delegation pool did not earn the expected native inflation before its large deposit within 90 seconds");
}

#[tokio::test]
async fn poc_delegation_one_octa_native_inflation_survives_large_mid_epoch_add() {
    Lazy::force(&ONE_OCTA_INFLATION_GOVERNANCE);
    println!("REW-10 one-Octa native inflation: five real committee nodes, native3000/commission3735, base400 TOPO, stake1000 TOPO, deposit50000 TOPO, rate_input=1/6000000000, installed_rate=999999/6000000001206571, fee_limit0, epoch3600s, synchronous public governance, atomic successes>0 && successes>=10*failures");
    let (f, baseline) = fixture_with_fee_limit(
        3000,
        DEFAULT_COMMISSION_BPS,
        Some(0),
        ONE_OCTA_INFLATION_DEPOSIT + 100 * OCTA,
    )
    .await;
    let baseline_epoch = installed_at(&f.client, baseline).await.epoch;
    initialize_zero_power_reward_positions(&f, baseline_epoch).await;
    let factory = f.factory.clone().with_gas_unit_price(1);
    let installed_tx = success(
        execute(
            &f.client,
            &f.root,
            &factory,
            one_octa_inflation_governance(f.pool, baseline_epoch, true, 1),
        )
        .await,
    );
    let installed_version = installed_tx.info.version.0;
    let before = installed_at(&f.client, installed_version - 1).await;
    assert_eq!(before.reward_context, (baseline_epoch, true, 0, 1, true, 0));
    let epoch = one_octa_inflation_context(&f, installed_version).await;
    assert_eq!(epoch, baseline_epoch + 1);
    assert_eq!(
        installed_at(&f.client, installed_version).await.validators,
        before.validators
    );
    assert_eq!(events(&installed_tx, "::stake::PoCEpochInstalled").len(), 1);
    assert!(events(&installed_tx, "::stake::DistributeRewards").is_empty());
    assert!(events(&installed_tx, "::stake::DistributeTransactionFee").is_empty());
    let credit = pool_event(&installed_tx, "::stake::PoCRewardCredited", f.pool);
    assert_eq!(integer(&credit.data["inflation"]), 0);
    assert_eq!(integer(&credit.data["fee"]), 0);
    let initial_pool = pool_at(&f.client, f.pool, installed_version).await;
    assert_eq!(integer(&initial_pool[3]), 0);
    assert_eq!(wide(&initial_pool[4]), U256::ZERO);
    assert_native_balances(&f, [INITIAL_BOND, 0, 0, 0], installed_version).await;
    let mut model = Shares::new(f.owner.address());
    assert_physical_shares(&f, &model, installed_version).await;
    assert_balances(&f, &model, installed_version).await;

    wait_for_one_octa_inflation(&f, epoch).await;
    let added = success(
        execute(
            &f.client,
            &f.delegator,
            &f.factory,
            aptos_stdlib::delegation_pool_add_stake(f.pool, ONE_OCTA_INFLATION_DEPOSIT),
        )
        .await,
    );
    let added_version = added.info.version.0;
    assert_eq!(
        one_octa_inflation_context(&f, added_version - 1).await,
        epoch
    );
    let fee = one_octa_inflation_quote(&f, added_version - 1).await;
    assert_eq!(fee, 50);
    assert_native_balances(&f, [INITIAL_BOND, 0, 0, 0], added_version - 1).await;
    assert_physical_shares(&f, &model, added_version - 1).await;
    model.deposit(f.delegator.address(), ONE_OCTA_INFLATION_DEPOSIT, fee);
    assert_native_balances(
        &f,
        [INITIAL_BOND, 0, ONE_OCTA_INFLATION_DEPOSIT, 0],
        added_version,
    )
    .await;
    assert_physical_shares(&f, &model, added_version).await;
    assert_balances(&f, &model, added_version).await;
    assert_eq!(one_octa_inflation_quote(&f, added_version).await, fee);
    assert_eq!(model.balance(f.owner.address()), INITIAL_BOND);
    assert_eq!(
        model.balance(f.delegator.address()),
        ONE_OCTA_INFLATION_DEPOSIT - fee
    );
    assert_eq!(model.balance(NULL), fee);
    assert_eq!(model.shares(NULL), fee as u128 * SHARE_SCALE);
    assert_eq!(model.shares(f.operator.address()), 0);
    let deposits = events(&added, "::delegation_pool::AddStake");
    assert_eq!(deposits.len(), 1);
    assert_eq!(address(&deposits[0].data["pool_address"]), f.pool);
    assert_eq!(
        address(&deposits[0].data["delegator_address"]),
        f.delegator.address()
    );
    assert_eq!(
        integer(&deposits[0].data["amount_added"]),
        ONE_OCTA_INFLATION_DEPOSIT as u128
    );
    assert_eq!(integer(&deposits[0].data["add_stake_fee"]), fee as u128);
    assert_commission(&f, &added, 0, 0);
    assert_no_poc_change(&f, &added).await;
    wallet_delta(&f, &added, -(ONE_OCTA_INFLATION_DEPOSIT as i128)).await;
    same_epoch_sync(&f, epoch, &model).await;
    assert_eq!(model.shares(NULL), 50 * SHARE_SCALE);

    let closed = close_one_octa_inflation(&f, epoch, &model).await;
    let closing_version = closed.info.version.0;
    let old = installed_at(&f.client, closing_version - 1).await;
    let new = installed_at(&f.client, closing_version).await;
    assert_eq!(
        one_octa_inflation_context(&f, closing_version - 1).await,
        epoch
    );
    assert_eq!(
        one_octa_inflation_context(&f, closing_version).await,
        epoch + 1
    );
    assert_eq!(old.validators, new.validators);
    let (successful, failed) = one_octa_inflation_counts(&f, closing_version - 1).await;
    assert!(successful > 0 && successful >= 10 * failed);
    // 仅用成功提交的 v-1 表现、旧期安装快照和独立宽整数模型生成金额预期。
    let inflation = mul_div(
        REWARD_BASE as u128 * old.reward_context.2 as u128,
        successful,
        (successful + failed) * old.reward_context.3 as u128,
    ) as u64;
    let native = (inflation as u128 * 3000 / 10000) as u64;
    let poc = inflation - native;
    let commission = (native as u128 * f.commission_bps as u128 / 10000) as u64;
    assert_eq!((inflation, native, poc, commission), (6, 1, 5, 0));
    assert_eq!(events(&closed, "::stake::PoCEpochInstalled").len(), 1);
    assert_eq!(events(&closed, "::reconfiguration::NewEpochEvent").len(), 1);
    assert!(events(&closed, "::stake::DistributeTransactionFee").is_empty());
    let native_events = events(&closed, "::stake::DistributeRewards")
        .into_iter()
        .filter(|event| address(&event.data["pool_address"]) == f.pool)
        .collect::<Vec<_>>();
    assert_eq!(native_events.len(), 1);
    assert_eq!(
        integer(&native_events[0].data["rewards_amount"]),
        native as u128
    );
    let credit = pool_event(&closed, "::stake::PoCRewardCredited", f.pool);
    assert_eq!(integer(&credit.data["closing_epoch"]), epoch as u128);
    assert_eq!(
        integer(&credit.data["reward_base_octa"]),
        REWARD_BASE as u128
    );
    assert_eq!(integer(&credit.data["inflation"]), poc as u128);
    assert_eq!(integer(&credit.data["fee"]), 0);
    assert_eq!(wide(&credit.data["delta_index"]), poc_index(poc));
    let split = pool_event(&closed, "::stake::PoCRewardSplit", f.pool);
    assert_eq!(integer(&split.data["closing_epoch"]), epoch as u128);
    assert_eq!(integer(&split.data["native_reward_bps"]), 3000);
    assert_eq!(
        integer(&split.data["total_inflation_octa"]),
        inflation as u128
    );
    assert_eq!(
        integer(&split.data["active_native_reward_octa"]),
        native as u128
    );
    assert_eq!(
        integer(&split.data["pending_inactive_native_reward_octa"]),
        0
    );
    assert_eq!(integer(&split.data["poc_inflation_octa"]), poc as u128);
    assert_eq!(native + poc, inflation);
    assert_native_balances(
        &f,
        [INITIAL_BOND, 0, ONE_OCTA_INFLATION_DEPOSIT, 0],
        closing_version - 1,
    )
    .await;
    assert_native_balances(
        &f,
        [INITIAL_BOND + ONE_OCTA_INFLATION_DEPOSIT + native, 0, 0, 0],
        closing_version,
    )
    .await;
    assert_eq!(pool_at(&f.client, f.pool, closing_version).await, vec![
        json!(POWER_UNITS.to_string()),
        json!(POWER_UNITS.to_string()),
        json!(REWARD_BASE.to_string()),
        json!(poc.to_string()),
        json!(poc_index(poc).to_string()),
    ]);
    assert_eq!(
        integer(&ledger_at(&f.client, f.pool, closing_version).await["reward_epoch"]),
        epoch as u128
    );
    // 安装 Epoch 后份额尚未落盘；只读余额已反映 NULL 释放和旧持有人应得收益。
    assert_physical_shares(&f, &model, closing_version).await;
    let real_shares = model.total - model.shares(NULL);
    for holder in f.holders() {
        let balance = if holder == NULL {
            0
        } else {
            mul_div(
                model.shares(holder),
                (model.coins + native) as u128,
                real_shares,
            ) as u64
        };
        assert_eq!(
            view(
                &f.client,
                "0x1::delegation_pool::get_stake",
                vec![json!(f.pool), json!(holder)],
                closing_version
            )
            .await,
            vec![json!(balance.to_string()), json!("0"), json!("0")]
        );
    }
    let synchronized = success(
        execute(
            &f.client,
            &f.owner,
            &f.factory,
            aptos_stdlib::delegation_pool_synchronize_delegation_pool(f.pool),
        )
        .await,
    );
    let sync_version = synchronized.info.version.0;
    assert_eq!(
        model.settle(native, f.commission_bps, f.operator.address()),
        commission
    );
    assert_eq!(model.balance(f.owner.address()), INITIAL_BOND + 1);
    assert_eq!(
        model.balance(f.delegator.address()),
        ONE_OCTA_INFLATION_DEPOSIT - 1
    );
    assert_eq!(model.balance(f.operator.address()), 0);
    assert_eq!(model.shares(f.operator.address()), 0);
    assert_eq!(model.shares(NULL), 0);
    assert_eq!(model.coins, INITIAL_BOND + ONE_OCTA_INFLATION_DEPOSIT + 1);
    let owned: u64 = model
        .holders
        .keys()
        .map(|holder| model.balance(*holder))
        .sum();
    assert_eq!(model.coins - owned, 1);
    assert_physical_shares(&f, &model, sync_version).await;
    assert_balances(&f, &model, sync_version).await;
    assert_commission(&f, &synchronized, 0, 0);
    assert_eq!(
        native_stake(&f.client, f.pool, sync_version - 1).await,
        native_stake(&f.client, f.pool, sync_version).await
    );
    assert_eq!(
        f.client
            .view_apt_account_balance_at_version(f.operator.address(), sync_version - 1)
            .await
            .unwrap()
            .into_inner(),
        f.client
            .view_apt_account_balance_at_version(f.operator.address(), sync_version)
            .await
            .unwrap()
            .into_inner()
    );
    assert_no_poc_change(&f, &synchronized).await;
    assert_payment(&f.client, &synchronized, 0).await;
    same_epoch_sync(&f, epoch + 1, &model).await;

    let q = U256::ONE << U256::from(128_u8);
    let accrued = U256::checked_mul(poc_index(poc), U256::from(POWER_UNITS)).unwrap();
    let fraction = U256::checked_sub(q, U256::from(80u128 << 16)).unwrap();
    assert_eq!(U256::checked_div(accrued, q).unwrap(), U256::from(4_u8));
    assert_eq!(U256::checked_rem(accrued, q).unwrap(), fraction);
    claim_power_reward(&f, &model, poc).await;
    for actor in [&f.owner, &f.delegator, &f.operator] {
        let tx = success(
            execute(
                &f.client,
                actor,
                &f.factory,
                aptos_stdlib::poc_allocation_claim_rewards(vec![f.pool]),
            )
            .await,
        );
        let version = tx.info.version.0;
        assert_payment(&f.client, &tx, 0).await;
        assert_no_poc_change(&f, &tx).await;
        assert_eq!(
            ledger_at(&f.client, f.pool, version - 1).await,
            ledger_at(&f.client, f.pool, version).await
        );
        assert_physical_shares(&f, &model, version).await;
        assert_balances(&f, &model, version).await;
        assert_native_balances(
            &f,
            [INITIAL_BOND + ONE_OCTA_INFLATION_DEPOSIT + 1, 0, 0, 0],
            version,
        )
        .await;
        assert_eq!(
            view(
                &f.client,
                "0x1::poc_accounting::get_position",
                vec![json!(actor.address()), json!(f.pool)],
                version
            )
            .await,
            vec![json!("0"), json!([]), json!("0"), json!("0")]
        );
    }
    let version = latest_version(&f.client).await;
    assert_eq!(one_octa_inflation_context(&f, version).await, epoch + 1);
    assert_eq!(integer(&pool_at(&f.client, f.pool, version).await[3]), 1);
    let position = view(
        &f.client,
        "0x1::poc_accounting::get_position",
        vec![json!(f.power_user.address()), json!(f.pool)],
        version,
    )
    .await;
    assert_eq!(position[1], json!([]));
    assert_eq!(integer(&position[2]), 0);
    assert_eq!(wide(&position[3]), fraction);
    assert_committee(&f, version).await;
    let expected_ledger = ledger_at(&f.client, f.pool, version).await;
    let expected_delegation = resource(
        &f.client,
        f.pool,
        "0x1::delegation_pool::DelegationPool",
        version,
    )
    .await;
    let expected_stake = resource(&f.client, f.pool, "0x1::stake::StakePool", version).await;
    let expected_rate = resource(
        &f.client,
        CORE_CODE_ADDRESS,
        "0x1::staking_config::StakingRewardsConfig",
        version,
    )
    .await;
    let installed = installed_at(&f.client, version).await;
    for member in &installed.validators.active_validators {
        let client = f.client_for_member(member.account_address);
        assert_eq!(ledger_at(&client, f.pool, version).await, expected_ledger);
        assert_eq!(
            resource(
                &client,
                f.pool,
                "0x1::delegation_pool::DelegationPool",
                version
            )
            .await,
            expected_delegation
        );
        assert_eq!(
            resource(&client, f.pool, "0x1::stake::StakePool", version).await,
            expected_stake
        );
        assert_eq!(
            resource(
                &client,
                CORE_CODE_ADDRESS,
                "0x1::staking_config::StakingRewardsConfig",
                version
            )
            .await,
            expected_rate
        );
        assert_shares_table(
            &client,
            &expected_delegation["active_shares"],
            &model,
            &f.holders(),
            version,
        )
        .await;
        for holder in f.holders() {
            assert_eq!(
                view(
                    &client,
                    "0x1::delegation_pool::get_stake",
                    vec![json!(f.pool), json!(holder)],
                    version
                )
                .await,
                vec![
                    json!(model.balance(holder).to_string()),
                    json!("0"),
                    json!("0")
                ]
            );
            assert_eq!(
                view(
                    &client,
                    "0x1::poc_accounting::get_position",
                    vec![json!(holder), json!(f.pool)],
                    version
                )
                .await,
                view(
                    &f.client,
                    "0x1::poc_accounting::get_position",
                    vec![json!(holder), json!(f.pool)],
                    version
                )
                .await
            );
        }
        for holder in &f.holders()[..4] {
            let allocation = resource(
                &client,
                *holder,
                "0x1::poc_accounting::UserAllocation",
                version,
            )
            .await;
            assert_eq!(
                allocation,
                resource(
                    &f.client,
                    *holder,
                    "0x1::poc_accounting::UserAllocation",
                    version
                )
                .await
            );
            let handle = address(&allocation["positions"]["handle"]);
            assert_eq!(
                table_entry(
                    &client,
                    handle,
                    "address",
                    "0x1::poc_accounting::Position",
                    json!(f.pool),
                    version
                )
                .await,
                table_entry(
                    &f.client,
                    handle,
                    "address",
                    "0x1::poc_accounting::Position",
                    json!(f.pool),
                    version
                )
                .await
            );
        }
    }
    println!("REW-10 one-Octa native inflation complete: closing_version={closing_version}, successes={successful}, failures={failed}, rate={}/{}, inflation={inflation}, native={native}, commission={commission}, add_fee={fee}, PoC={poc}, claim4/vault1/fraction={fraction}, owner={}, delegator={}, operator=0, native_share_dust=1, five nodes agree at version={version}", old.reward_context.2, old.reward_context.3, model.balance(f.owner.address()), model.balance(f.delegator.address()));
}

async fn commission_views(f: &Fixture, version: u64) -> (bool, u64, u64) {
    let effective = view(
        &f.client,
        "0x1::delegation_pool::is_next_commission_percentage_effective",
        vec![json!(f.pool)],
        version,
    )
    .await;
    let current = view(
        &f.client,
        "0x1::delegation_pool::operator_commission_percentage",
        vec![json!(f.pool)],
        version,
    )
    .await;
    let next = view(
        &f.client,
        "0x1::delegation_pool::operator_commission_percentage_next_lockup_cycle",
        vec![json!(f.pool)],
        version,
    )
    .await;
    (
        effective[0].as_bool().unwrap(),
        integer(&current[0]) as u64,
        integer(&next[0]) as u64,
    )
}

async fn completed_dkg_events(
    client: &Client,
    start: u64,
    end: u64,
    pool: AccountAddress,
) -> (usize, usize, usize, u64) {
    let mut installed = 0;
    let mut credits = 0;
    let mut splits = 0;
    let mut install_version = None;
    let mut cursor = start;
    while cursor <= end {
        let limit = (end - cursor + 1).min(100) as u16;
        let transactions = client
            .get_transactions(Some(cursor), Some(limit))
            .await
            .unwrap()
            .into_inner();
        assert!(!transactions.is_empty());
        for transaction in transactions {
            let transaction_version = cursor;
            assert_eq!(transaction.version(), Some(cursor));
            cursor += 1;
            let transaction_events = match &transaction {
                Transaction::UserTransaction(transaction) => &transaction.events,
                Transaction::GenesisTransaction(transaction) => &transaction.events,
                Transaction::BlockMetadataTransaction(transaction) => &transaction.events,
                Transaction::ValidatorTransaction(transaction) => transaction.events(),
                Transaction::StateCheckpointTransaction(_)
                | Transaction::BlockEpilogueTransaction(_) => continue,
                Transaction::PendingTransaction(_) => panic!("账本区间不能包含待提交交易"),
            };
            for event in transaction_events {
                let event_type = event.typ.to_string();
                if event_type.ends_with("::stake::PoCEpochInstalled") {
                    installed += 1;
                    assert!(install_version.replace(transaction_version).is_none());
                } else if event_type.ends_with("::stake::PoCRewardCredited")
                    && address(&event.data["pool"]) == pool
                {
                    credits += 1;
                } else if event_type.ends_with("::stake::PoCRewardSplit")
                    && address(&event.data["pool"]) == pool
                {
                    splits += 1;
                }
            }
        }
    }
    (installed, credits, splits, install_version.unwrap())
}

#[tokio::test]
async fn poc_commission_expiry_waits_for_real_dkg_and_pending_deposit() {
    println!("REW-10 佣金跨真实DKG：五个真实委员会节点、native3000/旧佣金3735/新佣金0、初始锁仓90秒、1%奖励率；普通DKG开启后暂停并跨过佣金时间，Chunky关闭/watchdog关闭");
    let (f, _) = fixture_with_options(
        3000,
        DEFAULT_COMMISSION_BPS,
        Some(0),
        1000 * OCTA,
        Some(90),
        false,
    )
    .await;
    let mut model = Shares::new(f.owner.address());

    let changed = success(
        execute(
            &f.client,
            &f.owner,
            &f.factory,
            aptos_stdlib::delegation_pool_update_commission_percentage(0),
        )
        .await,
    );
    let changed_at = changed.info.version.0;
    let changes = events(&changed, "::delegation_pool::CommissionPercentageChange");
    assert_eq!(changes.len(), 1);
    assert_eq!(address(&changes[0].data["pool_address"]), f.pool);
    assert_eq!(address(&changes[0].data["owner"]), f.owner.address());
    assert_eq!(
        integer(&changes[0].data["commission_percentage_next_lockup_cycle"]),
        0
    );
    assert_eq!(commission_views(&f, changed_at).await, (false, 3735, 0));
    let pending_commission = resource(
        &f.client,
        f.pool,
        "0x1::delegation_pool::NextCommissionPercentage",
        changed_at,
    )
    .await;
    let effective_after = integer(&pending_commission["effective_after_secs"]) as u64;

    // 先用同步换届安装普通 DKG 配置；新增质押随后进入本期 pending_active，
    // 因而不会被这次配置安装提前激活。
    let dkg_enabled = success(execute(&f.client, &f.root, &f.factory, freeze_governance(6)).await);
    let epoch = installed_at(&f.client, dkg_enabled.info.version.0)
        .await
        .epoch;
    assert_eq!(
        commission_views(&f, dkg_enabled.info.version.0).await,
        (false, 3735, 0)
    );
    deposit(&f, 3000, epoch, &mut model, 0).await;
    assert!(model.shares(NULL) > 0 && model.balance(NULL) > 0);

    positive_fee_pause(&f, true).await;
    let frozen = success(execute(&f.client, &f.root, &f.factory, freeze_governance(3)).await);
    let frozen_at = frozen.info.version.0;
    assert_eq!(installed_at(&f.client, frozen_at).await.epoch, epoch);
    let dkg = resource_at_version::<DKGState>(&f.client, frozen_at).await;
    let session = dkg.in_progress.as_ref().expect("必须启动真实普通DKG会话");
    assert_eq!(session.metadata.dealer_epoch, epoch);
    assert_eq!(session.target_epoch(), epoch + 1);
    assert!(session.transcript.is_empty());
    assert_eq!(native_stake(&f.client, f.pool, frozen_at).await, vec![
        json!(INITIAL_BOND.to_string()),
        json!("0"),
        json!(DEPOSIT.to_string()),
        json!("0")
    ]);

    tokio::time::timeout(Duration::from_secs(150), async {
        loop {
            let ledger = f
                .client
                .get_ledger_information()
                .await
                .unwrap()
                .into_inner();
            if ledger.timestamp_usecs / 1_000_000 > effective_after {
                break;
            }
            success(
                execute(
                    &f.client,
                    &f.power_user,
                    &f.factory,
                    aptos_stdlib::topo_coin_transfer(f.owner.address(), 1),
                )
                .await,
            );
            tokio::time::sleep(Duration::from_millis(500)).await;
        }
    })
    .await
    .expect("佣金生效时间未在150秒内到达");
    let expired_at = latest_version(&f.client).await;
    assert_eq!(installed_at(&f.client, expired_at).await.epoch, epoch);
    assert_eq!(commission_views(&f, expired_at).await, (false, 3735, 0));
    same_epoch_sync(&f, epoch, &model).await;
    let waiting_at = latest_version(&f.client).await;
    assert_eq!(commission_views(&f, waiting_at).await, (false, 3735, 0));
    assert_eq!(native_stake(&f.client, f.pool, waiting_at).await, vec![
        json!(INITIAL_BOND.to_string()),
        json!("0"),
        json!(DEPOSIT.to_string()),
        json!("0")
    ]);
    assert!(model.shares(NULL) > 0 && model.balance(NULL) > 0);

    positive_fee_pause(&f, false).await;
    let completed_at = tokio::time::timeout(Duration::from_secs(120), async {
        loop {
            let ledger = f
                .client
                .get_ledger_information()
                .await
                .unwrap()
                .into_inner();
            if ledger.epoch == epoch + 1 {
                let dkg = resource_at_version::<DKGState>(&f.client, ledger.version).await;
                if let Some(completed) = dkg
                    .last_completed
                    .as_ref()
                    .filter(|completed| completed.target_epoch() == epoch + 1)
                {
                    assert!(!completed.transcript.is_empty());
                    assert_targets(
                        &completed.metadata.target_validator_set,
                        &installed_at(&f.client, ledger.version).await.validators,
                    );
                    break ledger.version;
                }
            }
            tokio::time::sleep(Duration::from_millis(500)).await;
        }
    })
    .await
    .expect("真实普通DKG未在120秒内完成");
    let completion_events =
        completed_dkg_events(&f.client, frozen_at + 1, completed_at, f.pool).await;
    assert_eq!(completion_events.0, 1);
    assert_eq!(completion_events.1, 1);
    assert_eq!(completion_events.2, 1);
    let installed_at_version = completion_events.3;
    let before = installed_at(&f.client, installed_at_version - 1).await;
    let after = installed_at(&f.client, installed_at_version).await;
    assert_eq!((before.epoch, after.epoch), (epoch, epoch + 1));
    assert_eq!(after.validators, before.validators);
    assert_eq!(commission_views(&f, completed_at).await, (true, 0, 0));
    let validator = before
        .validators
        .active_validators
        .iter()
        .find(|validator| validator.account_address == f.pool)
        .unwrap();
    let proposal_counts = view(
        &f.client,
        "0x1::stake::get_current_epoch_proposal_counts",
        vec![json!(validator.config().validator_index.to_string())],
        installed_at_version - 1,
    )
    .await;
    let successful = integer(&proposal_counts[0]);
    let failed = integer(&proposal_counts[1]);
    assert!(successful > 0);
    let inflation = (REWARD_BASE as u128 * successful * before.reward_context.2 as u128
        / ((successful + failed) * before.reward_context.3 as u128)) as u64;
    let native = inflation * 3000 / 10000;
    let commission = native * DEFAULT_COMMISSION_BPS / 10000;
    assert!(native > 0 && commission > 0);
    assert_eq!(
        native_stake(&f.client, f.pool, installed_at_version).await,
        vec![
            json!((INITIAL_BOND + DEPOSIT + native).to_string()),
            json!("0"),
            json!("0"),
            json!("0")
        ]
    );

    let synchronized = success(
        execute(
            &f.client,
            &f.owner,
            &f.factory,
            aptos_stdlib::delegation_pool_synchronize_delegation_pool(f.pool),
        )
        .await,
    );
    assert_eq!(
        model.settle(native, DEFAULT_COMMISSION_BPS, f.operator.address()),
        commission
    );
    assert_commission(&f, &synchronized, commission, 0);
    assert_eq!(model.shares(NULL), 0);
    let synchronized_at = synchronized.info.version.0;
    let delegation = resource(
        &f.client,
        f.pool,
        "0x1::delegation_pool::DelegationPool",
        synchronized_at,
    )
    .await;
    assert_eq!(integer(&delegation["operator_commission_percentage"]), 0);
    let installed_commission = resource(
        &f.client,
        f.pool,
        "0x1::delegation_pool::NextCommissionPercentage",
        synchronized_at,
    )
    .await;
    assert_eq!(
        integer(&installed_commission["commission_percentage_next_lockup_cycle"]),
        0
    );
    assert_balances(&f, &model, synchronized_at).await;
    assert_eq!(commission_views(&f, synchronized_at).await, (true, 0, 0));
    assert!(
        integer(
            &view(
                &f.client,
                "0x1::delegation_pool::get_add_stake_fee",
                vec![json!(f.pool), json!(DEPOSIT.to_string())],
                synchronized_at,
            )
            .await[0]
        ) > 0
    );
    assert_committee(&f, synchronized_at).await;
    println!("REW-10 佣金跨真实DKG完成：epoch={epoch}->{}, frozen_version={frozen_at}, completed_version={completed_at}, native={native}, old_commission={commission}, new_commission=0, NULL临时份额按旧佣金结算后释放，五个当前节点同版本", epoch + 1);
}

const POSITIVE_FEE_DKG_FAILPOINT: &str = "dkg::process_dkg_start_event";
const FROZEN_FEE_LIMIT: u64 = 39;
const FROZEN_INACTIVE: u64 = 50 * OCTA;

static FREEZE_GOVERNANCE: Lazy<Vec<u8>> = Lazy::new(|| {
    compile_script(
        "PoCPositiveFeeDelegationFreeze",
        r#"script {
        use topo_std::fixed_point64;
        use topo_framework::epoch_timeout_config;
        use topo_framework::randomness_config;
        use topo_framework::stake;
        use topo_framework::staking_config;
        use topo_framework::topo_governance;
        fun main(root: &signer, operation: u8, lockup_secs: u64) {
            let framework = topo_governance::get_signer_testnet_only(root, @0x1);
            if (operation == 0) {
                staking_config::update_recurring_lockup_duration_secs(&framework, lockup_secs);
            } else if (operation == 1) {
                stake::set_transaction_fee_limit_per_epoch_per_pool(&framework, 0);
                topo_governance::reconfigure(&framework);
            } else if (operation == 2 || operation == 5 || operation == 6) {
                // 当前 randomness 配置为 Off：本次提交先转换
                // 已到期的 pending 本金，再安装真实 DKG 配置。
                staking_config::update_recurring_lockup_duration_secs(&framework, 3600);
                if (operation == 2) {
                    stake::set_transaction_fee_limit_per_epoch_per_pool(&framework, 39);
                };
                if (operation == 6) {
                    let rate = fixed_point64::create_from_rational(1, 100);
                    staking_config::update_rewards_config(
                        &framework, rate, rate, 31536000,
                        fixed_point64::create_from_rational(0, 1));
                };
                randomness_config::set_for_next_epoch(&framework,
                    randomness_config::new_v1(
                        fixed_point64::create_from_rational(1, 2),
                        fixed_point64::create_from_rational(2, 3)));
                epoch_timeout_config::set_for_next_epoch(&framework,
                    epoch_timeout_config::new_disabled());
                topo_governance::reconfigure(&framework);
            } else if (operation == 3) {
                topo_governance::reconfigure(&framework);
            } else {
                assert!(operation == 4, 0);
                topo_governance::force_end_epoch(&framework);
            };
        }
    }"#,
    )
});

fn freeze_governance(operation: u8) -> TransactionPayload {
    freeze_governance_with_lockup(operation, 0)
}

fn freeze_governance_with_lockup(operation: u8, lockup_secs: u64) -> TransactionPayload {
    TransactionPayload::Script(Script::new(FREEZE_GOVERNANCE.clone(), vec![], vec![
        TransactionArgument::U8(operation),
        TransactionArgument::U64(lockup_secs),
    ]))
}

fn empty_shares() -> Shares {
    Shares {
        coins: 0,
        total: 0,
        holders: BTreeMap::new(),
    }
}

/// OLC0 仅包含 owner 已到期的提取权益，OLC1 保存 delegator 的待提取权益。
/// 使用不同持有人，避免 unlock 按正常规则自动提取前一 OLC 的余额，
/// 从而掩盖后续显式 withdraw 的行为。
struct PositiveFeeModel {
    active: Shares,
    inactive: Shares,
    pending: Shares,
    native: [u64; 4],
}

async fn positive_fee_model_at(
    f: &Fixture,
    client: &Client,
    model: &PositiveFeeModel,
    version: u64,
) {
    assert_eq!(
        native_stake(client, f.pool, version).await,
        model
            .native
            .map(|amount| json!(amount.to_string()))
            .to_vec()
    );
    assert_eq!(model.active.coins, model.native[0] + model.native[2]);
    assert_eq!(model.inactive.coins, model.native[1]);
    assert_eq!(model.pending.coins, model.native[3]);
    let delegation = resource(
        client,
        f.pool,
        "0x1::delegation_pool::DelegationPool",
        version,
    )
    .await;
    assert_eq!(integer(&delegation["operator_commission_percentage"]), 3735);
    assert_eq!(integer(&delegation["observed_lockup_cycle"]["index"]), 1);
    assert_eq!(
        integer(&delegation["total_coins_inactive"]),
        model.inactive.coins as u128
    );
    assert_shares_table(
        client,
        &delegation["active_shares"],
        &model.active,
        &f.holders(),
        version,
    )
    .await;
    for (index, shares) in [(0, &model.inactive), (1, &model.pending)] {
        let table = table_entry(
            client,
            address(&delegation["inactive_shares"]["handle"]),
            "0x1::delegation_pool::ObservedLockupCycle",
            "0x1::pool_u64_unbound::Pool",
            json!({"index": index.to_string()}),
            version,
        )
        .await
        .unwrap();
        assert_shares_table(client, &table, shares, &f.holders(), version).await;
    }
    for holder in f.holders() {
        let expected_withdrawal = if model.inactive.shares(holder) > 0 {
            Some(json!({"index": "0"}))
        } else if model.pending.shares(holder) > 0 {
            Some(json!({"index": "1"}))
        } else {
            None
        };
        assert_eq!(
            table_entry(
                client,
                address(&delegation["pending_withdrawals"]["handle"]),
                "address",
                "0x1::delegation_pool::ObservedLockupCycle",
                json!(holder),
                version
            )
            .await,
            expected_withdrawal
        );
        assert_eq!(
            view(
                client,
                "0x1::delegation_pool::get_stake",
                vec![json!(f.pool), json!(holder)],
                version
            )
            .await,
            vec![
                json!(model.active.balance(holder).to_string()),
                json!(model.inactive.balance(holder).to_string()),
                json!(model.pending.balance(holder).to_string())
            ]
        );
    }
}

async fn positive_fee_context(f: &Fixture, version: u64, limit: u64) -> u64 {
    let installed = installed_at(&f.client, version).await;
    assert_eq!(
        installed.reward_context,
        (installed.epoch, true, 0, 1, true, limit)
    );
    assert_eq!(
        integer(&installed.reward_split["installed_native_reward_bps"]),
        3000
    );
    assert_eq!(
        integer(&installed.reward_split["installed_epoch"]),
        installed.epoch as u128
    );
    installed.epoch
}

async fn positive_fee_quote(f: &Fixture, model: &PositiveFeeModel, version: u64) -> u64 {
    positive_fee_context(f, version, FROZEN_FEE_LIMIT).await;
    // 通胀为零，费用 39 分出原生收益 11，floor(11*3735/10000)=4；
    // 报价为 active/PI 分别取整的差异预留余量：11-4+1。
    let native_upper = FROZEN_FEE_LIMIT as u128 * 3000 / 10000;
    let commission_floor = native_upper * 3735 / 10000;
    let net_upper = native_upper - commission_floor + u128::from(commission_floor > 0);
    assert_eq!(net_upper, 8);
    let eligible = model.native[0] as u128 + model.native[3] as u128;
    let fee = (DEPOSIT as u128 * net_upper).div_ceil(eligible + net_upper) as u64;
    assert!(fee > 0);
    assert_eq!(
        view(
            &f.client,
            "0x1::delegation_pool::get_add_stake_fee",
            vec![json!(f.pool), json!(DEPOSIT.to_string())],
            version
        )
        .await,
        vec![json!(fee.to_string())]
    );
    fee
}

async fn initialize_zero_power_reward_positions(f: &Fixture, epoch: u64) {
    // 领取指定池的奖励同时要求存在 UserAllocation 和对应 Position。
    // 无原始算力时，先选择目标池创建零持仓，
    // 再将待生效比例覆盖为空，仍会保留该持仓。
    for actor in [&f.owner, &f.delegator, &f.operator] {
        for bps in [vec![10000], vec![]] {
            let pools = if bps.is_empty() { vec![] } else { vec![f.pool] };
            let tx = success(
                execute(
                    &f.client,
                    actor,
                    &f.factory,
                    aptos_stdlib::poc_allocation_set_allocations(pools.clone(), bps.clone()),
                )
                .await,
            );
            let version = tx.info.version.0;
            assert_eq!(positive_fee_context(f, version, 0).await, epoch);
            assert_eq!(
                installed_at(&f.client, version - 1).await,
                installed_at(&f.client, version).await
            );
            let power = view(
                &f.client,
                "0x1::poc_power_store::get_accounting_snapshot",
                vec![json!(actor.address())],
                version,
            )
            .await;
            assert_eq!(integer(&power[0]), 0);
            assert_eq!(integer(&power[1]), 0);
            assert_eq!(
                power,
                view(
                    &f.client,
                    "0x1::poc_power_store::get_accounting_snapshot",
                    vec![json!(actor.address())],
                    version - 1
                )
                .await
            );
            if !bps.is_empty() {
                assert!(optional_resource_at_version(
                    &f.client,
                    actor.address(),
                    "0x1::poc_accounting::UserAllocation",
                    version - 1
                )
                .await
                .is_none());
            }
            let ratios = if bps.is_empty() {
                json!([])
            } else {
                json!([{"pool": f.pool.to_hex_literal(), "bps": "10000"}])
            };
            let pending = json!({"vec": [{"epoch": (epoch + 1).to_string(), "ratios": ratios}]});
            let allocation = resource(
                &f.client,
                actor.address(),
                "0x1::poc_accounting::UserAllocation",
                version,
            )
            .await;
            assert_eq!(allocation["active"], json!([]));
            assert_eq!(allocation["pending"], pending);
            assert_eq!(
                view(
                    &f.client,
                    "0x1::poc_accounting::get_allocations",
                    vec![json!(actor.address())],
                    version
                )
                .await,
                vec![json!([]), pending]
            );
            let ledger = super::fee_rewards::ledger_at(&f.client, f.pool, version).await;
            assert_eq!(
                ledger,
                super::fee_rewards::ledger_at(&f.client, f.pool, version - 1).await
            );
            assert_eq!(
                table_entry(
                    &f.client,
                    address(&allocation["positions"]["handle"]),
                    "address",
                    "0x1::poc_accounting::Position",
                    json!(f.pool),
                    version
                )
                .await,
                Some(
                    json!({"units": "0", "changes": [], "cursor": ledger["index"], "accrued": "0"})
                )
            );
            assert_eq!(
                view(
                    &f.client,
                    "0x1::poc_accounting::get_position",
                    vec![json!(actor.address()), json!(f.pool)],
                    version
                )
                .await,
                vec![json!("0"), json!([]), json!("0"), json!("0")]
            );
            assert_eq!(
                pool_at(&f.client, f.pool, version - 1).await,
                pool_at(&f.client, f.pool, version).await
            );
            for name in [
                "0x1::stake::StakePool",
                "0x1::delegation_pool::DelegationPool",
            ] {
                assert_eq!(
                    resource(&f.client, f.pool, name, version - 1).await,
                    resource(&f.client, f.pool, name, version).await
                );
            }
            let scheduled = events(&tx, "::poc_accounting::AllocationScheduled");
            assert_eq!(scheduled.len(), 1);
            assert_eq!(
                scheduled[0].data,
                json!({
                    "user": actor.address().to_hex_literal(),
                    "effective_epoch": (epoch + 1).to_string(),
                    "pools": pools.iter().map(AccountAddress::to_hex_literal).collect::<Vec<_>>(),
                    "bps": bps.iter().map(u64::to_string).collect::<Vec<_>>()
                })
            );
            assert!(events(&tx, "::poc_accounting::PoCRewardClaimed").is_empty());
            assert_payment(&f.client, &tx, 0).await;
        }
    }
    println!("Delegation zero-power claim preparation: owner/delegator/operator each have an empty pending allocation and a retained zero-unit/zero-accrued position; both public transactions stayed in epoch={epoch}, PoC/native pool state unchanged");
}

async fn prepare_positive_fee_withdrawal(f: &Fixture) -> PositiveFeeModel {
    // 刚安装的费用 Epoch 尚无 gas 单价高于销毁阈值的用户交易；
    // 先按零费用结算，再准备 inactive 本金。
    let low_factory = f.factory.clone().with_gas_unit_price(1);
    let zero = success(execute(&f.client, &f.root, &low_factory, freeze_governance(1)).await);
    let version = zero.info.version.0;
    assert_eq!(recorded_fee(&f.client, f.pool, version - 1).await, 0);
    let epoch = positive_fee_context(f, version, 0).await;
    assert_eq!(installed_at(&f.client, version - 1).await.epoch + 1, epoch);
    assert_eq!(
        integer(&pool_event(&zero, "::stake::PoCRewardCredited", f.pool).data["fee"]),
        0
    );
    assert_native_balances(f, [INITIAL_BOND, 0, 0, 0], version).await;
    let mut active = Shares::new(f.owner.address());
    let mut inactive = empty_shares();
    let unlock = success(
        execute(
            &f.client,
            &f.owner,
            &f.factory,
            aptos_stdlib::delegation_pool_unlock(f.pool, FROZEN_INACTIVE),
        )
        .await,
    );
    let version = unlock.info.version.0;
    assert_eq!(
        active.redeem_partial(f.owner.address(), FROZEN_INACTIVE),
        FROZEN_INACTIVE
    );
    inactive.buy(f.owner.address(), FROZEN_INACTIVE);
    assert_native_balances(
        f,
        [INITIAL_BOND - FROZEN_INACTIVE, 0, 0, FROZEN_INACTIVE],
        version,
    )
    .await;
    assert_commission(f, &unlock, 0, 0);
    wallet_delta(f, &unlock, 0).await;
    let lock = integer(
        &resource(&f.client, f.pool, "0x1::stake::StakePool", version).await["locked_until_secs"],
    );
    initialize_zero_power_reward_positions(f, epoch).await;
    println!("FRZ-02 positive fee setup: wait for real short lock={lock}; owner pending={FROZEN_INACTIVE}; rate0/fee0");
    tokio::time::timeout(Duration::from_secs(40), async {
        loop {
            let version = latest_version(&f.client).await;
            assert_eq!(positive_fee_context(f, version, 0).await, epoch);
            let clock = resource(
                &f.client,
                CORE_CODE_ADDRESS,
                "0x1::timestamp::CurrentTimeMicroseconds",
                version,
            )
            .await;
            if integer(&clock["microseconds"]) / 1_000_000 > lock {
                break;
            }
            tokio::time::sleep(Duration::from_millis(200)).await;
        }
    })
    .await
    .expect("Delegation's short lock did not expire within 40 seconds");
    let installed = success(execute(&f.client, &f.root, &low_factory, freeze_governance(2)).await);
    let version = installed.info.version.0;
    assert_eq!(
        positive_fee_context(f, version, FROZEN_FEE_LIMIT).await,
        epoch + 1
    );
    assert_eq!(
        integer(&pool_event(&installed, "::stake::PoCRewardCredited", f.pool).data["inflation"]),
        0
    );
    assert_eq!(
        integer(&pool_event(&installed, "::stake::PoCRewardCredited", f.pool).data["fee"]),
        0
    );
    assert!(events(&installed, "::stake::DistributeRewards").is_empty());
    assert!(events(&installed, "::stake::DistributeTransactionFee").is_empty());
    let clock = resource(
        &f.client,
        CORE_CODE_ADDRESS,
        "0x1::timestamp::CurrentTimeMicroseconds",
        version,
    )
    .await;
    let now = integer(&clock["microseconds"]) / 1_000_000;
    assert!(now > lock);
    assert_eq!(
        integer(
            &resource(&f.client, f.pool, "0x1::stake::StakePool", version).await
                ["locked_until_secs"]
        ),
        now + 3600
    );
    let model = PositiveFeeModel {
        active,
        inactive,
        pending: empty_shares(),
        native: [INITIAL_BOND - FROZEN_INACTIVE, FROZEN_INACTIVE, 0, 0],
    };
    let sync = success(
        execute(
            &f.client,
            &f.owner,
            &f.factory,
            aptos_stdlib::delegation_pool_synchronize_delegation_pool(f.pool),
        )
        .await,
    );
    assert_commission(f, &sync, 0, 0);
    assert_payment(&f.client, &sync, 0).await;
    positive_fee_model_at(f, &f.client, &model, sync.info.version.0).await;
    assert!(
        resource_at_version::<DKGState>(&f.client, sync.info.version.0)
            .await
            .in_progress
            .is_none()
    );
    success(
        execute(
            &f.client,
            &f.owner,
            &f.factory,
            aptos_stdlib::delegation_pool_enable_delegators_allowlisting(),
        )
        .await,
    );
    for allowed in [f.owner.address(), f.delegator.address()] {
        success(
            execute(
                &f.client,
                &f.owner,
                &f.factory,
                aptos_stdlib::delegation_pool_allowlist_delegator(allowed),
            )
            .await,
        );
    }
    model
}

#[derive(Clone, Copy, Debug)]
enum PositiveFeeCall {
    Add,
    Unlock,
    Reactivate,
    Withdraw,
}

const POSITIVE_FEE_CALLS: [PositiveFeeCall; 4] = [
    PositiveFeeCall::Add,
    PositiveFeeCall::Unlock,
    PositiveFeeCall::Reactivate,
    PositiveFeeCall::Withdraw,
];

impl PositiveFeeCall {
    fn amount(self) -> u64 {
        match self {
            Self::Add => DEPOSIT,
            Self::Unlock => 40 * OCTA,
            Self::Reactivate | Self::Withdraw => 10 * OCTA,
        }
    }

    fn payload(self, pool: AccountAddress) -> TransactionPayload {
        match self {
            Self::Add => aptos_stdlib::delegation_pool_add_stake(pool, self.amount()),
            Self::Unlock => aptos_stdlib::delegation_pool_unlock(pool, self.amount()),
            Self::Reactivate => aptos_stdlib::delegation_pool_reactivate_stake(pool, self.amount()),
            Self::Withdraw => aptos_stdlib::delegation_pool_withdraw(pool, self.amount()),
        }
    }

    fn actor(self, f: &Fixture) -> &LocalAccount {
        match self {
            Self::Withdraw => &f.owner,
            Self::Add | Self::Unlock | Self::Reactivate => &f.delegator,
        }
    }

    fn event(self) -> (&'static str, &'static str) {
        match self {
            Self::Add => ("::delegation_pool::AddStake", "amount_added"),
            Self::Unlock => ("::delegation_pool::UnlockStake", "amount_unlocked"),
            Self::Reactivate => ("::delegation_pool::ReactivateStake", "amount_reactivated"),
            Self::Withdraw => ("::delegation_pool::WithdrawStake", "amount_withdrawn"),
        }
    }
}

async fn positive_fee_success(f: &Fixture, call: PositiveFeeCall, model: &mut PositiveFeeModel) {
    let tx = success(execute(&f.client, call.actor(f), &f.factory, call.payload(f.pool)).await);
    let version = tx.info.version.0;
    positive_fee_model_at(f, &f.client, model, version - 1).await;
    let actor = call.actor(f).address();
    let amount = call.amount();
    let mut fee = 0;
    let (actual, wallet_change) = match call {
        PositiveFeeCall::Add => {
            fee = positive_fee_quote(f, model, version - 1).await;
            model.active.deposit(actor, amount, fee);
            model.native[2] += amount;
            (amount, -(amount as i128))
        },
        PositiveFeeCall::Unlock => {
            // 所有剩余余额和目标余额均超过最低 10 TOPO 要求，
            // 金额仅受每次份额兑换代币时向下取整的影响。
            assert!(model.active.balance(actor) - amount >= 10 * OCTA);
            let actual = model.active.redeem_partial(actor, amount);
            model.pending.buy(actor, actual);
            model.native[0] -= actual;
            model.native[3] += actual;
            (actual, 0)
        },
        PositiveFeeCall::Reactivate => {
            assert!(model.pending.balance(actor) - amount >= 10 * OCTA);
            let actual = model.pending.redeem_partial(actor, amount);
            model.active.buy(actor, actual);
            model.native[0] += actual;
            model.native[3] -= actual;
            (actual, 0)
        },
        PositiveFeeCall::Withdraw => {
            let actual = model.inactive.redeem_partial(actor, amount);
            model.native[1] -= actual;
            (actual, actual as i128)
        },
    };
    positive_fee_model_at(f, &f.client, model, version).await;
    let (event_type, amount_field) = call.event();
    let business = events(&tx, event_type);
    assert_eq!(business.len(), 1);
    assert_eq!(address(&business[0].data["pool_address"]), f.pool);
    assert_eq!(address(&business[0].data["delegator_address"]), actor);
    assert_eq!(integer(&business[0].data[amount_field]), actual as u128);
    if matches!(call, PositiveFeeCall::Add) {
        assert_eq!(integer(&business[0].data["add_stake_fee"]), fee as u128);
        assert!(model.active.shares(NULL) > 0);
    }
    assert_commission(f, &tx, 0, 0);
    assert_no_poc_change(f, &tx).await;
    wallet_delta(f, &tx, wallet_change).await;
    println!("FRZ-02 positive fee success: call={call:?}, version={version}, requested={amount}, actual={actual}, fee={fee}, NULL_shares={}, native={:?}", model.active.shares(NULL), model.native);
}

#[derive(Debug, PartialEq)]
struct PositiveFeeSnapshot {
    data: BTreeMap<String, Value>,
    handles: BTreeSet<AccountAddress>,
}

async fn positive_fee_smart_table(
    client: &Client,
    name: &str,
    table: &Value,
    types: (&str, &str),
    version: u64,
    snapshot: &mut PositiveFeeSnapshot,
) {
    let handle = address(&table["buckets"]["inner"]["handle"]);
    for bucket in 0..integer(&table["num_buckets"]) {
        let value = table_entry(
            client,
            handle,
            "u64",
            &format!("vector<0x1::smart_table::Entry<{}, {}>>", types.0, types.1),
            json!(bucket.to_string()),
            version,
        )
        .await
        .unwrap();
        collect_handles(&value, &mut snapshot.handles);
        snapshot.data.insert(format!("{name}/{bucket}"), value);
    }
}

async fn positive_fee_snapshot(f: &Fixture, client: &Client, version: u64) -> PositiveFeeSnapshot {
    let mut snapshot = PositiveFeeSnapshot {
        data: BTreeMap::new(),
        handles: BTreeSet::new(),
    };
    for name in [
        "stake::StakePool",
        "stake::ValidatorConfig",
        "stake::OwnerCapability",
        "delegation_pool::DelegationPool",
        "delegation_pool::GovernanceRecords",
        "delegation_pool::DelegationPoolAllowlisting",
    ] {
        let value = resource(client, f.pool, &format!("0x1::{name}"), version).await;
        collect_handles(&value, &mut snapshot.handles);
        snapshot.data.insert(name.to_owned(), value);
    }
    snapshot.data.insert(
        "ownership".to_owned(),
        resource(
            client,
            f.owner.address(),
            "0x1::delegation_pool::DelegationPoolOwnership",
            version,
        )
        .await,
    );
    let delegation = snapshot.data["delegation_pool::DelegationPool"].clone();
    assert_eq!(integer(&delegation["observed_lockup_cycle"]["index"]), 1);
    for holder in f.holders() {
        snapshot.data.insert(
            format!("active/{holder}"),
            json!(
                table_entry(
                    client,
                    address(&delegation["active_shares"]["shares"]["inner"]["handle"]),
                    "address",
                    "u128",
                    json!(holder),
                    version
                )
                .await
            ),
        );
        snapshot.data.insert(
            format!("withdrawal/{holder}"),
            json!(
                table_entry(
                    client,
                    address(&delegation["pending_withdrawals"]["handle"]),
                    "address",
                    "0x1::delegation_pool::ObservedLockupCycle",
                    json!(holder),
                    version
                )
                .await
            ),
        );
        snapshot.data.insert(
            format!("balance/{holder}"),
            json!(
                view(
                    client,
                    "0x1::delegation_pool::get_stake",
                    vec![json!(f.pool), json!(holder)],
                    version
                )
                .await
            ),
        );
    }
    for index in 0..=1 {
        let pool = table_entry(
            client,
            address(&delegation["inactive_shares"]["handle"]),
            "0x1::delegation_pool::ObservedLockupCycle",
            "0x1::pool_u64_unbound::Pool",
            json!({"index": index.to_string()}),
            version,
        )
        .await
        .unwrap();
        collect_handles(&pool, &mut snapshot.handles);
        for holder in f.holders() {
            snapshot.data.insert(
                format!("inactive/{index}/{holder}"),
                json!(
                    table_entry(
                        client,
                        address(&pool["shares"]["inner"]["handle"]),
                        "address",
                        "u128",
                        json!(holder),
                        version
                    )
                    .await
                ),
            );
        }
        snapshot.data.insert(format!("inactive/{index}"), pool);
    }
    let governance = snapshot.data["delegation_pool::GovernanceRecords"].clone();
    for (name, key, value) in [
        ("votes", "0x1::delegation_pool::VotingRecordKey", "u64"),
        ("votes_per_proposal", "u64", "u64"),
        (
            "vote_delegation",
            "address",
            "0x1::delegation_pool::VoteDelegation",
        ),
        (
            "delegated_votes",
            "address",
            "0x1::delegation_pool::DelegatedVotes",
        ),
    ] {
        positive_fee_smart_table(
            client,
            name,
            &governance[name],
            (key, value),
            version,
            &mut snapshot,
        )
        .await;
    }
    let allowlist =
        snapshot.data["delegation_pool::DelegationPoolAllowlisting"]["allowlist"].clone();
    positive_fee_smart_table(
        client,
        "allowlist",
        &allowlist,
        ("address", "bool"),
        version,
        &mut snapshot,
    )
    .await;
    snapshot.data.insert(
        "poc_pool".to_owned(),
        json!(pool_at(client, f.pool, version).await),
    );
    snapshot.data.insert(
        "poc_ledger".to_owned(),
        super::fee_rewards::ledger_at(client, f.pool, version).await,
    );
    snapshot.data.insert(
        "fee_quote".to_owned(),
        json!(
            view(
                client,
                "0x1::delegation_pool::get_add_stake_fee",
                vec![json!(f.pool), json!(DEPOSIT.to_string())],
                version
            )
            .await
        ),
    );
    snapshot
}

async fn positive_fee_reject(
    f: &Fixture,
    model: &PositiveFeeModel,
    call: PositiveFeeCall,
    actor: &LocalAccount,
    error: (&str, u64),
) -> u64 {
    let tx = execute(&f.client, actor, &f.factory, call.payload(f.pool)).await;
    assert_abort(&f.client, &tx, error.0, error.1, &f.holders()[..4], &[
        f.pool
    ])
    .await;
    let version = tx.info.version.0;
    let before = positive_fee_snapshot(f, &f.client, version - 1).await;
    assert_eq!(positive_fee_snapshot(f, &f.client, version).await, before);
    for change in &tx.info.changes {
        match change {
            WriteSetChange::WriteTableItem(item) => assert!(!before
                .handles
                .contains(&AccountAddress::from_bytes(item.handle.inner()).unwrap())),
            WriteSetChange::DeleteTableItem(item) => assert!(!before
                .handles
                .contains(&AccountAddress::from_bytes(item.handle.inner()).unwrap())),
            WriteSetChange::WriteResource(item) => assert!(
                !item.data.typ.to_string().contains("::delegation_pool::")
                    && !item.data.typ.to_string().contains("::stake::")
            ),
            WriteSetChange::DeleteResource(item) => assert!(
                !item.resource.to_string().contains("::delegation_pool::")
                    && !item.resource.to_string().contains("::stake::")
            ),
            WriteSetChange::WriteModule(_) | WriteSetChange::DeleteModule(_) => {
                panic!("Unexpected module write")
            },
        }
    }
    assert!(tx.events.iter().all(
        |event| !event.typ.to_string().contains("::delegation_pool::")
            && !event.typ.to_string().contains("::stake::")
    ));
    positive_fee_model_at(f, &f.client, model, version - 1).await;
    positive_fee_model_at(f, &f.client, model, version).await;
    wallet_delta(f, &tx, 0).await;
    for holder in f.holders()[..4].iter().copied().chain([f.pool]) {
        if holder != actor.address() {
            assert_eq!(
                f.client
                    .view_apt_account_balance_at_version(holder, version - 1)
                    .await
                    .unwrap()
                    .into_inner(),
                f.client
                    .view_apt_account_balance_at_version(holder, version)
                    .await
                    .unwrap()
                    .into_inner()
            );
        }
    }
    println!("FRZ-02 positive fee rejected: {call:?}, actor={}, version={version}, module={}, code={:#x}, existing_NULL_shares={}, inactive_OLC0={}, pending_OLC1={}",
        actor.address(), error.0, error.1, model.active.shares(NULL), model.inactive.coins, model.pending.coins);
    version
}

async fn positive_fee_unowned_withdrawal(f: &Fixture, model: &PositiveFeeModel) -> u64 {
    // withdraw 不接受任意收款人。若签名者没有提取权益，
    // 此调用仅执行同步，不会因权限中止，也不会支付代币。
    let tx = success(
        execute(
            &f.client,
            &f.power_user,
            &f.factory,
            PositiveFeeCall::Withdraw.payload(f.pool),
        )
        .await,
    );
    let version = tx.info.version.0;
    positive_fee_model_at(f, &f.client, model, version - 1).await;
    positive_fee_model_at(f, &f.client, model, version).await;
    assert_commission(f, &tx, 0, 0);
    assert!(events(&tx, "::delegation_pool::WithdrawStake").is_empty());
    assert!(events(&tx, "::stake::WithdrawStake").is_empty());
    assert_no_poc_change(f, &tx).await;
    wallet_delta(f, &tx, 0).await;
    version
}

async fn positive_fee_unauthorized(f: &Fixture, model: &PositiveFeeModel, frozen: bool) {
    for call in [PositiveFeeCall::Add, PositiveFeeCall::Reactivate] {
        positive_fee_reject(f, model, call, &f.power_user, ("delegation_pool", 0x50019)).await;
    }
    // 无 active 份额的签名者以零赎回金额进入 stake 的冻结检查；
    // 未冻结时，则由目标余额的最低要求拒绝该操作。
    positive_fee_reject(
        f,
        model,
        PositiveFeeCall::Unlock,
        &f.power_user,
        if frozen {
            ("stake", 0x30014)
        } else {
            ("delegation_pool", 0x10009)
        },
    )
    .await;
    positive_fee_unowned_withdrawal(f, model).await;
}

async fn positive_fee_collect(f: &Fixture, model: &PositiveFeeModel) -> u64 {
    let version = latest_version(&f.client).await;
    let epoch = positive_fee_context(f, version, FROZEN_FEE_LIMIT).await;
    let (factory, burn) = priced_fee_factory(&f.client, &f.factory, version).await;
    tokio::time::timeout(Duration::from_secs(90), async {
        loop {
            let version = latest_version(&f.client).await;
            if recorded_fee(&f.client, f.pool, version).await == FROZEN_FEE_LIMIT {
                break;
            }
            let tx = success(
                execute(
                    &f.client,
                    &f.power_user,
                    &factory,
                    aptos_stdlib::topo_coin_transfer(f.owner.address(), 1),
                )
                .await,
            );
            let (_, _, distributable) =
                assert_transfer_fee_block(&f.client, &tx, burn, epoch, FROZEN_FEE_LIMIT).await;
            assert!(distributable > FROZEN_FEE_LIMIT);
        }
    })
    .await
    .expect("Positive-fee delegation did not earn 39 Octa before freezing");
    let version = latest_version(&f.client).await;
    assert_eq!(
        positive_fee_context(f, version, FROZEN_FEE_LIMIT).await,
        epoch
    );
    assert_eq!(
        recorded_fee(&f.client, f.pool, version).await,
        FROZEN_FEE_LIMIT
    );
    positive_fee_model_at(f, &f.client, model, version).await;
    assert!(model.active.shares(NULL) > 0 && model.active.balance(NULL) > 0);
    positive_fee_quote(f, model, version).await;
    println!("FRZ-02 prefreeze: epoch={epoch}, version={version}, recorded_fee39/native11, NULL_shares={}, NULL_coins={}, native={:?}",
        model.active.shares(NULL), model.active.balance(NULL), model.native);
    version
}

struct PositiveFeeFrozen {
    epoch: u64,
    context: Vec<Vec<u8>>,
    dkg: DKGState,
    target: ValidatorSet,
}

async fn positive_fee_pause(f: &Fixture, pause: bool) {
    for node in f.swarm.validators() {
        node.rest_client()
            .set_failpoint(
                POSITIVE_FEE_DKG_FAILPOINT.to_owned(),
                if pause { "pause" } else { "off" }.to_owned(),
            )
            .await
            .unwrap();
    }
}

async fn positive_fee_freeze(f: &Fixture, model: &PositiveFeeModel) -> PositiveFeeFrozen {
    positive_fee_pause(f, true).await;
    let tx = success(execute(&f.client, &f.root, &f.factory, freeze_governance(3)).await);
    let version = tx.info.version.0;
    let epoch = positive_fee_context(f, version, FROZEN_FEE_LIMIT).await;
    assert_eq!(
        installed_at(&f.client, version - 1).await,
        installed_at(&f.client, version).await
    );
    assert_eq!(
        positive_fee_snapshot(f, &f.client, version - 1).await,
        positive_fee_snapshot(f, &f.client, version).await
    );
    positive_fee_model_at(f, &f.client, model, version).await;
    assert!(events(&tx, "::stake::PoCEpochInstalled").is_empty());
    assert!(events(&tx, "::stake::PoCRewardCredited").is_empty());
    let dkg = resource_at_version::<DKGState>(&f.client, version).await;
    let session = dkg
        .in_progress
        .as_ref()
        .expect("Expected real paused delegation DKG");
    assert_eq!(session.metadata.dealer_epoch, epoch);
    assert_eq!(session.target_epoch(), epoch + 1);
    assert!(session.transcript.is_empty());
    let (target, fallback): (ValidatorSet, bool) = f
        .client
        .get_account_resource_at_version_bcs(
            CORE_CODE_ADDRESS,
            "0x1::stake::PrecomputedValidatorSet",
            version,
        )
        .await
        .unwrap()
        .into_inner();
    assert!(!fallback);
    assert_eq!(target, installed_at(&f.client, version).await.validators);
    assert_targets(&session.metadata.target_validator_set, &target);
    assert_targets(&session.metadata.dealer_validator_set, &target);
    let plan = resource(
        &f.client,
        CORE_CODE_ADDRESS,
        "0x1::stake::EpochPlan",
        version,
    )
    .await;
    let cutoff = integer(&plan["data"]["cutoff_secs"]);
    assert!(
        cutoff
            < integer(
                &resource(&f.client, f.pool, "0x1::stake::StakePool", version).await
                    ["locked_until_secs"]
            )
    );
    println!("FRZ-02 positive fee DKG paused: epoch={epoch}, cutoff={cutoff}, version={version}, five current/target members");
    PositiveFeeFrozen {
        epoch,
        context: frozen_context_at(&f.client, version).await,
        dkg,
        target,
    }
}

async fn positive_fee_assert_frozen(f: &Fixture, frozen: &PositiveFeeFrozen, version: u64) {
    assert_eq!(
        positive_fee_context(f, version, FROZEN_FEE_LIMIT).await,
        frozen.epoch
    );
    assert_eq!(frozen_context_at(&f.client, version).await, frozen.context);
    assert_eq!(
        resource_at_version::<DKGState>(&f.client, version).await,
        frozen.dkg
    );
    assert_eq!(
        recorded_fee(&f.client, f.pool, version).await,
        FROZEN_FEE_LIMIT
    );
}

async fn positive_fee_finish(
    f: &Fixture,
    frozen: &PositiveFeeFrozen,
    model: &mut PositiveFeeModel,
) {
    let tx = success(execute(&f.client, &f.root, &f.factory, freeze_governance(4)).await);
    let version = tx.info.version.0;
    positive_fee_assert_frozen(f, frozen, version - 1).await;
    positive_fee_model_at(f, &f.client, model, version - 1).await;
    let closing = model.native;
    let native = FROZEN_FEE_LIMIT * 3000 / 10000;
    let pending_reward =
        (native as u128 * closing[3] as u128 / (closing[0] as u128 + closing[3] as u128)) as u64;
    let active_reward = native - pending_reward;
    let active_commission = active_reward * DEFAULT_COMMISSION_BPS / 10000;
    let pending_commission = pending_reward * DEFAULT_COMMISSION_BPS / 10000;
    let poc = FROZEN_FEE_LIMIT - native;
    assert_eq!(
        (
            native,
            active_reward,
            pending_reward,
            active_commission,
            pending_commission,
            poc
        ),
        (11, 11, 0, 4, 0, 28)
    );
    assert_eq!(
        positive_fee_context(f, version, FROZEN_FEE_LIMIT).await,
        frozen.epoch + 1
    );
    assert_eq!(
        installed_at(&f.client, version).await.validators,
        frozen.target
    );
    assert_eq!(events(&tx, "::stake::PoCEpochInstalled").len(), 1);
    assert_eq!(events(&tx, "::stake::PoCRewardCredited").len(), 5);
    assert!(events(&tx, "::stake::DistributeRewards").is_empty());
    let native_events = events(&tx, "::stake::DistributeTransactionFee")
        .into_iter()
        .filter(|event| address(&event.data["pool_address"]) == f.pool)
        .collect::<Vec<_>>();
    assert_eq!(native_events.len(), 1);
    assert_eq!(
        integer(&native_events[0].data["fee_amount"]),
        native as u128
    );
    let credit = pool_event(&tx, "::stake::PoCRewardCredited", f.pool);
    assert_eq!(integer(&credit.data["closing_epoch"]), frozen.epoch as u128);
    assert_eq!(
        integer(&credit.data["reward_base_octa"]),
        REWARD_BASE as u128
    );
    assert_eq!(integer(&credit.data["inflation"]), 0);
    assert_eq!(integer(&credit.data["fee"]), poc as u128);
    assert_eq!(wide(&credit.data["delta_index"]), poc_index(poc));
    let split = pool_event(&tx, "::stake::PoCRewardSplit", f.pool);
    assert_eq!(integer(&split.data["native_reward_bps"]), 3000);
    assert_eq!(integer(&split.data["closing_epoch"]), frozen.epoch as u128);
    for field in [
        "total_inflation_octa",
        "active_native_reward_octa",
        "pending_inactive_native_reward_octa",
        "poc_inflation_octa",
    ] {
        assert_eq!(integer(&split.data[field]), 0);
    }
    assert_eq!(poc + native, FROZEN_FEE_LIMIT);
    model.native = [
        closing[0] + closing[2] + active_reward,
        closing[1],
        0,
        closing[3] + pending_reward,
    ];
    assert_native_balances(f, model.native, version).await;
    // 安装 Epoch 时向原生池入账；份额赎回和佣金结算
    // 延后至随后的公开同步交易执行。
    assert_eq!(
        resource(
            &f.client,
            f.pool,
            "0x1::delegation_pool::DelegationPool",
            version - 1
        )
        .await,
        resource(
            &f.client,
            f.pool,
            "0x1::delegation_pool::DelegationPool",
            version
        )
        .await
    );
    let old_pool = pool_at(&f.client, f.pool, version - 1).await;
    assert_eq!(integer(&old_pool[3]), 0);
    assert_eq!(wide(&old_pool[4]), U256::ZERO);
    assert_eq!(pool_at(&f.client, f.pool, version).await, vec![
        json!(POWER_UNITS.to_string()),
        json!(POWER_UNITS.to_string()),
        json!(REWARD_BASE.to_string()),
        json!(poc.to_string()),
        json!(poc_index(poc).to_string())
    ]);
    let sync = success(
        execute(
            &f.client,
            &f.owner,
            &f.factory,
            aptos_stdlib::delegation_pool_synchronize_delegation_pool(f.pool),
        )
        .await,
    );
    assert_eq!(
        model
            .active
            .settle(active_reward, DEFAULT_COMMISSION_BPS, f.operator.address()),
        active_commission
    );
    assert_eq!(
        model
            .pending
            .settle(pending_reward, DEFAULT_COMMISSION_BPS, f.operator.address()),
        pending_commission
    );
    assert_eq!(model.active.shares(NULL), 0);
    assert_commission(f, &sync, active_commission, pending_commission);
    positive_fee_model_at(f, &f.client, model, sync.info.version.0).await;
    assert_eq!(model.inactive.balance(f.owner.address()), 40 * OCTA);
    assert_eq!(model.pending.balance(f.delegator.address()), 30 * OCTA);
    assert_eq!(model.active.balance(f.operator.address()), 3);
    assert_no_poc_change(f, &sync).await;
    wallet_delta(f, &sync, 0).await;
    for name in [
        "0x1::stake::EpochPlan",
        "0x1::stake::PrecomputedValidatorSet",
    ] {
        assert!(optional_resource_at_version(
            &f.client,
            CORE_CODE_ADDRESS,
            name,
            sync.info.version.0
        )
        .await
        .is_none());
    }
    assert!(
        resource_at_version::<DKGState>(&f.client, sync.info.version.0)
            .await
            .in_progress
            .is_none()
    );
    positive_fee_pause(f, false).await;
    println!("FRZ-02 positive fee completed: epoch={} -> {}, version={version}, native_active={active_reward}, native_PI={pending_reward}, commission_active={active_commission}, commission_PI={pending_commission}, PoC={poc}, matured_inactive_unchanged={}, NULL_shares_released", frozen.epoch, frozen.epoch + 1, model.inactive.coins);
}

async fn positive_fee_claim(f: &Fixture, model: &PositiveFeeModel) -> u64 {
    let poc = FROZEN_FEE_LIMIT - FROZEN_FEE_LIMIT * 3000 / 10000;
    let q = U256::ONE << U256::from(128_u8);
    let accrued = U256::checked_mul(poc_index(poc), U256::from(POWER_UNITS)).unwrap();
    let claim = u64::try_from(U256::checked_div(accrued, q).unwrap()).unwrap();
    let fraction = U256::checked_rem(accrued, q).unwrap();
    assert_eq!((poc, claim), (28, 27));
    for (actor, payment) in [
        (&f.power_user, claim),
        (&f.power_user, 0),
        (&f.owner, 0),
        (&f.delegator, 0),
        (&f.operator, 0),
    ] {
        let tx = success(
            execute(
                &f.client,
                actor,
                &f.factory,
                aptos_stdlib::poc_allocation_claim_rewards(vec![f.pool]),
            )
            .await,
        );
        let version = tx.info.version.0;
        assert_payment(&f.client, &tx, payment).await;
        positive_fee_model_at(f, &f.client, model, version - 1).await;
        positive_fee_model_at(f, &f.client, model, version).await;
        assert_eq!(
            installed_at(&f.client, version - 1).await,
            installed_at(&f.client, version).await
        );
        let payments = events(&tx, "::poc_accounting::PoCRewardClaimed");
        assert_eq!(payments.len(), usize::from(payment > 0));
        if payment > 0 {
            assert_eq!(address(&payments[0].data["pool"]), f.pool);
            assert_eq!(address(&payments[0].data["user"]), actor.address());
            assert_eq!(integer(&payments[0].data["amount"]), payment as u128);
        }
        let pool = pool_at(&f.client, f.pool, version).await;
        assert_eq!(integer(&pool[3]), (poc - claim) as u128);
        assert_eq!(wide(&pool[4]), poc_index(poc));
        let position = view(
            &f.client,
            "0x1::poc_accounting::get_position",
            vec![json!(f.power_user.address()), json!(f.pool)],
            version,
        )
        .await;
        assert_eq!(integer(&position[0]), POWER_UNITS);
        assert_eq!(integer(&position[2]), 0);
        assert_eq!(wide(&position[3]), fraction);
    }
    latest_version(&f.client).await
}

#[tokio::test]
async fn poc_frozen_positive_fee_delegation_entries_rollback_and_resume() {
    println!("FRZ-02 positive fee variant: 5 actual committee nodes; native3000/commission3735; rate0/fee39; public lockup30s only during inactive preparation, then3600s; ordinary DKG enabled publicly/Chunky off/watchdog disabled; owner withdraws OLC0 and delegator unlocks/reactivates OLC1; no injected time or balances");
    let (f, _) = fixture_with_options(
        3000,
        DEFAULT_COMMISSION_BPS,
        Some(FROZEN_FEE_LIMIT),
        1000 * OCTA,
        Some(30),
        false,
    )
    .await;
    let mut model = prepare_positive_fee_withdrawal(&f).await;
    for call in POSITIVE_FEE_CALLS {
        positive_fee_success(&f, call, &mut model).await;
    }
    assert_eq!(model.native, [920 * OCTA, 40 * OCTA, 100 * OCTA, 30 * OCTA]);
    assert_eq!(model.active.balance(NULL), 1);
    positive_fee_unauthorized(&f, &model, false).await;
    positive_fee_collect(&f, &model).await;
    let frozen = positive_fee_freeze(&f, &model).await;
    for call in POSITIVE_FEE_CALLS {
        let version =
            positive_fee_reject(&f, &model, call, call.actor(&f), ("stake", 0x30014)).await;
        positive_fee_assert_frozen(&f, &frozen, version).await;
    }
    positive_fee_unauthorized(&f, &model, true).await;
    positive_fee_assert_frozen(&f, &frozen, latest_version(&f.client).await).await;
    assert_eq!(model.active.balance(NULL), 1);
    positive_fee_finish(&f, &frozen, &mut model).await;
    // 原金额和角色仍满足操作条件。已提交的 Epoch 合并原生本金并释放旧入池费份额；
    // 独立模型逐步使用新的份额价格，
    // 不再沿用冻结前的物理份额作为预期。
    for call in POSITIVE_FEE_CALLS {
        positive_fee_success(&f, call, &mut model).await;
    }
    positive_fee_unauthorized(&f, &model, false).await;
    let version = positive_fee_claim(&f, &model).await;
    assert_committee(&f, version).await;
    let expected = positive_fee_snapshot(&f, &f.client, version).await;
    let installed = installed_at(&f.client, version).await;
    assert_eq!(installed.epoch, frozen.epoch + 1);
    for member in &installed.validators.active_validators {
        let client = f.client_for_member(member.account_address);
        assert_eq!(positive_fee_snapshot(&f, &client, version).await, expected);
        positive_fee_model_at(&f, &client, &model, version).await;
    }
    println!("FRZ-02 positive fee matrix complete: version={version}, five current nodes agree, four same-payload writes resumed, NULL_shares_from_new_epoch={}, PoC_claim27/vault1", model.active.shares(NULL));
}
