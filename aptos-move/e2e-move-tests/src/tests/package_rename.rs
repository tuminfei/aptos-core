// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

use crate::{assert_success, tests::common, MoveHarness};
use topo_framework::BuildOptions;
use aptos_package_builder::PackageBuilder;
use aptos_types::account_address::AccountAddress;

#[test]
fn topo_framework_dep_still_exposes_aptos_framework_namespace() {
    let mut builder = PackageBuilder::new("Package");
    builder.add_source(
        "rename_smoke.move",
        r#"
        module 0xcafe::rename_smoke {
            use aptos_framework::chain_id;

            entry fun verify_namespace(_s: &signer) {
                let _chain_id = chain_id::get();
            }
        }
        "#,
    );
    builder.add_local_dep(
        "TopoFramework",
        &common::framework_dir_path("topo-framework").to_string_lossy(),
    );
    let path = builder.write_to_temp().unwrap();

    let mut harness = MoveHarness::new();
    let account = harness.new_account_at(AccountAddress::from_hex_literal("0xcafe").unwrap());

    assert_success!(harness.publish_package_with_options(
        &account,
        path.path(),
        BuildOptions::default(),
    ));
    assert_success!(harness.run_entry_function(
        &account,
        str::parse("0xcafe::rename_smoke::verify_namespace").unwrap(),
        vec![],
        vec![],
    ));
}
