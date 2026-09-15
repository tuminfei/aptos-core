// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

use super::shadow_mode::create_swarm_with_dkg_only;
use crate::{randomness::run_reconfiguration_script, utils::get_on_chain_resource};
use aptos_api_types::Transaction;
use aptos_forge::{Node, NodeExt, SwarmExt};
use aptos_logger::info;
use aptos_rest_client::Client;
use aptos_types::dkg::chunky_dkg::ChunkyDKGState;
use std::time::Duration;

const FORCE_END_EVENT_TYPE: &str = "0x1::reconfiguration_with_dkg::ForceEndEpochEvent";

/// Scan transactions from `start_version` forward, returning the first
/// `ForceEndEpochEvent` payload as JSON (or `None` if not found within
/// `max_txns` transactions).
async fn find_force_end_event(
    client: &Client,
    start_version: u64,
    max_txns: u64,
) -> Option<serde_json::Value> {
    const PAGE: u16 = 100;
    // 固定本次扫描的账本上界，并限制最后一页大小，避免请求尚不存在的交易版本。
    let end_version = client
        .get_ledger_information()
        .await
        .expect("ledger info")
        .into_inner()
        .version;
    let mut cursor = start_version;
    let mut scanned: u64 = 0;
    while scanned < max_txns && cursor <= end_version {
        let limit = (PAGE as u64)
            .min(max_txns - scanned)
            .min(end_version - cursor + 1) as u16;
        let txns = client
            .get_transactions(Some(cursor), Some(limit))
            .await
            .expect("get_transactions")
            .into_inner();
        if txns.is_empty() {
            return None;
        }
        for txn in &txns {
            let events = match txn {
                Transaction::UserTransaction(t) => &t.events,
                Transaction::BlockMetadataTransaction(t) => &t.events,
                Transaction::GenesisTransaction(t) => &t.events,
                Transaction::StateCheckpointTransaction(_) => continue,
                Transaction::BlockEpilogueTransaction(_) => continue,
                Transaction::ValidatorTransaction(t) => t.events(),
                Transaction::PendingTransaction(_) => continue,
            };
            for ev in events {
                if ev.typ.to_string() == FORCE_END_EVENT_TYPE {
                    return Some(ev.data.clone());
                }
            }
        }
        let last_version = txns
            .last()
            .and_then(|t| t.version())
            .expect("transaction has version");
        cursor = last_version + 1;
        scanned += txns.len() as u64;
    }
    None
}

/// 生成同时启用 Chunky DKG V1 和短宽限期 watchdog 的治理脚本。
/// 提交及生效 epoch 的确认由公共重配置辅助函数处理。
fn script_to_enable_chunky_v1_and_watchdog(watchdog_grace_period_secs: u64) -> String {
    format!(
        r#"
script {{
    use topo_std::fixed_point64;
    use topo_framework::topo_governance;
    use topo_framework::chunky_dkg_config;
    use topo_framework::epoch_timeout_config;
    use topo_framework::features;

    fun main(core_resources: &signer) {{
        let framework_signer = topo_governance::get_signer_testnet_only(core_resources, @0x1);

        // Chunky DKG V1 (real, no shadow grace).
        let chunky_cfg = chunky_dkg_config::new_v1(
            fixed_point64::create_from_rational(1, 2),
            fixed_point64::create_from_rational(2, 3),
        );
        chunky_dkg_config::set_for_next_epoch(&framework_signer, chunky_cfg);

        // Epoch watchdog: force-end after `n` seconds of stalled reconfig.
        let timeout_cfg = epoch_timeout_config::new_with_grace_period({});
        epoch_timeout_config::set_for_next_epoch(&framework_signer, timeout_cfg);

        // ENCRYPTED_TRANSACTIONS feature flag (108) — required for chunky DKG path.
        features::change_feature_flags_for_next_epoch(&framework_signer, vector[108], vector[]);

        topo_governance::reconfigure(&framework_signer);
    }}
}}
"#,
        watchdog_grace_period_secs
    )
}

