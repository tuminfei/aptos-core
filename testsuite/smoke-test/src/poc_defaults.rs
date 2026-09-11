// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

use crate::smoke_test_environment::SwarmBuilder;
use aptos_api_types::{Transaction, UserTransaction};
use aptos_cached_packages::aptos_stdlib;
use aptos_forge::{NodeExt, Swarm, SwarmExt};
use aptos_genesis::poc::PocGenesisConfiguration;
use aptos_rest_client::Client;
use aptos_sdk::{transaction_builder::TransactionFactory, types::LocalAccount};
use aptos_types::{
    account_address::AccountAddress,
    account_config::CORE_CODE_ADDRESS,
    on_chain_config::{ConfigurationResource, OnChainConfig, ValidatorSet},
    transaction::TransactionPayload,
};
use std::{sync::Arc, time::Duration};

const OCTA_PER_TOPO: u64 = 100_000_000;
type RewardContext = (u64, bool, u64, u64, bool, u64);

async fn submit(
    client: &Client,
    account: &LocalAccount,
    factory: &TransactionFactory,
    payload: TransactionPayload,
) -> UserTransaction {
    let signed = account.sign_with_transaction_builder(factory.payload(payload));
    let transaction =
        tokio::time::timeout(Duration::from_secs(60), client.submit_and_wait(&signed))
            .await
            .expect("PoC default-network transaction timed out")
            .unwrap()
            .into_inner();
    let Transaction::UserTransaction(transaction) = transaction else {
        panic!("Expected a committed user transaction")
    };
    assert!(transaction.info.success, "{}", transaction.info.vm_status);
    transaction
}

async fn balance_at(client: &Client, address: AccountAddress, version: u64) -> u64 {
    client
        .view_apt_account_balance_at_version(address, version)
        .await
        .unwrap()
        .into_inner()
}

async fn installed_at(client: &Client, version: u64) -> (ValidatorSet, RewardContext) {
    let validators = client
        .get_account_resource_at_version_bcs::<ValidatorSet>(
            CORE_CODE_ADDRESS,
            &ValidatorSet::struct_tag().to_canonical_string(),
            version,
        )
        .await
        .unwrap()
        .into_inner();
    let context = client
        .get_account_resource_at_version_bcs::<RewardContext>(
            CORE_CODE_ADDRESS,
            "0x1::stake::InstalledRewardContext",
            version,
        )
        .await
        .unwrap()
        .into_inner();
    let configuration = client
        .get_account_resource_at_version_bcs::<ConfigurationResource>(
            CORE_CODE_ADDRESS,
            &ConfigurationResource::struct_tag().to_canonical_string(),
            version,
        )
        .await
        .unwrap()
        .into_inner();
    assert_eq!(context.0, configuration.epoch());
    (validators, context)
}

