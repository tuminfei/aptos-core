// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

//! 多周期奖励 churn：四个创世背景池和一个真实出块委托池共用同一套
//! 五池整数账本。短档逐期全量核对，长档按固定 seed 采样并在周期边界全量核对。

use super::{
    defaults::installed_at,
    delegation_rewards::{churn_fixture, wait_for_real_proposals, Fixture},
    fee_rewards::{
        address, events, integer, ledger_at, pool_at, pool_event, position_at, priced_fee_factory,
        recorded_fee, success, view, wide,
    },
    optional_resource_at_version,
    transactions::{compile_script, execute},
};
use aptos_api_types::{
    AptosErrorCode, BlockMetadataTransaction, Event, Transaction, UserTransaction,
};
use aptos_cached_packages::aptos_stdlib;
use aptos_forge::Swarm;
use aptos_rest_client::{error::RestError, Client};
use aptos_sdk::types::LocalAccount;
use aptos_types::{
    account_address::AccountAddress,
    account_config::CORE_CODE_ADDRESS,
    transaction::{Script, TransactionArgument, TransactionPayload},
};
use move_core_types::int256::U256;
use once_cell::sync::Lazy;
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, VecDeque},
    time::{Duration, Instant},
};

const PREPARATION_CLOSINGS: u64 = 60;
const DRAIN_CLOSINGS: u64 = 2;
const OCTA: u64 = 100_000_000;
const INITIAL_BOND: u64 = 1000 * OCTA;
const INITIAL_RAW_POWER: u64 = 400;
const UNIT_SCALE: u128 = 1 << 16;
const INDEX_SCALE: u128 = 1 << 64;
const NATIVE_REWARD_BPS: u64 = 3000;
const COMMISSION_BPS: u64 = 3735;
const RETENTION_BPS: u64 = 9995;
const FEE_LIMIT: u64 = 17;
const LOCKUP_SECS: u64 = 3;
const SHARE_SCALE: u128 = 10_000_000_000_000_000;
const NULL_SHAREHOLDER: AccountAddress = AccountAddress::ZERO;

static CHURN_GOVERNANCE: Lazy<Vec<u8>> = Lazy::new(|| {
    compile_script(
        "PoCRewardChurn",
        r#"script {
        use topo_std::fixed_point64;
        use topo_framework::poc_power_store;
        use topo_framework::reconfiguration;
        use topo_framework::stake;
        use topo_framework::staking_config;
        use topo_framework::topo_governance;

        fun main(root: &signer, operation: u8, value: u64, actor: address,
            enable_rate: bool, fee_limit: u64) {
            let framework = topo_governance::get_signer_testnet_only(root, @0x1);
            if (operation == 0) {
                poc_power_store::set_operator(&framework, actor);
                poc_power_store::set_power_period_in_epochs(&framework, value);
                staking_config::update_recurring_lockup_duration_secs(&framework, 3);
            } else if (operation == 1) {
                let rate = if (enable_rate) {
                    fixed_point64::create_from_rational(1, 100)
                } else {
                    fixed_point64::create_from_rational(0, 1)
                };
                staking_config::update_rewards_config(
                    &framework, rate, rate, 31536000,
                    fixed_point64::create_from_rational(0, 1));
                stake::set_transaction_fee_limit_per_epoch_per_pool(&framework, fee_limit);
                topo_governance::reconfigure(&framework);
            } else if (operation == 2) {
                topo_governance::reconfigure(&framework);
            } else {
                assert!(operation == 3, 0);
                stake::schedule_reward_split(
                    &framework, value, reconfiguration::current_epoch() + 1);
                topo_governance::reconfigure(&framework);
            };
        }
    }"#,
    )
});

fn governance_payload(
    operation: u8,
    value: u64,
    actor: AccountAddress,
    enable_rate: bool,
    fee_limit: u64,
) -> TransactionPayload {
    TransactionPayload::Script(Script::new(CHURN_GOVERNANCE.clone(), vec![], vec![
        TransactionArgument::U8(operation),
        TransactionArgument::U64(value),
        TransactionArgument::Address(actor),
        TransactionArgument::Bool(enable_rate),
        TransactionArgument::U64(fee_limit),
    ]))
}

fn committed_events(transaction: &Transaction) -> &[Event] {
    match transaction {
        Transaction::UserTransaction(transaction) => &transaction.events,
        Transaction::GenesisTransaction(transaction) => &transaction.events,
        Transaction::BlockMetadataTransaction(transaction) => &transaction.events,
        Transaction::ValidatorTransaction(transaction) => transaction.events(),
        Transaction::StateCheckpointTransaction(_) | Transaction::BlockEpilogueTransaction(_) => {
            &[]
        },
        Transaction::PendingTransaction(_) => panic!("ledger history cannot contain pending txns"),
    }
}

fn matching_events<'a>(transaction_events: &'a [Event], suffix: &str) -> Vec<&'a Event> {
    transaction_events
        .iter()
        .filter(|event| event.typ.to_string().ends_with(suffix))
        .collect()
}

fn pool_event_from<'a>(
    transaction_events: &'a [Event],
    suffix: &str,
    pool: AccountAddress,
) -> &'a Event {
    let matching = matching_events(transaction_events, suffix)
        .into_iter()
        .filter(|event| address(&event.data["pool"]) == pool)
        .collect::<Vec<_>>();
    assert_eq!(matching.len(), 1, "expected one {suffix} for pool {pool}");
    matching[0]
}

#[derive(Clone, Copy, Debug)]
struct RunConfig {
    rounds: u64,
    users: usize,
    period_epochs: u64,
    seed: u64,
    sample_every: u64,
    fill_fee_limit: bool,
    inject_failures: bool,
    enable_rate: bool,
}

#[derive(Clone, Debug, Default)]
struct PositionModel {
    units: u128,
    claimable: u64,
    fractional: U256,
    claimed: u64,
}

#[derive(Clone, Debug, Default)]
struct SharesModel {
    coins: u64,
    total_shares: u128,
    holders: BTreeMap<AccountAddress, u128>,
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

impl SharesModel {
    fn empty() -> Self {
        Self::default()
    }

    fn with_owner(owner: AccountAddress) -> Self {
        let mut result = Self::empty();
        result.buy(owner, INITIAL_BOND);
        result
    }

    fn shares(&self, holder: AccountAddress) -> u128 {
        self.holders.get(&holder).copied().unwrap_or(0)
    }

    fn balance(&self, holder: AccountAddress) -> u64 {
        if self.total_shares == 0 {
            0
        } else {
            mul_div(self.shares(holder), self.coins as u128, self.total_shares) as u64
        }
    }

    fn amount_to_shares(&self, amount: u64) -> u128 {
        if self.coins == 0 || self.total_shares == 0 {
            amount as u128 * SHARE_SCALE
        } else {
            mul_div(amount as u128, self.total_shares, self.coins as u128)
        }
    }

    fn buy(&mut self, holder: AccountAddress, amount: u64) -> u128 {
        if amount == 0 {
            return 0;
        }
        let shares = self.amount_to_shares(amount);
        assert!(shares > 0);
        self.coins = self.coins.checked_add(amount).unwrap();
        self.total_shares = self.total_shares.checked_add(shares).unwrap();
        *self.holders.entry(holder).or_default() += shares;
        shares
    }

    fn deposit(&mut self, holder: AccountAddress, amount: u64, fee: u64) {
        assert!(fee <= amount);
        self.buy(holder, amount - fee);
        self.buy(NULL_SHAREHOLDER, fee);
    }

    fn redeem_requested(&mut self, holder: AccountAddress, amount: u64) -> u64 {
        let balance = self.balance(holder);
        if balance == 0 {
            return 0;
        }
        let shares = if amount >= balance {
            self.shares(holder)
        } else {
            self.amount_to_shares(amount)
        };
        if shares == 0 {
            return 0;
        }
        let redeemed = mul_div(shares, self.coins as u128, self.total_shares) as u64;
        let remaining = self.holders.get_mut(&holder).unwrap();
        *remaining -= shares;
        if *remaining == 0 {
            self.holders.remove(&holder);
        }
        self.coins -= redeemed;
        self.total_shares -= shares;
        redeemed
    }

    fn adjusted_transfer_amount(
        &self,
        destination: &SharesModel,
        holder: AccountAddress,
        requested: u64,
    ) -> u64 {
        let balance = self.balance(holder);
        if balance == 0 {
            return 0;
        }
        let redeem_value = |amount: u64| {
            let shares = if amount >= balance {
                self.shares(holder)
            } else {
                self.amount_to_shares(amount)
            };
            if self.total_shares == 0 {
                0
            } else {
                mul_div(shares, self.coins as u128, self.total_shares) as u64
            }
        };
        let mut amount = requested;
        let redeemed = redeem_value(amount);
        if destination.balance(holder) + redeemed < 10 * OCTA {
            amount = 10 * OCTA - destination.balance(holder) + 1;
        }
        if balance - redeem_value(amount) < 10 * OCTA {
            amount = balance;
        }
        amount
    }

    fn preview_transfer_amount(
        &self,
        destination: &SharesModel,
        holder: AccountAddress,
        requested: u64,
    ) -> u64 {
        let adjusted = self.adjusted_transfer_amount(destination, holder, requested);
        let balance = self.balance(holder);
        let shares = if adjusted >= balance {
            self.shares(holder)
        } else {
            self.amount_to_shares(adjusted)
        };
        if shares == 0 || self.total_shares == 0 {
            0
        } else {
            mul_div(shares, self.coins as u128, self.total_shares) as u64
        }
    }

    fn transfer_with_minimum(
        &mut self,
        destination: &mut SharesModel,
        holder: AccountAddress,
        requested: u64,
    ) -> u64 {
        let adjusted = self.adjusted_transfer_amount(destination, holder, requested);
        let redeemed = self.redeem_requested(holder, adjusted);
        destination.buy(holder, redeemed);
        redeemed
    }

    fn settle(&mut self, actual_coins: u64, commission: u64, operator: AccountAddress) {
        let null_coins = self.balance(NULL_SHAREHOLDER);
        let null_shares = self.holders.remove(&NULL_SHAREHOLDER).unwrap_or(0);
        self.coins -= null_coins;
        self.total_shares -= null_shares;
        assert!(commission <= actual_coins);
        self.coins = actual_coins - commission;
        self.buy(operator, commission);
    }

    fn dust(&self) -> u64 {
        self.coins
            - self
                .holders
                .keys()
                .map(|holder| self.balance(*holder))
                .sum::<u64>()
    }
}

#[derive(Clone, Debug)]
struct BackgroundPoolModel {
    address: AccountAddress,
    units: u128,
    next_units: u128,
    reward_base_octa: u64,
    vault: u64,
    reward_index: U256,
    credited: u64,
    claimed: u64,
    native: [u64; 4],
}

#[derive(Clone, Debug)]
struct TestPoolModel {
    pool: BackgroundPoolModel,
    active: SharesModel,
    pending_inactive: SharesModel,
    inactive: BTreeMap<u64, SharesModel>,
    positions: BTreeMap<AccountAddress, PositionModel>,
    observed_lockup_cycle: u64,
    locked_until_secs: u64,
}

#[derive(Clone, Debug)]
struct NetworkModel {
    pools: BTreeMap<AccountAddress, BackgroundPoolModel>,
    tested: TestPoolModel,
    recent_operations: VecDeque<String>,
    credited: u64,
    claimed: u64,
    positive_epochs: u64,
    zero_epochs: u64,
    mixed_proposal_pool_epochs: u64,
    cross_node_comparisons: u64,
    native_bps: u64,
    current_epoch: u64,
    current_period: u64,
    period_index: u128,
    first_poc_epoch: u64,
    first_closing_epoch: u64,
    last_closing_epoch: u64,
    max_checkpoints: u64,
    split_totals: BTreeMap<u64, (u64, u64)>,
}

#[derive(Clone, Debug)]
struct PowerUserModel {
    address: AccountAddress,
    versions: BTreeMap<u64, u128>,
    ratio: u64,
    pending_ratio: Option<(u64, u64)>,
}

impl PowerUserModel {
    fn version_units(&self, period: u64) -> u128 {
        self.versions
            .range(..=period)
            .next_back()
            .map(|(_, units)| *units)
            .unwrap_or(0)
    }

