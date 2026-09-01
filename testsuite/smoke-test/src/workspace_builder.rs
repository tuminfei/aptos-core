// Copyright (c) Aptos Foundation
// Licensed pursuant to the Innovation-Enabling Source Code License, available at https://github.com/aptos-labs/aptos-core/blob/main/LICENSE

//! DO NOT USE OUTSIDE OF SMOKE_TEST CRATE
//!
//! This utility is to only be used inside of smoke test.

use aptos_forge::cargo_build_common_args;
use aptos_logger::prelude::*;
use once_cell::sync::Lazy;
use std::{env, path::PathBuf, process::Command};

const WORKSPACE_BUILD_ERROR_MSG: &str = r#"
    Unable to build the workspace binaries required by smoke tests. Cannot continue running tests.

    Try running 'cargo build --release --package aptos --package aptos-debugger --bins' yourself.
"#;

// Global flag indicating if all binaries in the workspace have been built.
// When SMOKE_TEST_PREBUILD_BINARIES=1 is set (e.g. in CI with nextest archives),
// skip the cargo build and assume binaries are already present.
static WORKSPACE_BUILT: Lazy<bool> = Lazy::new(|| {
    if env::var("SMOKE_TEST_PREBUILD_BINARIES").is_ok() {
        info!("Skipping workspace build: SMOKE_TEST_PREBUILD_BINARIES is set");
        return true;
    }

    info!("Building project binaries");
    let common_args = cargo_build_common_args();
    let mut args = Vec::new();
    let mut index = 0;
    while index < common_args.len() {
        let arg = common_args[index];
        if arg == "--features" {
            index += 2;
            continue;
        }
        if arg.starts_with("--features=") {
            index += 1;
            continue;
        }
        args.push(arg);
        index += 1;
    }
    // Smoke tests only access these two workspace binaries through `get_bin()`.
    // Building every workspace binary also pulls in unrelated system dependencies
    // (for example, libpq for the NFT metadata crawler), which makes these tests
    // fail before the requested binaries are built.
    args.append(&mut vec![
        "--package",
        "aptos",
        "--package",
        "aptos-debugger",
        "--bins",
    ]);

    let cargo_build = Command::new("cargo")
        .current_dir(workspace_root())
        .args(&args)
        .output()
        .expect(WORKSPACE_BUILD_ERROR_MSG);
    if cargo_build.status.success() {
        info!("Finished building project binaries");
        true
    } else {
        error!("Output: {:?}", cargo_build);
        false
    }
});

// Path to top level workspace
pub fn workspace_root() -> PathBuf {
    let mut path = build_dir();
    while !path.ends_with("target") {
        if !path.pop() {
            panic!(
                "Could not find 'target' directory ascending from {:?}",
                build_dir()
            );
        }
    }
    path.pop();
    path
}

// Path to the directory where build artifacts live.
// When SMOKE_TEST_BIN_DIR is set, use that directory instead of inferring from current_exe.
fn build_dir() -> PathBuf {
    if let Ok(dir) = env::var("SMOKE_TEST_BIN_DIR") {
        return PathBuf::from(dir);
    }
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

// Returns a `Command` for invoking the `aptos-debugger` binary.
pub fn get_aptos_debugger_command() -> Command {
    Command::new(get_bin("aptos-debugger"))
}

// Path to a specified binary
pub fn get_bin<S: AsRef<str>>(bin_name: S) -> PathBuf {
    assert_ne!(
        "aptos-node",
        bin_name.as_ref(),
        "aptos-node must be built and used via local swarm cargo_build_aptos_node"
    );

    // We have to check to see if the workspace is built first to ensure that the binaries we're
    // testing are up to date.
    if !*WORKSPACE_BUILT {
        panic!("{}", WORKSPACE_BUILD_ERROR_MSG);
    }

    let bin_name = bin_name.as_ref();
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
