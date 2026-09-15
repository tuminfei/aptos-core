// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

use crate::{
    randomness::{
        decrypt_key_map, get_on_chain_resource_at_version, run_reconfiguration_script,
        script_to_disable_main_logic, verify_dkg_transcript, wait_for_epoch_start,
    },
    smoke_test_environment::SwarmBuilder,
};
use aptos_forge::{Node, Swarm, SwarmExt};
use aptos_logger::info;
use aptos_types::{
    dkg::DKGState,
    on_chain_config::{OnChainChunkyDKGConfig, OnChainRandomnessConfig},
    randomness::PerBlockRandomness,
};
use std::{sync::Arc, time::Duration};

/// 仅关闭随机数主逻辑，验证实际生效 epoch 及下一 epoch 的 DKG 和种子状态。
#[tokio::test]
async fn disable_feature_0() {
    let epoch_duration_secs = 20;
    let timeout = Duration::from_secs(epoch_duration_secs * 2);

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

            // Ensure randomness is enabled.
            conf.consensus_config.enable_validator_txns();
            conf.randomness_config_override = Some(OnChainRandomnessConfig::default_enabled());
            // This test disables randomness mid-run; chunky DKG depends on it,
            // so keep chunky DKG off to avoid stalling epoch transitions.
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

    info!("Disabling randomness main logic.");
    let epoch = run_reconfiguration_script(
        &swarm,
        &cli,
        root_idx,
        &client,
        &script_to_disable_main_logic(),
        timeout,
    )
    .await;
    let version = wait_for_epoch_start(&swarm, &client, epoch, timeout).await;

    // 依赖在换届完成后关闭，保留最后一份 DKG 结果；新 epoch 首块的随机数种子应为空。
    info!("Randomness disabled in epoch {epoch}. The final DKG transcript should still be available, but the seed should be absent.");
    let dkg_session = get_on_chain_resource_at_version::<DKGState>(&client, version)
        .await
        .last_completed
        .expect("The final DKG result should be present when randomness is disabled");
    assert_eq!(epoch, dkg_session.target_epoch());
    assert!(verify_dkg_transcript(&dkg_session, &decrypt_key_map).is_ok());

    let randomness_seed =
        get_on_chain_resource_at_version::<PerBlockRandomness>(&client, version).await;
    assert_eq!(epoch, randomness_seed.epoch);
    assert!(randomness_seed.seed.is_none());

    // 下一 epoch 不应生成新的 DKG 结果，但允许保留历史 last_completed。
    let next_epoch = epoch + 1;
    let version = wait_for_epoch_start(&swarm, &client, next_epoch, timeout).await;

    info!("In epoch {next_epoch}, no new DKG transcript or randomness seed should be available.");
    let maybe_last_complete = get_on_chain_resource_at_version::<DKGState>(&client, version)
        .await
        .last_completed;
    assert!(
        maybe_last_complete.is_none()
            || maybe_last_complete.as_ref().unwrap().target_epoch() != next_epoch
    );

    let randomness_seed =
        get_on_chain_resource_at_version::<PerBlockRandomness>(&client, version).await;
    assert_eq!(next_epoch, randomness_seed.epoch);
    assert!(randomness_seed.seed.is_none());
}