    fn ratio_at(&self, epoch: u64) -> u64 {
        self.pending_ratio
            .filter(|(target, _)| *target <= epoch)
            .map(|(_, ratio)| ratio)
            .unwrap_or(self.ratio)
    }

    fn allocated_units(&self, epoch: u64, period: u64) -> u128 {
        mul_div(
            self.version_units(period),
            self.ratio_at(epoch) as u128,
            10_000,
        )
    }

    fn advance(&mut self, epoch: u64) {
        if let Some((target, ratio)) = self.pending_ratio {
            if target <= epoch {
                self.ratio = ratio;
                self.pending_ratio = None;
            }
        }
    }
}

#[derive(Clone, Debug, Default)]
struct PowerBook {
    users: BTreeMap<AccountAddress, PowerUserModel>,
}

impl PowerBook {
    fn pool_units(&self, epoch: u64, period: u64) -> u128 {
        self.users
            .values()
            .map(|user| user.allocated_units(epoch, period))
            .sum()
    }

    fn advance(&mut self, epoch: u64) {
        for user in self.users.values_mut() {
            user.advance(epoch);
        }
    }
}

#[derive(Clone, Debug)]
struct PendingReactivation {
    user: AccountAddress,
    amount: u64,
}

#[derive(Clone, Copy, Debug)]
struct RewardParts {
    total_inflation: u64,
    native_inflation: u64,
    poc_inflation: u64,
    native_fee: u64,
    poc_fee: u64,
    active_native_inflation: u64,
    pending_native_inflation: u64,
    active_native_fee: u64,
    pending_native_fee: u64,
    delta_index: U256,
}

fn period_index(period: u64) -> u128 {
    (0..period).fold(INDEX_SCALE, |index, _| {
        index * RETENTION_BPS as u128 / 10_000
    })
}

fn entitlement_scale() -> U256 {
    U256::ONE << U256::from(128_u8)
}

fn normalized_units(raw: u64, period: u64) -> u128 {
    let numerator =
        U256::checked_mul(U256::from(raw), U256::from(UNIT_SCALE * INDEX_SCALE)).unwrap();
    u128::try_from(U256::checked_div(numerator, U256::from(period_index(period))).unwrap()).unwrap()
}

fn pool_power(units: u128, index: u128) -> u64 {
    let numerator = U256::checked_mul(U256::from(units), U256::from(index)).unwrap();
    u64::try_from(U256::checked_div(numerator, U256::from(UNIT_SCALE * INDEX_SCALE)).unwrap())
        .unwrap()
}

fn reward_amount(base: u64, success: u64, failed: u64, rate: u64, denominator: u64) -> u64 {
    if success + failed == 0 {
        return 0;
    }
    let value = U256::checked_mul(
        U256::checked_mul(U256::from(base), U256::from(rate)).unwrap(),
        U256::from(success),
    )
    .unwrap();
    u64::try_from(
        U256::checked_div(
            value,
            U256::checked_mul(U256::from(denominator), U256::from(success + failed)).unwrap(),
        )
        .unwrap(),
    )
    .unwrap()
}

fn split_native(amount: u64, active: u64, pending: u64) -> (u64, u64) {
    if active + pending == 0 {
        assert_eq!(amount, 0);
        return (0, 0);
    }
    let pending_reward =
        mul_div(amount as u128, pending as u128, (active + pending) as u128) as u64;
    (amount - pending_reward, pending_reward)
}

fn reward_parts(
    pool: &BackgroundPoolModel,
    rate: u64,
    denominator: u64,
    native_bps: u64,
    success_count: u64,
    failed_count: u64,
    fee: u64,
) -> RewardParts {
    let total_inflation = reward_amount(
        pool.reward_base_octa,
        success_count,
        failed_count,
        rate,
        denominator,
    );
    let native_inflation = (total_inflation as u128 * native_bps as u128 / 10_000) as u64;
    let poc_inflation = total_inflation - native_inflation;
    let native_fee = (fee as u128 * native_bps as u128 / 10_000) as u64;
    let poc_fee = fee - native_fee;
    let (active_native_inflation, pending_native_inflation) =
        split_native(native_inflation, pool.native[0], pool.native[3]);
    let (active_native_fee, pending_native_fee) =
        split_native(native_fee, pool.native[0], pool.native[3]);
    let poc = poc_inflation + poc_fee;
    let delta_index = if pool.units == 0 {
        assert_eq!(poc, 0);
        U256::ZERO
    } else {
        U256::checked_div(
            U256::checked_mul(U256::from(poc), entitlement_scale()).unwrap(),
            U256::from(pool.units),
        )
        .unwrap()
    };
    RewardParts {
        total_inflation,
        native_inflation,
        poc_inflation,
        native_fee,
        poc_fee,
        active_native_inflation,
        pending_native_inflation,
        active_native_fee,
        pending_native_fee,
        delta_index,
    }
}

async fn latest_version(client: &Client) -> u64 {
    client
        .get_ledger_information()
        .await
        .unwrap()
        .into_inner()
        .version
}

async fn resource(client: &Client, owner: AccountAddress, name: &str, version: u64) -> Value {
    optional_resource_at_version(client, owner, name, version)
        .await
        .unwrap_or_else(|| panic!("Missing {name} at {owner}, version {version}"))
        .data
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
        Err(error) => panic!("Cannot read table item at version {version}: {error}"),
    }
}

async fn chain_time_secs(client: &Client, version: u64) -> u64 {
    (integer(
        &resource(
            client,
            CORE_CODE_ADDRESS,
            "0x1::timestamp::CurrentTimeMicroseconds",
            version,
        )
        .await["microseconds"],
    ) / 1_000_000) as u64
}

async fn native_stake(client: &Client, pool: AccountAddress, version: u64) -> [u64; 4] {
    let values = view(client, "0x1::stake::get_stake", vec![json!(pool)], version).await;
    assert_eq!(values.len(), 4);
    std::array::from_fn(|index| integer(&values[index]) as u64)
}

async fn clock_at(client: &Client, version: u64) -> (u64, u64, u128, Option<u128>) {
    let values = view(
        client,
        "0x1::poc_power_store::get_normalization_clock",
        vec![],
        version,
    )
    .await;
    let next = values[3]["vec"].as_array().unwrap().first().map(integer);
    (
        integer(&values[0]) as u64,
        integer(&values[1]) as u64,
        integer(&values[2]),
        next,
    )
}

impl NetworkModel {
    async fn new(f: &Fixture, version: u64, first_poc_epoch: u64) -> Self {
        let installed = installed_at(&f.client, version).await;
        let mut backgrounds = BTreeMap::new();
        let units = INITIAL_RAW_POWER as u128 * UNIT_SCALE;
        let mut tested = None;
        for validator in &installed.validators.active_validators {
            let address = validator.account_address;
            let pool = BackgroundPoolModel {
                address,
                units,
                next_units: units,
                reward_base_octa: INITIAL_RAW_POWER * OCTA,
                vault: 0,
                reward_index: U256::ZERO,
                credited: 0,
                claimed: 0,
                native: [INITIAL_BOND, 0, 0, 0],
            };
            if address == f.pool {
                tested = Some(TestPoolModel {
                    pool,
                    active: SharesModel::with_owner(f.owner.address()),
                    pending_inactive: SharesModel::empty(),
                    inactive: BTreeMap::new(),
                    positions: BTreeMap::from([(f.power_user.address(), PositionModel {
                        units,
                        ..PositionModel::default()
                    })]),
                    observed_lockup_cycle: 0,
                    locked_until_secs: integer(
                        &resource(&f.client, f.pool, "0x1::stake::StakePool", version).await
                            ["locked_until_secs"],
                    ) as u64,
                });
            } else {
                backgrounds.insert(address, pool);
            }
        }
        assert_eq!(backgrounds.len(), 4);
        let mut result = Self {
            pools: backgrounds,
            tested: tested.expect("Delegation pool missing from installed committee"),
            recent_operations: VecDeque::new(),
            credited: 0,
            claimed: 0,
            positive_epochs: 0,
            zero_epochs: 0,
            mixed_proposal_pool_epochs: 0,
            cross_node_comparisons: 0,
            native_bps: NATIVE_REWARD_BPS,
            current_epoch: installed.epoch,
            current_period: 0,
            period_index: INDEX_SCALE,
            first_poc_epoch,
            first_closing_epoch: u64::MAX,
            last_closing_epoch: 0,
            max_checkpoints: 0,
            split_totals: BTreeMap::new(),
        };
        assert_eq!(f.setup_closings.len(), 2);
        let before_join_version = f.setup_closings[0].info.version.0 - 1;
        let expected_pre_join_closings = installed_at(&f.client, before_join_version)
            .await
            .epoch
            .checked_sub(first_poc_epoch)
            .expect("Fixture preparation must follow the first PoC epoch");
        // Startup and fixture governance close epochs before the replacement pool
        // joins. Replay every settlement from its own version-1 context. Four of
        // the five genesis pools continue as this run's backgrounds; the replaced
        // fifth pool is deliberately outside the steady-state model.
        let background_addresses = result.pools.keys().copied().collect::<Vec<_>>();
        let mut cursor = 0;
        let mut pre_join_closings = 0;
        while cursor <= before_join_version {
            let limit = (before_join_version - cursor + 1).min(100) as u16;
            let transactions = f
                .client
                .get_transactions(Some(cursor), Some(limit))
                .await
                .unwrap()
                .into_inner();
            assert_eq!(transactions.len(), limit as usize);
            for transaction in transactions {
                let version = transaction.version().unwrap();
                assert_eq!(version, cursor);
                cursor += 1;
                let transaction_events = committed_events(&transaction);
                if matching_events(transaction_events, "::stake::PoCRewardCredited").is_empty() {
                    continue;
                }
                let closing_metadata = match &transaction {
                    Transaction::BlockMetadataTransaction(metadata) => Some(metadata),
                    _ => None,
                };
                result
                    .replay_setup_close(
                        f,
                        version,
                        transaction_events,
                        closing_metadata,
                        false,
                        &background_addresses,
                    )
                    .await;
                pre_join_closings += 1;
            }
        }
        assert_eq!(
            result.first_closing_epoch, first_poc_epoch,
            "genesis preparation must replay rewards from the first PoC epoch"
        );
        assert_eq!(
            pre_join_closings, expected_pre_join_closings,
            "genesis preparation must settle every epoch before the pool joins"
        );

        // The join closes the final five-genesis-pool committee. The following
        // close covers all four continuing backgrounds plus the new delegation
        // pool.
        for (index, closing) in f.setup_closings.iter().enumerate() {
            let current_test_pool = index + 1 == f.setup_closings.len();
            let addresses = if current_test_pool {
                result.addresses()
            } else {
                result.pools.keys().copied().collect::<Vec<_>>()
            };
            result
                .replay_setup_close(
                    f,
                    closing.info.version.0,
                    &closing.events,
                    None,
                    current_test_pool,
                    &addresses,
                )
                .await;
        }
        result.current_epoch = installed.epoch;
        result.native_bps = integer(&installed.reward_split["installed_native_reward_bps"]) as u64;
        result.assert_all_pools(f, version, "new-final").await;
        result
    }

