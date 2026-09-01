# Topo Framework Migration TODO

This checklist is the execution plan for rebuilding the `aptos-framework` -> `topo-framework` migration on a fresh branch.

It is intentionally ordered so that the framework package set is stabilized first, and only then are the minimum downstream fixes applied.

Use it together with `docs/TOPO_FRAMEWORK_MIGRATION_SUMMARY.md`.

## 0. Working Rules

- [ ] Treat this as a framework reconstruction task, not a repo-wide rename.
- [ ] Start from the framework subtree and only expand outward when compilation/tests prove it is necessary.
- [ ] Keep a running note for every non-framework file you touch: "why is this required by the package/module rename?"
- [ ] Do not do a blind `aptos` -> `topo` replacement across the repo.
- [ ] Keep compatibility aliases when they are still needed.

## 1. Create The Fresh Branch

- [ ] Start from the intended clean upstream base.

```bash
git status --short
git checkout main
git pull --ff-only
git checkout -b codex/topo-framework-rebuild
```

- [ ] Record the new branch head and the reference source branch head.

```bash
git rev-parse HEAD
git rev-parse topo_framework
git merge-base topo_framework company/main
```

- [ ] Read repo guidance before editing.

```bash
sed -n '1,220p' CLAUDE.md
sed -n '1,260p' agents.md
```

- [ ] Confirm the work stays out of consensus/crypto/schema/protocol-sensitive areas unless a concrete framework dependency forces it.

## 2. Phase A: Rename The Five Framework Packages

- [ ] Rename these directories:

```text
aptos-move/framework/aptos-framework -> aptos-move/framework/topo-framework
aptos-move/framework/aptos-stdlib -> aptos-move/framework/topo-stdlib
aptos-move/framework/aptos-token -> aptos-move/framework/topo-token
aptos-move/framework/aptos-token-objects -> aptos-move/framework/topo-token-objects
aptos-move/framework/aptos-trading -> aptos-move/framework/topo-trading
```

- [ ] Update package names in the renamed `Move.toml` files:

```text
AptosFramework -> TopoFramework
AptosStdlib -> TopoStdlib
AptosToken -> TopoToken
AptosTokenObjects -> TopoTokenObjects
AptosTrading -> TopoTrading
```

- [ ] Update named addresses in those manifests:

```text
aptos_std -> topo_std
aptos_framework -> topo_framework
aptos_token -> topo_token
aptos_token_objects -> topo_token_objects
aptos_trading -> topo_trading
```

- [ ] Keep intentionally unchanged names where they are part of the expected end state:

```text
aptos_fungible_asset
aptos_token
aptos_experimental
core_resources
vm_reserved
```

### Phase A completion check

- [ ] `find aptos-move/framework -maxdepth 2 -type d | sort` shows the `topo-*` package directories.
- [ ] The five renamed package manifests match the target-state naming from `TOPO_FRAMEWORK_MIGRATION_SUMMARY.md`.

## 3. Phase B: Rename The Main Framework Modules

- [ ] Rename the three main chain-owned modules:

```text
aptos_account.move -> topo_account.move
aptos_coin.move -> topo_coin.move
aptos_governance.move -> topo_governance.move
```

- [ ] Rename matching spec/doc/test files that follow those module names.

- [ ] Update framework-local references:

```text
module declarations
use statements
friend declarations
doc links
spec references
tests
```

- [ ] Migrate the native coin type, not only the `aptos_coin.move` file name:

```text
AptosCoin -> TopoCoin
AptosCoinCapabilities -> TopoCoinCapabilities
AptosCoinMintCapability -> TopoCoinMintCapability
ExistsAptosCoin -> ExistsTopoCoin
is_apt<CoinType>() -> is_topo<CoinType>()
allow_apt_creation -> allow_topo_creation
EAPT_PAIRING_IS_NOT_ENABLED -> ETOPO_PAIRING_IS_NOT_ENABLED
0x1::topo_coin::AptosCoin -> 0x1::topo_coin::TopoCoin
Aptos Coin / APT -> Topo Coin / TOPO, for native coin metadata/spec checks
```

