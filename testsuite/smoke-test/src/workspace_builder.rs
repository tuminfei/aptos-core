// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

//! DO NOT USE OUTSIDE OF SMOKE_TEST CRATE
//!
//! This utility is to only be used inside of smoke test.

use aptos_forge::cargo_build_common_args;
use aptos_logger::prelude::*;
use once_cell::sync::Lazy;
use std::{collections::HashMap, env, path::PathBuf, process::Command, sync::Mutex};

fn build_error_message(bin_name: &str) -> String {
    format!(
        "\n    Unable to build binary '{}'. Cannot continue running tests.\n\n    Try running 'cargo build --release --bin {}' yourself.\n",
        bin_name, bin_name
    )
}

// Cache of per-binary build results. Smoke tests only need a small subset of workspace
// binaries, so building them lazily avoids unrelated workspace failures blocking targeted tests.
static BUILT_BINS: Lazy<Mutex<HashMap<String, bool>>> = Lazy::new(|| Mutex::new(HashMap::new()));

fn ensure_bin_built(bin_name: &str) {
    let mut built_bins = BUILT_BINS.lock().unwrap();
    match built_bins.get(bin_name).copied() {
        Some(true) => return,
        Some(false) => panic!("{}", build_error_message(bin_name)),
        None => {},
    }

    info!("Building project binary {}", bin_name);
    let mut args = cargo_build_common_args();
    args.push("--bin");
    args.push(bin_name);

    let cargo_build = Command::new("cargo")
        .current_dir(workspace_root())
        .args(&args)
        .output()
        .unwrap_or_else(|_| panic!("{}", build_error_message(bin_name)));
    let success = cargo_build.status.success();
    if success {
        info!("Finished building project binary {}", bin_name);
    } else {
        error!("Failed to build {}: {:?}", bin_name, cargo_build);
    }
    built_bins.insert(bin_name.to_owned(), success);

    if !success {
        panic!("{}", build_error_message(bin_name));
    }
}

// Path to top level workspace
pub fn workspace_root() -> PathBuf {
    let mut path = build_dir();
    while !path.ends_with("target") {
        path.pop();
    }
    path.pop();
    path
}

// Path to the directory where build artifacts live.
//TODO maybe add an Environment Variable which points to built binaries
fn build_dir() -> PathBuf {
    env::current_exe()
        .ok()
        .map(|mut path| {
            path.pop();
            if path.ends_with("deps") {
                path.pop();
            }
            path
        })
        .expect("Can't find the build directory. Cannot continue running tests")
}

// Path to a specified binary
pub fn get_bin<S: AsRef<str>>(bin_name: S) -> PathBuf {
    let bin_name = bin_name.as_ref();
    assert_ne!(
        "aptos-node", bin_name,
        "aptos-node must be built and used via local swarm cargo_build_aptos_node"
    );

    ensure_bin_built(bin_name);
    let bin_path = build_dir().join(format!("{}{}", bin_name, env::consts::EXE_SUFFIX));

    // If the binary doesn't exist then either building them failed somehow or the supplied binary
    // name doesn't match any binaries this workspace can produce.
    if !bin_path.exists() {
        panic!(
            "Can't find binary '{}' in expected path {:?}",
            bin_name, bin_path
        );
    }

    bin_path
}