    async fn replay_setup_close(
        &mut self,
        f: &Fixture,
        version: u64,
        transaction_events: &[Event],
        closing_metadata: Option<&BlockMetadataTransaction>,
        current_test_pool: bool,
        addresses: &[AccountAddress],
    ) {
        assert!(version > 0);
        let before = installed_at(&f.client, version - 1).await;
        if self.first_closing_epoch == u64::MAX {
            self.first_closing_epoch = before.epoch;
        } else {
            assert_eq!(
                before.epoch,
                self.last_closing_epoch + 1,
                "setup closing epochs must be strictly consecutive"
            );
        }
        let native_bps = integer(&before.reward_split["installed_native_reward_bps"]) as u64;
        let (_, poc_enabled, rate, denominator, distribute_fee, fee_limit) = before.reward_context;
        assert!(poc_enabled && denominator > 0);
        for address in addresses {
            let validator = before
                .validators
                .active_validators
                .iter()
                .find(|validator| validator.account_address == *address)
                .unwrap_or_else(|| panic!("setup closing {} omitted pool {address}", before.epoch));
            let counts = view(
                &f.client,
                "0x1::stake::get_current_epoch_proposal_counts",
                vec![json!(validator.config().validator_index.to_string())],
                version - 1,
            )
            .await;
            let mut success_count = integer(&counts[0]) as u64;
            let mut failed_count = integer(&counts[1]) as u64;
            // A settlement emitted by the block metadata transaction itself has
            // already recorded that block's proposer outcome before rewards run,
            // while a version-1 view necessarily precedes it. Account for only
            // those deterministic metadata deltas; user-triggered closes have a
            // preceding block metadata version and need no adjustment.
            if let Some(metadata) = closing_metadata {
                success_count += u64::from(*metadata.proposer.inner() == *address);
                failed_count += metadata
                    .failed_proposer_indices
                    .iter()
                    .filter(|index| **index as u64 == validator.config().validator_index)
                    .count() as u64;
            }
            let fee = if distribute_fee {
                recorded_fee(&f.client, *address, version - 1)
                    .await
                    .min(fee_limit)
            } else {
                0
            };
            let expected = reward_parts(
                self.pool(*address),
                rate,
                denominator,
                native_bps,
                success_count,
                failed_count,
                fee,
            );
            let credit =
                pool_event_from(transaction_events, "::stake::PoCRewardCredited", *address);
            assert_eq!(integer(&credit.data["closing_epoch"]), before.epoch as u128);
            assert_eq!(
                integer(&credit.data["inflation"]),
                expected.poc_inflation as u128
            );
            assert_eq!(integer(&credit.data["fee"]), expected.poc_fee as u128);
            assert_eq!(wide(&credit.data["delta_index"]), expected.delta_index);
            let split = pool_event_from(transaction_events, "::stake::PoCRewardSplit", *address);
            assert_eq!(
                integer(&split.data["total_inflation_octa"]),
                expected.total_inflation as u128
            );
            assert_eq!(
                integer(&split.data["active_native_reward_octa"]),
                expected.active_native_inflation as u128
            );
            assert_eq!(
                integer(&split.data["pending_inactive_native_reward_octa"]),
                expected.pending_native_inflation as u128
            );
            let pool = self.pool_mut(*address);
            let poc = expected.poc_inflation + expected.poc_fee;
            pool.vault += poc;
            pool.credited += poc;
            pool.reward_index = U256::checked_add(pool.reward_index, expected.delta_index).unwrap();
            pool.native[0] += expected.active_native_inflation + expected.active_native_fee;
            pool.native[3] += expected.pending_native_inflation + expected.pending_native_fee;
            pool.native[0] += pool.native[2];
            pool.native[2] = 0;
            self.credited += poc;
            if poc > 0 {
                self.positive_epochs += 1;
            } else {
                self.zero_epochs += 1;
            }
            let totals = self.split_totals.entry(native_bps).or_default();
            totals.0 += expected.native_inflation + expected.native_fee;
            totals.1 += poc;
            if current_test_pool && *address == f.pool {
                let position = self
                    .tested
                    .positions
                    .get_mut(&f.power_user.address())
                    .unwrap();
                let accrued = U256::checked_add(
                    position.fractional,
                    U256::checked_mul(U256::from(position.units), expected.delta_index).unwrap(),
                )
                .unwrap();
                position.claimable +=
                    u64::try_from(U256::checked_div(accrued, entitlement_scale()).unwrap())
                        .unwrap();
                position.fractional = U256::checked_rem(accrued, entitlement_scale()).unwrap();
            }
        }
        assert_eq!(
            matching_events(transaction_events, "::stake::PoCRewardCredited").len(),
            5
        );
        assert_eq!(
            matching_events(transaction_events, "::stake::PoCRewardSplit").len(),
            5
        );
        self.last_closing_epoch = before.epoch;
    }

    fn pool(&self, address: AccountAddress) -> &BackgroundPoolModel {
        if address == self.tested.pool.address {
            &self.tested.pool
        } else {
            self.pools.get(&address).unwrap()
        }
    }

    fn pool_mut(&mut self, address: AccountAddress) -> &mut BackgroundPoolModel {
        if address == self.tested.pool.address {
            &mut self.tested.pool
        } else {
            self.pools.get_mut(&address).unwrap()
        }
    }

    fn addresses(&self) -> Vec<AccountAddress> {
        self.pools
            .keys()
            .copied()
            .chain(std::iter::once(self.tested.pool.address))
            .collect()
    }

    fn record(&mut self, operation: String) {
        if self.recent_operations.len() == 20 {
            self.recent_operations.pop_front();
        }
        self.recent_operations.push_back(operation);
    }

    async fn assert_all_pools(&self, f: &Fixture, version: u64, phase: &str) {
        let installed_epoch = installed_at(&f.client, version).await.epoch;
        for address in self.addresses() {
            let expected = self.pool(address);
            let actual = pool_at(&f.client, address, version).await;
            let ledger = ledger_at(&f.client, address, version).await;
            let context = format!(
                "phase={phase}, pool={address}, version={version}, installed_epoch={installed_epoch}, model_epoch={}, reward_epoch={}, recent={:?}",
                self.current_epoch,
                integer(&ledger["reward_epoch"]),
                self.recent_operations
            );
            assert_eq!(integer(&actual[0]), expected.units, "{context}");
            assert_eq!(integer(&actual[1]), expected.next_units, "{context}");
            assert_eq!(
                integer(&actual[2]),
                expected.reward_base_octa as u128,
                "{context}"
            );
            assert_eq!(integer(&actual[3]), expected.vault as u128, "{context}");
            assert_eq!(wide(&actual[4]), expected.reward_index, "{context}");
            assert_eq!(
                native_stake(&f.client, address, version).await,
                expected.native,
                "{context}"
            );
            assert_eq!(
                integer(&ledger["reward_epoch"]),
                self.last_closing_epoch as u128,
                "{context}"
            );
        }
    }
}

fn expected_period(epoch: u64, period_epochs: u64) -> u64 {
    if epoch < 61 {
        0
    } else {
        1 + (epoch - 61) / period_epochs
    }
}

fn expected_next_boundary(epoch: u64, period_epochs: u64) -> u64 {
    if epoch < 61 {
        61
    } else {
        61 + expected_period(epoch, period_epochs) * period_epochs
    }
}

fn allocated_powers(
    model: &NetworkModel,
    target_units: &BTreeMap<AccountAddress, u128>,
    target_index: u128,
    cutoff_secs: u64,
) -> BTreeMap<AccountAddress, u64> {
    let mut candidates = BTreeMap::new();
    let mut total_growth = 0u128;
    let current_total: u128 = model
        .addresses()
        .iter()
        .map(|address| model.pool(*address).reward_base_octa as u128 / OCTA as u128)
        .sum();
    for address in model.addresses() {
        let pool = model.pool(address);
        // Genesis config uses POWER_PER_OHMP=100_000_000 and
        // bond_octa_per_ohmp=OCTA*100_000_000, so the exact bond cap reduces to
        // floor(bond_octa/OCTA).  Pending-inactive principal counts only while its
        // lock is still live at the frozen transition cutoff.
        let pending_inactive_bond = if address != model.tested.pool.address
            || model.tested.locked_until_secs > cutoff_secs
        {
            pool.native[3]
        } else {
            0
        };
        let bond_octa = pool.native[0]
            .checked_add(pool.native[2])
            .unwrap()
            .checked_add(pending_inactive_bond)
            .unwrap();
        let bond_cap = bond_octa / OCTA;
        let candidate = pool_power(target_units[&address], target_index)
            .min(bond_cap)
            .min(1000);
        assert!(candidate >= 10, "pool {address} fell below minimum power");
        let old = model.pool(address).reward_base_octa / OCTA;
        total_growth += candidate.saturating_sub(old) as u128;
        candidates.insert(address, candidate);
    }
    let budget = current_total * 25 / 100;
    if total_growth <= budget {
        return candidates;
    }
    candidates
        .into_iter()
        .map(|(address, candidate)| {
            let old = model.pool(address).reward_base_octa / OCTA;
            let delta = candidate.saturating_sub(old);
            let allocated = candidate.min(old) as u128 + delta as u128 * budget / total_growth;
            (address, allocated as u64)
        })
        .collect()
}

struct CloseResult {
    test_rewards: RewardParts,
    test_matured: bool,
    version: u64,
}