- [ ] Update framework coin specs/tests that mention the old native coin name:

```text
aptos-move/framework/topo-framework/sources/topo_coin.spec.move
aptos-move/framework/topo-framework/tests/topo_coin_tests.move
aptos-move/framework/topo-framework/tests/delegation_pool_integration_tests.move
```

Expected result:

```text
No framework-local native coin type remains in the mixed state topo_coin::AptosCoin.
Topo coin tests use names such as test_topo_setup_and_mint.
Comments/spec utf8 checks use TOPO/TopoCoin where they describe the native coin.
```

- [ ] Re-check that these modules still publish under the intended framework address.

### Phase B completion check

- [ ] Searching the framework subtree for the three old module names only returns intentional historical/compatibility cases.

```bash
rg -n "aptos_account|aptos_coin|aptos_governance" aptos-move/framework
```

## 4. Phase C: Update Framework Rust Crates And Build Glue

- [ ] Update root `Cargo.toml` workspace dependency names:

```text
aptos-framework -> topo-framework
aptos-framework-natives -> topo-framework-natives
```

- [ ] Update framework crate imports/usages:

```text
aptos_framework -> topo_framework
aptos_framework_natives -> topo_framework_natives
```

- [ ] Update `aptos-move/framework/Cargo.toml`:

```text
[package]
name = "topo-framework"

[dependencies]
topo-framework-natives = { workspace = true }
```

- [ ] Update framework build glue:

```text
aptos-move/framework/src/lib.rs
aptos-move/framework/src/aptos.rs
aptos-move/framework/src/built_package.rs
aptos-move/framework/src/main.rs
```

- [ ] Ensure package ordering and canonical package names use the `topo-*`/`Topo*` forms.

- [ ] Keep or add the package rename regression test:

```text
aptos-move/framework/tests/package_rename_test.rs
```

Expected result:

```text
building "topo-framework" yields metadata package name "TopoFramework"
```

### Phase C completion check

- [ ] `cargo metadata --no-deps` resolves.
- [ ] `cargo check -p topo-framework` resolves.

## 5. Phase D: Rebuild Cached Packages

- [ ] Rename cached package helper modules if needed:

```text
aptos_token_sdk_builder.rs -> topo_token_sdk_builder.rs
aptos_token_objects_sdk_builder.rs -> topo_token_objects_sdk_builder.rs
```

- [ ] Update `aptos-move/framework/cached-packages/src/lib.rs`:
  - export `topo_stdlib`
  - keep `pub use topo_stdlib as aptos_stdlib` if current callers still require it

- [ ] Rebuild cached packages:

```bash
scripts/cargo_build_aptos_cached_packages.sh
git status --short aptos-move/framework/cached-packages
```

### Phase D completion check

- [ ] Cached packages regenerate cleanly.
- [ ] `aptos-move/framework/cached-packages/src/head.mrb` is updated when framework bytecode changed.
- [ ] No unexpected framework package names remain in generated outputs.

## 6. Phase E: Apply The Minimum Downstream Fixes

Only after Phases A-D are stable, touch the direct integration points.

- [ ] Gas schedule:

```text
aptos-move/aptos-gas-schedule/src/gas_schedule/mod.rs
aptos-move/aptos-gas-schedule/src/gas_schedule/aptos_framework.rs -> topo_framework.rs
```

- [ ] CLI:

```text
aptos-move/cli/src/commands.rs
```

Typical changes:

```text
AptosFramework -> TopoFramework
aptos_framework -> topo_framework
aptos_cached_packages::aptos_stdlib::* -> aptos_cached_packages::topo_stdlib::*
```

- [ ] Release builder:

```text
aptos-move/aptos-release-builder/src/components/framework.rs
```

- [ ] If necessary, update only the tests/examples/goldens that explicitly mention old framework names:

