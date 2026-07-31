# Topo Framework Migration Summary

This document is the target-state summary for rebuilding the `aptos-framework` -> `topo-framework` migration on a fresh branch.

It is intentionally written as a reconstruction reference, not as a full narrative of every file touched on the current `topo_framework` branch.

Use it to answer three questions:

1. what the rebuilt branch is supposed to look like
2. which renames are mandatory
3. which downstream changes are allowed only as minimal follow-up, not as a repo-wide sweep

## Primary Goal

On a fresh branch, rename the Aptos framework package family and the main chain-owned framework modules from the `aptos_*` naming to the `topo_*` naming, while preserving the minimum compatibility surface required for the repo to build and test.

The reconstruction goal is:

- rename the framework package directories
- rename the Rust framework crate names
- rename the Move package identities
- rename the main chain-owned framework modules
- update only the direct Rust/Test/API integration points that explicitly refer to those renamed packages or modules

This is not a repo-wide "replace aptos with topo" task.

## Source Branch Reference

When cross-checking against the existing implementation work:

- source branch: `topo_framework`
- reference HEAD at time of writing: `be171945077f9913766c15d87ad9c7945bcca06f`
- merge-base used during audit: `de0e326405517cef605319b23fcc2b1f95a55ca4`

Useful reference commands:

```bash
git rev-parse topo_framework
git merge-base topo_framework company/main
git diff --name-status --find-renames de0e326405517cef605319b23fcc2b1f95a55ca4...topo_framework -- aptos-move/framework
```

The existing `topo_framework` branch contains much more than the rename itself. Use it as a lookup source, not as a blind replay source.

## Target End State

### Directory/package rename map

These package directories are the core of the migration:

| Old path | New path |
| --- | --- |
| `aptos-move/framework/aptos-framework` | `aptos-move/framework/topo-framework` |
| `aptos-move/framework/aptos-stdlib` | `aptos-move/framework/topo-stdlib` |
| `aptos-move/framework/aptos-token` | `aptos-move/framework/topo-token` |
| `aptos-move/framework/aptos-token-objects` | `aptos-move/framework/topo-token-objects` |
| `aptos-move/framework/aptos-trading` | `aptos-move/framework/topo-trading` |

### Move package identity map

After the migration, the package names should be:

| Old package | New package |
| --- | --- |
| `AptosFramework` | `TopoFramework` |
| `AptosStdlib` | `TopoStdlib` |
| `AptosToken` | `TopoToken` |
| `AptosTokenObjects` | `TopoTokenObjects` |
| `AptosTrading` | `TopoTrading` |

### Rust crate identity map

The framework Rust crates should end up as:

| Old crate | New crate |
| --- | --- |
| `aptos-framework` | `topo-framework` |
| `aptos-framework-natives` | `topo-framework-natives` |
| `aptos_framework` | `topo_framework` |
| `aptos_framework_natives` | `topo_framework_natives` |

### Main Move module rename map

These are the main module renames that define the framework-level API rename:

| Old module | New module |
| --- | --- |
| `aptos_account` | `topo_account` |
| `aptos_coin` | `topo_coin` |
| `aptos_governance` | `topo_governance` |

Their corresponding source/spec/doc/test files should move with the module rename.

### Main coin type target state

The native coin should be migrated as a coin type rename, not only as a module-file rename.

Expected framework-local outcomes:

| Old symbol/string | New symbol/string |
| --- | --- |
| `struct AptosCoin` | `struct TopoCoin` |
| `AptosCoinCapabilities` | `TopoCoinCapabilities` |
| `AptosCoinMintCapability` | `TopoCoinMintCapability` |
| `ExistsAptosCoin` | `ExistsTopoCoin` |
| `is_apt<CoinType>()` | `is_topo<CoinType>()` |
| `allow_apt_creation` | `allow_topo_creation` |
| `EAPT_PAIRING_IS_NOT_ENABLED` | `ETOPO_PAIRING_IS_NOT_ENABLED` |
| `0x1::topo_coin::AptosCoin` | `0x1::topo_coin::TopoCoin` |
| coin metadata `Aptos Coin` / `APT` | `Topo Coin` / `TOPO` |

Important Rust/API integration outcomes:

