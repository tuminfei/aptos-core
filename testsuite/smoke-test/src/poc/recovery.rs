// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

use super::defaults::{installed_at, strict_testnet_swarm, wait_for_initial_dkg};
use anyhow::{ensure, Context, Result};
use aptos_api_types::{Transaction, ViewRequest};
use aptos_cached_packages::aptos_stdlib;
use aptos_forge::{NodeExt, Swarm, SwarmExt};
use aptos_rest_client::{Client, State};
use aptos_types::{
    account_address::AccountAddress,
    account_config::CORE_CODE_ADDRESS,
    on_chain_config::{ConfigurationResource, OnChainConfig},
};
use serde_json::Value;
use std::{collections::BTreeMap, time::Duration};
use tokio::time::{sleep, timeout, timeout_at, Instant};

const REST_TIMEOUT: Duration = Duration::from_secs(5);
const RECOVERY_TIMEOUT: Duration = Duration::from_secs(90);
const CATCHUP_TIMEOUT: Duration = Duration::from_secs(30);
const STABILIZE_TIMEOUT: Duration = Duration::from_secs(30);
const STABLE_FOR: Duration = Duration::from_secs(5);
const OBSERVE_FOR: Duration = Duration::from_secs(30);
const POLL_INTERVAL: Duration = Duration::from_secs(1);

#[derive(Debug, PartialEq)]
struct RewardState {
    // 精确资源快照同时覆盖已安装分流、账本 Epoch 和标准化时钟。
    resources: Vec<Vec<u8>>,
    pools: Vec<Vec<Value>>,
    stakes: Vec<Vec<Value>>,
}

async fn view_at(
    client: &Client,
    function: &str,
    pool: AccountAddress,
    version: u64,
) -> Result<Vec<Value>> {
    Ok(client
        .view(
            &ViewRequest {
                function: function.parse()?,
                type_arguments: vec![],
                arguments: vec![serde_json::json!(pool.to_hex_literal())],
            },
            Some(version),
        )
        .await?
        .into_inner())
}

async fn rewards_at(
    client: &Client,
    pools: &[AccountAddress],
    version: u64,
) -> Result<RewardState> {
    timeout(REST_TIMEOUT, async {
        let mut resources = vec![];
        for resource in [
            "0x1::reconfiguration::Configuration",
            "0x1::stake::InstalledRewardContext",
            "0x1::poc_reward_split::RewardSplitConfig",
            "0x1::poc_accounting::AccountingState",
            "0x1::poc_power_store::PeriodClock",
        ] {
            resources.push(
                client
                    .get_account_resource_at_version_bytes(CORE_CODE_ADDRESS, resource, version)
                    .await?
                    .into_inner(),
            );
        }
        let mut pool_states = vec![];
        let mut stakes = vec![];
        for pool in pools {
            // 这些查询使用指定 Epoch 的逻辑 units，无需将表项主动落盘。
            pool_states
                .push(view_at(client, "0x1::poc_accounting::get_pool", *pool, version).await?);
            stakes.push(view_at(client, "0x1::stake::get_stake", *pool, version).await?);
        }
        Ok(RewardState {
            resources,
            pools: pool_states,
            stakes,
        })
    })
    .await
    .context("SYS-02 reward snapshot exceeded 5 seconds")?
}

async fn wait_for_fresh_epoch(client: &Client) -> Result<State> {
    let initial = client.get_ledger_information().await?.into_inner().epoch;
    timeout(RECOVERY_TIMEOUT, async {
        loop {
            let ledger = client.get_ledger_information().await?.into_inner();
            if ledger.epoch > initial {
                let configuration = client
                    .get_account_resource_at_version_bcs::<ConfigurationResource>(
                        CORE_CODE_ADDRESS,
                        &ConfigurationResource::struct_tag().to_canonical_string(),
                        ledger.version,
                    )
                    .await?
                    .into_inner();
                if ledger
                    .timestamp_usecs
                    .saturating_sub(configuration.last_reconfiguration_time_micros())
                    < 3_000_000
                {
                    return Ok(ledger);
                }
            }
            sleep(Duration::from_millis(200)).await;
        }
    })
    .await
    .context("SYS-02 could not observe the beginning of a new epoch within 90 seconds")?
}