```text
aptos-move/e2e-move-tests
testsuite/smoke-test
api/src/tests
api/goldens
```

- [ ] Update genesis and e2e executor references that still call old framework modules:

```text
aptos-move/vm-genesis/src/lib.rs
aptos-move/e2e-tests/src/executor.rs
```

Required checks:

```bash
rg -n "aptos_governance|initialize_aptos_coin|initialize_core_resources_and_aptos_coin" \
  aptos-move/vm-genesis aptos-move/e2e-tests
```

Expected result:

```text
genesis uses topo_governance, initialize_topo_coin, and initialize_core_resources_and_topo_coin.
e2e executor force_end_epoch calls topo_governance.
```

- [ ] Update cached-package transaction payload callers from old coin helper names:

```bash
rg -n "aptos_coin_transfer|aptos_coin_mint|aptos_account_transfer|aptos_account_create_account" \
  aptos-move testsuite api crates
```

Expected result:

```text
Callers use topo_coin_transfer, topo_coin_mint, topo_account_transfer, or topo_account_create_account.
Intentional compatibility aliases, if any, are documented.
```

- [ ] Update utility coin and chain-id fallout:

```text
types/src/utility_coin.rs
sdk/src/types.rs
types/src/chain_id.rs
aptos-move/e2e-move-tests/src/tests/chain_id.rs
aptos-move/e2e-move-tests/src/tests/transaction_context.rs
```

Expected result:

```text
TopoCoinType type tags point at 0x1::topo_coin::TopoCoin.
TOPO_COIN_TYPE_STR is 0x1::topo_coin::TopoCoin.
NamedChain::from_chain_id matches against the enum ids, not stale numeric ids.
e2e chain-id assertions compare with ChainId::test().id().
```

- [ ] Update Move package resolver built-in package subdirectories:

```text
third_party/move/tools/move-package/src/source_package/std_lib.rs
```

Expected result:

```text
TopoStdlib -> topo-stdlib
TopoToken -> topo-token
TopoTokenObjects -> topo-token-objects
TopoTrading -> topo-trading
TopoFramework -> topo-framework
```

- [ ] Update e2e-built example packages before running full e2e:

```text
aptos-move/move-examples/mint_nft/1-Create-NFT
aptos-move/move-examples/mint_nft/2-Using-Resource-Account
aptos-move/move-examples/mint_nft/3-Adding-Admin
aptos-move/move-examples/mint_nft/4-Getting-Production-Ready
aptos-move/move-examples/dao/nft_dao
aptos-move/move-examples/token_objects/hero
aptos-move/move-examples/resource_account
aptos-move/move-examples/event
aptos-move/move-examples/scripts/two_by_two_transfer
aptos-move/move-examples/resource_groups/primary
aptos-move/move-examples/resource_groups/secondary
```

Required package checks:

```bash
rg -n "github.com/aptos-labs/topo-framework|subdir = \"aptos-token|subdir = \"aptos-token-objects|subdir = \"aptos-stdlib\"" \
  aptos-move/move-examples aptos-move/e2e-move-tests/src/tests
rg -n "aptos_std::|aptos_token::|aptos_token_objects::" \
  aptos-move/move-examples/mint_nft \
  aptos-move/move-examples/dao/nft_dao \
  aptos-move/move-examples/token_objects/hero \
  aptos-move/move-examples/resource_account \
  aptos-move/move-examples/event \
  aptos-move/move-examples/scripts/two_by_two_transfer \
  aptos-move/move-examples/resource_groups
```

Expected result:

```text
Packages built by e2e tests use local topo-framework/topo-stdlib/topo-token/topo-token-objects dependencies.
Move source imports use topo_std, topo_token, and topo_token_objects.
No e2e-built example package fetches the remote topo-framework git repo.
```

- [ ] Update smoke-test runtime Move scripts embedded in Rust string literals:

```text
testsuite/smoke-test/src/chunky_dkg/enable_feature.rs
testsuite/smoke-test/src/chunky_dkg/epoch_timeout.rs
testsuite/smoke-test/src/chunky_dkg/shadow_mode.rs
testsuite/smoke-test/src/decryption/mod.rs
testsuite/smoke-test/src/permissioned_delegation.rs
testsuite/smoke-test/src/randomness/enable_feature_2.rs
testsuite/smoke-test/src/randomness/mod.rs
```

Required checks:

```bash
rg -n "aptos_std::|aptos_framework::|aptos_token::|aptos_token_objects::" \
  testsuite/smoke-test
```

Expected result:

```text
Governance/randomness/decryption/chunky-DKG scripts import topo_std::fixed_point64.
Permissioned delegation scripts import topo_std::ed25519.
No smoke-test runtime script still imports aptos_std, aptos_framework, aptos_token, or aptos_token_objects.
```

- [ ] Update Rust-side smoke/CLI/Rosetta strings that still name old framework modules:

```text
crates/aptos/src/test/mod.rs
crates/aptos/src/common/init.rs
crates/aptos/src/governance/mod.rs
crates/aptos-rosetta/src/types/move_types.rs
aptos-move/aptos-release-builder/src/simulate.rs
aptos-move/aptos-sdk-builder/src/golang.rs
```

Required checks:

```bash
rg -n "aptos_account|aptos_coin|aptos_governance|0x1::AptosCoin::AptosCoin|0x1::aptos" \
  crates/aptos crates/aptos-rosetta aptos-move/aptos-release-builder/src \
  aptos-move/aptos-sdk-builder/src testsuite/smoke-test/src testsuite/forge/src api/src
```

Expected result:

```text
Runtime module strings use topo_account, topo_coin, and topo_governance.
0x1::topo_coin::TopoCoin is used for native coin type tags.
Remaining old-name hits are function names, compatibility names, comments, or external Aptos concepts.
```

- [ ] Update account-abstraction derivable-account tests to use the actual swarm chain id.

```text
testsuite/smoke-test/src/account_abstraction.rs
testsuite/smoke-test/src/sui_derivable_account.rs
```

Required behavior:

```text
Do not hard-code Chain ID: 4.
Do not hard-code Aptos blockchain (local).
Read info.transaction_factory().get_chain_id().id().
Format network name as mainnet/testnet/local/custom network: <id>, matching Move verifier behavior.
```

Expected result:

```text
Ethereum, Solana, and Sui derivable-account tests do not abort with vm_error_code 4016 when the local swarm uses a custom chain id.
```

- [ ] Update the local CLI faucet mint path after the topo coin module rename.

```text
crates/aptos-faucet/core/src/server/run.rs
crates/aptos-faucet/core/src/funder/mod.rs
```

Required behavior:

```text
RunConfig::build_for_cli should not rely on stale checked-in minter script bytecode.
Configure the default mint asset to use TransactionMethod::EntryFunction.
The entry function should be 0x1::topo_coin::mint.
```

Expected result:

```text
Faucet-driven smoke tests do not fail with LINKER_ERROR from the old minter script.
```

- [ ] Apply known e2e stability fixes discovered during migration:

```text
aptos-move/e2e-move-tests/src/tests/memory_quota.rs
aptos-move/e2e-move-tests/src/tests/transaction_context.rs
third_party/move/tools/move-coverage/src/coverage_map.rs
```

Expected result:

```text
memory_quota manually spawned compiler threads use a large enough stack.
transaction_context block-split proptest has a bounded local case count.
move-coverage accepts both Script::main and script::main when skipping script trace records.
```

- [ ] Regenerate OpenAPI only if the API-visible representation changed because of the rename.

```bash
cargo run -p aptos-openapi-spec-generator -- -f yaml -o api/doc/spec.yaml
cargo run -p aptos-openapi-spec-generator -- -f json -o api/doc/spec.json
```

### Phase E completion check