- `types/src/utility_coin.rs` exposes `TopoCoinType`, whose type tag is `0x1::topo_coin::TopoCoin`
- `sdk/src/types.rs` uses `TOPO_COIN_TYPE_STR = "0x1::topo_coin::TopoCoin"`
- generated cached package helpers such as `topo_stdlib::topo_coin_transfer` use `TopoCoinType`
- Rosetta/native transfer parsing recognizes `topo_account` and `topo_coin`, with `TopoCoin` as the native coin resource

Do not leave mixed names like `topo_coin::AptosCoin`; that state compiles in some places but fails once e2e tests publish packages or runtime helpers look up the native coin type.

## Package Manifest Target State

These are the key manifest outcomes that should exist on the rebuilt branch.

### `aptos-move/framework/topo-framework/Move.toml`

Expected essentials:

- package name: `TopoFramework`
- addresses:
  - `std = "0x1"`
  - `topo_std = "0x1"`
  - `topo_framework = "0x1"`
- still intentionally present:
  - `aptos_fungible_asset = "0xA"`
  - `aptos_token = "0x3"`
  - `core_resources = "0xA550C18"`
  - `vm_reserved = "0x0"`
- dependencies:
  - `TopoStdlib = { local = "../topo-stdlib" }`
  - `MoveStdlib = { local = "../move-stdlib" }`

### `aptos-move/framework/topo-stdlib/Move.toml`

Expected essentials:

- package name: `TopoStdlib`
- addresses:
  - `std = "0x1"`
  - `topo_std = "0x1"`
  - `topo_framework = "0x1"`

### `aptos-move/framework/topo-token/Move.toml`

Expected essentials:

- package name: `TopoToken`
- addresses:
  - `std = "0x1"`
  - `topo_framework = "0x1"`
  - `topo_token = "0x3"`
- dependency:
  - `TopoFramework = { local = "../topo-framework" }`

### `aptos-move/framework/topo-token-objects/Move.toml`

Expected essentials:

- package name: `TopoTokenObjects`
- addresses:
  - `std = "0x1"`
  - `topo_std = "0x1"`
  - `topo_framework = "0x1"`
  - `topo_token_objects = "0x4"`
- dependency:
  - `TopoFramework = { local = "../topo-framework" }`

### `aptos-move/framework/topo-trading/Move.toml`

Expected essentials:

- package name: `TopoTrading`
- addresses:
  - `std = "0x1"`
  - `topo_std = "0x1"`
  - `topo_framework = "0x1"`
  - `topo_trading = "0x5"`
- dependencies:
  - `TopoStdlib = { local = "../topo-stdlib" }`
  - `TopoFramework = { local = "../topo-framework" }`

## Rust Wiring Target State

These are the Rust-side changes that are part of the rename itself and should exist on the rebuilt branch.

### Root workspace

In the root `Cargo.toml`:

- `topo-framework = { path = "aptos-move/framework" }`
- `topo-framework-natives = { path = "aptos-move/framework/natives" }`

### Framework crate

In `aptos-move/framework/Cargo.toml`:

- package name is `topo-framework`
- dependency on `topo-framework-natives = { workspace = true }`

The current branch also shows:

- `aptos-move/framework/src/main.rs` program name: `topo-framework`
- feature wiring and imports moved from `aptos_framework*` to `topo_framework*`

### Framework build glue

These files define the framework package set and should be aligned with the new names:

- `aptos-move/framework/src/lib.rs`
- `aptos-move/framework/src/aptos.rs`
- `aptos-move/framework/src/built_package.rs`

Expected outcomes:

- framework package ordering uses `topo-stdlib`, `topo-framework`, `topo-token`, `topo-token-objects`, `topo-trading`
- canonical package identities use `TopoFramework`, `TopoStdlib`, `TopoToken`, `TopoTokenObjects`, `TopoTrading`

### Cached packages

Expected outcomes:

- `aptos-move/framework/cached-packages/src/lib.rs` exports `topo_stdlib`
- compatibility alias `pub use topo_stdlib as aptos_stdlib` may remain temporarily
- token builder helper module names move from `aptos_token_*` to `topo_token_*`

## Minimal Downstream Integration Surface

Only a small set of non-framework areas should be considered first-class migration participants.

### Must-review integration points