async fn observe_quorum_loss(client: &Client, pools: &[AccountAddress]) -> Result<State> {
    let settling_started = Instant::now();
    let settled = timeout(STABILIZE_TIMEOUT, async {
        let mut previous = client.get_ledger_information().await?.into_inner();
        let mut unchanged_since = Instant::now();
        loop {
            sleep(POLL_INTERVAL).await;
            let ledger = client.get_ledger_information().await?.into_inner();
            ensure!(
                ledger.version >= previous.version,
                "Ledger version regressed after stopping a node"
            );
            if ledger.version != previous.version || ledger.epoch != previous.epoch {
                unchanged_since = Instant::now();
            } else if unchanged_since.elapsed() >= STABLE_FOR {
                return Ok::<_, anyhow::Error>(ledger);
            }
            previous = ledger;
        }
    })
    .await
    .context("SYS-02 in-flight commits did not stabilize within 30 seconds")??;
    println!(
        "SYS-02 settled: elapsed={:?}, epoch={}, version={}, unchanged_for={STABLE_FOR:?}",
        settling_started.elapsed(),
        settled.epoch,
        settled.version,
    );

    let expected = rewards_at(client, pools, settled.version).await?;
    let observation_started = Instant::now();
    timeout(OBSERVE_FOR + REST_TIMEOUT + POLL_INTERVAL, async {
        loop {
            let ledger = client.get_ledger_information().await?.into_inner();
            ensure!(
                (ledger.version, ledger.epoch, ledger.block_height, ledger.timestamp_usecs)
                    == (settled.version, settled.epoch, settled.block_height, settled.timestamp_usecs),
                "SYS-02 50% voting power committed during the stable observation window: before={settled:?}, after={ledger:?}",
            );
            ensure!(
                rewards_at(client, pools, ledger.version).await? == expected,
                "SYS-02 reward, stake or epoch state changed without quorum",
            );
            if observation_started.elapsed() >= OBSERVE_FOR {
                break;
            }
            sleep(POLL_INTERVAL).await;
        }
        Ok::<_, anyhow::Error>(())
    })
    .await
    .context("SYS-02 stable observation RPCs exceeded their time budget")??;
    println!(
        "SYS-02 no quorum: observed={:?}, epoch={}, version={}, no new rewards",
        observation_started.elapsed(),
        settled.epoch,
        settled.version,
    );
    Ok(settled)
}

fn number(value: &Value) -> Result<u64> {
    value
        .as_str()
        .context("Expected a Move integer string")?
        .parse()
        .context("Invalid Move u64")
}