async fn close_epoch(
    f: &Fixture,
    model: &mut NetworkModel,
    power: &mut PowerBook,
    period_epochs: u64,
    payload: TransactionPayload,
    force_test_maturity: bool,
) -> CloseResult {
    let observed_version = latest_version(&f.client).await;
    let observed = installed_at(&f.client, observed_version).await;
    assert_eq!(observed.epoch, model.current_epoch);
    assert_eq!(observed.reward_context.0, model.current_epoch);
    assert_eq!(
        model.current_period,
        expected_period(observed.epoch, period_epochs)
    );
    model
        .assert_all_pools(f, observed_version, "close-observed")
        .await;

    let transaction = success(execute(&f.client, &f.root, &f.factory, payload).await);
    let version = transaction.info.version.0;
    // The reconfiguration transaction may land after a fresh BlockMetadata.
    // Freeze every old-epoch input at the actual transaction boundary so the
    // reference model includes that block's proposal result and fee updates.
    let closing_version = version - 1;
    let before = installed_at(&f.client, closing_version).await;
    assert_eq!(before.epoch, model.current_epoch);
    assert_eq!(before.reward_context.0, model.current_epoch);
    model
        .assert_all_pools(f, closing_version, "close-version-1")
        .await;

    let native_bps = integer(&before.reward_split["installed_native_reward_bps"]) as u64;
    assert_eq!(native_bps, model.native_bps);
    let (_, poc_enabled, rate, denominator, distribute_fee, fee_limit) = before.reward_context;
    assert!(poc_enabled && denominator > 0);
    let mut inputs = BTreeMap::new();
    let mut expected_total_inflation = 0u64;
    let mut expected_total_split = 0u64;
    for validator in &before.validators.active_validators {
        let address = validator.account_address;
        let counts = view(
            &f.client,
            "0x1::stake::get_current_epoch_proposal_counts",
            vec![json!(validator.config().validator_index.to_string())],
            closing_version,
        )
        .await;
        let successes = integer(&counts[0]) as u64;
        let failures = integer(&counts[1]) as u64;
        let fee = if distribute_fee {
            recorded_fee(&f.client, address, closing_version)
                .await
                .min(fee_limit)
        } else {
            0
        };
        let parts = reward_parts(
            model.pool(address),
            rate,
            denominator,
            native_bps,
            successes,
            failures,
            fee,
        );
        expected_total_inflation = expected_total_inflation
            .checked_add(parts.total_inflation)
            .unwrap();
        expected_total_split = expected_total_split
            .checked_add(parts.native_inflation + parts.poc_inflation)
            .unwrap();
        if successes > 0 && failures > 0 {
            model.mixed_proposal_pool_epochs += 1;
        }
        inputs.insert(address, (successes, failures, fee, parts));
    }
    assert_eq!(expected_total_inflation, expected_total_split);

    let after = installed_at(&f.client, version).await;
    assert_eq!(after.epoch, before.epoch + 1);
    assert_eq!(events(&transaction, "::stake::PoCEpochInstalled").len(), 1);
    assert_eq!(events(&transaction, "::stake::PoCRewardCredited").len(), 5);
    assert_eq!(events(&transaction, "::stake::PoCRewardSplit").len(), 5);

    let target_period = expected_period(after.epoch, period_epochs);
    let target_index = period_index(target_period);
    let clock = clock_at(&f.client, version).await;
    assert_eq!(clock.0, target_period);
    assert_eq!(clock.1, expected_next_boundary(after.epoch, period_epochs));
    assert_eq!(clock.2, target_index);
    assert_eq!(clock.3, Some(period_index(target_period + 1)));
    assert_eq!(
        view(
            &f.client,
            "0x1::poc_power_store::get_power_period_in_epochs",
            vec![],
            version,
        )
        .await,
        vec![json!(period_epochs.to_string())]
    );

    power.advance(after.epoch);
    let mut target_units = BTreeMap::new();
    for address in model.addresses() {
        let units = if address == f.pool {
            power.pool_units(after.epoch, target_period)
        } else {
            model.pool(address).units
        };
        target_units.insert(address, units);
    }
    let close_time = chain_time_secs(&f.client, version).await;
    let powers = allocated_powers(model, &target_units, target_index, close_time);
    let installed_powers = after
        .validators
        .active_validators
        .iter()
        .map(|validator| {
            (
                validator.account_address,
                validator.consensus_voting_power(),
            )
        })
        .collect::<BTreeMap<_, _>>();
    assert_eq!(installed_powers, powers);

    let test_lock_expired = close_time >= model.tested.locked_until_secs;
    if force_test_maturity {
        assert!(
            test_lock_expired,
            "forced maturity closed at {close_time} before lock {}",
            model.tested.locked_until_secs
        );
    }
    let mut test_matured = false;
    let mut test_rewards = None;
    let addresses = model.addresses();
    for address in addresses {
        let (successes, failures, fee, parts) = inputs[&address];
        let old = model.pool(address).clone();
        let credit = pool_event(&transaction, "::stake::PoCRewardCredited", address);
        assert_eq!(integer(&credit.data["closing_epoch"]), before.epoch as u128);
        assert_eq!(
            integer(&credit.data["reward_base_octa"]),
            old.reward_base_octa as u128
        );
        assert_eq!(
            integer(&credit.data["inflation"]),
            parts.poc_inflation as u128
        );
        assert_eq!(integer(&credit.data["fee"]), parts.poc_fee as u128);
        assert_eq!(wide(&credit.data["delta_index"]), parts.delta_index);
        let split = pool_event(&transaction, "::stake::PoCRewardSplit", address);
        assert_eq!(integer(&split.data["closing_epoch"]), before.epoch as u128);
        assert_eq!(
            integer(&split.data["native_reward_bps"]),
            native_bps as u128
        );
        assert_eq!(
            integer(&split.data["total_inflation_octa"]),
            parts.total_inflation as u128
        );
        assert_eq!(
            integer(&split.data["active_native_reward_octa"]),
            parts.active_native_inflation as u128
        );
        assert_eq!(
            integer(&split.data["pending_inactive_native_reward_octa"]),
            parts.pending_native_inflation as u128
        );
        assert_eq!(
            integer(&split.data["poc_inflation_octa"]),
            parts.poc_inflation as u128
        );
        assert_eq!(
            parts.total_inflation,
            parts.native_inflation + parts.poc_inflation
        );
        assert_eq!(fee, parts.native_fee + parts.poc_fee);

        let poc = parts.poc_inflation + parts.poc_fee;
        {
            let pool = model.pool_mut(address);
            pool.vault = pool.vault.checked_add(poc).unwrap();
            pool.credited = pool.credited.checked_add(poc).unwrap();
            pool.reward_index = U256::checked_add(pool.reward_index, parts.delta_index).unwrap();
            pool.native[0] = pool.native[0]
                .checked_add(parts.active_native_inflation + parts.active_native_fee)
                .unwrap();
            pool.native[3] = pool.native[3]
                .checked_add(parts.pending_native_inflation + parts.pending_native_fee)
                .unwrap();
            pool.native[0] = pool.native[0].checked_add(pool.native[2]).unwrap();
            pool.native[2] = 0;
            if address == f.pool && test_lock_expired && pool.native[3] > 0 {
                pool.native[1] = pool.native[1].checked_add(pool.native[3]).unwrap();
                pool.native[3] = 0;
                test_matured = true;
            }
            pool.units = target_units[&address];
            pool.next_units = if address == f.pool {
                let next_epoch = after.epoch + 1;
                power.pool_units(next_epoch, expected_period(next_epoch, period_epochs))
            } else {
                pool.units
            };
            pool.reward_base_octa = powers[&address] * OCTA;
            assert_eq!(pool.vault, pool.credited - pool.claimed);
        }

        model.credited = model.credited.checked_add(poc).unwrap();
        let totals = model.split_totals.entry(native_bps).or_default();
        totals.0 = totals
            .0
            .checked_add(parts.native_inflation + parts.native_fee)
            .unwrap();
        totals.1 = totals.1.checked_add(poc).unwrap();
        if poc > 0 {
            model.positive_epochs += 1;
        } else {
            model.zero_epochs += 1;
        }
        if address == f.pool {
            test_rewards = Some(parts);
        }
        model.record(format!(
            "close epoch={} pool={} success={} failed={} fee={} inflation={} poc={}",
            before.epoch, address, successes, failures, fee, parts.total_inflation, poc
        ));
    }

    let test_rewards = test_rewards.unwrap();
    for position in model.tested.positions.values_mut() {
        let accrued = U256::checked_add(
            position.fractional,
            U256::checked_mul(U256::from(position.units), test_rewards.delta_index).unwrap(),
        )
        .unwrap();
        position.claimable = position
            .claimable
            .checked_add(
                u64::try_from(U256::checked_div(accrued, entitlement_scale()).unwrap()).unwrap(),
            )
            .unwrap();
        position.fractional = U256::checked_rem(accrued, entitlement_scale()).unwrap();
    }
    for (address, position) in &mut model.tested.positions {
        position.units = power
            .users
            .get(address)
            .map(|user| user.allocated_units(after.epoch, target_period))
            .unwrap_or(0);
    }

    model.current_epoch = after.epoch;
    model.current_period = target_period;
    model.period_index = target_index;
    model.native_bps = integer(&after.reward_split["installed_native_reward_bps"]) as u64;
    model.last_closing_epoch = before.epoch;
    if test_lock_expired {
        model.tested.locked_until_secs = close_time + LOCKUP_SECS;
    }
    assert_eq!(
        integer(
            &resource(&f.client, f.pool, "0x1::stake::StakePool", version).await
                ["locked_until_secs"],
        ) as u64,
        model.tested.locked_until_secs,
        "validator lock must renew from the exact transition cutoff"
    );
    model.assert_all_pools(f, version, "close-after").await;
    assert_eq!(
        model.credited - model.claimed,
        model
            .addresses()
            .iter()
            .map(|address| model.pool(*address).vault)
            .sum::<u64>()
    );
    CloseResult {
        test_rewards,
        test_matured,
        version,
    }
}

async fn assert_shares_pool(
    client: &Client,
    table: &Value,
    expected: &SharesModel,
    holders: &[AccountAddress],
    version: u64,
) {
    assert_eq!(integer(&table["total_coins"]), expected.coins as u128);
    assert_eq!(integer(&table["total_shares"]), expected.total_shares);
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
            expected.shares(*holder),
            "holder={holder}"
        );
        assert_eq!(actual.is_some(), expected.shares(*holder) > 0);
    }
    if expected.total_shares > 0 {
        assert!(
            expected.dust() < expected.holders.len() as u64,
            "post-synchronize floor dust exceeded the number of nonzero holders"
        );
    }
}

async fn assert_test_shares(
    f: &Fixture,
    model: &TestPoolModel,
    users: &[LocalAccount],
    version: u64,
) {
    let delegation = resource(
        &f.client,
        f.pool,
        "0x1::delegation_pool::DelegationPool",
        version,
    )
    .await;
    assert_eq!(
        integer(&delegation["operator_commission_percentage"]),
        COMMISSION_BPS as u128
    );
    assert_eq!(
        integer(&delegation["observed_lockup_cycle"]["index"]),
        model.observed_lockup_cycle as u128
    );
    assert_eq!(
        integer(&delegation["total_coins_inactive"]),
        model.pool.native[1] as u128
    );
    let holders = std::iter::once(f.owner.address())
        .chain(std::iter::once(f.operator.address()))
        .chain(users.iter().map(LocalAccount::address))
        .chain(std::iter::once(NULL_SHAREHOLDER))
        .collect::<Vec<_>>();
    assert_shares_pool(
        &f.client,
        &delegation["active_shares"],
        &model.active,
        &holders,
        version,
    )
    .await;
    let inactive_handle = address(&delegation["inactive_shares"]["handle"]);
    // `inactive_shares` is a native Table and exposes only its handle. Prove
    // every nonempty historical key retained by `redeem_inactive_shares`; that
    // function removes a past pool once its total coins reach zero.
    for (cycle, shares) in &model.inactive {
        let actual = table_entry(
            &f.client,
            inactive_handle,
            "0x1::delegation_pool::ObservedLockupCycle",
            "0x1::pool_u64_unbound::Pool",
            json!({"index": cycle.to_string()}),
            version,
        )
        .await
        .unwrap_or_else(|| panic!("missing inactive shares for OLC {cycle}"));
        assert_shares_pool(&f.client, &actual, shares, &holders, version).await;
    }
    let pending = table_entry(
        &f.client,
        inactive_handle,
        "0x1::delegation_pool::ObservedLockupCycle",
        "0x1::pool_u64_unbound::Pool",
        json!({"index": model.observed_lockup_cycle.to_string()}),
        version,
    )
    .await
    .unwrap();
    assert_shares_pool(
        &f.client,
        &pending,
        &model.pending_inactive,
        &holders,
        version,
    )
    .await;

    for holder in holders
        .into_iter()
        .filter(|holder| *holder != NULL_SHAREHOLDER)
    {
        let expected_inactive = model
            .inactive
            .values()
            .map(|shares| shares.balance(holder))
            .sum::<u64>();
        let expected = vec![
            json!(model.active.balance(holder).to_string()),
            json!(expected_inactive.to_string()),
            json!(model.pending_inactive.balance(holder).to_string()),
        ];
        assert_eq!(
            view(
                &f.client,
                "0x1::delegation_pool::get_stake",
                vec![json!(f.pool), json!(holder)],
                version,
            )
            .await,
            expected,
            "delegation holder={holder}"
        );
    }
    assert_eq!(model.active.shares(NULL_SHAREHOLDER), 0);
}

