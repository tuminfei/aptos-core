// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

use crate::{
    randomness::{
        decrypt_key_map, get_on_chain_resource_at_version, run_reconfiguration_script,
        script_to_enable_main_logic, script_to_update_consensus_config, verify_dkg_transcript,
        wait_for_epoch_start,
    },
    smoke_test_environment::SwarmBuilder,
    utils::get_current_consensus_config,
};
use aptos_forge::{Node, Swarm, SwarmExt};
use aptos_logger::{debug, info};
use aptos_types::{
    dkg::DKGState,
    on_chain_config::{OnChainChunkyDKGConfig, OnChainRandomnessConfig},
};
use std::{sync::Arc, time::Duration};

/// 先启用随机数主逻辑，再启用 validator 交易；以各自实际生效的 epoch 为准。
#[tokio::test]
async fn enable_feature_0() {
    let epoch_duration_secs = 20;
    let estimated_dkg_latency_secs = 40;
    let timeout = Duration::from_secs(epoch_duration_secs + estimated_dkg_latency_secs);

    let (swarm, mut cli, _faucet) = SwarmBuilder::new_local(4)
        .with_num_fullnodes(1)
        .with_aptos()
        .with_init_config(Arc::new(|_, config, _| {
            // 通过换届和首块事件定位断言快照，避免读取到后续 epoch 的状态。
            config.indexer_db_config.enable_event = true;
        }))
        .with_init_genesis_config(Arc::new(move |conf| {
            conf.epoch_duration_secs = epoch_duration_secs;
            conf.allow_new_validators = true;

            // start with vtxn disabled and randomness off.
            conf.consensus_config.disable_validator_txns();
            conf.randomness_config_override = Some(OnChainRandomnessConfig::default_disabled());
            // Chunky DKG depends on randomness + vtxns; keep it off here too.
            conf.chunky_dkg_config_override = Some(OnChainChunkyDKGConfig::default_disabled());
        }))
        .build_with_cli(0)
        .await;

    let root_addr = swarm.chain_info().root_account().address();
    let root_idx = cli.add_account_with_address_to_cli(swarm.root_key(), root_addr);

    let decrypt_key_map = decrypt_key_map(&swarm);

    let client_endpoint = swarm.validators().nth(1).unwrap().rest_api_endpoint();
    let client = aptos_rest_client::Client::new(client_endpoint.clone());

    swarm
        .wait_for_all_nodes_to_catchup_to_epoch(3, Duration::from_secs(epoch_duration_secs * 2))
        .await
        .expect("Waited too long for epoch 3.");

    info!("Enabling randomness main logic.");
    let enable_dkg_script = script_to_enable_main_logic();

    let epoch =
        run_reconfiguration_script(&swarm, &cli, root_idx, &client, &enable_dkg_script, timeout)
            .await;
    wait_for_epoch_start(&swarm, &client, epoch, timeout).await;

    info!("Randomness main logic activated in epoch {epoch}. Enabling validator transactions.");
    let mut config = get_current_consensus_config(&client).await;
    config.enable_validator_txns();
    let enable_vtxn_script = script_to_update_consensus_config(&config);
    debug!("enable_vtxn_script={}", enable_vtxn_script);
    let epoch = run_reconfiguration_script(
        &swarm,
        &cli,
        root_idx,
        &client,
        &enable_vtxn_script,
        timeout,
    )
    .await;
    let version = wait_for_epoch_start(&swarm, &client, epoch, timeout).await;

    // 依赖在该 epoch 才全部启用，上一 epoch 尚不能完成 DKG；结果应在下一 epoch 出现。
    info!(
        "Both dependencies activated in epoch {epoch}. No DKG result should exist for this epoch."
    );
    let maybe_last_complete = get_on_chain_resource_at_version::<DKGState>(&client, version)
        .await
        .last_completed;
    assert!(
        maybe_last_complete.is_none()
            || maybe_last_complete.as_ref().unwrap().target_epoch() != epoch
    );

    let target_epoch = epoch + 1;
    info!("Waiting for epoch {target_epoch}.");
    let version = wait_for_epoch_start(&swarm, &client, target_epoch, timeout).await;
    let dkg_session = get_on_chain_resource_at_version::<DKGState>(&client, version)
        .await
        .last_completed
        .expect("DKG result should be present after the first enabled epoch");
    assert_eq!(target_epoch, dkg_session.target_epoch());
    assert!(verify_dkg_transcript(&dkg_session, &decrypt_key_map).is_ok());
}
