// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

//! Public-entry regression tests for PWR-02/05/06 and ALC-01.
//! These use an explicit four-node A fixture, not the default T2 deployment.

use super::{
    assert_installed_on_all_nodes, optional_resource_at_version, poc_swarm_builder,
    resource_at_version, Transition,
};
use aptos_api_types::{
    Event, Transaction, TransactionData, UserTransaction, ViewRequest, WriteSetChange,
};
use aptos_cached_packages::aptos_stdlib;
use aptos_forge::{LocalSwarm, NodeExt, Swarm};
use aptos_genesis::poc::{DeploymentLimits, DeploymentMode, PocGenesisConfiguration, PowerParams};
use aptos_rest_client::{error::RestError, Client};
use aptos_sdk::{transaction_builder::TransactionFactory, types::LocalAccount};
use aptos_types::{
    account_address::AccountAddress,
    account_config::{AccountResource, CORE_CODE_ADDRESS},
    on_chain_config::{OnChainChunkyDKGConfig, OnChainRandomnessConfig, ValidatorSet},
    transaction::{ExecutionStatus, Script, TransactionArgument, TransactionPayload},
};
use move_core_types::{
    identifier::Identifier, language_storage::ModuleId, vm_status::AbortLocation,
};
use once_cell::sync::Lazy;
use serde_json::{json, Value};
use std::{collections::BTreeSet, path::Path, sync::Arc, time::Duration};
use topo_framework::{BuildOptions, BuiltPackage};

const UNIT_SCALE: u128 = 1 << 32;
const INVALID_ARGUMENT: u64 = 1 << 16;
const OUT_OF_RANGE: u64 = 2 << 16;
const PERMISSION_DENIED: u64 = 5 << 16;

/// Compile only a transaction script against the production framework sources.
/// The script obtains its framework signer through the existing, authenticated
/// testnet governance entry; it cannot call friend or test-only Move functions.
pub(super) fn compile_script(name: &str, source: &str) -> Vec<u8> {
    let directory = tempfile::tempdir().unwrap();
    let framework = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../aptos-move/framework/topo-framework")
        .canonicalize()
        .unwrap();
    std::fs::create_dir(directory.path().join("sources")).unwrap();
    std::fs::write(
        directory.path().join("Move.toml"),
        format!(
            "[package]\nname = {name:?}\nversion = \"0.0.0\"\n\n[dependencies.TopoFramework]\nlocal = {framework:?}\n"
        ),
    )
    .unwrap();
    std::fs::write(directory.path().join("sources/main.move"), source).unwrap();
    let mut scripts = BuiltPackage::build(
        directory.path().to_path_buf(),
        BuildOptions::move_2().set_latest_language(),
    )
    .unwrap()
    .extract_script_code();
    assert_eq!(scripts.len(), 1);
    scripts.remove(0)
}

static POWER_GOVERNANCE_SCRIPT: Lazy<Vec<u8>> = Lazy::new(|| {
    compile_script(
        "PoCPublicPowerGovernance",
        r#"
script {
    use topo_framework::poc_power_store;
    use topo_framework::topo_governance;

    fun main(root: &signer, change_operator: bool, address: address, period: u64, power: u64) {
        let framework = topo_governance::get_signer_testnet_only(root, @0x1);
        if (change_operator) {
            poc_power_store::set_operator(&framework, address);
        } else {
            poc_power_store::stage_batch_update(&framework, period, vector[address], vector[power]);
        };
    }
}
"#,
    )
});

fn governance_payload(
    change_operator: bool,
    address: AccountAddress,
    power: u64,
) -> TransactionPayload {
    TransactionPayload::Script(Script::new(POWER_GOVERNANCE_SCRIPT.clone(), vec![], vec![
        TransactionArgument::Bool(change_operator),
        TransactionArgument::Address(address),
        TransactionArgument::U64(1),
        TransactionArgument::U64(power),
    ]))
}