async fn synchronize_test_pool(
    f: &Fixture,
    model: &mut NetworkModel,
    users: &[LocalAccount],
    result: &CloseResult,
) -> u64 {
    let active_gain =
        result.test_rewards.active_native_inflation + result.test_rewards.active_native_fee;
    let pending_gain =
        result.test_rewards.pending_native_inflation + result.test_rewards.pending_native_fee;
    let active_commission = (active_gain as u128 * COMMISSION_BPS as u128 / 10_000) as u64;
    let pending_commission = (pending_gain as u128 * COMMISSION_BPS as u128 / 10_000) as u64;
    let active_actual = model.tested.active.coins + active_gain;
    let pending_actual = model.tested.pending_inactive.coins + pending_gain;
    model
        .tested
        .active
        .settle(active_actual, active_commission, f.operator.address());
    model
        .tested
        .pending_inactive
        .settle(pending_actual, pending_commission, f.operator.address());
    // Buying a new pending-inactive commission share first executes the
    // beneficiary's one older matured withdrawal.  Model that implicit payout
    // before advancing the current OLC.
    let implicit_operator_withdrawal = if pending_commission > 0 {
        let old_cycle = model
            .tested
            .inactive
            .iter()
            .find(|(_, shares)| shares.balance(f.operator.address()) > 0)
            .map(|(cycle, _)| *cycle);
        old_cycle.map(|cycle| {
            let (amount, emptied) = {
                let shares = model.tested.inactive.get_mut(&cycle).unwrap();
                let amount = shares.redeem_requested(f.operator.address(), u64::MAX);
                (amount, shares.coins == 0)
            };
            if emptied {
                model.tested.inactive.remove(&cycle);
            }
            model.tested.pool.native[1] -= amount;
            (cycle, amount)
        })
    } else {
        None
    };
    if result.test_matured {
        let cycle = model.tested.observed_lockup_cycle;
        let matured = std::mem::take(&mut model.tested.pending_inactive);
        assert!(matured.coins > 0);
        model.tested.inactive.insert(cycle, matured);
        model.tested.observed_lockup_cycle += 1;
    }

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
    let commissions = events(&transaction, "::delegation_pool::DistributeCommission");
    assert_eq!(commissions.len(), 1);
    assert_eq!(address(&commissions[0].data["pool_address"]), f.pool);
    assert_eq!(
        integer(&commissions[0].data["commission_active"]),
        active_commission as u128
    );
    assert_eq!(
        integer(&commissions[0].data["commission_pending_inactive"]),
        pending_commission as u128
    );
    let delegation_withdrawals = events(&transaction, "::delegation_pool::WithdrawStake");
    let stake_withdrawals = events(&transaction, "::stake::WithdrawStake");
    assert_eq!(
        delegation_withdrawals.len(),
        usize::from(implicit_operator_withdrawal.is_some())
    );
    assert_eq!(
        stake_withdrawals.len(),
        usize::from(implicit_operator_withdrawal.is_some())
    );
    if let Some((cycle, amount)) = implicit_operator_withdrawal {
        assert_eq!(
            address(&delegation_withdrawals[0].data["delegator_address"]),
            f.operator.address()
        );
        assert_eq!(
            integer(&delegation_withdrawals[0].data["amount_withdrawn"]),
            amount as u128
        );
        assert_eq!(
            integer(&stake_withdrawals[0].data["amount_withdrawn"]),
            amount as u128
        );
        model.record(format!(
            "implicit_operator_withdraw olc={cycle} amount={amount} version={version}"
        ));
    }
    assert!(events(&transaction, "::stake::PoCRewardCredited").is_empty());
    assert!(events(&transaction, "::poc_accounting::PoCRewardClaimed").is_empty());
    assert_eq!(
        native_stake(&f.client, f.pool, version).await,
        model.tested.pool.native
    );
    assert_test_shares(f, &model.tested, users, version).await;
    model.record(format!(
        "sync version={version} active_commission={active_commission} pending_commission={pending_commission} matured={}",
        result.test_matured
    ));
    version
}

struct PreparedRun {
    fixture: Fixture,
    model: NetworkModel,
    power: PowerBook,
    users: Vec<LocalAccount>,
    started: Instant,
}

async fn prepare_run(config: RunConfig) -> PreparedRun {
    Lazy::force(&CHURN_GOVERNANCE);
    println!(
        "PoC reward churn seed={:#x}: rounds={}, users={}, period_epochs={}, retention={}, native_bps={}, commission_bps={}, fee_limit={}, lockup_secs={}, rate={}, preparation closes through E60, drain={}",
        config.seed,
        config.rounds,
        config.users,
        config.period_epochs,
        RETENTION_BPS,
        NATIVE_REWARD_BPS,
        COMMISSION_BPS,
        FEE_LIMIT,
        LOCKUP_SECS,
        if config.enable_rate { "1%" } else { "0" },
        DRAIN_CLOSINGS,
    );
    let (fixture, initial_version) =
        churn_fixture(NATIVE_REWARD_BPS, COMMISSION_BPS, RETENTION_BPS).await;
    // Budget preparation and churn after the fixture is ready, excluding the
    // potentially long wait for swarm node slots in the full smoke suite.
    let started = Instant::now();
    let accounting = resource(
        &fixture.client,
        CORE_CODE_ADDRESS,
        "0x1::poc_accounting::AccountingState",
        initial_version,
    )
    .await;
    let first_poc_epoch = integer(
        accounting["config"]["first_poc_epoch"]["vec"]
            .as_array()
            .unwrap()
            .first()
            .expect("PoC first epoch must be installed"),
    ) as u64;
    let mut model = NetworkModel::new(&fixture, initial_version, first_poc_epoch).await;
    let mut power = PowerBook {
        users: BTreeMap::from([(fixture.power_user.address(), PowerUserModel {
            address: fixture.power_user.address(),
            versions: BTreeMap::from([(0, INITIAL_RAW_POWER as u128 * UNIT_SCALE)]),
            ratio: 10_000,
            pending_ratio: None,
        })]),
    };
    assert_eq!(
        power.pool_units(model.current_epoch, 0),
        model.tested.pool.units
    );

    while model.current_epoch < 60 {
        let result = close_epoch(
            &fixture,
            &mut model,
            &mut power,
            60,
            governance_payload(2, 0, fixture.owner.address(), false, 0),
            false,
        )
        .await;
        assert_eq!(result.test_rewards.total_inflation, 0);
        assert_eq!(result.test_rewards.poc_fee, 0);
        synchronize_test_pool(&fixture, &mut model, &[], &result).await;
    }
    assert_eq!(model.current_epoch, 60);

    let configured = success(
        execute(
            &fixture.client,
            &fixture.root,
            &fixture.factory,
            governance_payload(0, config.period_epochs, fixture.owner.address(), false, 0),
        )
        .await,
    );
    assert!(events(&configured, "::stake::PoCEpochInstalled").is_empty());
    let configured_version = configured.info.version.0;
    assert_eq!(
        clock_at(&fixture.client, configured_version).await.1,
        61,
        "changing the next period length must preserve the already fixed E61 boundary"
    );
    assert_eq!(
        view(
            &fixture.client,
            "0x1::poc_power_store::get_power_period_in_epochs",
            vec![],
            configured_version,
        )
        .await,
        vec![json!(config.period_epochs.to_string())]
    );

    let mut public = fixture.swarm.chain_info().into_aptos_public_info();
    let mut users = Vec::with_capacity(config.users);
    for _ in 0..config.users {
        users.push(
            public
                .create_and_fund_user_account(2_000 * OCTA)
                .await
                .unwrap(),
        );
    }
    for (index, user) in users.iter().enumerate() {
        let amount = 100 * OCTA + index as u64 + 1;
        let added = success(
            execute(
                &fixture.client,
                user,
                &fixture.factory,
                aptos_stdlib::delegation_pool_add_stake(fixture.pool, amount),
            )
            .await,
        );
        let add_events = events(&added, "::delegation_pool::AddStake");
        assert_eq!(add_events.len(), 1);
        assert_eq!(integer(&add_events[0].data["amount_added"]), amount as u128);
        assert_eq!(integer(&add_events[0].data["add_stake_fee"]), 0);
        model.tested.active.deposit(user.address(), amount, 0);
        model.tested.pool.native[2] += amount;

        success(
            execute(
                &fixture.client,
                user,
                &fixture.factory,
                aptos_stdlib::poc_allocation_set_allocations(vec![fixture.pool], vec![10_000]),
            )
            .await,
        );
        let raw = 1 + index as u64;
        power.users.insert(user.address(), PowerUserModel {
            address: user.address(),
            versions: BTreeMap::from([(1, normalized_units(raw, 1))]),
            ratio: 0,
            pending_ratio: Some((61, 10_000)),
        });
        model
            .tested
            .positions
            .insert(user.address(), PositionModel::default());
    }
    let legacy_empty = success(
        execute(
            &fixture.client,
            &fixture.power_user,
            &fixture.factory,
            aptos_stdlib::poc_allocation_set_allocations(vec![], vec![]),
        )
        .await,
    );
    assert!(legacy_empty.info.success);
    power
        .users
        .get_mut(&fixture.power_user.address())
        .unwrap()
        .pending_ratio = Some((61, 0));

    let upload = success(
        execute(
            &fixture.client,
            &fixture.owner,
            &fixture.factory,
            aptos_stdlib::poc_power_store_stage_batch_update(
                1,
                users.iter().map(LocalAccount::address).collect(),
                (0..users.len()).map(|index| 1 + index as u64).collect(),
            ),
        )
        .await,
    );
    assert_eq!(
        events(&upload, "::poc_power_store::PowerNormalized").len(),
        users.len()
    );
    assert_eq!(
        events(&upload, "::poc_power_store::PowerUpdateStagedEvent").len(),
        users.len()
    );
    model.tested.pool.next_units = power.pool_units(61, 1);
    model
        .assert_all_pools(&fixture, upload.info.version.0, "initial-upload")
        .await;

    let installed = close_epoch(
        &fixture,
        &mut model,
        &mut power,
        config.period_epochs,
        governance_payload(1, 0, fixture.owner.address(), config.enable_rate, FEE_LIMIT),
        false,
    )
    .await;
    assert_eq!(model.current_epoch, PREPARATION_CLOSINGS + 1);
    assert_eq!(model.current_period, 1);
    assert_eq!(model.period_index, period_index(1));
    assert_eq!(
        expected_next_boundary(61, config.period_epochs),
        61 + config.period_epochs
    );
    assert_eq!(installed.test_rewards.total_inflation, 0);
    synchronize_test_pool(&fixture, &mut model, &users, &installed).await;
    assert_eq!(model.tested.pool.native[2], 0);
    assert_eq!(model.tested.active.shares(NULL_SHAREHOLDER), 0);
    assert_eq!(model.tested.active.coins, model.tested.pool.native[0]);
    assert!(first_poc_epoch <= model.first_closing_epoch);
    println!(
        "PoC churn prepared: F={}, preparation_closing_range={}..=60, installed_epoch=61, period=1, next_boundary={}, users={}, test_units={}, version={}, elapsed={:?}",
        first_poc_epoch,
        model.first_closing_epoch,
        expected_next_boundary(61, config.period_epochs),
        users.len(),
        model.tested.pool.units,
        installed.version,
        started.elapsed(),
    );
    PreparedRun {
        fixture,
        model,
        power,
        users,
        started,
    }
}

#[derive(Clone, Copy, Debug)]
struct DeterministicRng(u64);

impl DeterministicRng {
    fn new(seed: u64) -> Self {
        assert_ne!(seed, 0);
        Self(seed)
    }

    fn next(&mut self) -> u64 {
        let mut value = self.0;
        value ^= value << 13;
        value ^= value >> 7;
        value ^= value << 17;
        self.0 = value;
        value
    }

    fn index(&mut self, length: usize) -> usize {
        (self.next() as usize) % length
    }
}

fn apply_zero_reward_sync(model: &mut TestPoolModel, operator: AccountAddress) {
    // Every public delegation operation synchronizes before doing business.
    // The Move synchronizer deliberately keeps NULL shares while any
    // pending-active principal is still in flight.  They are released only
    // after an epoch transition has merged that principal into active.
    if model.pool.native[2] == 0 {
        let active = model.active.coins;
        model.active.settle(active, 0, operator);
    }
    let pending = model.pending_inactive.coins;
    model.pending_inactive.settle(pending, 0, operator);
}