- [ ] Every non-framework file touched can be justified as a direct rename consequence.
- [ ] No broad unrelated Rust subtree was modified "just to keep names consistent".

## 7. Explicit Non-Goals

- [ ] Do not carry branch-local extras unless they are separately requested:

```text
POC dashboard changes
workflow/release script additions
source-hiding CLI feature work
large binary fixture churn
unrelated docs cleanup
```

- [ ] Do not assume these paths belong in the default migration:

```text
third_party/
crates/
consensus/
storage/
network/
execution/
state-sync/
```

- [ ] If you change files there anyway, add a short written justification before keeping them.

## 8. Search Passes

- [ ] Search the framework subtree first:

```bash
rg -n "AptosFramework|AptosStdlib|AptosToken|AptosTokenObjects|AptosTrading|aptos-framework|aptos_framework|aptos_account|aptos_coin|aptos_governance" \
  aptos-move/framework
```

- [ ] Search the direct integration surface second:

```bash
rg -n "AptosFramework|AptosStdlib|aptos-framework|aptos_framework|aptos_account|aptos_coin|aptos_governance" \
  aptos-move/cli aptos-move/aptos-release-builder aptos-move/aptos-gas-schedule api testsuite/smoke-test aptos-move/e2e-move-tests
```

- [ ] Search known missed runtime/test symbols from the first migration pass:

```bash
rg -n "aptos_coin_transfer|initialize_aptos_coin|initialize_core_resources_and_aptos_coin|aptos_governance|aptos_std::|aptos_token::|aptos_token_objects::" \
  aptos-move testsuite api types third_party/move/tools/move-package
```

- [ ] Search for stale native coin names and mixed `topo_coin::AptosCoin` states:

```bash
rg -n "\bAptosCoin\b|Aptos Coin|0x1::topo_coin::AptosCoin|\bis_apt\b|\ballow_apt_creation\b|EAPT_PAIRING_IS_NOT_ENABLED|APTOS_COIN_TYPE_STR|\bAptosCoinType\b|test_apt" \
  aptos-move/framework/topo-framework \
  aptos-move/e2e-move-tests/src \
  aptos-move/e2e-tests/src \
  testsuite/smoke-test/src \
  crates/aptos crates/aptos-rosetta sdk types api/src api/types
```

Expected result:

```text
Core runtime/test surfaces use TopoCoin, TOPO_COIN_TYPE_STR, TopoCoinType, and is_topo.
Any remaining APT/AptosCoin hits are reviewed as external Aptos concepts, legacy fixtures, or intentionally unchanged compatibility text.
```

- [ ] Search Rust smoke/CLI/Rosetta integration strings for old chain-owned module names:

```bash
rg -n "aptos_account|aptos_coin|aptos_governance|0x1::AptosCoin::AptosCoin|0x1::aptos" \
  crates/aptos crates/aptos-rosetta crates/aptos-faucet aptos-move/aptos-release-builder/src \
  aptos-move/aptos-sdk-builder/src testsuite/smoke-test/src testsuite/forge/src api/src
```

- [ ] Search local faucet paths for stale minter script usage if faucet smoke tests fail with `LINKER_ERROR`:

```bash
rg -n "MINTER_SCRIPT|TransactionMethod::Script|topo_coin|aptos_coin" crates/aptos-faucet aptos-move/move-examples/scripts/minter
```

- [ ] Search e2e-built packages for stale remote dependency subdirs:

```bash
rg -n "github.com/aptos-labs/topo-framework|subdir = \"aptos-token|subdir = \"aptos-token-objects|subdir = \"aptos-stdlib\"" \
  aptos-move/move-examples aptos-move/e2e-move-tests/src/tests
```

- [ ] Search smoke-test runtime script strings for stale framework package imports:

```bash
rg -n "use aptos_std::|use aptos_framework::|use aptos_token::|use aptos_token_objects::" \
  testsuite/smoke-test
```

- [ ] Classify each remaining old-name hit:

```text
Must change: stale internal references to renamed framework packages/modules.
May stay: compatibility aliases, external Aptos concepts, intentional unchanged addresses, historical docs.
```

## 9. Verification And Test Plan

Run verification in layers. Do not move to broad downstream tests until the framework package set and cached packages are stable.

### 9.1 Static rename audit

- [ ] Confirm the target framework directories exist.

```bash
find aptos-move/framework -maxdepth 2 -type d | sort
```

Expected result:

```text
aptos-move/framework/topo-framework
aptos-move/framework/topo-stdlib
aptos-move/framework/topo-token
aptos-move/framework/topo-token-objects
aptos-move/framework/topo-trading
```

- [ ] Search old names in the framework subtree.

```bash
rg -n "AptosFramework|AptosStdlib|AptosToken|AptosTokenObjects|AptosTrading|aptos-framework|aptos_framework|aptos_account|aptos_coin|aptos_governance" \
  aptos-move/framework
```

Expected result:

```text
No stale references to renamed package/module names.
Any remaining old-name hits are reviewed as compatibility aliases, external Aptos concepts, historical docs, or intentional unchanged addresses.
```

- [ ] Search new names in the framework subtree.

```bash
rg -n "TopoFramework|TopoStdlib|TopoToken|TopoTokenObjects|TopoTrading|topo-framework|topo_framework|topo_account|topo_coin|topo_governance" \
  aptos-move/framework
```

Expected result:

```text
The renamed package names, crate names, named addresses, and module names appear in the expected framework files.
```

### 9.2 Workspace and framework checks

- [ ] Verify Cargo workspace metadata resolves.

```bash
cargo metadata --no-deps
```

- [ ] Verify the renamed framework Rust crates compile.

```bash
cargo check -p topo-framework
cargo check -p topo-framework-natives
```

- [ ] Run the framework test package.

```bash
cargo test -p topo-framework
```

Expected result:

```text
The package rename regression test passes.
Move framework tests resolve TopoFramework, TopoStdlib, TopoToken, TopoTokenObjects, and TopoTrading.
No stale aptos-framework crate dependency is required for the framework package.
```

### 9.3 Cached package verification

- [ ] Rebuild cached framework packages after the final Move/framework edit.

```bash
scripts/cargo_build_aptos_cached_packages.sh
```

- [ ] Inspect generated cached package changes.

```bash
git status --short aptos-move/framework/cached-packages
git diff -- aptos-move/framework/cached-packages
```

Expected result:

```text
Generated cached package changes are limited to expected package/module rename fallout.
head.mrb changes when framework Move bytecode changed.
topo_stdlib is exported.
aptos_stdlib compatibility remains only if still required by callers.
```

### 9.4 Direct downstream integration checks

Run only the checks for areas touched by Phase E.

- [ ] Gas schedule and framework integration compile through the framework tests.

```bash
cargo check -p topo-framework
```

- [ ] Release builder tests, if release builder files changed.

```bash
cargo test -p aptos-release-builder
```

- [ ] CLI compile check, if CLI files changed.

```bash
cargo check -p aptos
```

- [ ] API tests, if API code, API goldens, or API test packages changed.

```bash
cargo test -p aptos-api
```

- [ ] Move E2E tests, if e2e Move tests or renamed framework module references changed there.

```bash
RUST_MIN_STACK=8388608 cargo test -p e2e-move-tests
```

Expected result after the known migration fixes:

```text
335 passed; 0 failed; 12 ignored
```

- [ ] Run the framework Move unit test binary explicitly.

```bash
RUST_MIN_STACK=8388608 cargo test -p topo-framework --test move_unit_test
```

Expected result:

```text
Rust harness tests pass.
Move framework unit tests report all tests passed.
```

- [ ] Run targeted native coin and package-publish regression checks after the TopoCoin rename.

```bash
TEST_FILTER=topo_coin RUST_MIN_STACK=8388608 cargo test -p topo-framework --test move_unit_test move_framework_unit_tests -- --nocapture
RUST_MIN_STACK=8388608 cargo test -p e2e-move-tests simple_defi
```