- `aptos-move/aptos-gas-schedule/src/gas_schedule/mod.rs`
- `aptos-move/aptos-gas-schedule/src/gas_schedule/topo_framework.rs`
- `aptos-move/cli/src/commands.rs`
- `aptos-move/aptos-release-builder/src/components/framework.rs`
- framework-related cached package callers

### Typical expected changes there

- `AptosFramework` -> `TopoFramework`
- `aptos_framework` -> `topo_framework`
- path/module references updated to `topo-framework`
- cached package references updated from `aptos_stdlib` to `topo_stdlib` where appropriate

### Test and golden follow-up

The following areas may need edits, but only after the framework rename is in place and only where the expected output explicitly names the renamed packages/modules:

- `aptos-move/e2e-move-tests`
- `testsuite/smoke-test`
- `api/src/tests`
- `api/goldens`
- `api/doc/spec.yaml`
- `api/doc/spec.json`

## Test-Discovered Omissions From `feat/topo_rebase`

The `feat/topo_rebase` migration pass exposed several rename gaps only after running the framework and e2e tests. Treat these as mandatory checks in the next rebuild, because they are easy to miss with framework-only search passes.

### Genesis and cached-package callers

| Area | Missed stale reference | Required fix |
| --- | --- | --- |
| `aptos-move/vm-genesis/src/lib.rs` | `aptos_governance`, `initialize_aptos_coin`, `initialize_core_resources_and_aptos_coin` | Use `topo_governance`, `initialize_topo_coin`, and `initialize_core_resources_and_topo_coin` |
| `aptos-move/e2e-tests/src/executor.rs` | `exec("aptos_governance", "force_end_epoch", ...)` | Call `topo_governance::force_end_epoch` |
| cached package users | `aptos_cached_packages::topo_stdlib::aptos_coin_transfer` | Use `topo_coin_transfer` |
| `types/src/utility_coin.rs` | `TopoCoinType` still points at module `aptos_coin` | Point the coin type tag and `MoveStructType::MODULE_NAME` at `topo_coin` |

### Native coin rename fallout

The main coin migration must update the Move type, framework helper predicates, Rust type tags, generated cached package helpers, tests, specs, and API-visible strings together.

Known stale references from the `feat/topo_rebase` pass:

| Area | Missed stale reference | Required fix |
| --- | --- | --- |
| `aptos-move/framework/topo-framework/sources/topo_coin.move` | `struct AptosCoin`, `MintCapability<AptosCoin>`, `coin::mint<AptosCoin>`, metadata `Aptos Coin` / `APT` | Use `TopoCoin`, `MintCapability<TopoCoin>`, `coin::mint<TopoCoin>`, metadata `Topo Coin` / `TOPO` |
| `aptos-move/framework/topo-framework/sources/coin.move` | `is_apt<CoinType>()` compares against `0x1::topo_coin::AptosCoin` | Rename to `is_topo<CoinType>()` and compare against `0x1::topo_coin::TopoCoin` |
| framework specs/tests | comments/spec utf8 checks/test names still refer to APT/AptosCoin | Update to TOPO/TopoCoin and rename tests such as `test_apt_setup_and_mint` |
| `types/src/utility_coin.rs` | old `AptosCoinType` naming or `TopoCoinType` pointing at the old resource | Use `TopoCoinType` pointing at module `topo_coin`, struct `TopoCoin` |
| `sdk/src/types.rs` | old `APTOS_COIN_TYPE_STR` or old string literal | Use `TOPO_COIN_TYPE_STR = "0x1::topo_coin::TopoCoin"` |
| generated cached packages | helper code still imports/uses the old coin type | Regenerate cached packages and ensure `topo_stdlib::topo_coin_transfer` uses `TopoCoinType` |
| e2e examples and goldens | package/test expectations still use `0x1::topo_coin::AptosCoin` | Update only the direct compile/runtime/golden references to `0x1::topo_coin::TopoCoin` |

Representative failure when Move source is updated but the cached framework bundle is stale:

```text
tests::simple_defi::exchange_e2e_test ... FAILED
left: Keep(MiscellaneousError(Some(LOOKUP_FAILED)))
right: Keep(Success)
```

Root cause: `head.mrb` still contains the old framework bundle. `cargo build -p aptos-cached-packages` only proves the crate compiles; it is not a substitute for regenerating cached packages.

Required command after any `.move` edit under `aptos-move/framework/`:

```bash
scripts/cargo_build_aptos_cached_packages.sh
git status --short aptos-move/framework/cached-packages
```