fn assert_zero_commission(transaction: &UserTransaction, pool: AccountAddress) {
    let commissions = events(transaction, "::delegation_pool::DistributeCommission");
    assert_eq!(commissions.len(), 1);
    assert_eq!(address(&commissions[0].data["pool_address"]), pool);
    assert_eq!(integer(&commissions[0].data["commission_active"]), 0);
    assert_eq!(
        integer(&commissions[0].data["commission_pending_inactive"]),
        0
    );
}

async fn assert_wallet_delta(
    client: &Client,
    transaction: &UserTransaction,
    account: AccountAddress,
    business_delta: i128,
) {
    let version = transaction.info.version.0;
    let before = client
        .view_apt_account_balance_at_version(account, version - 1)
        .await
        .unwrap()
        .into_inner();
    let after = client
        .view_apt_account_balance_at_version(account, version)
        .await
        .unwrap()
        .into_inner();
    let statements = events(transaction, "::transaction_fee::FeeStatement");
    assert_eq!(statements.len(), 1);
    let gas = transaction.info.gas_used.0 as i128 * transaction.request.gas_unit_price.0 as i128;
    let refund = integer(&statements[0].data["storage_fee_refund_octas"]) as i128;
    assert_eq!(
        after as i128 - before as i128,
        business_delta - gas + refund,
        "wallet delta at version {version}"
    );
}

fn inactive_balance(model: &TestPoolModel, user: AccountAddress) -> u64 {
    model
        .inactive
        .values()
        .map(|shares| shares.balance(user))
        .sum()
}

async fn assert_user_stake(f: &Fixture, model: &TestPoolModel, user: AccountAddress, version: u64) {
    assert_eq!(
        view(
            &f.client,
            "0x1::delegation_pool::get_stake",
            vec![json!(f.pool), json!(user)],
            version,
        )
        .await,
        vec![
            json!(model.active.balance(user).to_string()),
            json!(inactive_balance(model, user).to_string()),
            json!(model.pending_inactive.balance(user).to_string()),
        ]
    );
}

fn expected_add_stake_fee(
    model: &NetworkModel,
    rate: u64,
    denominator: u64,
    distribute_fee: bool,
    fee_limit: u64,
    amount: u64,
) -> u64 {
    if denominator == 0 || model.native_bps == 0 {
        return 0;
    }
    let total_inflation =
        reward_amount(model.tested.pool.reward_base_octa, 1, 0, rate, denominator);
    let native_inflation = (total_inflation as u128 * model.native_bps as u128 / 10_000) as u64;
    let native_fee = if distribute_fee {
        (fee_limit as u128 * model.native_bps as u128 / 10_000) as u64
    } else {
        0
    };
    let upper = native_inflation.checked_add(native_fee).unwrap();
    if upper == 0 || COMMISSION_BPS == 10_000 {
        return 0;
    }
    let commission = (upper as u128 * COMMISSION_BPS as u128 / 10_000) as u64;
    let mut net = upper - commission;
    if commission > 0 && net < upper {
        net += 1;
    }
    let eligible = model.tested.pool.native[0]
        .checked_add(model.tested.pool.native[3])
        .unwrap();
    if eligible == 0 {
        return 0;
    }
    let numerator = amount as u128 * net as u128;
    let denominator = eligible as u128 + net as u128;
    numerator.div_ceil(denominator) as u64
}

async fn add_stake(
    f: &Fixture,
    model: &mut NetworkModel,
    users: &[LocalAccount],
    user_index: usize,
    amount: u64,
) -> u64 {
    let user = &users[user_index];
    let before_version = latest_version(&f.client).await;
    let installed = installed_at(&f.client, before_version).await;
    assert_eq!(installed.epoch, model.current_epoch);
    let (_, enabled, rate, denominator, distribute_fee, fee_limit) = installed.reward_context;
    assert!(enabled);
    let fee = expected_add_stake_fee(model, rate, denominator, distribute_fee, fee_limit, amount);
    assert_eq!(
        view(
            &f.client,
            "0x1::delegation_pool::get_add_stake_fee",
            vec![json!(f.pool), json!(amount.to_string())],
            before_version,
        )
        .await,
        vec![json!(fee.to_string())]
    );
    apply_zero_reward_sync(&mut model.tested, f.operator.address());
    let transaction = success(
        execute(
            &f.client,
            user,
            &f.factory,
            aptos_stdlib::delegation_pool_add_stake(f.pool, amount),
        )
        .await,
    );
    let added = events(&transaction, "::delegation_pool::AddStake");
    assert_eq!(added.len(), 1);
    assert_eq!(address(&added[0].data["pool_address"]), f.pool);
    assert_eq!(address(&added[0].data["delegator_address"]), user.address());
    assert_eq!(integer(&added[0].data["amount_added"]), amount as u128);
    assert_eq!(integer(&added[0].data["add_stake_fee"]), fee as u128);
    assert_zero_commission(&transaction, f.pool);
    model.tested.active.deposit(user.address(), amount, fee);
    model.tested.pool.native[2] = model.tested.pool.native[2].checked_add(amount).unwrap();
    let version = transaction.info.version.0;
    assert_eq!(
        native_stake(&f.client, f.pool, version).await,
        model.tested.pool.native
    );
    assert_user_stake(f, &model.tested, user.address(), version).await;
    assert_wallet_delta(&f.client, &transaction, user.address(), -(amount as i128)).await;
    model.record(format!(
        "add epoch={} user={} nominal={} fee={} version={version}",
        model.current_epoch,
        user.address(),
        amount,
        fee
    ));
    fee
}

async fn unlock_stake(
    f: &Fixture,
    model: &mut NetworkModel,
    users: &[LocalAccount],
    user_index: usize,
    nominal: u64,
) -> u64 {
    let user = &users[user_index];
    apply_zero_reward_sync(&mut model.tested, f.operator.address());
    let expected = model.tested.active.preview_transfer_amount(
        &model.tested.pending_inactive,
        user.address(),
        nominal,
    );
    assert!(expected > 0);
    assert!(nominal <= model.tested.pool.native[0]);
    let transaction = success(
        execute(
            &f.client,
            user,
            &f.factory,
            aptos_stdlib::delegation_pool_unlock(f.pool, nominal),
        )
        .await,
    );
    let actual = model.tested.active.transfer_with_minimum(
        &mut model.tested.pending_inactive,
        user.address(),
        nominal,
    );
    assert_eq!(actual, expected);
    model.tested.pool.native[0] -= actual;
    model.tested.pool.native[3] += actual;
    for event_type in ["::delegation_pool::UnlockStake", "::stake::UnlockStake"] {
        let unlocked = events(&transaction, event_type);
        assert_eq!(unlocked.len(), 1);
        assert_eq!(address(&unlocked[0].data["pool_address"]), f.pool);
        assert_eq!(
            integer(&unlocked[0].data["amount_unlocked"]),
            actual as u128
        );
        if event_type.contains("delegation_pool") {
            assert_eq!(
                address(&unlocked[0].data["delegator_address"]),
                user.address()
            );
        }
    }
    assert_zero_commission(&transaction, f.pool);
    let version = transaction.info.version.0;
    assert_eq!(
        native_stake(&f.client, f.pool, version).await,
        model.tested.pool.native
    );
    assert_user_stake(f, &model.tested, user.address(), version).await;
    assert_wallet_delta(&f.client, &transaction, user.address(), 0).await;
    model.record(format!(
        "unlock epoch={} user={} nominal={} actual={} version={version}",
        model.current_epoch,
        user.address(),
        nominal,
        actual
    ));
    actual
}

async fn reactivate_stake(
    f: &Fixture,
    model: &mut NetworkModel,
    users: &[LocalAccount],
    pending: PendingReactivation,
) -> u64 {
    let user = users
        .iter()
        .find(|user| user.address() == pending.user)
        .unwrap();
    apply_zero_reward_sync(&mut model.tested, f.operator.address());
    let expected = model.tested.pending_inactive.preview_transfer_amount(
        &model.tested.active,
        user.address(),
        pending.amount,
    );
    assert!(expected > 0);
    let transaction = success(
        execute(
            &f.client,
            user,
            &f.factory,
            aptos_stdlib::delegation_pool_reactivate_stake(f.pool, pending.amount),
        )
        .await,
    );
    let actual = model.tested.pending_inactive.transfer_with_minimum(
        &mut model.tested.active,
        user.address(),
        pending.amount,
    );
    assert_eq!(actual, expected);
    model.tested.pool.native[0] += actual;
    model.tested.pool.native[3] -= actual;
    let reactivated = events(&transaction, "::delegation_pool::ReactivateStake");
    assert_eq!(reactivated.len(), 1);
    assert_eq!(
        integer(&reactivated[0].data["amount_reactivated"]),
        actual as u128
    );
    assert_zero_commission(&transaction, f.pool);
    let version = transaction.info.version.0;
    assert_eq!(
        native_stake(&f.client, f.pool, version).await,
        model.tested.pool.native
    );
    assert_user_stake(f, &model.tested, user.address(), version).await;
    assert_wallet_delta(&f.client, &transaction, user.address(), 0).await;
    model.record(format!(
        "reactivate epoch={} user={} nominal={} actual={} version={version}",
        model.current_epoch,
        user.address(),
        pending.amount,
        actual
    ));
    actual
}

async fn withdraw_matured(
    f: &Fixture,
    model: &mut NetworkModel,
    users: &[LocalAccount],
    user: AccountAddress,
    nominal: u64,
) -> u64 {
    let actor = users.iter().find(|actor| actor.address() == user).unwrap();
    apply_zero_reward_sync(&mut model.tested, f.operator.address());
    let cycle = model
        .tested
        .inactive
        .iter()
        .find(|(_, shares)| shares.balance(user) > 0)
        .map(|(cycle, _)| *cycle)
        .expect("matured user must have inactive shares");
    let (expected, emptied) = {
        let shares = model.tested.inactive.get_mut(&cycle).unwrap();
        let amount = shares.redeem_requested(user, nominal);
        (amount, shares.coins == 0)
    };
    if emptied {
        model.tested.inactive.remove(&cycle);
    }
    assert!(expected > 0);
    let transaction = success(
        execute(
            &f.client,
            actor,
            &f.factory,
            aptos_stdlib::delegation_pool_withdraw(f.pool, nominal),
        )
        .await,
    );
    model.tested.pool.native[1] -= expected;
    for event_type in ["::delegation_pool::WithdrawStake", "::stake::WithdrawStake"] {
        let withdrawn = events(&transaction, event_type);
        assert_eq!(withdrawn.len(), 1);
        assert_eq!(address(&withdrawn[0].data["pool_address"]), f.pool);
        assert_eq!(
            integer(&withdrawn[0].data["amount_withdrawn"]),
            expected as u128
        );
    }
    assert_zero_commission(&transaction, f.pool);
    let version = transaction.info.version.0;
    assert_eq!(
        native_stake(&f.client, f.pool, version).await,
        model.tested.pool.native
    );
    assert_user_stake(f, &model.tested, user, version).await;
    assert_wallet_delta(&f.client, &transaction, user, expected as i128).await;
    model.record(format!(
        "withdraw epoch={} user={} nominal={} actual={} olc={} version={version}",
        model.current_epoch, user, nominal, expected, cycle
    ));
    expected
}

