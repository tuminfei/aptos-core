// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

use crate::utils;
use anyhow::{anyhow, ensure, Result};
use aptos::{common::types::GasOptions, test::CliTestFramework};
use aptos_crypto::{compat::Sha3_256, Uniform};
use aptos_dkg::weighted_vuf::traits::WeightedVUF;
use aptos_forge::{LocalSwarm, SwarmExt};
use aptos_logger::info;
use aptos_rest_client::Client;
use aptos_types::{
    dkg::{DKGSessionState, DKGState, DKGTrait, DefaultDKG},
    on_chain_config::{ConfigurationResource, OnChainConfig, OnChainConsensusConfig},
    randomness::{PerBlockRandomness, RandMetadata, WVUF},
    validator_verifier::ValidatorConsensusInfo,
};
use digest::Digest;
use move_core_types::{account_address::AccountAddress, language_storage::CORE_CODE_ADDRESS};
use rand::{prelude::StdRng, SeedableRng};
use std::{collections::HashMap, time::Duration};
use tokio::time::Instant;

mod disable_feature_0;
mod disable_feature_1;
mod dkg_with_validator_down;
mod dkg_with_validator_join_leave;
mod e2e_basic_consumption;
mod e2e_correctness;
mod enable_feature_0;
mod enable_feature_1;
mod enable_feature_2;
mod entry_func_attrs;
mod optimistic_verification;
mod randomness_stall_recovery;
mod validator_restart_during_dkg;

#[allow(dead_code)]
async fn get_current_version(rest_client: &Client) -> u64 {
    rest_client
        .get_ledger_information()
        .await
        .unwrap()
        .inner()
        .version
}

/// 按指定版本读取历史资源，让多个断言使用同一账本快照。
#[allow(dead_code)]
async fn get_on_chain_resource_at_version<T: OnChainConfig>(
    rest_client: &Client,
    version: u64,
) -> T {
    let maybe_response = rest_client
        .get_account_resource_at_version_bcs::<T>(
            CORE_CODE_ADDRESS,
            T::struct_tag().to_canonical_string().as_str(),
            version,
        )
        .await;
    let response = maybe_response.unwrap();
    response.into_inner()
}

/// 提交治理脚本并返回缓冲配置实际生效的 epoch；脚本编译期间可能发生自然换届。
pub(crate) async fn run_reconfiguration_script(
    swarm: &LocalSwarm,
    cli: &CliTestFramework,
    root_idx: usize,
    client: &Client,
    script: &str,
    timeout: Duration,
) -> u64 {
    let mut retries = 0;
    let summary = loop {
        // 显式 gas 上限跳过 CLI 模拟估算，让配置冻结错误在实际提交后统一处理。
        match cli
            .run_script_with_gas_options(
                root_idx,
                script,
                Some(GasOptions {
                    gas_unit_price: Some(1),
                    max_gas: Some(2_000_000),
                    expiration_secs: 60,
                }),
            )
            .await
        {
            Ok(summary) => break summary,
            Err(error)
                if retries < 2
                    && error
                        .to_string()
                        .contains("0x1::reconfiguration_state: ERECONFIGURATION_IN_PROGRESS(") =>
            {
                // 脚本编译可能跨过自然换届边界；仅重试配置冻结这一明确的 Move abort。
                // 最多额外重试两次，其他错误直接暴露给测试。
                retries += 1;
                info!("Configuration is frozen; retrying governance script ({retries}/2)");
                let epoch = client
                    .get_ledger_information()
                    .await
                    .expect("Failed to fetch the reconfiguration epoch")
                    .into_inner()
                    .epoch;
                // 等待当前换届真正完成，避免在 DKG 仍冻结配置时再次提交。
                swarm
                    .wait_for_all_nodes_to_catchup_to_epoch(epoch + 1, timeout)
                    .await
                    .expect("In-progress reconfiguration did not finish before retrying");
            },
            Err(error) => panic!("Reconfiguration transaction failed: {error}"),
        }
    };
    let version = summary.version.expect("Missing reconfiguration version");
    swarm
        .wait_for_all_nodes_to_catchup_to_version(version, timeout)
        .await
        .expect("Nodes did not catch up to the reconfiguration transaction");

    // 以治理交易执行前的 epoch 为准，其中已包含同块 prologue 的影响。
    // 缓冲配置在下一 epoch 生效，兼容同步换届和等待 DKG 完成的路径。
    get_on_chain_resource_at_version::<ConfigurationResource>(client, version - 1)
        .await
        .epoch()
        + 1
}