/// 扫描完整的有界账本区间，包括提交 DKG 的验证者交易。
async fn verify_recovery_rewards(
    client: &Client,
    pools: &[AccountAddress],
    before: &State,
    after: &State,
    before_rewards: &RewardState,
    after_rewards: &RewardState,
) -> Result<()> {
    let mut credits = BTreeMap::new();
    let mut splits = BTreeMap::new();
    let mut installations = BTreeMap::new();
    let mut cursor = before.version + 1;
    while cursor <= after.version {
        let limit = (after.version - cursor + 1).min(100) as u16;
        let transactions = client
            .get_transactions(Some(cursor), Some(limit))
            .await?
            .into_inner();
        ensure!(
            !transactions.is_empty(),
            "Missing transactions at version {cursor}"
        );
        for transaction in transactions {
            ensure!(
                transaction.version() == Some(cursor),
                "Non-contiguous recovery transaction history at {cursor}"
            );
            cursor += 1;
            let events = match &transaction {
                Transaction::UserTransaction(transaction) => &transaction.events,
                Transaction::BlockMetadataTransaction(transaction) => &transaction.events,
                Transaction::GenesisTransaction(transaction) => &transaction.events,
                Transaction::ValidatorTransaction(transaction) => transaction.events(),
                Transaction::StateCheckpointTransaction(_)
                | Transaction::BlockEpilogueTransaction(_) => continue,
                Transaction::PendingTransaction(_) => {
                    anyhow::bail!("Pending transaction in committed ledger history")
                },
            };
            for event in events {
                let event_type = event.typ.to_string();
                if event_type.ends_with("::stake::PoCEpochInstalled") {
                    let epoch = number(&event.data["epoch"])?;
                    ensure!(
                        installations.insert(epoch, cursor - 1).is_none(),
                        "Epoch {epoch} installed more than once"
                    );
                } else if event_type.ends_with("::stake::PoCRewardCredited")
                    || event_type.ends_with("::stake::PoCRewardSplit")
                {
                    let epoch = number(&event.data["closing_epoch"])?;
                    let pool = AccountAddress::from_hex_literal(
                        event.data["pool"].as_str().context("Missing reward pool")?,
                    )?;
                    let records = if event_type.ends_with("::stake::PoCRewardCredited") {
                        &mut credits
                    } else {
                        &mut splits
                    };
                    ensure!(
                        records.insert((epoch, pool), event.data.clone()).is_none(),
                        "Duplicate {event_type} for pool {pool} in closing epoch {epoch}"
                    );
                }
            }
        }
    }
    let epochs = after.epoch - before.epoch;
    ensure!(epochs > 0, "Recovery did not install another epoch");
    ensure!(
        installations.len() as u64 == epochs,
        "Missing or unexpected epoch installation events"
    );
    ensure!(
        credits.len() as u64 == epochs * pools.len() as u64,
        "Missing or unexpected reward credits"
    );
    ensure!(splits.len() == credits.len(), "Missing reward split events");
    for (index, pool) in pools.iter().enumerate() {
        let mut poc_total = 0_u128;
        let mut native_total = 0_u128;
        for epoch in before.epoch..after.epoch {
            ensure!(
                installations.contains_key(&(epoch + 1)),
                "Epoch {} was not installed",
                epoch + 1
            );
            let credit = credits
                .get(&(epoch, *pool))
                .context("Missing per-pool epoch credit")?;
            let split = splits
                .get(&(epoch, *pool))
                .context("Missing per-pool epoch split")?;
            let inflation = number(&split["total_inflation_octa"])? as u128;
            let native = number(&split["active_native_reward_octa"])? as u128
                + number(&split["pending_inactive_native_reward_octa"])? as u128;
            let poc = number(&credit["inflation"])? as u128;
            ensure!(
                number(&split["native_reward_bps"])? == 3000,
                "Default native split changed"
            );
            ensure!(
                native == inflation * 3000 / 10000,
                "Incorrect native inflation split"
            );
            ensure!(
                poc == number(&split["poc_inflation_octa"])? as u128 && poc + native == inflation,
                "Inflation split is not conserved"
            );
            ensure!(
                number(&credit["fee"])? == 0,
                "T2-F installed fee limit must remain zero"
            );
            poc_total += poc;
            native_total += native;
        }
        ensure!(
            before_rewards.pools[index].len() == 5 && after_rewards.pools[index].len() == 5,
            "Unexpected pool view layout"
        );
        ensure!(
            number(&after_rewards.pools[index][3])? as u128
                == number(&before_rewards.pools[index][3])? as u128 + poc_total,
            "Pool {pool} vault delta differs from its unique epoch credits",
        );
        let total_stake = |values: &[Value]| -> Result<u128> {
            ensure!(values.len() == 4, "Unexpected native stake view layout");
            values
                .iter()
                .try_fold(0_u128, |sum, value| Ok(sum + number(value)? as u128))
        };
        ensure!(
            total_stake(&after_rewards.stakes[index])?
                == total_stake(&before_rewards.stakes[index])? + native_total,
            "Pool {pool} native balance delta differs from its unique epoch rewards",
        );
        println!("SYS-02 rewards: pool={pool}, closing_epochs={}..{}, poc={poc_total}, native={native_total}", before.epoch, after.epoch);
    }
    Ok(())
}