async fn set_allocation(
    f: &Fixture,
    model: &mut NetworkModel,
    power: &mut PowerBook,
    users: &[LocalAccount],
    user_index: usize,
    ratio: u64,
    period_epochs: u64,
) -> u64 {
    let user = &users[user_index];
    let target_epoch = model.current_epoch + 1;
    let (pools, ratios) = if ratio == 0 {
        (vec![], vec![])
    } else {
        (vec![f.pool], vec![ratio])
    };
    let transaction = success(
        execute(
            &f.client,
            user,
            &f.factory,
            aptos_stdlib::poc_allocation_set_allocations(pools, ratios),
        )
        .await,
    );
    let scheduled = events(&transaction, "::poc_accounting::AllocationScheduled");
    assert_eq!(scheduled.len(), 1);
    assert_eq!(address(&scheduled[0].data["user"]), user.address());
    assert_eq!(
        integer(&scheduled[0].data["effective_epoch"]),
        target_epoch as u128
    );
    let power_user = power.users.get_mut(&user.address()).unwrap();
    assert!(power_user.pending_ratio.is_none());
    power_user.pending_ratio = Some((target_epoch, ratio));
    model.tested.pool.next_units =
        power.pool_units(target_epoch, expected_period(target_epoch, period_epochs));
    let version = transaction.info.version.0;
    model.assert_all_pools(f, version, "allocate").await;
    model.record(format!(
        "allocation epoch={} user={} ratio={} effective={} version={version}",
        model.current_epoch,
        user.address(),
        ratio,
        target_epoch
    ));
    version
}

fn raw_power_for(user_index: usize, period: u64) -> u64 {
    if (user_index as u64 + period) % 7 == 0 {
        0
    } else {
        1 + user_index as u64 + period % 3
    }
}

async fn stage_next_power_period(
    f: &Fixture,
    model: &mut NetworkModel,
    power: &mut PowerBook,
    users: &[LocalAccount],
    period_epochs: u64,
) -> u64 {
    let target_period = model.current_period + 1;
    let raw = users
        .iter()
        .enumerate()
        .map(|(index, _)| raw_power_for(index, target_period))
        .collect::<Vec<_>>();
    let transaction = success(
        execute(
            &f.client,
            &f.owner,
            &f.factory,
            aptos_stdlib::poc_power_store_stage_batch_update(
                target_period,
                users.iter().map(LocalAccount::address).collect(),
                raw.clone(),
            ),
        )
        .await,
    );
    let normalized = events(&transaction, "::poc_power_store::PowerNormalized");
    let staged = events(&transaction, "::poc_power_store::PowerUpdateStagedEvent");
    assert_eq!(normalized.len(), users.len());
    assert_eq!(staged.len(), users.len());
    for (index, user) in users.iter().enumerate() {
        let units = normalized_units(raw[index], target_period);
        assert_eq!(address(&normalized[index].data["user"]), user.address());
        assert_eq!(
            integer(&normalized[index].data["effective_period"]),
            target_period as u128
        );
        assert_eq!(integer(&normalized[index].data["units"]), units);
        let entry = power.users.get_mut(&user.address()).unwrap();
        assert_eq!(entry.address, user.address());
        assert!(entry.versions.insert(target_period, units).is_none());
    }
    let boundary = expected_next_boundary(model.current_epoch, period_epochs);
    model.tested.pool.next_units = power.pool_units(boundary, target_period);
    let version = transaction.info.version.0;
    model.assert_all_pools(f, version, "stage-power").await;
    model.record(format!(
        "upload epoch={} target_period={} boundary={} version={version}",
        model.current_epoch, target_period, boundary
    ));
    version
}

async fn fill_test_pool_fee_limit(f: &Fixture, users: &[LocalAccount], model: &mut NetworkModel) {
    let start = latest_version(&f.client).await;
    if recorded_fee(&f.client, f.pool, start).await == FEE_LIMIT {
        return;
    }
    let (factory, _) = priced_fee_factory(&f.client, &f.factory, start).await;
    let completed = tokio::time::timeout(Duration::from_secs(90), async {
        let mut count = 0u64;
        loop {
            let transaction = success(
                execute(
                    &f.client,
                    &users[0],
                    &factory,
                    aptos_stdlib::topo_coin_transfer(users[1].address(), 1_000),
                )
                .await,
            );
            count += 1;
            let version = transaction.info.version.0;
            let fee = recorded_fee(&f.client, f.pool, version).await;
            assert!(fee <= FEE_LIMIT);
            if fee == FEE_LIMIT {
                break (count, version);
            }
        }
    })
    .await
    .expect("test pool fee accumulator did not reach 17 Octa within 90 seconds");
    model.record(format!(
        "fill_fee epoch={} transfers={} version={}",
        model.current_epoch, completed.0, completed.1
    ));
}

async fn proposal_counts(f: &Fixture, version: u64) -> (u64, u64) {
    let installed = installed_at(&f.client, version).await;
    let validator = installed
        .validators
        .active_validators
        .iter()
        .find(|validator| validator.account_address == f.pool)
        .unwrap();
    let values = view(
        &f.client,
        "0x1::stake::get_current_epoch_proposal_counts",
        vec![json!(validator.config().validator_index.to_string())],
        version,
    )
    .await;
    (integer(&values[0]) as u64, integer(&values[1]) as u64)
}

async fn inject_mixed_proposals(f: &mut Fixture, users: &[LocalAccount], model: &mut NetworkModel) {
    let epoch = model.current_epoch;
    f.swarm.validator_mut(f.node_key).unwrap().stop();
    let stopped = tokio::time::timeout(Duration::from_secs(90), async {
        loop {
            let transaction = success(
                execute(
                    &f.client,
                    &users[0],
                    &f.factory,
                    aptos_stdlib::topo_coin_transfer(users[1].address(), 1),
                )
                .await,
            );
            let version = transaction.info.version.0;
            let counts = proposal_counts(f, version).await;
            if counts.1 > 0 {
                break (counts.0, counts.1, version);
            }
        }
    })
    .await;
    f.swarm.validator_mut(f.node_key).unwrap().start().unwrap();
    let (successes_before_recovery, failed, stopped_version) =
        stopped.expect("stopped test validator did not miss a proposal within 90 seconds");
    let minimum_recovered_successes = successes_before_recovery.checked_add(1).unwrap();
    let recovered_version = wait_for_real_proposals(f, epoch, minimum_recovered_successes).await;
    let (successes, failures) = proposal_counts(f, recovered_version).await;
    assert!(successes >= minimum_recovered_successes && failures >= failed);
    model.record(format!(
        "mixed_proposals epoch={epoch} successes_before_recovery={successes_before_recovery} successes_after_recovery={successes} failed={failures} stopped_version={stopped_version} recovered_version={recovered_version}"
    ));
}

async fn wait_for_test_lock(f: &Fixture, model: &NetworkModel) {
    let lock = model.tested.locked_until_secs;
    tokio::time::timeout(Duration::from_secs(45), async {
        loop {
            let version = latest_version(&f.client).await;
            if chain_time_secs(&f.client, version).await > lock {
                break;
            }
            tokio::time::sleep(Duration::from_millis(200)).await;
        }
    })
    .await
    .unwrap_or_else(|_| panic!("short validator lock {lock} did not expire within 45 seconds"));
}

async fn claim_user(f: &Fixture, model: &mut NetworkModel, actor: &LocalAccount) -> u64 {
    let expected = model
        .tested
        .positions
        .get(&actor.address())
        .unwrap()
        .claimable;
    let transaction = success(
        execute(
            &f.client,
            actor,
            &f.factory,
            aptos_stdlib::poc_allocation_claim_rewards(vec![f.pool]),
        )
        .await,
    );
    let payments = events(&transaction, "::poc_accounting::PoCRewardClaimed");
    assert_eq!(payments.len(), usize::from(expected > 0));
    if expected > 0 {
        assert_eq!(address(&payments[0].data["user"]), actor.address());
        assert_eq!(address(&payments[0].data["pool"]), f.pool);
        assert_eq!(integer(&payments[0].data["amount"]), expected as u128);
    }
    model.tested.pool.vault -= expected;
    model.tested.pool.claimed += expected;
    model.claimed += expected;
    let (units, fractional) = {
        let position = model.tested.positions.get_mut(&actor.address()).unwrap();
        position.claimed += expected;
        position.claimable = 0;
        (position.units, position.fractional)
    };
    let version = transaction.info.version.0;
    assert_wallet_delta(&f.client, &transaction, actor.address(), expected as i128).await;
    model.assert_all_pools(f, version, "claim").await;
    let actual = position_at(&f.client, actor.address(), f.pool, version).await;
    assert_eq!(integer(&actual[0]), units);
    assert_eq!(integer(&actual[2]), 0);
    assert_eq!(wide(&actual[3]), fractional);
    assert_eq!(
        model.tested.pool.vault,
        model.tested.pool.credited - model.tested.pool.claimed
    );
    model.record(format!(
        "claim epoch={} user={} amount={} version={version}",
        model.current_epoch,
        actor.address(),
        expected
    ));
    expected
}

async fn checkpoint_count(f: &Fixture, model: &NetworkModel, ledger: &Value, version: u64) -> u64 {
    // Native Move tables expose only a handle through REST, not a readable
    // length. Probe every epoch installed so far: future changes do not create
    // checkpoints until the pool advances to their epoch. Using
    // the already-read handle avoids fetching PoolLedger once per epoch.
    let handle = address(&ledger["checkpoints"]["handle"]);
    let mut count = 0;
    for epoch in model.first_poc_epoch..=model.current_epoch {
        if let Some(checkpoint) = table_entry(
            &f.client,
            handle,
            "u64",
            "0x1::poc_accounting::Checkpoint",
            json!(epoch.to_string()),
            version,
        )
        .await
        {
            assert!(
                integer(&checkpoint["refs"]) > 0,
                "checkpoint {epoch} at version {version} has no references"
            );
            count += 1;
        }
    }
    count
}

async fn assert_positions(
    f: &Fixture,
    model: &mut NetworkModel,
    actors: &[&LocalAccount],
    version: u64,
) -> u64 {
    for actor in actors {
        let expected = model.tested.positions.get(&actor.address()).unwrap();
        let actual = position_at(&f.client, actor.address(), f.pool, version).await;
        assert_eq!(
            integer(&actual[0]),
            expected.units,
            "user={}",
            actor.address()
        );
        assert_eq!(
            integer(&actual[2]),
            expected.claimable as u128,
            "user={}",
            actor.address()
        );
        assert_eq!(
            wide(&actual[3]),
            expected.fractional,
            "user={}",
            actor.address()
        );
        assert!(
            actual[1].as_array().unwrap().len() <= 2,
            "position future-change bound exceeded for {}",
            actor.address()
        );
    }
    let ledger = ledger_at(&f.client, f.pool, version).await;
    let changes = ledger["changes"].as_array().unwrap();
    assert!(
        changes.len() <= 2,
        "pool future-change protocol bound exceeded"
    );
    for change in changes {
        let epoch = integer(&change["epoch"]) as u64;
        assert!(
            epoch > integer(&ledger["epoch"]) as u64,
            "future pool change epoch {epoch} must follow the pool's installed epoch"
        );
    }
    let checkpoints = checkpoint_count(f, model, &ledger, version).await;
    model.max_checkpoints = model.max_checkpoints.max(checkpoints);
    checkpoints
}

async fn snapshot_data(
    f: &Fixture,
    client: &Client,
    model: &NetworkModel,
    users: &[LocalAccount],
    version: u64,
) -> BTreeMap<String, Value> {
    let mut result = BTreeMap::new();
    for name in [
        "0x1::poc_accounting::AccountingState",
        "0x1::poc_power_store::PowerStore",
        "0x1::poc_power_store::PeriodClock",
        "0x1::stake::ValidatorPerformance",
        "0x1::stake::PendingTransactionFee",
    ] {
        result.insert(
            name.to_owned(),
            resource(client, CORE_CODE_ADDRESS, name, version).await,
        );
    }
    for address in model.addresses() {
        result.insert(
            format!("stake:{address}"),
            resource(client, address, "0x1::stake::StakePool", version).await,
        );
        result.insert(
            format!("ledger:{address}"),
            ledger_at(client, address, version).await,
        );
        result.insert(
            format!("pool:{address}"),
            json!(pool_at(client, address, version).await),
        );
    }
    result.insert(
        format!("delegation:{}", f.pool),
        resource(
            client,
            f.pool,
            "0x1::delegation_pool::DelegationPool",
            version,
        )
        .await,
    );
    for user in users {
        result.insert(
            format!("position:{}", user.address()),
            json!(position_at(client, user.address(), f.pool, version).await),
        );
    }
    result.insert(
        format!("position:{}", f.power_user.address()),
        json!(position_at(client, f.power_user.address(), f.pool, version).await),
    );
    result
}

