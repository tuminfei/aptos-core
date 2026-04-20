// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

use crate::{
    randomness::{
        decrypt_key_map, get_current_epoch, governance_gas_options, script_to_enable_main_logic,
        script_to_update_consensus_config, verify_dkg_transcript, wait_for_new_dkg_completion,
        wait_for_randomness_main_logic_enabled, wait_for_validator_txns_enabled,
    },
    smoke_test_environment::SwarmBuilder,
    utils::get_current_consensus_config,
};
use aptos_forge::{Node, Swarm, SwarmExt};
use aptos_logger::{debug, info};
use aptos_types::on_chain_config::OnChainRandomnessConfig;
use std::{sync::Arc, time::Duration};

/// Enable on-chain randomness in the following steps.
/// - Enable validator transactions in consensus config in epoch `e`.
/// - Enable randomness main logic in epoch `e + 1`.
#[tokio::test]
async fn enable_feature_1() {
    let epoch_duration_secs = 20;
    let estimated_dkg_latency_secs = 120;

    let (swarm, mut cli, _faucet) = SwarmBuilder::new_local(4)
        .with_num_fullnodes(1)
        .with_aptos()
        .with_init_genesis_config(Arc::new(move |conf| {
            conf.epoch_duration_secs = epoch_duration_secs;
            conf.allow_new_validators = true;

            // start with vtxn disabled and randomness off.
            conf.consensus_config.disable_validator_txns();
            conf.randomness_config_override = Some(OnChainRandomnessConfig::default_disabled());
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

    info!("Now in epoch 3. Enabling validator transactions.");
    let mut config = get_current_consensus_config(&client).await;
    config.enable_validator_txns();
    let enable_vtxn_script = script_to_update_consensus_config(&config);

    debug!("enable_vtxn_script={}", enable_vtxn_script);
    let txn_summary = cli
        .run_script_with_gas_options(root_idx, enable_vtxn_script.as_str(), Some(governance_gas.clone()))
        .await
        .expect("Txn execution error.");
    debug!("enabling_vtxn_summary={:?}", txn_summary);

    wait_for_validator_txns_enabled(&client, true, epoch_duration_secs * 4).await;
    let vtxn_effective_epoch = get_current_epoch(&client).await;
    info!(
        "Validator transactions became effective in epoch {}.",
        vtxn_effective_epoch
    );

    info!("Enabling randomness main logic.");
    let enable_main_logic_script = script_to_enable_main_logic();
    let txn_summary = cli
        .run_script_with_gas_options(root_idx, enable_main_logic_script.as_str(), Some(governance_gas))
        .await
        .expect("Txn execution error.");
    debug!("txn_summary={:?}", txn_summary);

    wait_for_randomness_main_logic_enabled(&client, true, epoch_duration_secs * 4).await;
    let fully_enabled_epoch = get_current_epoch(&client).await;
    info!(
        "Randomness and validator transactions are both effective in epoch {}.",
        fully_enabled_epoch
    );

    let dkg_session = wait_for_new_dkg_completion(
        &client,
        Some(fully_enabled_epoch + 1),
        None,
        epoch_duration_secs + estimated_dkg_latency_secs,
    )
    .await;

    assert!(
        dkg_session.target_epoch() > fully_enabled_epoch,
        "DKG target epoch {} should be newer than the epoch {} where both dependencies became effective",
        dkg_session.target_epoch(),
        fully_enabled_epoch
    );
    assert!(verify_dkg_transcript(&dkg_session, &decrypt_key_map).is_ok());
}