/// Keep the clock stable while testing individual inputs. DKG is disabled,
/// epochs are one hour, four genesis pools each have 10 power / 100 Octa, and
/// max_upload_users is explicitly 32. Other A parameters match the F4 fixture.
async fn transaction_swarm() -> LocalSwarm {
    println!("PoC transaction fixture A: 4 nodes; Open; epoch=3600s; ordinary/Chunky DKG=off; retention_bps=10000; native_reward_bps=0; max_upload_users=32; allocation/claim limit=4; validator_limit=5; initial_power=10; bond=100 Octa; fee_limit=0; fee_max=10");
    poc_swarm_builder(Transition::Synchronous)
        .with_init_genesis_config(Arc::new(|config| {
            config.allow_new_validators = true;
            config.epoch_duration_secs = 3600;
            config.min_stake = 1;
            config.max_stake = 1000;
            config.voting_power_increase_limit = 25;
            config.randomness_config_override = Some(OnChainRandomnessConfig::Off);
            config.chunky_dkg_config_override = Some(OnChainChunkyDKGConfig::default_disabled());
            config.poc_genesis_config = Some(Arc::new(|_| PocGenesisConfiguration {
                params: PowerParams {
                    bond_octa_per_ohmp: 100_000_000,
                    min_power: 10,
                    max_power: 1000,
                    min_validators: 4,
                },
                limits: DeploymentLimits {
                    max_allocations: 4,
                    max_claim_pools: 4,
                    max_upload_users: 32,
                    validator_limit: 5,
                    max_reward_base_octa: 1000,
                    rate_max_num: 1,
                    rate_max_den: 1,
                    fee_max: 10,
                    reward_epoch_limit: 1000,
                },
                deployment_mode: DeploymentMode::Open,
                retention_bps: 10000,
                max_relative_period: 100,
                initial_raw_power: 10,
                native_reward_bps: 0,
            }));
        }))
        .build()
        .await
}