/// 返回目标 epoch 的首块版本，让断言固定读取该时刻的状态，避免后续换届干扰。
/// 客户端所连接的节点必须启用事件索引。
async fn wait_for_epoch_start(
    swarm: &LocalSwarm,
    client: &Client,
    epoch: u64,
    timeout: Duration,
) -> u64 {
    swarm
        .wait_for_all_nodes_to_catchup_to_epoch(epoch, timeout)
        .await
        .expect("Nodes did not reach the expected epoch");
    tokio::time::timeout(timeout, async {
        let epoch_version = loop {
            // 创世 epoch 1 对应事件序号 0，按目标 epoch 定位换届事件。
            let events = client
                .get_account_events_bcs(
                    CORE_CODE_ADDRESS,
                    &ConfigurationResource::struct_tag().to_canonical_string(),
                    "events",
                    Some(epoch - 1),
                    Some(1),
                )
                .await
                .expect("Failed to fetch the epoch event")
                .into_inner();
            if let Some(event) = events.first() {
                break event.transaction_version;
            }
            tokio::time::sleep(Duration::from_millis(200)).await;
        };
        let closing_block = client
            .get_block_by_version_bcs(epoch_version, false)
            .await
            .expect("Failed to fetch the epoch-ending block")
            .into_inner();
        loop {
            // 换届事件位于上一 epoch 的收尾块；随机数要到新 epoch 的首块才会更新。
            let blocks = client
                .get_new_block_events_bcs(Some(closing_block.block_height + 1), Some(1))
                .await
                .expect("Failed to fetch the first block of the epoch")
                .into_inner();
            if let Some(block) = blocks.first() {
                assert_eq!(block.event.epoch(), epoch);
                return block.version;
            }
            tokio::time::sleep(Duration::from_millis(200)).await;
        }
    })
    .await
    .expect("Timed out waiting for the epoch's first block to be indexed")
}

/// Poll the on-chain state until we see a DKG session finishes.
/// Return a `DKGSessionState` of the DKG session seen.
#[allow(dead_code)]
async fn wait_for_dkg_finish(
    client: &Client,
    target_epoch: Option<u64>,
    time_limit_secs: u64,
) -> DKGSessionState {
    let mut dkg_state = utils::get_on_chain_resource::<DKGState>(client).await;
    let timer = Instant::now();
    while timer.elapsed().as_secs() < time_limit_secs
        && !(dkg_state.in_progress.is_none()
            && dkg_state.last_completed.is_some()
            && (target_epoch.is_none()
                || dkg_state
                    .last_completed
                    .as_ref()
                    .map(|session| session.metadata.dealer_epoch + 1)
                    == target_epoch))
    {
        tokio::time::sleep(Duration::from_secs(1)).await;
        dkg_state = utils::get_on_chain_resource::<DKGState>(client).await;
    }
    assert!(timer.elapsed().as_secs() < time_limit_secs);
    dkg_state.last_complete().clone()
}