async fn compare_all_nodes(
    f: &Fixture,
    model: &mut NetworkModel,
    users: &[LocalAccount],
    version: u64,
) {
    let installed = installed_at(&f.client, version).await;
    let expected = snapshot_data(f, &f.client, model, users, version).await;
    for validator in &installed.validators.active_validators {
        let client = f.client_for_member(validator.account_address);
        tokio::time::timeout(Duration::from_secs(30), client.wait_for_version(version))
            .await
            .expect("current validator did not catch up within 30 seconds")
            .unwrap();
        assert_eq!(installed_at(&client, version).await, installed);
        assert_eq!(
            snapshot_data(f, &client, model, users, version).await,
            expected,
            "same-version snapshot differs at validator {}",
            validator.account_address
        );
    }
    model.cross_node_comparisons += 1;
    model.record(format!(
        "snapshot epoch={} period={} version={version}",
        model.current_epoch, model.current_period
    ));
}

fn scheduled_native_bps(config: RunConfig, round: u64) -> Option<u64> {
    if config.rounds == 100 {
        match round {
            25 => Some(0),
            50 => Some(10_000),
            75 => Some(3_000),
            _ => None,
        }
    } else if config.rounds == 1000 && round % 100 == 0 {
        let tiers = [0, 1, 3_000, 5_000, 9_999, 10_000];
        Some(tiers[((round / 100 - 1) as usize) % tiers.len()])
    } else {
        None
    }
}

async fn run_reward_churn(config: RunConfig) {
    assert!(config.rounds > 0);
    assert!(config.users > 0);
    assert!(config.period_epochs > 0);
    assert!(config.sample_every > 0);
    let PreparedRun {
        mut fixture,
        mut model,
        mut power,
        users,
        started,
    } = prepare_run(config).await;
    let mut rng = DeterministicRng::new(config.seed);
    let mut pending_reactivations = VecDeque::new();
    let mut staged_through = 1;
    let main_final_epoch = model.current_epoch + config.rounds;

    for round in 1..=config.rounds {
        // A raw version is written only when its boundary occurs within this run.
        // This keeps the final drain free of unconsumed future checkpoint refs.
        if staged_through == model.current_period
            && expected_next_boundary(model.current_epoch, config.period_epochs)
                == model.current_epoch + 1
            && expected_next_boundary(model.current_epoch, config.period_epochs) <= main_final_epoch
        {
            stage_next_power_period(
                &fixture,
                &mut model,
                &mut power,
                &users,
                config.period_epochs,
            )
            .await;
            staged_through += 1;
        }

        while let Some(pending) = pending_reactivations.pop_front() {
            reactivate_stake(&fixture, &mut model, &users, pending).await;
        }

        let add_user = rng.index(users.len());
        let mut unlock_user = rng.index(users.len());
        while unlock_user == add_user {
            unlock_user = rng.index(users.len());
        }
        let mut allocation_user = rng.index(users.len());
        while allocation_user == add_user || allocation_user == unlock_user {
            allocation_user = rng.index(users.len());
        }

        let add_amount = 10 * OCTA + round % 7 + 1;
        add_stake(&fixture, &mut model, &users, add_user, add_amount).await;
        let ratios = [7_777, 3_333, 0, 10_000];
        set_allocation(
            &fixture,
            &mut model,
            &mut power,
            &users,
            allocation_user,
            ratios[((round - 1) as usize) % ratios.len()],
            config.period_epochs,
        )
        .await;

        if config.fill_fee_limit {
            fill_test_pool_fee_limit(&fixture, &users, &mut model).await;
        }
        if config.inject_failures && matches!(round, 20 | 60 | 80) {
            inject_mixed_proposals(&mut fixture, &users, &mut model).await;
        }

        let unlock_nominal = 11 * OCTA + round % 5 + 1;
        let unlocked =
            unlock_stake(&fixture, &mut model, &users, unlock_user, unlock_nominal).await;
        let force_maturity = round % 2 == 1;
        if force_maturity {
            wait_for_test_lock(&fixture, &model).await;
        }

        let previous_period = model.current_period;
        let scheduled_bps = scheduled_native_bps(config, round);
        let payload = if let Some(native_bps) = scheduled_bps {
            governance_payload(
                3,
                native_bps,
                fixture.owner.address(),
                config.enable_rate,
                FEE_LIMIT,
            )
        } else {
            governance_payload(2, 0, fixture.owner.address(), config.enable_rate, FEE_LIMIT)
        };
        let closed = close_epoch(
            &fixture,
            &mut model,
            &mut power,
            config.period_epochs,
            payload,
            force_maturity,
        )
        .await;
        if let Some(native_bps) = scheduled_bps {
            assert_eq!(model.native_bps, native_bps);
        }
        synchronize_test_pool(&fixture, &mut model, &users, &closed).await;
        if closed.test_matured {
            withdraw_matured(
                &fixture,
                &mut model,
                &users,
                users[unlock_user].address(),
                u64::MAX,
            )
            .await;
        } else {
            pending_reactivations.push_back(PendingReactivation {
                user: users[unlock_user].address(),
                amount: unlocked,
            });
        }

        let claim_interval = if config.rounds == 10 {
            3
        } else if config.rounds == 100 {
            7
        } else {
            50
        };
        if round % claim_interval == 0 {
            let claim_index = rng.index(users.len());
            claim_user(&fixture, &mut model, &users[claim_index]).await;
        }

        let boundary = model.current_period != previous_period;
        let sample = round % config.sample_every == 0 || boundary || round == config.rounds;
        if sample {
            let version = latest_version(&fixture.client).await;
            assert_test_shares(&fixture, &model.tested, &users, version).await;
            let actors = std::iter::once(&fixture.power_user)
                .chain(users.iter())
                .collect::<Vec<_>>();
            assert_positions(&fixture, &mut model, &actors, version).await;
            compare_all_nodes(&fixture, &mut model, &users, version).await;
        }
        println!(
            "PoC churn round={round}/{} epoch={} period={} next_boundary={} vault={} credited={} claimed={} pending_reactivation={} version={} elapsed={:?}",
            config.rounds,
            model.current_epoch,
            model.current_period,
            expected_next_boundary(model.current_epoch, config.period_epochs),
            model.tested.pool.vault,
            model.credited,
            model.claimed,
            pending_reactivations.len(),
            latest_version(&fixture.client).await,
            started.elapsed(),
        );
    }

    // Stop introducing changes.  Even-round pending stake is first restored, then
    // two clean closes prove that a stable epoch does not duplicate rewards.
    while let Some(pending) = pending_reactivations.pop_front() {
        reactivate_stake(&fixture, &mut model, &users, pending).await;
    }
    for drain in 1..=DRAIN_CLOSINGS {
        let closed = close_epoch(
            &fixture,
            &mut model,
            &mut power,
            config.period_epochs,
            governance_payload(2, 0, fixture.owner.address(), config.enable_rate, FEE_LIMIT),
            false,
        )
        .await;
        synchronize_test_pool(&fixture, &mut model, &users, &closed).await;
        assert!(!closed.test_matured || model.tested.pool.native[3] == 0);
        model.record(format!(
            "drain={drain} installed_epoch={} version={}",
            model.current_epoch, closed.version
        ));
    }

    // Claim every modeled position, including the legacy power owner that exited
    // at E61.  The latter consumes its old PositionChange/checkpoint reference.
    claim_user(&fixture, &mut model, &fixture.power_user).await;
    for user in &users {
        claim_user(&fixture, &mut model, user).await;
    }
    let zero_claim = claim_user(&fixture, &mut model, &users[0]).await;
    assert_eq!(zero_claim, 0, "repeat claim must emit no payment event");

    let final_version = latest_version(&fixture.client).await;
    assert_test_shares(&fixture, &model.tested, &users, final_version).await;
    let actors = std::iter::once(&fixture.power_user)
        .chain(users.iter())
        .collect::<Vec<_>>();
    let final_checkpoints = assert_positions(&fixture, &mut model, &actors, final_version).await;
    let final_ledger = ledger_at(&fixture.client, fixture.pool, final_version).await;
    assert_eq!(
        final_ledger["changes"],
        json!([]),
        "all matured position refs must be consumed by final claims"
    );
    assert_eq!(
        final_checkpoints, 0,
        "every checkpoint key in the configured reward window must be absent after final claims"
    );
    assert!(model
        .tested
        .positions
        .values()
        .all(|position| position.claimable == 0));
    assert_eq!(
        model.credited - model.claimed,
        model
            .addresses()
            .iter()
            .map(|address| model.pool(*address).vault)
            .sum::<u64>()
    );
    compare_all_nodes(&fixture, &mut model, &users, final_version).await;
    if config.inject_failures {
        assert!(
            model.mixed_proposal_pool_epochs >= 3,
            "three injected outages must yield at least three mixed pool-epochs"
        );
    }
    let elapsed = started.elapsed();
    if config.rounds == 10 {
        assert!(
            elapsed < Duration::from_secs(15 * 60),
            "10-round churn exceeded its 15-minute budget: {elapsed:?}"
        );
    }
    println!(
        "PoC reward churn complete: seed={:#x}, elapsed={elapsed:?}, final_version={final_version}, F={}, closing_range={}..={}, positive_pool_epochs={}, zero_pool_epochs={}, mixed_pool_epochs={}, split_totals(native,poc)={:?}, event_credited={}, event_claimed={}, final_network_vault={}, final_test_vault={}, active_dust={}, pending_dust={}, max_checkpoints={}, cross_node_comparisons={}",
        config.seed,
        model.first_poc_epoch,
        model.first_closing_epoch,
        model.last_closing_epoch,
        model.positive_epochs,
        model.zero_epochs,
        model.mixed_proposal_pool_epochs,
        model.split_totals,
        model.credited,
        model.claimed,
        model.credited - model.claimed,
        model.tested.pool.vault,
        model.tested.active.dust(),
        model.tested.pending_inactive.dust(),
        model.max_checkpoints,
        model.cross_node_comparisons,
    );
}

#[tokio::test]
async fn poc_reward_churn_10_epochs_exact() {
    run_reward_churn(RunConfig {
        rounds: 10,
        users: 10,
        period_epochs: 3,
        seed: 0x5EED_0010,
        sample_every: 1,
        fill_fee_limit: true,
        inject_failures: false,
        enable_rate: false,
    })
    .await;
}

#[tokio::test]
#[ignore = "nightly: 100-Epoch reward churn"]
async fn poc_reward_churn_100_epochs_seeded() {
    run_reward_churn(RunConfig {
        rounds: 100,
        users: 16,
        period_epochs: 3,
        seed: 0x5EED_0100,
        sample_every: 10,
        fill_fee_limit: false,
        inject_failures: true,
        enable_rate: true,
    })
    .await;
}

#[tokio::test]
#[ignore = "release soak: 1000-Epoch reward churn"]
async fn poc_reward_churn_1000_epochs_soak() {
    run_reward_churn(RunConfig {
        rounds: 1000,
        users: 32,
        period_epochs: 3,
        seed: 0x5EED_1000,
        sample_every: 50,
        fill_fee_limit: false,
        inject_failures: false,
        enable_rate: true,
    })
    .await;
}