/// submit_and_wait intentionally turns committed Move aborts into REST errors.
/// Poll the submitted hash instead so both successful and aborted transactions
/// retain their actual version, output, events, gas, and sequence number.
pub(super) async fn execute(
    client: &Client,
    account: &LocalAccount,
    factory: &TransactionFactory,
    payload: TransactionPayload,
) -> UserTransaction {
    let signed = account.sign_with_transaction_builder(factory.payload(payload));
    client.submit(&signed).await.unwrap();
    let transaction = tokio::time::timeout(Duration::from_secs(60), async {
        loop {
            match client
                .get_transaction_by_hash(signed.committed_hash())
                .await
            {
                Ok(response) => match response.into_inner() {
                    Transaction::UserTransaction(transaction) => break transaction,
                    Transaction::PendingTransaction(_) => {},
                    other @ (Transaction::GenesisTransaction(_)
                    | Transaction::BlockMetadataTransaction(_)
                    | Transaction::StateCheckpointTransaction(_)
                    | Transaction::BlockEpilogueTransaction(_)
                    | Transaction::ValidatorTransaction(_)) => {
                        panic!("Unexpected transaction for submitted user hash: {other:?}")
                    },
                },
                Err(RestError::Api(error))
                    if error.status_code == reqwest::StatusCode::NOT_FOUND => {},
                Err(error) => panic!("Failed to read submitted transaction: {error}"),
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    })
    .await
    .expect("PoC public-entry transaction did not commit within 60 seconds");
    println!(
        "PoC public-entry txn={} version={} success={} gas={} status={}",
        transaction.info.hash,
        transaction.info.version.0,
        transaction.info.success,
        transaction.info.gas_used.0,
        transaction.info.vm_status,
    );
    transaction
}

fn require_success(transaction: UserTransaction) -> UserTransaction {
    assert!(transaction.info.success, "{}", transaction.info.vm_status);
    transaction
}

async fn view_at(client: &Client, function: &str, args: Vec<Value>, version: u64) -> Vec<Value> {
    client
        .view(
            &ViewRequest {
                function: function.parse().unwrap(),
                type_arguments: vec![],
                arguments: args,
            },
            Some(version),
        )
        .await
        .unwrap()
        .into_inner()
}

fn address(value: &Value) -> AccountAddress {
    AccountAddress::from_hex_literal(value.as_str().unwrap()).unwrap()
}

fn table_handles(value: &Value, handles: &mut BTreeSet<AccountAddress>) {
    match value {
        Value::Object(fields) => {
            for (key, value) in fields {
                if key == "handle" {
                    handles.insert(address(value));
                } else {
                    table_handles(value, handles);
                }
            }
        },
        Value::Array(values) => {
            for value in values {
                table_handles(value, handles);
            }
        },
        Value::Null | Value::Bool(_) | Value::Number(_) | Value::String(_) => {},
    }
}

#[derive(Debug, PartialEq)]
struct BusinessState {
    resources: Vec<Value>,
    pools: Vec<Value>,
    users: Vec<Value>,
    handles: BTreeSet<AccountAddress>,
}

/// Besides logical views, read the actual pool ledgers to retain pending changes
/// and checkpoint refs. Their table handles also identify forbidden writes in an
/// aborted transaction's production VM output.
async fn business_state(
    client: &Client,
    users: &[AccountAddress],
    pools: &[AccountAddress],
    version: u64,
) -> BusinessState {
    let mut snapshot = BusinessState {
        resources: vec![],
        pools: vec![],
        users: vec![],
        handles: BTreeSet::new(),
    };
    let mut pools_handle = None;
    for resource_type in [
        "0x1::poc_power_store::PowerStore",
        "0x1::poc_power_store::PeriodClock",
        "0x1::poc_accounting::AccountingState",
        "0x1::poc_reward_split::RewardSplitConfig",
        "0x1::stake::InstalledRewardContext",
        "0x1::stake::ValidatorSet",
        "0x1::reconfiguration::Configuration",
    ] {
        let resource = client
            .get_account_resource_at_version(CORE_CODE_ADDRESS, resource_type, version)
            .await
            .unwrap()
            .into_inner()
            .unwrap()
            .data;
        if resource_type == "0x1::poc_accounting::AccountingState" {
            pools_handle = Some(address(&resource["pools"]["handle"]));
        }
        table_handles(&resource, &mut snapshot.handles);
        snapshot.resources.push(resource);
    }
    for pool in pools {
        let ledger = client
            .get_table_item_at_version(
                pools_handle.unwrap(),
                "address",
                "0x1::poc_accounting::PoolLedger",
                pool.to_hex_literal(),
                version,
            )
            .await
            .unwrap()
            .into_inner();
        table_handles(&ledger, &mut snapshot.handles);
        snapshot.pools.push(ledger);
    }
    for user in users {
        let allocation = optional_resource_at_version(
            client,
            *user,
            "0x1::poc_accounting::UserAllocation",
            version,
        )
        .await
        .map(|resource| resource.data);
        if let Some(allocation) = &allocation {
            table_handles(allocation, &mut snapshot.handles);
        }
        let mut observed = vec![json!(allocation)];
        for function in [
            "0x1::poc_power_store::get_user_power_version",
            "0x1::poc_power_store::get_accounting_snapshot",
            "0x1::poc_accounting::get_allocations",
        ] {
            observed.push(json!(
                view_at(client, function, vec![json!(user)], version).await
            ));
        }
        for pool in pools {
            observed.push(json!(
                view_at(
                    client,
                    "0x1::poc_accounting::get_position",
                    vec![json!(user), json!(pool)],
                    version,
                )
                .await
            ));
        }
        snapshot.users.push(json!(observed));
    }
    snapshot
}

fn poc_events<'a>(transaction: &'a UserTransaction, event_type: &str) -> Vec<&'a Event> {
    transaction
        .events
        .iter()
        .filter(|event| event.typ.to_string() == event_type)
        .collect()
}

async fn assert_unchanged(
    client: &Client,
    transaction: &UserTransaction,
    users: &[AccountAddress],
    pools: &[AccountAddress],
) {
    let version = transaction.info.version.0;
    let before = business_state(client, users, pools, version - 1).await;
    let after = business_state(client, users, pools, version).await;
    assert_eq!(before, after, "PoC state changed at version {version}");
    for change in &transaction.info.changes {
        match change {
            WriteSetChange::WriteResource(change) => assert!(
                !change.data.typ.to_string().contains("::poc_"),
                "Unexpected PoC resource write: {change:?}",
            ),
            WriteSetChange::DeleteResource(change) => assert!(
                !change.resource.to_string().contains("::poc_"),
                "Unexpected PoC resource removal: {change:?}",
            ),
            WriteSetChange::WriteTableItem(change) => assert!(!before
                .handles
                .contains(&AccountAddress::from_bytes(change.handle.inner()).unwrap())),
            WriteSetChange::DeleteTableItem(change) => assert!(!before
                .handles
                .contains(&AccountAddress::from_bytes(change.handle.inner()).unwrap())),
            WriteSetChange::WriteModule(_) | WriteSetChange::DeleteModule(_) => {
                panic!("Unexpected module change: {change:?}")
            },
        }
    }
    assert!(transaction
        .events
        .iter()
        .all(|event| !event.typ.to_string().contains("::poc_")));
}