/// Verify that DKG transcript of epoch i (stored in `new_dkg_state`) is correctly generated
/// by the validator set in epoch i-1 (stored in `new_dkg_state`).
fn verify_dkg_transcript(
    dkg_session: &DKGSessionState,
    decrypt_key_map: &HashMap<AccountAddress, <DefaultDKG as DKGTrait>::NewValidatorDecryptKey>,
) -> Result<()> {
    info!(
        "Verifying the transcript generated in epoch {}.",
        dkg_session.metadata.dealer_epoch,
    );
    let pub_params = DefaultDKG::new_public_params(&dkg_session.metadata);
    let transcript = bcs::from_bytes(dkg_session.transcript.as_slice()).map_err(|e| {
        anyhow!("DKG transcript verification failed with transcript deserialization error: {e}")
    })?;
    println!("transcript={:?}", transcript);
    DefaultDKG::verify_transcript(&pub_params, &transcript)?;

    info!("Double-verifying by reconstructing the dealt secret.");
    let dealt_secret_from_shares = dealt_secret_from_shares(
        dkg_session
            .metadata
            .target_validator_consensus_infos_cloned(),
        decrypt_key_map,
        &pub_params,
        &transcript,
    );

    println!("dealt_secret_from_shares={:?}", dealt_secret_from_shares);

    let dealt_secret_from_inputs = dealt_secret_from_input(
        &transcript,
        &pub_params,
        &pub_params.session_metadata.dealer_consensus_infos_cloned(),
    );
    println!("dealt_secret_from_inputs={:?}", dealt_secret_from_inputs);

    ensure!(
        dealt_secret_from_shares == dealt_secret_from_inputs,
        "dkg transcript verification failed with final check failure"
    );
    Ok(())
}

fn dealt_secret_from_shares(
    target_validator_set: Vec<ValidatorConsensusInfo>,
    decrypt_key_map: &HashMap<AccountAddress, <DefaultDKG as DKGTrait>::NewValidatorDecryptKey>,
    pub_params: &<DefaultDKG as DKGTrait>::PublicParams,
    transcript: &<DefaultDKG as DKGTrait>::Transcript,
) -> <DefaultDKG as DKGTrait>::DealtSecret {
    let player_share_pairs = target_validator_set
        .iter()
        .enumerate()
        .map(|(idx, validator_info)| {
            let dk = decrypt_key_map.get(&validator_info.address).unwrap();
            let (secret_share, _pub_key_share) = DefaultDKG::decrypt_secret_share_from_transcript(
                pub_params, transcript, idx as u64, dk,
            )
            .unwrap();
            (idx as u64, secret_share)
        })
        .collect();

    DefaultDKG::reconstruct_secret_from_shares(pub_params, player_share_pairs).unwrap()
}

fn dealt_secret_from_input(
    trx: &<DefaultDKG as DKGTrait>::Transcript,
    pub_params: &<DefaultDKG as DKGTrait>::PublicParams,
    dealer_validator_infos: &[ValidatorConsensusInfo],
) -> <DefaultDKG as DKGTrait>::DealtSecret {
    let dealers = DefaultDKG::get_dealers(trx);
    println!("dealers={:?}", dealers);
    let input_secrets = dealers
        .into_iter()
        .map(|dealer_idx| {
            let cur_addr = dealer_validator_infos[dealer_idx as usize].address;
            // Same seed is used in `DKGManager::setup_deal_broadcast` for smoke tests.
            let mut rng = StdRng::from_seed(cur_addr.into_bytes());
            <DefaultDKG as DKGTrait>::InputSecret::generate(&mut rng)
        })
        .collect();

    let aggregated_input_secret = DefaultDKG::aggregate_input_secret(input_secrets);
    DefaultDKG::dealt_secret_from_input(pub_params, &aggregated_input_secret)
}

#[allow(dead_code)]
fn num_validators(dkg_state: &DKGSessionState) -> usize {
    dkg_state.metadata.target_validator_set.len()
}

fn decrypt_key_map(
    swarm: &LocalSwarm,
) -> HashMap<AccountAddress, <DefaultDKG as DKGTrait>::NewValidatorDecryptKey> {
    swarm
        .validators()
        .map(|validator| {
            let dk = validator
                .config()
                .consensus
                .safety_rules
                .initial_safety_rules_config
                .identity_blob()
                .unwrap()
                .try_into_dkg_new_validator_decrypt_key()
                .unwrap();
            (validator.peer_id(), dk)
        })
        .collect::<HashMap<_, _>>()
}

