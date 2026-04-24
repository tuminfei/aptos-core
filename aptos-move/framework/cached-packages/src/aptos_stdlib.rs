// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

#![allow(unused_imports)]

pub use crate::{
    aptos_framework_sdk_builder::*, topo_token_objects_sdk_builder as topo_token_objects_stdlib,
    topo_token_sdk_builder as topo_token_stdlib,
};
use aptos_types::{
    account_address::AccountAddress,
    transaction::{EntryFunction, TransactionPayload},
    CoinType, TopoCoinType,
};
use move_core_types::{ident_str, identifier::Identifier, language_storage::ModuleId};

pub fn topo_coin_transfer(to: AccountAddress, amount: u64) -> TransactionPayload {
    coin_transfer(TopoCoinType::type_tag(), to, amount)
}

#[cfg(feature = "testing")]
pub fn publish_module_source(module_name: &str, module_src: &str) -> TransactionPayload {
    use aptos_framework::{BuildOptions, BuiltPackage};
    use aptos_package_builder::PackageBuilder;

    let mut builder = PackageBuilder::new("tmp");
    builder.add_source(module_name, module_src);

    let tmp_dir = builder.write_to_temp().unwrap();
    let package = BuiltPackage::build(tmp_dir.path().to_path_buf(), BuildOptions::default())
        .expect("Should be able to build a package");
    let code = package.extract_code();
    let metadata = package
        .extract_metadata()
        .expect("Should be able to extract metadata");
    let metadata_serialized =
        bcs::to_bytes(&metadata).expect("Should be able to serialize metadata");
    code_publish_package_txn(metadata_serialized, code)
}

/// Temporary workaround as `Object<T>` as a function argument is not recognised
/// when auto generating move transaction payloads. Will address in separate PR.
pub fn object_code_deployment_upgrade(
    metadata_serialized: Vec<u8>,
    code: Vec<Vec<u8>>,
    code_object: AccountAddress,
) -> TransactionPayload {
    TransactionPayload::EntryFunction(EntryFunction::new(
        ModuleId::new(
            AccountAddress::new([
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 1,
            ]),
            ident_str!("object_code_deployment").to_owned(),
        ),
        ident_str!("upgrade").to_owned(),
        vec![],
        vec![
            bcs::to_bytes(&metadata_serialized).unwrap(),
            bcs::to_bytes(&code).unwrap(),
            bcs::to_bytes(&code_object).unwrap(),
        ],
    ))
}

/// Temporary workaround as `Object<T>` as a function argument is not recognised
/// when auto generating move transaction payloads. Will address in separate PR.
pub fn object_code_deployment_freeze_code_object(
    code_object: AccountAddress,
) -> TransactionPayload {
    TransactionPayload::EntryFunction(EntryFunction::new(
        ModuleId::new(
            AccountAddress::new([
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 1,
            ]),
            ident_str!("object_code_deployment").to_owned(),
        ),
        ident_str!("freeze_code_object").to_owned(),
        vec![],
        vec![bcs::to_bytes(&code_object).unwrap()],
    ))
}

fn aptos_framework_entry_function(
    module_name: &str,
    function_name: &str,
    args: Vec<Vec<u8>>,
) -> TransactionPayload {
    TransactionPayload::EntryFunction(EntryFunction::new(
        ModuleId::new(
            AccountAddress::new([
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 1,
            ]),
            Identifier::new(module_name).unwrap(),
        ),
        Identifier::new(function_name).unwrap(),
        vec![],
        args,
    ))
}

pub fn staking_contract_create_staking_contract(
    operator: AccountAddress,
    voter: AccountAddress,
    amount: u64,
    commission_percentage: u64,
    contract_creation_seed: Vec<u8>,
) -> TransactionPayload {
    aptos_framework_entry_function(
        "staking_contract",
        "create_staking_contract",
        vec![
            bcs::to_bytes(&operator).unwrap(),
            bcs::to_bytes(&voter).unwrap(),
            bcs::to_bytes(&amount).unwrap(),
            bcs::to_bytes(&commission_percentage).unwrap(),
            bcs::to_bytes(&contract_creation_seed).unwrap(),
        ],
    )
}

pub fn staking_contract_update_voter(
    operator: AccountAddress,
    new_voter: AccountAddress,
) -> TransactionPayload {
    aptos_framework_entry_function(
        "staking_contract",
        "update_voter",
        vec![
            bcs::to_bytes(&operator).unwrap(),
            bcs::to_bytes(&new_voter).unwrap(),
        ],
    )
}

pub fn staking_contract_reset_lockup(operator: AccountAddress) -> TransactionPayload {
    aptos_framework_entry_function(
        "staking_contract",
        "reset_lockup",
        vec![bcs::to_bytes(&operator).unwrap()],
    )
}

pub fn staking_contract_update_commision(
    operator: AccountAddress,
    new_commission_percentage: u64,
) -> TransactionPayload {
    aptos_framework_entry_function(
        "staking_contract",
        "update_commision",
        vec![
            bcs::to_bytes(&operator).unwrap(),
            bcs::to_bytes(&new_commission_percentage).unwrap(),
        ],
    )
}

pub fn staking_contract_unlock_stake(operator: AccountAddress, amount: u64) -> TransactionPayload {
    aptos_framework_entry_function(
        "staking_contract",
        "unlock_stake",
        vec![
            bcs::to_bytes(&operator).unwrap(),
            bcs::to_bytes(&amount).unwrap(),
        ],
    )
}

pub fn staking_contract_switch_operator_with_same_commission(
    old_operator: AccountAddress,
    new_operator: AccountAddress,
) -> TransactionPayload {
    aptos_framework_entry_function(
        "staking_contract",
        "switch_operator_with_same_commission",
        vec![
            bcs::to_bytes(&old_operator).unwrap(),
            bcs::to_bytes(&new_operator).unwrap(),
        ],
    )
}

pub fn staking_contract_distribute(
    staker: AccountAddress,
    operator: AccountAddress,
) -> TransactionPayload {
    aptos_framework_entry_function(
        "staking_contract",
        "distribute",
        vec![
            bcs::to_bytes(&staker).unwrap(),
            bcs::to_bytes(&operator).unwrap(),
        ],
    )
}

pub fn delegation_pool_add_stake(pool_address: AccountAddress, amount: u64) -> TransactionPayload {
    aptos_framework_entry_function(
        "delegation_pool",
        "add_stake",
        vec![
            bcs::to_bytes(&pool_address).unwrap(),
            bcs::to_bytes(&amount).unwrap(),
        ],
    )
}

pub fn delegation_pool_unlock(pool_address: AccountAddress, amount: u64) -> TransactionPayload {
    aptos_framework_entry_function(
        "delegation_pool",
        "unlock",
        vec![
            bcs::to_bytes(&pool_address).unwrap(),
            bcs::to_bytes(&amount).unwrap(),
        ],
    )
}

pub fn delegation_pool_withdraw(pool_address: AccountAddress, amount: u64) -> TransactionPayload {
    aptos_framework_entry_function(
        "delegation_pool",
        "withdraw",
        vec![
            bcs::to_bytes(&pool_address).unwrap(),
            bcs::to_bytes(&amount).unwrap(),
        ],
    )
}