pub(super) async fn assert_abort(
    client: &Client,
    transaction: &UserTransaction,
    module: &str,
    code: u64,
    users: &[AccountAddress],
    pools: &[AccountAddress],
) {
    assert!(!transaction.info.success);
    let TransactionData::OnChain(committed) = client
        .get_transaction_by_version_bcs(transaction.info.version.0)
        .await
        .unwrap()
        .into_inner()
    else {
        panic!("Expected committed BCS transaction")
    };
    let ExecutionStatus::MoveAbort {
        location,
        code: actual_code,
        ..
    } = committed.info.status()
    else {
        panic!("Expected Move abort, got {:?}", committed.info.status())
    };
    assert_eq!(
        location,
        &AbortLocation::Module(ModuleId::new(
            CORE_CODE_ADDRESS,
            Identifier::new(module).unwrap(),
        )),
    );
    assert_eq!(*actual_code, code);
    assert_unchanged(client, transaction, users, pools).await;
    assert!(transaction.info.gas_used.0 > 0);
    let sender = transaction.request.sender.into();
    let before: AccountResource = client
        .get_account_resource_at_version_bcs(
            sender,
            "0x1::account::Account",
            transaction.info.version.0 - 1,
        )
        .await
        .unwrap()
        .into_inner();
    let after: AccountResource = client
        .get_account_resource_at_version_bcs(
            sender,
            "0x1::account::Account",
            transaction.info.version.0,
        )
        .await
        .unwrap()
        .into_inner();
    assert_eq!(after.sequence_number(), before.sequence_number() + 1);
}

fn factory(swarm: &LocalSwarm) -> TransactionFactory {
    swarm
        .chain_info()
        .transaction_factory()
        .with_gas_unit_price(1)
        .with_max_gas_amount(2_000_000)
        .with_transaction_expiration_time(60)
}

fn assert_uploaded(transaction: &UserTransaction, expected: &[(AccountAddress, u64)]) {
    let normalized = poc_events(transaction, "0x1::poc_power_store::PowerNormalized");
    let staged = poc_events(transaction, "0x1::poc_power_store::PowerUpdateStagedEvent");
    assert_eq!(normalized.len(), expected.len());
    assert_eq!(staged.len(), expected.len());
    for ((normalized, staged), (user, power)) in normalized.iter().zip(staged).zip(expected) {
        assert_eq!(address(&normalized.data["user"]), *user);
        assert_eq!(normalized.data["effective_period"], json!("1"));
        assert_eq!(
            normalized.data["units"],
            json!((*power as u128 * UNIT_SCALE).to_string()),
        );
        assert_eq!(address(&staged.data["user"]), *user);
        assert_eq!(staged.data["target_period"], json!("1"));
        assert_eq!(staged.data["effective_period"], json!("1"));
        assert_eq!(staged.data["power"], json!(power.to_string()));
    }
}

fn assert_operator_changed(
    transaction: &UserTransaction,
    old: AccountAddress,
    new: AccountAddress,
) {
    let events = poc_events(transaction, "0x1::poc_power_store::OperatorChangedEvent");
    assert_eq!(events.len(), 1);
    assert_eq!(address(&events[0].data["old_operator"]), old);
    assert_eq!(address(&events[0].data["new_operator"]), new);
}