/// 两个默认测试网验证者通过真实交易领取非零奖励，并在一个节点重启后继续换届。
#[tokio::test]
async fn poc_testnet_two_nodes_transfer_claim_and_restart() {
    let mut swarm = SwarmBuilder::new_local(2)
        .with_aptos()
        // 本地构建器默认只质押 10 Octa；这里使用 PoC 测试网约定的每池 1 TOPO。
        .with_init_genesis_stake(Arc::new(|_, amount| *amount = OCTA_PER_TOPO))
        .with_init_genesis_config(Arc::new(|config| {
            config.epoch_duration_secs = 10;
            config.poc_genesis_config = Some(Arc::new(|_| PocGenesisConfiguration::testnet()));
            // 普通 DKG 和验证者交易沿用默认开启值；Chunky DKG 沿用 SwarmBuilder 的关闭值。
        }))
        .build()
        .await;
    let client = swarm.validators().next().unwrap().rest_client();
    let identities = swarm
        .validators()
        .map(|node| {
            (
                node.peer_id(),
                node.account_private_key().as_ref().unwrap().private_key(),
            )
        })
        .collect::<Vec<_>>();
    let mut identities = identities.into_iter();
    let (owner_address, owner_key) = identities.next().unwrap();
    let (receiver_address, _) = identities.next().unwrap();
    let (genesis_set, genesis_context) = installed_at(&client, 0).await;
    assert_eq!(genesis_set.active_validators.len(), 2);
    assert_eq!(genesis_set.total_voting_power, 2 * OCTA_PER_TOPO as u128);
    assert!(genesis_set
        .active_validators
        .iter()
        .all(|validator| validator.consensus_voting_power() == OCTA_PER_TOPO));
    assert_eq!(genesis_context.0, 1);
    assert!(genesis_context.1);
    assert!(genesis_context.2 > 0 && genesis_context.3 > 0);
    assert_eq!(genesis_context.5, 0);
    assert_eq!(balance_at(&client, owner_address, 0).await, 0);
    assert_eq!(balance_at(&client, receiver_address, 0).await, 0);

    // 创世与自动换届不需要 owner 持有 gas；仅为后续付费用户交易通过测试根账户注资。
    swarm
        .wait_for_all_nodes_to_catchup_to_epoch(2, Duration::from_secs(120))
        .await
        .unwrap();
    swarm
        .chain_info()
        .into_aptos_public_info()
        .mint(owner_address, OCTA_PER_TOPO)
        .await
        .unwrap();

    let factory = swarm
        .chain_info()
        .transaction_factory()
        .with_gas_unit_price(1)
        .with_max_gas_amount(2_000_000)
        .with_transaction_expiration_time(120);
    let sequence = client
        .get_account(owner_address)
        .await
        .unwrap()
        .into_inner()
        .sequence_number;
    let owner = LocalAccount::new(owner_address, owner_key, sequence);
    let before = client.get_ledger_information().await.unwrap().into_inner();
    let receiver_before = balance_at(&client, receiver_address, before.version).await;
    let mut last_transfer_version = before.version;
    for _ in 0..10 {
        let transfer = submit(
            &client,
            &owner,
            &factory,
            aptos_stdlib::topo_coin_transfer(receiver_address, 1_000),
        )
        .await;
        assert!(transfer.info.gas_used.0 > 0);
        last_transfer_version = transfer.info.version.0;
    }
    assert_eq!(
        balance_at(&client, receiver_address, last_transfer_version).await,
        receiver_before + 10_000,
    );

    // 从当前已安装 Epoch 起等待两次完整换届，给默认奖励率和整数取整留下非零奖励。
    let before_rewards = client.get_ledger_information().await.unwrap().into_inner();
    swarm
        .wait_for_all_nodes_to_catchup_to_epoch(before_rewards.epoch + 2, Duration::from_secs(120))
        .await
        .unwrap();
    let claim = submit(
        &client,
        &owner,
        &factory,
        aptos_stdlib::poc_allocation_claim_rewards(vec![owner_address]),
    )
    .await;
    let claims = claim
        .events
        .iter()
        .filter(|event| {
            event
                .typ
                .to_string()
                .ends_with("::poc_accounting::PoCRewardClaimed")
        })
        .collect::<Vec<_>>();
    assert_eq!(
        claims.len(),
        1,
        "Expected one nonzero reward claim: {claim:?}"
    );
    let claimed = claims[0].data["amount"]
        .as_str()
        .unwrap()
        .parse::<u64>()
        .unwrap();
    assert!(claimed > 0);
    for field in ["user", "pool"] {
        assert_eq!(
            AccountAddress::from_hex_literal(claims[0].data[field].as_str().unwrap()).unwrap(),
            owner_address,
        );
    }
    let gas = claim.info.gas_used.0 * claim.request.gas_unit_price.0;
    assert!(gas > 0);
    let storage_refund = claim
        .events
        .iter()
        .find(|event| {
            event
                .typ
                .to_string()
                .ends_with("::transaction_fee::FeeStatement")
        })
        .map(|event| {
            event.data["storage_fee_refund_octas"]
                .as_str()
                .unwrap()
                .parse::<u64>()
                .unwrap()
        })
        .unwrap_or(0);
    let claim_version = claim.info.version.0;
    let balance_before_claim = balance_at(&client, owner_address, claim_version - 1).await;
    let balance_after_claim = balance_at(&client, owner_address, claim_version).await;
    assert_eq!(
        balance_after_claim as i128 - balance_before_claim as i128,
        claimed as i128 - gas as i128 + storage_refund as i128,
        "Claimed rewards must reach the owner after transaction fees",
    );
    println!("PoC testnet claimed {claimed} Octa at version {claim_version}; gas={gas}, storage_refund={storage_refund}");

    let before_restart = client.get_ledger_information().await.unwrap().into_inner();
    swarm
        .validator_mut(receiver_address)
        .unwrap()
        .restart()
        .await
        .unwrap();
    swarm
        .wait_for_all_nodes_to_catchup_to_epoch(before_restart.epoch + 1, Duration::from_secs(120))
        .await
        .unwrap();
    // 重启恢复后再提交一笔交易，验证两个节点已恢复 quorum 和用户交易处理。
    let transfer = submit(
        &client,
        &owner,
        &factory,
        aptos_stdlib::topo_coin_transfer(receiver_address, 1_000),
    )
    .await;
    let version = transfer.info.version.0;
    swarm
        .wait_for_all_nodes_to_catchup_to_version(version, Duration::from_secs(30))
        .await
        .unwrap();
    let (expected_set, expected_context) = installed_at(&client, version).await;
    assert_eq!(expected_set.active_validators.len(), 2);
    assert_eq!(expected_set.total_joining_power, 0);
    assert!(expected_set.active_validators.iter().all(|validator| {
        let power = validator.consensus_voting_power();
        power > 0 && power <= OCTA_PER_TOPO
    }));
    assert_eq!(
        expected_set.total_voting_power,
        expected_set
            .active_validators
            .iter()
            .map(|validator| validator.consensus_voting_power() as u128)
            .sum::<u128>(),
    );
    assert!(expected_context.0 > before_restart.epoch);
    assert!(expected_context.1);
    assert_eq!(expected_context.5, 0);
    for node in swarm.validators() {
        let (installed_set, installed_context) = installed_at(&node.rest_client(), version).await;
        assert_eq!(installed_set, expected_set);
        assert_eq!(installed_context, expected_context);
    }
}