/// SYS-02 / T2-F：保留原生默认值，稳定失去 quorum 满 30 秒后再恢复。
#[tokio::test]
async fn poc_testnet_two_nodes_quorum_loss_and_recovery() -> Result<()> {
    let startup = Instant::now();
    let mut swarm = strict_testnet_swarm(10).await;
    println!("SYS-02 node startup: {:?}", startup.elapsed());
    let identities = swarm
        .validators()
        .map(|node| node.peer_id())
        .collect::<Vec<_>>();
    ensure!(
        identities.len() == 2,
        "T2-F requires exactly two validators"
    );
    let client = swarm
        .validator(identities[0])
        .unwrap()
        .rest_client_with_timeout(REST_TIMEOUT);
    let initialization = Instant::now();
    wait_for_initial_dkg(&client).await?;
    println!(
        "SYS-02 initial ordinary/Chunky DKG: {:?}",
        initialization.elapsed()
    );

    let before = wait_for_fresh_epoch(&client).await?;
    let installed = installed_at(&client, before.version).await;
    ensure!(
        installed.epoch == before.epoch,
        "Installed snapshot epoch differs from the ledger"
    );
    ensure!(
        installed.reward_context.1
            && installed.reward_context.5 == 0
            && number(&installed.reward_split["installed_native_reward_bps"])? == 3000,
        "SYS-02 stopped epoch must retain PoC, zero fee limit and the default reward split",
    );
    let validators = &installed.validators.active_validators;
    ensure!(
        validators.len() == 2,
        "Installed committee is not two validators"
    );
    let powers = validators
        .iter()
        .map(|validator| validator.consensus_voting_power())
        .collect::<Vec<_>>();
    ensure!(
        powers[0] > 0 && powers[0] == powers[1],
        "SYS-02 requires actual equal installed weights: {powers:?}"
    );
    ensure!(
        installed.validators.total_voting_power == 2 * powers[0] as u128,
        "Unexpected total voting power"
    );
    ensure!(
        installed.validators.total_joining_power == 0,
        "Unexpected pending committee members"
    );
    let pools = validators
        .iter()
        .map(|validator| validator.account_address)
        .collect::<Vec<_>>();
    ensure!(
        identities.iter().all(|identity| pools.contains(identity)),
        "Swarm identities differ from the installed committee"
    );
    let before_rewards = rewards_at(&client, &pools, before.version).await?;
    let stop_ledger = client.get_ledger_information().await?.into_inner();
    ensure!(
        stop_ledger.epoch == before.epoch
            && stop_ledger
                .timestamp_usecs
                .saturating_sub(before.timestamp_usecs)
                < 2_000_000,
        "SYS-02 setup missed the start of the observed epoch before stopping a node",
    );
    println!(
        "SYS-02 stop: epoch={}, version={}, pools={pools:?}, installed_powers={powers:?}",
        before.epoch, before.version
    );
    let stopped_at = Instant::now();
    swarm.validator_mut(identities[1]).unwrap().stop();
    let observation = observe_quorum_loss(&client, &pools).await;

    // 即使观察或 RPC 失败，也始终尝试恢复已停止的进程。
    let recovery_started = Instant::now();
    let restart = swarm.validator_mut(identities[1]).unwrap().start();
    println!(
        "SYS-02 restart requested after {:?} offline; result={restart:?}",
        stopped_at.elapsed()
    );
    let settled =
        observation.context("SYS-02 no-quorum observation failed; node restart was attempted")?;
    restart.context("SYS-02 could not restart the stopped validator")?;

    let recovery_deadline = recovery_started + RECOVERY_TIMEOUT;
    let chain = swarm.chain_info();
    let signed = chain.root_account().sign_with_transaction_builder(
        chain
            .transaction_factory()
            .with_gas_unit_price(1)
            .with_max_gas_amount(2_000_000)
            .with_transaction_expiration_time(120)
            .payload(aptos_stdlib::topo_coin_transfer(identities[1], 1_000)),
    );
    let transfer = timeout_at(recovery_deadline, client.submit_and_wait(&signed))
        .await
        .context("SYS-02 recovery transfer exceeded the 90-second recovery budget")??
        .into_inner();
    let Transaction::UserTransaction(transfer) = transfer else {
        anyhow::bail!("SYS-02 recovery transfer did not return a committed user transaction");
    };
    ensure!(
        transfer.info.success,
        "Recovery transfer failed: {}",
        transfer.info.vm_status
    );
    ensure!(
        transfer.info.gas_used.0 > 0,
        "Recovery transfer did not pay gas"
    );
    println!(
        "SYS-02 recovery transfer: elapsed={:?}, version={}, gas={}",
        recovery_started.elapsed(),
        transfer.info.version.0,
        transfer.info.gas_used.0,
    );
    let after_transfer = client.get_ledger_information().await?.into_inner();
    let after = timeout_at(recovery_deadline, async {
        loop {
            let ledger = client.get_ledger_information().await?.into_inner();
            if ledger.epoch > after_transfer.epoch {
                return Ok::<_, anyhow::Error>(ledger);
            }
            sleep(POLL_INTERVAL).await;
        }
    })
    .await
    .context("SYS-02 post-transfer epoch did not install within the 90-second recovery budget")??;
    ensure!(
        after.version > settled.version && after.epoch > settled.epoch,
        "Recovery did not resume commits and epoch installation"
    );
    println!(
        "SYS-02 recovery epoch: elapsed={:?}, epoch={}, version={}",
        recovery_started.elapsed(),
        after.epoch,
        after.version
    );

    let catchup_started = Instant::now();
    timeout(
        CATCHUP_TIMEOUT,
        swarm.wait_for_all_nodes_to_catchup_to_version(after.version, CATCHUP_TIMEOUT),
    )
    .await
    .context("SYS-02 same-version catchup exceeded 30 seconds")??;
    let expected = installed_at(&client, after.version).await;
    ensure!(
        expected.epoch == after.epoch,
        "Recovered snapshot epoch differs from the ledger"
    );
    ensure!(
        expected.reward_context.1
            && expected.reward_context.5 == 0
            && number(&expected.reward_split["installed_native_reward_bps"])? == 3000
            && number(&expected.reward_split["configured_native_reward_bps"])? == 3000
            && expected.reward_split["pending_change"] == serde_json::json!({ "vec": [] }),
        "Recovery changed the PoC mode, installed fee limit or default reward split",
    );
    ensure!(
        expected
            .validators
            .active_validators
            .iter()
            .map(|validator| validator.account_address)
            .collect::<Vec<_>>()
            == pools,
        "Recovery changed the committee members or their order",
    );
    let recovered_power = expected.validators.active_validators[0].consensus_voting_power();
    ensure!(
        recovered_power > 0
            && expected.validators.active_validators[1].consensus_voting_power() == recovered_power
            && expected.validators.total_voting_power == 2 * recovered_power as u128
            && expected.validators.total_joining_power == 0
            && expected.validators.pending_active.is_empty()
            && expected.validators.pending_inactive.is_empty(),
        "Recovery did not retain the two equal installed weights",
    );
    let after_rewards = rewards_at(&client, &pools, after.version).await?;
    for node in swarm.validators() {
        let node_client = node.rest_client_with_timeout(REST_TIMEOUT);
        ensure!(
            installed_at(&node_client, after.version).await == expected,
            "Restored committee, reward context or split snapshot diverged at version {}",
            after.version
        );
        ensure!(
            rewards_at(&node_client, &pools, after.version).await? == after_rewards,
            "Restored reward balances diverged at version {}",
            after.version
        );
    }
    println!(
        "SYS-02 same-version catchup: {:?}",
        catchup_started.elapsed()
    );
    timeout(
        CATCHUP_TIMEOUT,
        verify_recovery_rewards(
            &client,
            &pools,
            &before,
            &after,
            &before_rewards,
            &after_rewards,
        ),
    )
    .await
    .context("SYS-02 recovery event audit exceeded 30 seconds")??;
    Ok(())
}