Expected result:

```text
aptos-move/framework/cached-packages/src/head.mrb is updated when framework bytecode changed.
topo_framework_sdk_builder.rs and topo_stdlib.rs reflect TopoCoin/TopoCoinType helper changes when needed.
```

Useful targeted verification:

```bash
TEST_FILTER=topo_coin RUST_MIN_STACK=8388608 cargo test -p topo-framework --test move_unit_test move_framework_unit_tests -- --nocapture
RUST_MIN_STACK=8388608 cargo test -p e2e-move-tests simple_defi
```

### Chain id and native helper fallout

| Area | Symptom | Required fix |
| --- | --- | --- |
| `types/src/chain_id.rs` | e2e chain-id tests fail because `NamedChain::from_chain_id` still maps old ids `1..5` | Match against `NamedChain::{MAINNET,TESTNET,DEVNET,TESTING,PREMAINNET}.id()` |
| e2e chain-id tests | hard-coded expected chain id `4` fails after chain id constants move | Compare with `ChainId::test().id()` |
| e2e Move source | feature helper renamed too broadly | Keep actual framework function names that are intentionally still `aptos_*`, for example `features::get_aptos_stdlib_chain_id_feature()` |

### Move package resolver and stdlib package naming

| Area | Missed stale reference | Required fix |
| --- | --- | --- |
| `third_party/move/tools/move-package/src/source_package/std_lib.rs` | `StdLib::sub_dir()` still maps `TopoStdlib`, token, token objects, and trading packages to `aptos-*` subdirectories | Map to `topo-stdlib`, `topo-token`, `topo-token-objects`, and `topo-trading` |
| e2e package manifests | local dependencies still use `aptos-stdlib`, `aptos-token`, or `aptos-token-objects` | Switch to `topo-stdlib`, `topo-token`, and `topo-token-objects` |

### E2E examples and data packages

Several e2e tests build packages from `aptos-move/move-examples` or `aptos-move/e2e-move-tests/src/tests/**/*.data`. These packages must not keep remote `github.com/aptos-labs/topo-framework.git` dependencies or old subdirs, otherwise local e2e runs fail or test the wrong package set.

Known packages that required fixes:

- `aptos-move/move-examples/mint_nft/{1-Create-NFT,2-Using-Resource-Account,3-Adding-Admin,4-Getting-Production-Ready}`
- `aptos-move/move-examples/dao/nft_dao`
- `aptos-move/move-examples/token_objects/hero`
- `aptos-move/move-examples/resource_account`
- `aptos-move/move-examples/event`
- `aptos-move/move-examples/scripts/two_by_two_transfer`
- `aptos-move/move-examples/resource_groups/{primary,secondary}`
- `aptos-move/e2e-move-tests/src/tests/fv_as_table_keys.rs`

Required package-source rewrites in those examples:

| Old reference | New reference |
| --- | --- |
| `aptos_std::` | `topo_std::` |
| `aptos_token::` | `topo_token::` |
| `aptos_token_objects::` | `topo_token_objects::` |
| `TopoFramework = { git = "...", subdir = "topo-framework", ... }` | local `TopoFramework = { local = ".../framework/topo-framework" }` |
| `subdir = "aptos-token"` | local `topo-token` package |
| `subdir = "aptos-token-objects"` | local `topo-token-objects` package |
| `subdir = "aptos-stdlib"` | local `topo-stdlib` package |

### Smoke-test runtime Move scripts

Several smoke tests build governance, randomness, decryption, and permissioned-delegation Move scripts from Rust string literals. These are not standalone `.move` files, so they are easy to miss if the migration only searches framework sources and e2e packages.

Known smoke-test files that required fixes:

- `testsuite/smoke-test/src/chunky_dkg/enable_feature.rs`
- `testsuite/smoke-test/src/chunky_dkg/epoch_timeout.rs`
- `testsuite/smoke-test/src/chunky_dkg/shadow_mode.rs`
- `testsuite/smoke-test/src/decryption/mod.rs`
- `testsuite/smoke-test/src/permissioned_delegation.rs`
- `testsuite/smoke-test/src/randomness/enable_feature_2.rs`
- `testsuite/smoke-test/src/randomness/mod.rs`

Required string-literal rewrites:

| Old reference | New reference |
| --- | --- |
| `use aptos_std::fixed_point64;` | `use topo_std::fixed_point64;` |
| `use aptos_std::ed25519;` | `use topo_std::ed25519;` |

Representative failure:

```text
error: address with no value
use aptos_std::fixed_point64;
address 'aptos_std' is not assigned a value
```

### Smoke-test stale framework-module strings

The broad `smoke-test` run also exposed runtime failures from Rust-side constants and test helpers that still named the old chain-owned modules. These do not necessarily fail at compile time because the strings are used in REST calls, view functions, Rosetta operation parsing, or transaction payload construction.

Known stale string fixes from the `feat/topo_rebase` pass:

| Area | Symptom | Required fix |
| --- | --- | --- |
| `crates/aptos/src/test/mod.rs` | CLI validator smoke tests build a coin type under `0x1::aptos_coin::AptosCoin` | Use `0x1::topo_coin::TopoCoin` |
| `crates/aptos/src/common/init.rs` | CLI init/faucet balance checks ask for `0x1::AptosCoin::AptosCoin` | Use `0x1::topo_coin::TopoCoin` |
| `crates/aptos/src/governance/mod.rs` | Governance CLI view calls `aptos_governance::get_remaining_voting_power` | Call `topo_governance::get_remaining_voting_power` |
| `crates/aptos-rosetta/src/types/move_types.rs` | Rosetta native transfer parsing still recognizes `aptos_account`/`aptos_coin` | Recognize `topo_account`/`topo_coin` |
| `aptos-move/aptos-release-builder/src/simulate.rs` | Release simulation patches the old governance module id | Patch `topo_governance` |
| `aptos-move/aptos-sdk-builder/src/golang.rs` | Go SDK builder filters the old account module name | Filter `topo_account` |

Useful audit command:

```bash
rg -n "aptos_account|aptos_coin|aptos_governance|0x1::AptosCoin::AptosCoin|0x1::aptos" \
  crates/aptos crates/aptos-rosetta aptos-move/aptos-release-builder/src \
  aptos-move/aptos-sdk-builder/src testsuite/smoke-test/src testsuite/forge/src api/src
```

After the required fixes, any remaining hits in this surface should be reviewed as function names, comments, compatibility names, or external Aptos concepts rather than runtime module ids.

### Account-abstraction domain messages

The account-abstraction derivable-account tests sign domain messages that are verified by Move code. The Move verifier derives its network display string from the actual on-chain chain id. Local swarms can use a non-`4` chain id, for example `164`, where the Move-side display string is `custom network: 164`.

Do not hard-code either:

```text
Chain ID: 4
Aptos blockchain (local)
```

Required behavior:

- read the chain id from `info.transaction_factory().get_chain_id().id()`
- use the same network-name mapping as the Move verifier:
  - `1 -> mainnet`
  - `2 -> testnet`
  - `4 -> local`
  - otherwise `custom network: <id>`

Representative failure when this is missed:

```text
ABORTED vm_error_code Some(4016)
```

This affected:

- `testsuite/smoke-test/src/account_abstraction.rs`
- `testsuite/smoke-test/src/sui_derivable_account.rs`

### Faucet minting path

The smoke tests that drive the CLI faucet exposed a stale prebuilt minter script path. `MintFunder` defaults to `TransactionMethod::Script` and submits the checked-in `MINTER_SCRIPT` bytecode from:

```text
aptos-move/move-examples/scripts/minter/build/Minter/bytecode_scripts/main.mv
```

After the framework module rename, that script can still link against old framework module names and fail at execution time.

Representative failure:

```text
Faucet issue ... Transaction committed on chain, but failed execution: LINKER_ERROR
```

Required fix for local CLI/server faucet construction:

- use `TransactionMethod::EntryFunction`
- call `0x1::topo_coin::mint`

This keeps faucet-driven smoke tests from depending on stale checked-in script bytecode.

### Long-running or flaky e2e-adjacent failures