Expected result:

```text
topo_coin tests pass with TopoCoin symbols.
simple_defi package publish succeeds; a LOOKUP_FAILED status usually means cached head.mrb is stale or a package still references topo_coin::AptosCoin.
```

- [ ] Compile the p2p profiling binary if cached package transfer helpers changed.

```bash
cargo check -p aptos-vm-profiling --bin run-aptos-p2p
```

- [ ] Smoke tests, if genesis, framework publish, staking, CLI smoke, or package publish paths changed.

```bash
cargo test -p smoke-test
```

When triaging the known runtime-script migration surface, run these targeted smoke tests first:

```bash
RUST_MIN_STACK=8388608 cargo test -p smoke-test chunky_dkg::enable_feature::chunky_dkg_enable_feature -- --nocapture
RUST_MIN_STACK=8388608 cargo test -p smoke-test test_permissioned_delegation -- --nocapture
RUST_MIN_STACK=8388608 cargo test -p smoke-test randomness::enable_feature_2::enable_feature_2 -- --nocapture
```

- [ ] Run targeted smoke tests for the derivable-account and Rosetta failures discovered in the broad smoke run:

```bash
RUST_MIN_STACK=8388608 cargo test -p smoke-test account_abstraction::test_ethereum_derivable_account -- --nocapture
RUST_MIN_STACK=8388608 cargo test -p smoke-test account_abstraction::test_solana_derivable_account -- --nocapture
RUST_MIN_STACK=8388608 cargo test -p smoke-test sui_derivable_account::test_sui_derivable_account -- --nocapture
RUST_MIN_STACK=8388608 cargo test -p smoke-test rosetta::test_network -- --nocapture
```

Expected result:

```text
Derivable-account tests use the actual chain id and matching network display name.
Rosetta/faucet smoke path mints through topo_coin::mint and does not fail with LINKER_ERROR.
```

Expected result:

```text
Failures should be rename-related only.
If a failure points to unrelated runtime, protocol, storage, or consensus behavior, stop and re-check whether the migration scope expanded incorrectly.
```

### 9.5 API and golden verification

Run this section only if API-visible output changes.

- [ ] Regenerate OpenAPI specs.

```bash
cargo run -p aptos-openapi-spec-generator -- -f yaml -o api/doc/spec.yaml
cargo run -p aptos-openapi-spec-generator -- -f json -o api/doc/spec.json
```

- [ ] Review API output changes.

```bash
git diff -- api/doc/spec.yaml api/doc/spec.json api/goldens api/src/tests
```

Expected result:

```text
Diffs should be limited to expected renamed package/module identifiers, such as TopoFramework, topo_framework, topo_account, topo_coin, or topo_governance.
Unexpected schema shape changes should be treated as migration bugs unless separately justified.
```

### 9.6 Final hygiene checks

- [ ] Run formatting check.

```bash
cargo +nightly fmt --check
```

- [ ] Run clippy on the core renamed framework crate.

```bash
cargo xclippy -p topo-framework
```

- [ ] Review the final diff shape.

```bash
git diff --stat
git diff --name-only
```

Expected result:

```text
The diff remains framework-centered.
Non-framework files are limited to direct integration fallout or documented follow-up changes.
```

### 9.7 Failure triage