/// PWR-02, PWR-05 and the public input matrix of PWR-06. Failed transactions
/// compare exact v-1/v business state, table writes, events and Move aborts.
/// A batch capacity error after an earlier successful item is covered by the VM
/// suite and is not claimed here; this fixture never injects oversized units.
#[tokio::test]
async fn poc_public_upload_authority_first_write_and_batch_inputs() {
    // Compile before starting the network so compilation cannot consume its epoch.
    Lazy::force(&POWER_GOVERNANCE_SCRIPT);
    let swarm = transaction_swarm().await;
    let client = swarm.validators().next().unwrap().rest_client();
    let factory = factory(&swarm);
    let root = swarm.chain_info().root_account();
    let mut public = swarm.chain_info().into_aptos_public_info();
    let operator = public
        .create_and_fund_user_account(100_000_000)
        .await
        .unwrap();
    let replacement = public
        // The fresh 32-user batch reserves 2,000,000 gas at 100 Octa/gas.
        .create_and_fund_user_account(1_000_000_000)
        .await
        .unwrap();
    let user = public
        .create_and_fund_user_account(100_000_000)
        .await
        .unwrap();
    let pools = swarm
        .validators()
        .map(|node| node.peer_id())
        .collect::<Vec<_>>();
    let users = [user.address()];
    let initial = client.get_ledger_information().await.unwrap().into_inner();
    assert!(
        initial.epoch < 60,
        "Input fixture reached its power boundary"
    );
    let installed = resource_at_version::<ValidatorSet>(&client, initial.version).await;

    // A zero-power user can allocate first; uploading later must create only the
    // boundary change, and duplicate uploads must preserve its checkpoint refs.
    require_success(
        execute(
            &client,
            &user,
            &factory,
            aptos_stdlib::poc_allocation_set_allocations(vec![pools[0]], vec![10_000]),
        )
        .await,
    );
    let set_operator = require_success(
        execute(
            &client,
            &root,
            &factory,
            governance_payload(true, operator.address(), 0),
        )
        .await,
    );
    assert_operator_changed(&set_operator, CORE_CODE_ADDRESS, operator.address());
    let denied = execute(
        &client,
        &user,
        &factory,
        aptos_stdlib::poc_power_store_stage_batch_update(1, users.to_vec(), vec![100]),
    )
    .await;
    assert_abort(
        &client,
        &denied,
        "poc_power_store",
        PERMISSION_DENIED + 2,
        &users,
        &pools,
    )
    .await;

    let first = require_success(
        execute(
            &client,
            &operator,
            &factory,
            aptos_stdlib::poc_power_store_stage_batch_update(1, vec![user.address(); 3], vec![
                100, 100, 200,
            ]),
        )
        .await,
    );
    assert_uploaded(&first, &[(user.address(), 100)]);
    assert_eq!(
        view_at(
            &client,
            "0x1::poc_power_store::get_user_power_version",
            vec![json!(user.address())],
            first.info.version.0
        )
        .await,
        vec![json!("0"), json!("0"), json!("1"), json!("100"), json!("0")],
    );
    assert_eq!(
        view_at(
            &client,
            "0x1::poc_accounting::get_position",
            vec![json!(user.address()), json!(pools[0])],
            first.info.version.0
        )
        .await,
        vec![
            json!("0"),
            json!([{ "epoch": "61", "units": (100 * UNIT_SCALE).to_string() }]),
            json!("0"),
            json!("0")
        ],
    );
    for power in [100, 200] {
        let repeated = require_success(
            execute(
                &client,
                &operator,
                &factory,
                aptos_stdlib::poc_power_store_stage_batch_update(1, users.to_vec(), vec![power]),
            )
            .await,
        );
        assert_unchanged(&client, &repeated, &users, &pools).await;
    }

    let replace = require_success(
        execute(
            &client,
            &root,
            &factory,
            governance_payload(true, replacement.address(), 0),
        )
        .await,
    );
    assert_operator_changed(&replace, operator.address(), replacement.address());
    let denied = execute(
        &client,
        &operator,
        &factory,
        aptos_stdlib::poc_power_store_stage_batch_update(1, users.to_vec(), vec![100]),
    )
    .await;
    assert_abort(
        &client,
        &denied,
        "poc_power_store",
        PERMISSION_DENIED + 2,
        &users,
        &pools,
    )
    .await;
    let uploaded = require_success(
        execute(
            &client,
            &replacement,
            &factory,
            aptos_stdlib::poc_power_store_stage_batch_update(1, vec![replacement.address()], vec![
                17,
            ]),
        )
        .await,
    );
    assert_uploaded(&uploaded, &[(replacement.address(), 17)]);
    let framework_upload = require_success(
        execute(
            &client,
            &root,
            &factory,
            governance_payload(false, operator.address(), 23),
        )
        .await,
    );
    assert_uploaded(&framework_upload, &[(operator.address(), 23)]);

    // Unchanged operator emits no duplicate event; an ordinary signer cannot
    // use the public setter to grant itself upload authority.
    let same_operator = require_success(
        execute(
            &client,
            &root,
            &factory,
            governance_payload(true, replacement.address(), 0),
        )
        .await,
    );
    assert!(poc_events(&same_operator, "0x1::poc_power_store::OperatorChangedEvent").is_empty());
    assert_eq!(
        business_state(&client, &users, &pools, same_operator.info.version.0 - 1).await,
        business_state(&client, &users, &pools, same_operator.info.version.0).await,
    );
    let denied = execute(
        &client,
        &operator,
        &factory,
        aptos_stdlib::poc_power_store_set_operator(operator.address()),
    )
    .await;
    assert_abort(
        &client,
        &denied,
        "system_addresses",
        PERMISSION_DENIED + 3,
        &users,
        &pools,
    )
    .await;

    let empty = require_success(
        execute(
            &client,
            &replacement,
            &factory,
            aptos_stdlib::poc_power_store_stage_batch_update(1, vec![], vec![]),
        )
        .await,
    );
    assert_unchanged(&client, &empty, &users, &pools).await;
    let zero_user = AccountAddress::from_hex_literal("0x123456").unwrap();
    let zero = require_success(
        execute(
            &client,
            &replacement,
            &factory,
            aptos_stdlib::poc_power_store_stage_batch_update(1, vec![zero_user], vec![0]),
        )
        .await,
    );
    assert_unchanged(&client, &zero, &users, &pools).await;
    assert_eq!(
        view_at(
            &client,
            "0x1::poc_power_store::is_user_normalized",
            vec![json!(zero_user)],
            zero.info.version.0
        )
        .await,
        vec![json!(false)]
    );

    // PWR-03's storage branch: zero is an explicit next version for an existing
    // genesis owner; the following 999 must not overwrite it in the same batch.
    let owner_zero = require_success(
        execute(
            &client,
            &replacement,
            &factory,
            aptos_stdlib::poc_power_store_stage_batch_update(1, vec![pools[0]; 2], vec![0, 999]),
        )
        .await,
    );
    assert_uploaded(&owner_zero, &[(pools[0], 0)]);
    assert_eq!(
        view_at(
            &client,
            "0x1::poc_power_store::get_user_power_version",
            vec![json!(pools[0])],
            owner_zero.info.version.0,
        )
        .await,
        vec![json!("0"), json!("10"), json!("1"), json!("0"), json!("10")],
    );
    assert_eq!(
        view_at(
            &client,
            "0x1::poc_power_store::get_accounting_snapshot",
            vec![json!(pools[0])],
            owner_zero.info.version.0,
        )
        .await,
        vec![
            json!((10 * UNIT_SCALE).to_string()),
            json!("0"),
            json!("0"),
            json!("61")
        ],
    );

    let batch_users = (0..33)
        .map(|index| AccountAddress::from_hex_literal(&format!("0x{:x}", 0x1000 + index)).unwrap())
        .collect::<Vec<_>>();
    // Storage fees are denominated in Octa and converted to gas by dividing by
    // the transaction's gas price (aptos-gas-meter::algebra::charge_storage_fee).
    // Keep the 2,000,000-gas budget and native gas schedule, but use 100 Octa/gas
    // for this one batch of 32 new versions. All negative cases below
    // retain the original 1 Octa/gas factory and their exact Move-abort checks.
    let batch_factory = factory.clone().with_gas_unit_price(100);
    println!(
        "PWR-06 fresh_users=32 gas_unit_price={} max_gas_amount={} maximum_fee_octa={} uploader_initial_funding_octa=1000000000",
        batch_factory.get_gas_unit_price(),
        batch_factory.get_max_gas_amount(),
        batch_factory.get_gas_unit_price() * batch_factory.get_max_gas_amount(),
    );
    let full_batch = require_success(
        execute(
            &client,
            &replacement,
            &batch_factory,
            aptos_stdlib::poc_power_store_stage_batch_update(1, batch_users[..32].to_vec(), vec![
                1;
                32
            ]),
        )
        .await,
    );
    let fee_statements = poc_events(&full_batch, "0x1::transaction_fee::FeeStatement");
    assert_eq!(fee_statements.len(), 1);
    println!(
        "PWR-06 fresh_users=32 version={} actual_gas_unit_price={} actual_max_gas_amount={} actual_gas_used={} charged_octa={} fee_statement={}",
        full_batch.info.version.0,
        full_batch.request.gas_unit_price.0,
        full_batch.request.max_gas_amount.0,
        full_batch.info.gas_used.0,
        full_batch.info.gas_used.0 * full_batch.request.gas_unit_price.0,
        fee_statements[0].data,
    );
    assert_uploaded(
        &full_batch,
        &batch_users[..32]
            .iter()
            .map(|user| (*user, 1))
            .collect::<Vec<_>>(),
    );
    for batch_user in &batch_users[..32] {
        assert_eq!(
            view_at(
                &client,
                "0x1::poc_power_store::is_user_normalized",
                vec![json!(batch_user)],
                full_batch.info.version.0 - 1,
            )
            .await,
            vec![json!(false)],
            "The 32-user limit test must create a first version for every user",
        );
        assert_eq!(
            view_at(
                &client,
                "0x1::poc_power_store::get_accounting_snapshot",
                vec![json!(batch_user)],
                full_batch.info.version.0
            )
            .await,
            vec![
                json!("0"),
                json!(UNIT_SCALE.to_string()),
                json!("0"),
                json!("61")
            ],
        );
    }
    for (label, period, addresses, powers, reason) in [
        ("33 distinct users", 1, batch_users, vec![1; 33], 13),
        (
            "33 duplicate users count before deduplication",
            1,
            vec![user.address(); 33],
            vec![100; 33],
            13,
        ),
        ("missing power", 1, users.to_vec(), vec![], 3),
        ("missing address", 1, vec![], vec![1], 3),
        ("current period", 0, users.to_vec(), vec![100], 6),
        ("skipped period", 2, users.to_vec(), vec![100], 6),
        ("far future period", u64::MAX, users.to_vec(), vec![100], 6),
    ] {
        println!("PWR-06: {label}");
        let denied = execute(
            &client,
            &replacement,
            &factory,
            aptos_stdlib::poc_power_store_stage_batch_update(period, addresses, powers),
        )
        .await;
        assert_abort(
            &client,
            &denied,
            "poc_power_store",
            INVALID_ARGUMENT + reason,
            &users,
            &pools,
        )
        .await;
    }
    let final_ledger = client.get_ledger_information().await.unwrap().into_inner();
    assert_eq!(
        final_ledger.epoch, initial.epoch,
        "Input fixture unexpectedly crossed an epoch"
    );
    assert_eq!(
        resource_at_version::<ValidatorSet>(&client, final_ledger.version).await,
        installed
    );
    assert_installed_on_all_nodes(&swarm, final_ledger.version, initial.epoch, &installed).await;
}