| Area | Symptom | Required fix |
| --- | --- | --- |
| `aptos-move/e2e-move-tests/src/tests/memory_quota.rs` | Full e2e run can abort with stack overflow inside manually spawned compiler threads | Increase the spawned setup thread stack size; the outer `RUST_MIN_STACK` does not affect manually spawned threads |
| `aptos-move/e2e-move-tests/src/tests/transaction_context.rs` | `test_monotonically_increasing_counter_across_transactions_with_block_splits` can dominate full e2e runtime | Add a local `ProptestConfig` with a bounded case count for this expensive block-split test |
| `third_party/move/tools/move-coverage/src/coverage_map.rs` | Full e2e coverage test failed on script trace context `"script::main"` vs expected `"Script::main"` | Accept both `Script` and `script` when skipping script trace records |

### Verification results from the fixed pass

The following commands passed after applying the above fixes:

```bash
RUST_MIN_STACK=8388608 cargo test -p topo-framework --test move_unit_test
RUST_MIN_STACK=8388608 cargo test -p e2e-move-tests
TEST_FILTER=topo_coin RUST_MIN_STACK=8388608 cargo test -p topo-framework --test move_unit_test move_framework_unit_tests -- --nocapture
RUST_MIN_STACK=8388608 cargo test -p e2e-move-tests simple_defi
cargo check -p aptos-vm-profiling --bin run-aptos-p2p
RUST_MIN_STACK=8388608 cargo test -p smoke-test chunky_dkg::enable_feature::chunky_dkg_enable_feature -- --nocapture
RUST_MIN_STACK=8388608 cargo test -p smoke-test test_permissioned_delegation -- --nocapture
RUST_MIN_STACK=8388608 cargo test -p smoke-test randomness::enable_feature_2::enable_feature_2 -- --nocapture
RUST_MIN_STACK=8388608 cargo test -p smoke-test account_abstraction::test_ethereum_derivable_account -- --nocapture
RUST_MIN_STACK=8388608 cargo test -p smoke-test account_abstraction::test_solana_derivable_account -- --nocapture
RUST_MIN_STACK=8388608 cargo test -p smoke-test sui_derivable_account::test_sui_derivable_account -- --nocapture
RUST_MIN_STACK=8388608 cargo test -p smoke-test rosetta::test_network -- --nocapture
```

Observed final e2e result after fixes:

```text
335 passed; 0 failed; 12 ignored
```

## Recommended Reconstruction Order

For a clean rebuild on a fresh branch, the safest sequence is:

1. rename the five framework package directories
2. update the five framework `Move.toml` package identities and named addresses
3. rename the three main modules:
   - `aptos_account`
   - `aptos_coin`
   - `aptos_governance`
4. update framework-local imports/docs/tests/specs
5. rename the Rust framework crates and update framework build glue
6. rebuild cached packages
7. fix only the direct downstream integration points that now fail to build or whose expected outputs explicitly contain the old names
8. regenerate API/spec/golden artifacts only if they changed because of the rename

This order matters: if downstream crates are touched before the framework package set is stable, the diff tends to grow unnecessarily.

## What Must Not Be Expanded Blindly

The existing `topo_framework` branch includes many broad edits outside the framework subtree. Those should not be treated as default migration scope.

Do not use the current branch as justification for sweeping changes under:

- `third_party/`
- `crates/`
- `consensus/`
- `storage/`
- `network/`
- `execution/`
- `state-sync/`

If files under those paths change on the rebuilt branch, document the exact dependency from the framework rename before keeping them.

## Allowed Compatibility Residue

Some `aptos_*` identifiers are allowed to remain after the rebuild.

Typical examples:

- compatibility aliases such as `aptos_stdlib` re-exported from `topo_stdlib`
- names that refer to external/public Aptos concepts
- addresses or modules intentionally not included in the rename set, such as `aptos_fungible_asset`

Do not classify every remaining `aptos_*` string as a missed migration.

## Useful Audit Commands

Search old names in the framework area:

```bash
rg -n "AptosFramework|AptosStdlib|AptosToken|AptosTokenObjects|AptosTrading|aptos-framework|aptos_framework|aptos_account|aptos_coin|aptos_governance" \
  aptos-move/framework
```

Search old names in the direct integration area:

```bash
rg -n "AptosFramework|AptosStdlib|aptos-framework|aptos_framework|aptos_account|aptos_coin|aptos_governance" \
  aptos-move/cli aptos-move/aptos-release-builder aptos-move/aptos-gas-schedule api testsuite/smoke-test aptos-move/e2e-move-tests
```

Inspect only the framework-related reference diff from the source branch:

```bash
git diff --find-renames de0e326405517cef605319b23fcc2b1f95a55ca4...topo_framework -- \
  aptos-move/framework \
  aptos-move/cli/src/commands.rs \
  aptos-move/aptos-release-builder/src/components/framework.rs \
  aptos-move/aptos-gas-schedule/src/gas_schedule
```

## Verification Strategy

The rebuilt branch should be verified in layers. Each layer should pass before expanding the migration to the next layer.

### Layer 1: static naming audit

This layer checks whether the intended rename actually landed and whether old names remain only where expected.

Required checks:

```bash
find aptos-move/framework -maxdepth 2 -type d | sort
rg -n "AptosFramework|AptosStdlib|AptosToken|AptosTokenObjects|AptosTrading|aptos-framework|aptos_framework|aptos_account|aptos_coin|aptos_governance" aptos-move/framework
rg -n "TopoFramework|TopoStdlib|TopoToken|TopoTokenObjects|TopoTrading|topo-framework|topo_framework|topo_account|topo_coin|topo_governance" aptos-move/framework
```

Expected result:

- the five `topo-*` framework package directories exist
- the five `Topo*` Move package names exist
- the three `topo_*` modules exist
- remaining old `aptos_*` matches are reviewed and classified as compatibility, external Aptos concepts, historical docs, or intentional unchanged addresses

### Layer 2: workspace and framework build

This layer proves the renamed Rust crate identities and framework package wiring resolve.

Required checks:

```bash
cargo metadata --no-deps
cargo check -p topo-framework
cargo check -p topo-framework-natives
cargo test -p topo-framework
```

Expected result:

- Cargo resolves `topo-framework` and `topo-framework-natives`
- framework tests build against the renamed Move package set
- the package rename regression test confirms package metadata name `TopoFramework`

### Layer 3: cached packages

This layer proves regenerated framework artifacts match the renamed package set.

Required checks:

```bash
scripts/cargo_build_aptos_cached_packages.sh
git status --short aptos-move/framework/cached-packages
```

Expected result:

- cached packages rebuild successfully
- `head.mrb` changes when framework Move bytecode changed
- generated changes are limited to expected framework package/module rename fallout
- compatibility exports such as `aptos_stdlib` are intentional if they remain

### Layer 4: direct downstream integration

Run these checks only after the framework layer is stable and only for areas that were touched.

Recommended checks:

```bash
cargo test -p aptos-release-builder
cargo check -p aptos
cargo test -p aptos-api
cargo test -p e2e-move-tests
cargo test -p smoke-test
```

Expected result:

- release builder resolves the renamed framework package paths
- CLI package injection uses `TopoFramework`/`topo-framework`
- API/e2e/smoke tests only change where expected outputs contain renamed package or module names

### Layer 5: generated API artifacts

Only run this layer if API-visible outputs change because of the rename.

Required commands when API output changes:

```bash
cargo run -p aptos-openapi-spec-generator -- -f yaml -o api/doc/spec.yaml
cargo run -p aptos-openapi-spec-generator -- -f json -o api/doc/spec.json
git diff -- api/doc/spec.yaml api/doc/spec.json api/goldens
```

Expected result:

- OpenAPI and golden diffs are limited to renamed framework/package/module identifiers
- unrelated API schema or behavior changes are not introduced by the migration

### Layer 6: final hygiene

Run these before handoff or PR:

```bash
cargo +nightly fmt --check
cargo xclippy -p topo-framework
git diff --stat
```

Expected result:

- formatting passes
- clippy passes for the core renamed framework crate
- `git diff --stat` still looks framework-centered, with downstream changes limited to direct integration fallout

## Acceptance Criteria

The rebuilt branch is in the right shape when all of the following are true:

- framework package directories are renamed to the `topo-*` names
- the five framework Move package names are the `Topo*` names
- the three main modules are renamed to `topo_*`
- `topo-framework` and `topo-framework-natives` resolve as the framework Rust crates
- cached packages rebuild successfully
- framework tests pass with `cargo test -p topo-framework`
- directly touched downstream packages pass their targeted checks
- API/OpenAPI/golden diffs, if present, only reflect expected renamed identifiers
- only direct downstream integration points are changed outside the framework subtree unless a specific dependency requires more

This summary defines the intended target state. The step-by-step execution order lives in `docs/TOPO_FRAMEWORK_MIGRATION_TODO.md`.