- [ ] If Move package resolution fails, inspect the renamed `Move.toml` files first.
- [ ] If Cargo cannot resolve `topo-framework`, inspect root `Cargo.toml`, `aptos-move/framework/Cargo.toml`, and stale `aptos-framework` dependencies.
- [ ] If cached package symbols fail, inspect `aptos-move/framework/cached-packages/src/lib.rs` and whether `topo_stdlib` plus any needed compatibility alias is exported.
- [ ] If `simple_defi` publish fails with `Keep(MiscellaneousError(Some(LOOKUP_FAILED)))`, inspect stale `topo_coin::AptosCoin` references and confirm `scripts/cargo_build_aptos_cached_packages.sh` updated `head.mrb`.
- [ ] If API tests fail only in expected text/goldens, regenerate or update goldens after confirming the rename is intentional.
- [ ] If e2e or smoke tests fail around genesis/package publish/staking, inspect framework package metadata names, named addresses, and cached packages before touching unrelated runtime code.
- [ ] If e2e fails with "function does not exist" under `0x1::genesis`, inspect stale genesis function wrappers in `aptos-move/vm-genesis/src/lib.rs`.
- [ ] If e2e fails while "FETCHING GIT DEPENDENCY https://github.com/aptos-labs/topo-framework.git", inspect the e2e-built example package `Move.toml` and replace remote dependencies with local `topo-*` packages.
- [ ] If e2e fails with unresolved `aptos_std`, `aptos_token`, or `aptos_token_objects`, inspect the example package sources that the test builds, not only framework sources.
- [ ] If smoke tests fail while compiling `RunScript` with `address 'aptos_std' is not assigned a value`, inspect Rust string-literal Move scripts under `testsuite/smoke-test`, especially chunky DKG, decryption, randomness, and permissioned delegation.
- [ ] If e2e chain-id assertions fail, inspect `types/src/chain_id.rs` and hard-coded e2e expected ids before changing chain-id native behavior.
- [ ] If account-abstraction derivable-account tests fail with `vm_error_code Some(4016)`, inspect the signed message body for stale hard-coded `Chain ID: 4` or `Aptos blockchain (local)`.
- [ ] If Rosetta or CLI smoke tests fail during faucet funding with `LINKER_ERROR`, inspect whether the local faucet is submitting the stale minter script instead of `0x1::topo_coin::mint`.
- [ ] If Rosetta tests fail to parse transfer operations, inspect `crates/aptos-rosetta/src/types/move_types.rs` for stale `aptos_account` or `aptos_coin` module constants.
- [ ] If `move_executor_coverage::test_coverage` fails on `"script"` vs `"Script"`, update `move-coverage` trace parsing to accept both spellings for skipped script records.
- [ ] If `memory_quota` aborts with stack overflow, inspect manually spawned setup/compiler threads; increasing only `RUST_MIN_STACK` is insufficient.
- [ ] If a failure points into consensus, storage, network, crypto, or protocol code, pause and verify whether the failure is really caused by the framework rename.

## 10. Final Acceptance Checklist

- [ ] The five framework package directories use the `topo-*` names.
- [ ] The five framework Move package names use the `Topo*` names.
- [ ] The three main modules use the `topo_*` names.
- [ ] `topo-framework` and `topo-framework-natives` are the framework Rust crate identities.
- [ ] Cached packages rebuild successfully.
- [ ] `cargo test -p topo-framework` passes.
- [ ] Targeted downstream checks pass for every downstream area touched.
- [ ] API/OpenAPI/golden changes, if any, are limited to expected renamed identifiers.
- [ ] Downstream edits are limited to direct integration fallout.
- [ ] Any remaining `aptos_*` names are intentional and understood.

## 11. Reference Diff Commands

Look only at the framework-centered reference diff from the existing source branch:

```bash
git diff --find-renames de0e326405517cef605319b23fcc2b1f95a55ca4...topo_framework -- \
  aptos-move/framework \
  aptos-move/cli/src/commands.rs \
  aptos-move/aptos-release-builder/src/components/framework.rs \
  aptos-move/aptos-gas-schedule/src/gas_schedule
```

If needed, inspect only package manifests from the source branch:

```bash
git show topo_framework:aptos-move/framework/topo-framework/Move.toml
git show topo_framework:aptos-move/framework/topo-stdlib/Move.toml
git show topo_framework:aptos-move/framework/topo-token/Move.toml
git show topo_framework:aptos-move/framework/topo-token-objects/Move.toml
git show topo_framework:aptos-move/framework/topo-trading/Move.toml
```