/// Fetch the DKG result and the block randomness (from aggregation) for a specific version.
/// Derive the distributed secret from DKG result.
/// Verify that the randomness from aggregation (the actual one store on chain) equals to
/// the randomness from direct evaluation using the distributed secret (the expected one).
async fn verify_randomness(
    decrypt_key_map: &HashMap<AccountAddress, <DefaultDKG as DKGTrait>::NewValidatorDecryptKey>,
    rest_client: &Client,
    version: u64,
) -> Result<()> {
    // Fetch resources.
    let (dkg_state, on_chain_block_randomness) = tokio::join!(
        get_on_chain_resource_at_version::<DKGState>(rest_client, version),
        get_on_chain_resource_at_version::<PerBlockRandomness>(rest_client, version)
    );

    ensure!(
        on_chain_block_randomness.seed.is_some(),
        "randomness verification failed with seed missing"
    );

    // Derive the shared secret.
    let dkg_session = dkg_state
        .last_completed
        .ok_or_else(|| anyhow!("randomness verification failed with missing dkg result"))?;
    let dkg_pub_params = DefaultDKG::new_public_params(&dkg_session.metadata);
    let transcript =
        bcs::from_bytes::<<DefaultDKG as DKGTrait>::Transcript>(dkg_session.transcript.as_slice())
            .map_err(|_| {
                anyhow!(
                "randomness verification failed with on-chain dkg transcript deserialization error"
            )
            })?;
    let dealt_secret = dealt_secret_from_shares(
        dkg_session
            .metadata
            .target_validator_consensus_infos_cloned(),
        decrypt_key_map,
        &dkg_pub_params,
        &transcript,
    );

    // Compare the outputs from 2 paths.
    let rand_metadata = RandMetadata {
        epoch: on_chain_block_randomness.epoch,
        round: on_chain_block_randomness.round,
    };
    let input = bcs::to_bytes(&rand_metadata).unwrap();
    let output = WVUF::eval(&dealt_secret, input.as_slice());
    let output_serialized = bcs::to_bytes(&output).unwrap();
    let expected_randomness_seed = Sha3_256::digest(output_serialized.as_slice()).to_vec();

    ensure!(
        expected_randomness_seed == on_chain_block_randomness.seed.clone().unwrap(),
        "randomness verification failed with final check failure"
    );
    Ok(())
}

fn script_to_enable_main_logic() -> String {
    r#"
script {
    use topo_framework::topo_governance;
    use topo_framework::randomness_config;
    use topo_std::fixed_point64;

    fun main(core_resources: &signer) {
        let framework_signer = topo_governance::get_signer_testnet_only(core_resources, @0x1);
        let config = randomness_config::new_v1(
            fixed_point64::create_from_rational(1, 2),
            fixed_point64::create_from_rational(2, 3)
        );
        randomness_config::set_for_next_epoch(&framework_signer, config);
        topo_governance::reconfigure(&framework_signer);
    }
}
"#
    .to_string()
}

fn script_to_disable_main_logic() -> String {
    r#"
script {
    use topo_framework::topo_governance;
    use topo_framework::randomness_config;
    fun main(core_resources: &signer) {
        let framework_signer = topo_governance::get_signer_testnet_only(core_resources, @0x1);
        let config = randomness_config::new_off();
        randomness_config::set_for_next_epoch(&framework_signer, config);
        topo_governance::reconfigure(&framework_signer);
    }
}
"#
    .to_string()
}

fn script_to_update_consensus_config(config: &OnChainConsensusConfig) -> String {
    let config_bytes = bcs::to_bytes(config).unwrap();
    format!(
        r#"
script {{
    use topo_framework::topo_governance;
    use topo_framework::consensus_config;

    fun main(core_resources: &signer) {{
        let framework_signer = topo_governance::get_signer_testnet_only(core_resources, @0x1);
        let config_bytes = vector{:?};
        consensus_config::set_for_next_epoch(&framework_signer, config_bytes);
        topo_governance::reconfigure(&framework_signer);
    }}
}}
    "#,
        config_bytes
    )
}
