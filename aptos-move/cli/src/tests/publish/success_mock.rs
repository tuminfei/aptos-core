// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

use crate::tests::common;
use aptos_cli_common::TransactionSummary;
use aptos_types::transaction::TransactionPayload;
use std::sync::{Arc, Mutex};
use topo_framework::natives::code::PackageMetadata;

fn fake_summary() -> TransactionSummary {
    TransactionSummary {
        transaction_hash: aptos_crypto::HashValue::zero().into(),
        gas_used: None,
        gas_unit_price: None,
        pending: None,
        sender: None,
        sequence_number: None,
        replay_protector: None,
        success: Some(true),
        timestamp_us: None,
        version: None,
        vm_status: None,
        deployed_object_address: None,
    }
}

fn metadata_from_payload(payload: &TransactionPayload) -> PackageMetadata {
    let TransactionPayload::EntryFunction(entry_fn) = payload else {
        panic!("expected entry function payload, got {payload:?}");
    };
    let metadata_bytes: Vec<u8> = bcs::from_bytes(
        entry_fn
            .args()
            .first()
            .expect("publish payload must include metadata argument"),
    )
    .expect("metadata argument should decode to raw bytes");
    bcs::from_bytes(&metadata_bytes).expect("raw metadata bytes should decode")
}

#[test]
fn publish_success_mock() {
    let pkg = common::make_package("pub_mock", &[(
        "pub_mock",
        "module 0xCAFE::pub_mock {
    public fun hello(): u64 { 42 }
}",
    )]);
    let dir = pkg.path().to_str().unwrap();

    let (env, buffer) = common::env_with_mock(|ctx| {
        ctx.expect_submit_transaction()
            .returning(|_, _| Ok(fake_summary()));
    });

    let output = common::run_cli_with_env(
        &[
            "publish",
            "--package-dir",
            dir,
            "--skip-fetch-latest-git-deps",
            "--assume-yes",
        ],
        env,
        buffer,
    );
    common::check_baseline(file!(), &output);
}

#[test]
fn publish_hides_sources_for_selected_modules() {
    let pkg = common::make_package("pub_mock", &[
        (
            "poc_hidden",
            "module 0xCAFE::poc_hidden {
    public fun hello(): u64 { 7 }
}",
        ),
        (
            "poc_hidden_extra",
            "module 0xCAFE::poc_hidden_extra {
    public fun hello(): u64 { 42 }
}",
        ),
        (
            "visible_module",
            "module 0xCAFE::visible_module {
    public fun hello(): u64 { 99 }
}",
        ),
    ]);
    let dir = pkg.path().to_str().unwrap();
    let captured_metadata = Arc::new(Mutex::new(None));
    let captured_metadata_clone = Arc::clone(&captured_metadata);

    let (env, buffer) = common::env_with_mock(|ctx| {
        ctx.expect_submit_transaction()
            .returning(move |_, payload| {
                let metadata = metadata_from_payload(&payload);
                *captured_metadata_clone
                    .lock()
                    .unwrap_or_else(|e| e.into_inner()) = Some(metadata);
                Ok(fake_summary())
            });
    });

    let output = common::run_cli_with_env(
        &[
            "publish",
            "--package-dir",
            dir,
            "--skip-fetch-latest-git-deps",
            "--hide-source-for-module",
            "topo_framework::poc_hidden",
            "--assume-yes",
        ],
        env,
        buffer,
    );
    assert!(output.result.is_ok(), "publish failed: {:?}", output.result);

    let metadata = captured_metadata
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
        .expect("publish should submit metadata");
    let hidden_module = metadata
        .modules
        .iter()
        .find(|module| module.name == "poc_hidden")
        .expect("hidden module should exist");
    assert!(
        hidden_module.source.is_empty() && hidden_module.source_map.is_empty(),
        "hidden module source artifacts should be omitted"
    );

    let similar_module = metadata
        .modules
        .iter()
        .find(|module| module.name == "poc_hidden_extra")
        .expect("similar module should exist");
    assert!(
        !similar_module.source.is_empty(),
        "exact matching should not hide similarly named modules"
    );

    let visible_module = metadata
        .modules
        .iter()
        .find(|module| module.name == "visible_module")
        .expect("visible module should exist");
    assert!(
        !visible_module.source.is_empty(),
        "non-matching module source should remain present"
    );
}

#[test]
fn publish_rejects_unmatched_hidden_module_requests() {
    let pkg = common::make_package("pub_mock", &[(
        "poc_hidden",
        "module 0xCAFE::poc_hidden {
    public fun hello(): u64 { 7 }
}",
    )]);
    let dir = pkg.path().to_str().unwrap();

    let (env, buffer) = common::env_with_mock(|ctx| {
        ctx.expect_submit_transaction().times(0);
    });

    let output = common::run_cli_with_env(
        &[
            "publish",
            "--package-dir",
            dir,
            "--skip-fetch-latest-git-deps",
            "--hide-source-for-module",
            "topo_framework::poc_regsitry",
            "--assume-yes",
        ],
        env,
        buffer,
    );

    let err = output
        .result
        .expect_err("publish should fail before submitting a transaction");
    assert!(err.contains("Requested modules to hide were not found"));
    assert!(err.contains("topo_framework::poc_regsitry"));
}
