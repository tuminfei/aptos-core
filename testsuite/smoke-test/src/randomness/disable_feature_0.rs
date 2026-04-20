// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

use crate::{
    randomness::{
        decrypt_key_map, get_current_epoch, governance_gas_options, script_to_disable_main_logic,
        verify_dkg_transcript, wait_for_epoch_at_least, wait_for_new_dkg_completion,
        wait_for_randomness_main_logic_enabled,
    },
    smoke_test_environment::SwarmBuilder,
    utils::get_on_chain_resource,
};
use aptos_forge::{Node, Swarm, SwarmExt};
use aptos_logger::{debug, info};
use aptos_types::{
    dkg::DKGState, on_chain_config::OnChainRandomnessConfig, randomness::PerBlockRandomness,
};
use std::{sync::Arc, time::Duration};

/// Disable on-chain randomness by only disabling randomness main logic.
#[tokio::test]
async fn disable_feature_0() {
    let epoch_duration_secs = 20;
    let estimated_dkg_latency_secs = 120;

    let (swarm, mut cli, _faucet) = SwarmBuilder::new_local(4)
        .with_num_fullnodes(1)
        .with_aptos()
        .with_init_genesis_config(Arc::new(move |conf| {
            conf.epoch_duration_secs = epoch_duration_secs;
            conf.allow_new_validators = true;

            // Ensure randomness is enabled.
            conf.consensus_config.enable_validator_txns();
            conf.randomness_config_override = Some(OnChainRandomnessConfig::default_enabled());
        }))
        .build_with_cli(0)
        .await;

    let root_addr = swarm.chain_info().root_account().address();
    let root_idx = cli.add_account_with_address_to_cli(swarm.root_key(), root_addr);
    let governance_gas = governance_gas_options();

    let decrypt_key_map = decrypt_key_map(&swarm);

    let client_endpoint = swarm.validators().nth(1).unwrap().rest_api_endpoint();
    let client = aptos_rest_client::Client::new(client_endpoint.clone());

    swarm
        .wait_for_all_nodes_to_catchup_to_epoch(3, Duration::from_secs(epoch_duration_secs * 2))
        .await
        .expect("Waited too long for epoch 3.");

    info!("Now in epoch 3. Disabling randomness main logic.");
    let previous_target_epoch = get_on_chain_resource::<DKGState>(&client)
        .await
        .last_completed
        .as_ref()
        .map(|session| session.target_epoch());
    let txn_summary = cli
        .run_script_with_gas_options(
            root_idx,
            script_to_disable_main_logic().as_str(),
            Some(governance_gas),
        )
        .await
        .expect("Txn execution error.");
    debug!("txn_summary={:?}", txn_summary);

    wait_for_randomness_main_logic_enabled(&client, false, epoch_duration_secs * 6).await;
    let disable_effective_epoch = get_current_epoch(&client).await;
    info!(
        "Randomness main logic became disabled in epoch {}.",
        disable_effective_epoch
    );

    let dkg_session = wait_for_new_dkg_completion(
        &client,
        Some(disable_effective_epoch),
        previous_target_epoch,
        epoch_duration_secs + estimated_dkg_latency_secs,
    )
    .await;
    assert!(verify_dkg_transcript(&dkg_session, &decrypt_key_map).is_ok());

    let randomness_seed = get_on_chain_resource::<PerBlockRandomness>(&client).await;
    assert!(randomness_seed.seed.is_none());

    wait_for_epoch_at_least(&client, disable_effective_epoch + 1, epoch_duration_secs * 4).await;

    info!("Checking that no newer DKG result is produced after randomness is disabled.");
    let maybe_last_complete = get_on_chain_resource::<DKGState>(&client)
        .await
        .last_completed
        .map(|session| session.target_epoch());
    assert_eq!(
        maybe_last_complete,
        Some(dkg_session.target_epoch()),
        "No additional DKG session should complete after randomness is disabled"
    );

    let randomness_seed = get_on_chain_resource::<PerBlockRandomness>(&client).await;
    assert!(randomness_seed.seed.is_none());
}