/// ALC-01: valid full/partial/empty allocation, configure before first upload,
/// future units and invalid vector/ratio/pool combinations on real transactions.
#[tokio::test]
async fn poc_public_allocation_inputs_and_upload_synchronization() {
    Lazy::force(&POWER_GOVERNANCE_SCRIPT);
    let swarm = transaction_swarm().await;
    let client = swarm.validators().next().unwrap().rest_client();
    let factory = factory(&swarm);
    let root = swarm.chain_info().root_account();
    let mut public = swarm.chain_info().into_aptos_public_info();
    let user = public
        .create_and_fund_user_account(100_000_000)
        .await
        .unwrap();
    let stranger = public
        .create_and_fund_user_account(100_000_000)
        .await
        .unwrap();
    let users = [user.address(), stranger.address()];
    let pools = swarm
        .validators()
        .map(|node| node.peer_id())
        .collect::<Vec<_>>();
    let initial = client.get_ledger_information().await.unwrap().into_inner();
    assert!(
        initial.epoch < 60,
        "Input fixture reached its power boundary"
    );
    let installed = resource_at_version::<ValidatorSet>(&client, initial.version).await;

    for (chosen, ratios) in [
        (vec![pools[0]], vec![10_000]),
        (pools.clone(), vec![2_500; 4]),
        (vec![], vec![]),
        (vec![pools[0], pools[1]], vec![2_500, 5_000]),
    ] {
        let allocated = require_success(
            execute(
                &client,
                &user,
                &factory,
                aptos_stdlib::poc_allocation_set_allocations(chosen.clone(), ratios.clone()),
            )
            .await,
        );
        let events = poc_events(&allocated, "0x1::poc_accounting::AllocationScheduled");
        assert_eq!(events.len(), 1);
        assert_eq!(address(&events[0].data["user"]), user.address());
        assert_eq!(
            events[0].data["effective_epoch"],
            json!((initial.epoch + 1).to_string())
        );
        assert_eq!(
            events[0].data["pools"]
                .as_array()
                .unwrap()
                .iter()
                .map(address)
                .collect::<Vec<_>>(),
            chosen
        );
        assert_eq!(
            events[0].data["bps"],
            json!(ratios.iter().map(u64::to_string).collect::<Vec<_>>())
        );
        let allocation = view_at(
            &client,
            "0x1::poc_accounting::get_allocations",
            vec![json!(user.address())],
            allocated.info.version.0,
        )
        .await;
        assert_eq!(allocation[0], json!([]));
        let pending = &allocation[1]["vec"][0];
        assert_eq!(pending["epoch"], json!((initial.epoch + 1).to_string()));
        assert_eq!(pending["ratios"].as_array().unwrap().len(), chosen.len());
        for (actual, (pool, ratio)) in pending["ratios"]
            .as_array()
            .unwrap()
            .iter()
            .zip(chosen.iter().zip(&ratios))
        {
            assert_eq!(address(&actual["pool"]), *pool);
            assert_eq!(actual["bps"], json!(ratio.to_string()));
        }
        for pool in &pools {
            assert_eq!(
                view_at(
                    &client,
                    "0x1::poc_accounting::get_position",
                    vec![json!(user.address()), json!(pool)],
                    allocated.info.version.0
                )
                .await,
                vec![json!("0"), json!([]), json!("0"), json!("0")],
            );
        }
    }
    let uploaded = require_success(
        execute(
            &client,
            &root,
            &factory,
            governance_payload(false, user.address(), 100),
        )
        .await,
    );
    assert_uploaded(&uploaded, &[(user.address(), 100)]);
    for (pool, power) in [(pools[0], 25), (pools[1], 50), (pools[2], 0), (pools[3], 0)] {
        let position = view_at(
            &client,
            "0x1::poc_accounting::get_position",
            vec![json!(user.address()), json!(pool)],
            uploaded.info.version.0,
        )
        .await;
        assert_eq!(position[0], json!("0"));
        assert_eq!(
            position[1],
            if power == 0 {
                json!([])
            } else {
                json!([{ "epoch": "61", "units": (power * UNIT_SCALE).to_string() }])
            }
        );
        assert_eq!(position[2], json!("0"));
        assert_eq!(position[3], json!("0"));
    }

    for (label, chosen, ratios, code) in [
        (
            "duplicate pool",
            vec![pools[0]; 2],
            vec![2_500; 2],
            INVALID_ARGUMENT + 3,
        ),
        (
            "pool not enabled",
            vec![pools[0], stranger.address()],
            vec![5_000; 2],
            INVALID_ARGUMENT + 5,
        ),
        ("zero bps", vec![pools[0]], vec![0], INVALID_ARGUMENT + 2),
        (
            "sum exceeds 10000",
            vec![pools[0], pools[1]],
            vec![5_000, 5_001],
            INVALID_ARGUMENT + 2,
        ),
        ("missing bps", vec![pools[0]], vec![], INVALID_ARGUMENT + 2),
        ("missing pool", vec![], vec![1], INVALID_ARGUMENT + 2),
        (
            "five inputs before duplicate validation",
            vec![pools[0]; 5],
            vec![2_000; 5],
            OUT_OF_RANGE + 4,
        ),
    ] {
        println!("ALC-01: {label}");
        let denied = execute(
            &client,
            &user,
            &factory,
            aptos_stdlib::poc_allocation_set_allocations(chosen, ratios),
        )
        .await;
        assert_abort(&client, &denied, "poc_accounting", code, &users, &pools).await;
    }

    // The signature owns the allocation: another account can configure itself,
    // while the first user's position and version remain independent.
    let other = require_success(
        execute(
            &client,
            &stranger,
            &factory,
            aptos_stdlib::poc_allocation_set_allocations(vec![pools[0]], vec![10_000]),
        )
        .await,
    );
    for function in [
        "0x1::poc_accounting::get_allocations",
        "0x1::poc_power_store::get_accounting_snapshot",
    ] {
        assert_eq!(
            view_at(
                &client,
                function,
                vec![json!(user.address())],
                other.info.version.0 - 1
            )
            .await,
            view_at(
                &client,
                function,
                vec![json!(user.address())],
                other.info.version.0
            )
            .await,
        );
    }
    let final_ledger = client.get_ledger_information().await.unwrap().into_inner();
    assert_eq!(
        final_ledger.epoch, initial.epoch,
        "Input fixture unexpectedly crossed an epoch"
    );
    assert_eq!(
        resource_at_version::<ValidatorSet>(&client, final_ledger.version).await,
        installed
    );
    assert_installed_on_all_nodes(&swarm, final_ledger.version, initial.epoch, &installed).await;
}