/// Test that the general epoch-timeout watchdog force-ends the epoch when
/// chunky DKG is stalled and there is no chunky shadow grace period.
///
/// Strategy:
/// 1. Bring up a swarm with DKG enabled (chunky DKG OFF).
/// 2. Activate a failpoint that makes chunky DKG ignore its start event.
/// 3. Via governance, enable chunky V1 (no shadow grace) AND set the
///    epoch-timeout watchdog with a short grace period.
/// 4. Verify epochs continue advancing — only possible because the watchdog
///    force-finalizes the in-progress reconfig.
#[tokio::test]
async fn epoch_timeout_watchdog_force_ends_epoch() {
    let epoch_duration_secs = 20;
    let watchdog_grace_period_secs = 30;

    let (swarm, cli, root_idx) = create_swarm_with_dkg_only(4, epoch_duration_secs).await;
    let client_endpoint = swarm.validators().nth(1).unwrap().rest_api_endpoint();
    let client = aptos_rest_client::Client::new(client_endpoint);

    swarm
        .wait_for_all_nodes_to_catchup_to_epoch(2, Duration::from_secs(epoch_duration_secs * 3))
        .await
        .expect("Waited too long for epoch 2.");

    let ledger_before = client
        .get_ledger_information()
        .await
        .expect("ledger info")
        .into_inner();
    let epoch_before = ledger_before.epoch;
    let version_before = ledger_before.version;
    info!(
        "Network stable at epoch {} (version {})",
        epoch_before, version_before
    );

    // Stall chunky DKG on all validators before enabling it.
    info!("Activating chunky_dkg::process_dkg_start_event failpoint on all validators...");
    for validator in swarm.validators() {
        validator
            .rest_client()
            .set_failpoint(
                "chunky_dkg::process_dkg_start_event".to_string(),
                "return".to_string(),
            )
            .await
            .expect("Failed to set failpoint");
    }

    info!(
        "Enabling chunky V1 + epoch watchdog (grace={}s) via governance...",
        watchdog_grace_period_secs
    );
    let activation_epoch = run_reconfiguration_script(
        &swarm,
        &cli,
        root_idx,
        &client,
        &script_to_enable_chunky_v1_and_watchdog(watchdog_grace_period_secs),
        Duration::from_secs(epoch_duration_secs * 3),
    )
    .await;

    // 从配置实际生效的 epoch 起验证下一次换届，避免脚本编译期间自然换届导致目标偏移。
    // 此时 DKG 已被故障注入阻塞，必须由 watchdog 推进到下一 epoch。
    let target_epoch = activation_epoch + 1;
    let time_limit_secs = epoch_duration_secs * 2 + watchdog_grace_period_secs + 60;
    let timer = tokio::time::Instant::now();
    let mut reached_target = false;

    info!(
        "Waiting for epoch to reach {} (stuck chunky DKG, watchdog should force-end)...",
        target_epoch
    );
    while timer.elapsed().as_secs() < time_limit_secs {
        let ledger = client
            .get_ledger_information()
            .await
            .expect("ledger info")
            .into_inner();
        let dkg_state = get_on_chain_resource::<ChunkyDKGState>(&client).await;
        info!(
            "epoch={} chunky_in_progress={} chunky_completed={} elapsed={}s",
            ledger.epoch,
            dkg_state.in_progress.is_some(),
            dkg_state.last_completed.is_some(),
            timer.elapsed().as_secs(),
        );
        if ledger.epoch >= target_epoch {
            reached_target = true;
            break;
        }
        tokio::time::sleep(Duration::from_secs(5)).await;
    }

    assert!(
        reached_target,
        "Epoch did not advance past {} within {}s — watchdog did not fire as expected",
        target_epoch, time_limit_secs,
    );

    let dkg_state = get_on_chain_resource::<ChunkyDKGState>(&client).await;
    assert!(
        dkg_state.last_completed.is_none(),
        "Chunky DKG should not have completed (failpoint blocks it)"
    );

    // Critical: assert the watchdog actually fired. Without this, the test would
    // pass even if some other finalization path advanced the epoch.
    info!(
        "Scanning for ForceEndEpochEvent from version {}...",
        version_before
    );
    let event_data = find_force_end_event(&client, version_before, 50_000)
        .await
        .expect(
            "ForceEndEpochEvent not found in transactions after watchdog deadline — \
             epoch advanced through some path other than the watchdog",
        );
    info!("Found ForceEndEpochEvent: {}", event_data);
    let variant = event_data
        .get("__variant__")
        .and_then(|v| v.as_str())
        .unwrap_or_else(|| panic!("missing __variant__: {}", event_data));
    assert_eq!(
        variant, "V1",
        "unexpected ForceEndEpochEvent variant: {}",
        event_data,
    );
    let chunky_incomplete = event_data
        .get("chunky_incomplete")
        .and_then(|v| v.as_bool())
        .unwrap_or_else(|| panic!("missing/non-bool chunky_incomplete: {}", event_data));
    assert!(
        chunky_incomplete,
        "ForceEndEpochEvent.chunky_incomplete should be true (chunky DKG was stalled): {}",
        event_data,
    );

    info!("Watchdog force-ended the epoch despite stalled chunky DKG");
}
