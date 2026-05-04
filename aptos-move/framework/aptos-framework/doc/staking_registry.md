
<a id="0x1_staking_registry"></a>

# Module `0x1::staking_registry`

Staking Registry — Delegation, power accounting, and reward distribution for the POC validator set.


<a id="@Overview_0"></a>

### Overview


This module is the economic heart of the Topo chain's Proof-of-Contribution (POC) staking system.
It replaces the traditional "stake amount = voting power" model with a hybrid model where a user's
effective voting power is the MINIMUM of:
1. Their committed POC power (from <code><a href="poc_power_store.md#0x1_poc_power_store">poc_power_store</a></code>) — contribution-based weight
2. Their deposit coverage (deposit_octas * 1,000,000 / octas_per_million_power) — economic skin-in-the-game
If <code>octas_per_million_power == 0</code>, no deposit backing is required.

This dual-constraint design ensures that:
- Pure capital holders without contribution history cannot dominate governance
- Pure contributors without economic stake cannot dominate governance
- Both dimensions must be maintained to retain voting influence


<a id="@Key_Concepts_1"></a>

### Key Concepts


- ValidatorPool: A pool owned by a validator. Delegators stake behind a pool to lend it their power.
- UserStakeInfo: Per-user record of deposited TOPO coins, current delegation target, and cooldown state.
- Effective Power: min(committed_poc_power, deposit_octas * 1,000,000 / octas_per_million_power),
or committed_poc_power when deposit backing is disabled.
- Commission: Validators earn a percentage of epoch rewards and transaction fees from their pool.
- Cooldown: After undelegating, users must wait <code>cooldown_secs</code> before they can re-delegate or withdraw.
This prevents rapid stake-hopping that could destabilize the validator set.
- Force Undelegate: If a user's effective power drops below <code>maintain_threshold</code> (a fraction of
<code>min_active_power</code>), they are automatically removed from the pool at epoch boundaries.


<a id="@Reward_Flow_2"></a>

### Reward Flow


At each epoch boundary (<code>on_new_epoch</code> in stake.move):
1. <code>distribute_epoch_rewards</code> is called for each active/pending_inactive validator
2. Rewards are minted proportionally to each delegator's effective power share
3. Commission is taken first; remainder is split pro-rata among delegators
4. Rewards are deposited directly into each user's <code>deposit</code> balance (auto-compounding)
5. Transaction fees follow the same distribution path via <code>distribute_transaction_fees</code>


<a id="@Validator_Lifecycle_(as_seen_by_this_module)_3"></a>

### Validator Lifecycle (as seen by this module)


INACTIVE → PENDING_ACTIVE (join_validator_set) → ACTIVE (on_new_epoch)
→ PENDING_INACTIVE (leave_validator_set) → INACTIVE (on_new_epoch)

Only ACTIVE and PENDING_INACTIVE validators contribute to effective power reads.


    -  [Overview](#@Overview_0)
    -  [Key Concepts](#@Key_Concepts_1)
    -  [Reward Flow](#@Reward_Flow_2)
    -  [Validator Lifecycle (as seen by this module)](#@Validator_Lifecycle_(as_seen_by_this_module)_3)
-  [Resource `PendingMintCapability`](#0x1_staking_registry_PendingMintCapability)
-  [Resource `StakingRegistry`](#0x1_staking_registry_StakingRegistry)
-  [Struct `StakingRegistryConfig`](#0x1_staking_registry_StakingRegistryConfig)
-  [Struct `ValidatorPool`](#0x1_staking_registry_ValidatorPool)
-  [Struct `UserStakeInfo`](#0x1_staking_registry_UserStakeInfo)
-  [Constants](#@Constants_4)
-  [Function `registry_exists`](#0x1_staking_registry_registry_exists)
-  [Function `store_topo_coin_mint_cap`](#0x1_staking_registry_store_topo_coin_mint_cap)
-  [Function `initialize`](#0x1_staking_registry_initialize)
-  [Function `set_active_power_thresholds`](#0x1_staking_registry_set_active_power_thresholds)
-  [Function `set_min_active_power`](#0x1_staking_registry_set_min_active_power)
-  [Function `set_force_exit_power_bps`](#0x1_staking_registry_set_force_exit_power_bps)
-  [Function `set_octas_per_million_power`](#0x1_staking_registry_set_octas_per_million_power)
-  [Function `set_cooldown_secs`](#0x1_staking_registry_set_cooldown_secs)
-  [Function `ensure_min_cooldown_secs`](#0x1_staking_registry_ensure_min_cooldown_secs)
-  [Function `calculate_genesis_power_from_stake`](#0x1_staking_registry_calculate_genesis_power_from_stake)
-  [Function `register_validator`](#0x1_staking_registry_register_validator)
-  [Function `register_validator_for_genesis`](#0x1_staking_registry_register_validator_for_genesis)
-  [Function `register_validator_for_owner`](#0x1_staking_registry_register_validator_for_owner)
-  [Function `deposit`](#0x1_staking_registry_deposit)
-  [Function `delegate`](#0x1_staking_registry_delegate)
-  [Function `undelegate`](#0x1_staking_registry_undelegate)
-  [Function `withdraw_deposit`](#0x1_staking_registry_withdraw_deposit)
-  [Function `get_effective_power`](#0x1_staking_registry_get_effective_power)
-  [Function `get_validator_joining_power`](#0x1_staking_registry_get_validator_joining_power)
-  [Function `get_validator_total_power`](#0x1_staking_registry_get_validator_total_power)
-  [Function `get_validator_total_power_for_next_epoch`](#0x1_staking_registry_get_validator_total_power_for_next_epoch)
-  [Function `get_validator_member_powers_for_next_epoch`](#0x1_staking_registry_get_validator_member_powers_for_next_epoch)
-  [Function `get_validator_member_powers_with_current_power`](#0x1_staking_registry_get_validator_member_powers_with_current_power)
-  [Function `get_total_staked_power`](#0x1_staking_registry_get_total_staked_power)
-  [Function `validator_exists`](#0x1_staking_registry_validator_exists)
-  [Function `validators_exist`](#0x1_staking_registry_validators_exist)
-  [Function `get_validator_view`](#0x1_staking_registry_get_validator_view)
-  [Function `get_validator_views_by_addresses`](#0x1_staking_registry_get_validator_views_by_addresses)
-  [Function `get_user_stake_view`](#0x1_staking_registry_get_user_stake_view)
-  [Function `users_have_stake_records`](#0x1_staking_registry_users_have_stake_records)
-  [Function `get_user_stake_views_by_addresses`](#0x1_staking_registry_get_user_stake_views_by_addresses)
-  [Function `get_validator_delegator_count`](#0x1_staking_registry_get_validator_delegator_count)
-  [Function `get_validator_delegators`](#0x1_staking_registry_get_validator_delegators)
-  [Function `get_validator_delegator_views`](#0x1_staking_registry_get_validator_delegator_views)
-  [Function `get_user_stake_info`](#0x1_staking_registry_get_user_stake_info)
-  [Function `get_validator_owner`](#0x1_staking_registry_get_validator_owner)
-  [Function `get_validator_commission_bps`](#0x1_staking_registry_get_validator_commission_bps)
-  [Function `set_total_staked_power`](#0x1_staking_registry_set_total_staked_power)
-  [Function `get_cooldown_secs`](#0x1_staking_registry_get_cooldown_secs)
-  [Function `get_octas_per_million_power`](#0x1_staking_registry_get_octas_per_million_power)
-  [Function `get_min_active_power`](#0x1_staking_registry_get_min_active_power)
-  [Function `get_force_exit_power_bps`](#0x1_staking_registry_get_force_exit_power_bps)
-  [Function `set_validator_pending_active`](#0x1_staking_registry_set_validator_pending_active)
-  [Function `set_validator_active`](#0x1_staking_registry_set_validator_active)
-  [Function `set_validator_pending_inactive`](#0x1_staking_registry_set_validator_pending_inactive)
-  [Function `set_validator_inactive`](#0x1_staking_registry_set_validator_inactive)
-  [Function `force_undelegate_below_threshold`](#0x1_staking_registry_force_undelegate_below_threshold)
-  [Function `update_validator_commission`](#0x1_staking_registry_update_validator_commission)
-  [Function `distribute_epoch_rewards`](#0x1_staking_registry_distribute_epoch_rewards)
-  [Function `distribute_transaction_fees`](#0x1_staking_registry_distribute_transaction_fees)
-  [Function `register_validator_internal`](#0x1_staking_registry_register_validator_internal)
-  [Function `delegate_internal`](#0x1_staking_registry_delegate_internal)
-  [Function `undelegate_internal`](#0x1_staking_registry_undelegate_internal)
-  [Function `assert_registry_exists`](#0x1_staking_registry_assert_registry_exists)
-  [Function `assert_valid_commission`](#0x1_staking_registry_assert_valid_commission)
-  [Function `assert_valid_active_power_config`](#0x1_staking_registry_assert_valid_active_power_config)
-  [Function `extract_withdrawable_deposit`](#0x1_staking_registry_extract_withdrawable_deposit)
-  [Function `new_user_info`](#0x1_staking_registry_new_user_info)
-  [Function `ensure_user_record`](#0x1_staking_registry_ensure_user_record)
-  [Function `mint_to_user_deposit`](#0x1_staking_registry_mint_to_user_deposit)
-  [Function `add_delegator`](#0x1_staking_registry_add_delegator)
-  [Function `remove_delegator`](#0x1_staking_registry_remove_delegator)
-  [Function `set_validator_status`](#0x1_staking_registry_set_validator_status)
-  [Function `calculate_force_exit_power`](#0x1_staking_registry_calculate_force_exit_power)
-  [Function `should_force_undelegate`](#0x1_staking_registry_should_force_undelegate)
-  [Function `force_undelegate_member`](#0x1_staking_registry_force_undelegate_member)
-  [Function `calculate_effective_power`](#0x1_staking_registry_calculate_effective_power)
-  [Function `get_user_effective_power_for_validator`](#0x1_staking_registry_get_user_effective_power_for_validator)
-  [Function `get_user_effective_power_for_validator_with_extra_deposit`](#0x1_staking_registry_get_user_effective_power_for_validator_with_extra_deposit)
-  [Function `get_user_effective_power_for_validator_for_next_epoch`](#0x1_staking_registry_get_user_effective_power_for_validator_for_next_epoch)
-  [Function `get_user_effective_power_for_validator_for_next_epoch_with_extra_deposit`](#0x1_staking_registry_get_user_effective_power_for_validator_for_next_epoch_with_extra_deposit)
-  [Function `calculate_effective_power_from_deposit`](#0x1_staking_registry_calculate_effective_power_from_deposit)
-  [Function `copy_addresses`](#0x1_staking_registry_copy_addresses)
-  [Function `build_validator_view`](#0x1_staking_registry_build_validator_view)
-  [Function `empty_validator_view`](#0x1_staking_registry_empty_validator_view)
-  [Function `build_user_stake_view`](#0x1_staking_registry_build_user_stake_view)
-  [Function `empty_user_stake_view`](#0x1_staking_registry_empty_user_stake_view)
-  [Function `build_delegator_view`](#0x1_staking_registry_build_delegator_view)
-  [Function `get_active_effective_power`](#0x1_staking_registry_get_active_effective_power)
-  [Function `calculate_validator_total_power`](#0x1_staking_registry_calculate_validator_total_power)
-  [Function `copy_address_range`](#0x1_staking_registry_copy_address_range)
-  [Function `range_end`](#0x1_staking_registry_range_end)
-  [Function `calculate_rewards_amount`](#0x1_staking_registry_calculate_rewards_amount)
-  [Specification](#@Specification_5)
    -  [Function `get_effective_power`](#@Specification_5_get_effective_power)
    -  [Function `get_validator_total_power`](#@Specification_5_get_validator_total_power)


<pre><code><b>use</b> <a href="coin.md#0x1_coin">0x1::coin</a>;
<b>use</b> <a href="dispatchable_fungible_asset.md#0x1_dispatchable_fungible_asset">0x1::dispatchable_fungible_asset</a>;
<b>use</b> <a href="fungible_asset.md#0x1_fungible_asset">0x1::fungible_asset</a>;
<b>use</b> <a href="object.md#0x1_object">0x1::object</a>;
<b>use</b> <a href="poc_power_store.md#0x1_poc_power_store">0x1::poc_power_store</a>;
<b>use</b> <a href="primary_fungible_store.md#0x1_primary_fungible_store">0x1::primary_fungible_store</a>;
<b>use</b> <a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">0x1::signer</a>;
<b>use</b> <a href="../../aptos-stdlib/doc/simple_map.md#0x1_simple_map">0x1::simple_map</a>;
<b>use</b> <a href="../../aptos-stdlib/doc/smart_table.md#0x1_smart_table">0x1::smart_table</a>;
<b>use</b> <a href="system_addresses.md#0x1_system_addresses">0x1::system_addresses</a>;
<b>use</b> <a href="../../aptos-stdlib/doc/table.md#0x1_table">0x1::table</a>;
<b>use</b> <a href="timestamp.md#0x1_timestamp">0x1::timestamp</a>;
<b>use</b> <a href="topo_coin.md#0x1_topo_coin">0x1::topo_coin</a>;
</code></pre>



<a id="0x1_staking_registry_PendingMintCapability"></a>

## Resource `PendingMintCapability`

Temporary holding resource for the TopoCoin MintCapability during genesis.
Genesis calls <code>store_topo_coin_mint_cap</code> before <code>initialize</code>, so the cap
must be parked here until the full registry is ready to receive it.


<pre><code><b>struct</b> <a href="staking_registry.md#0x1_staking_registry_PendingMintCapability">PendingMintCapability</a> <b>has</b> key
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>mint_cap: <a href="coin.md#0x1_coin_MintCapability">coin::MintCapability</a>&lt;<a href="topo_coin.md#0x1_topo_coin_TopoCoin">topo_coin::TopoCoin</a>&gt;</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a id="0x1_staking_registry_StakingRegistry"></a>

## Resource `StakingRegistry`

The global staking registry, stored under @aptos_framework.

Contains all validator pools, all user stake records, and the global config.
The <code>mint_cap</code> is used to mint new TOPO coins as epoch rewards and fee distributions.


<pre><code><b>struct</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> <b>has</b> key
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>validators: <a href="../../aptos-stdlib/doc/table.md#0x1_table_Table">table::Table</a>&lt;<b>address</b>, <a href="staking_registry.md#0x1_staking_registry_ValidatorPool">staking_registry::ValidatorPool</a>&gt;</code>
</dt>
<dd>
 Map from validator pool address → ValidatorPool
</dd>
<dt>
<code>users: <a href="../../aptos-stdlib/doc/table.md#0x1_table_Table">table::Table</a>&lt;<b>address</b>, <a href="staking_registry.md#0x1_staking_registry_UserStakeInfo">staking_registry::UserStakeInfo</a>&gt;</code>
</dt>
<dd>
 Map from user address → UserStakeInfo
</dd>
<dt>
<code>total_staked_power: u64</code>
</dt>
<dd>
 Snapshot of total staked power across all active validators; updated at epoch boundaries
</dd>
<dt>
<code>mint_cap: <a href="coin.md#0x1_coin_MintCapability">coin::MintCapability</a>&lt;<a href="topo_coin.md#0x1_topo_coin_TopoCoin">topo_coin::TopoCoin</a>&gt;</code>
</dt>
<dd>
 Capability to mint TopoCoin for reward distribution
</dd>
<dt>
<code>config: <a href="staking_registry.md#0x1_staking_registry_StakingRegistryConfig">staking_registry::StakingRegistryConfig</a></code>
</dt>
<dd>

</dd>
</dl>


</details>

<a id="0x1_staking_registry_StakingRegistryConfig"></a>

## Struct `StakingRegistryConfig`

Tunable parameters for the staking system.


<pre><code><b>struct</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistryConfig">StakingRegistryConfig</a> <b>has</b> <b>copy</b>, drop, store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>octas_per_million_power: u64</code>
</dt>
<dd>
 How many octas (smallest TOPO unit) of deposit are required to back 1,000,000
 units of POC power. A value of 0 disables the deposit backing requirement.
 Effective power = min(poc_power, deposit_octas * 1,000,000 / octas_per_million_power)
</dd>
<dt>
<code>max_delegators_per_validator: u64</code>
</dt>
<dd>
 Hard cap on the number of delegators per validator pool.
 Prevents unbounded iteration cost during reward distribution.
</dd>
<dt>
<code>cooldown_secs: u64</code>
</dt>
<dd>
 Seconds a user must wait after undelegating before they can re-delegate or withdraw.
 Set to max(recurring_lockup_duration, governance_voting_duration) at genesis.
</dd>
<dt>
<code>genesis_stake_power_multiplier: u64</code>
</dt>
<dd>
 Multiplier applied to stake_amount when computing genesis power.
 Default 1 means 1 octa of stake = 1 unit of genesis power.
</dd>
<dt>
<code>min_active_power: u64</code>
</dt>
<dd>
 Minimum effective power required to join or remain in a validator pool.
</dd>
<dt>
<code>force_exit_power_bps: u64</code>
</dt>
<dd>
 Users whose power falls below (min_active_power * force_exit_power_bps / 10000)
 are automatically removed from the pool at epoch boundaries.
 Default 8000 bps = 80% of min_active_power.
</dd>
</dl>


</details>

<a id="0x1_staking_registry_ValidatorPool"></a>

## Struct `ValidatorPool`

A validator's delegation pool.

<code>delegator_index</code> is a SmartTable for O(1) membership checks and O(1) removal
(using swap-remove on <code>delegator_list</code>).


<pre><code><b>struct</b> <a href="staking_registry.md#0x1_staking_registry_ValidatorPool">ValidatorPool</a> <b>has</b> store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>owner_address: <b>address</b></code>
</dt>
<dd>
 The owner of this pool (receives commission rewards)
</dd>
<dt>
<code>delegator_index: <a href="../../aptos-stdlib/doc/smart_table.md#0x1_smart_table_SmartTable">smart_table::SmartTable</a>&lt;<b>address</b>, u64&gt;</code>
</dt>
<dd>
 Maps delegator address → index in delegator_list (for O(1) removal)
</dd>
<dt>
<code>delegator_list: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;</code>
</dt>
<dd>
 Ordered list of all current delegators
</dd>
<dt>
<code>commission_bps: u64</code>
</dt>
<dd>
 Validator's commission rate in basis points (0–10000)
</dd>
<dt>
<code>status: u64</code>
</dt>
<dd>
 Current lifecycle status (PENDING_ACTIVE / ACTIVE / PENDING_INACTIVE / INACTIVE)
</dd>
</dl>


</details>

<a id="0x1_staking_registry_UserStakeInfo"></a>

## Struct `UserStakeInfo`

Per-user staking state.


<pre><code><b>struct</b> <a href="staking_registry.md#0x1_staking_registry_UserStakeInfo">UserStakeInfo</a> <b>has</b> store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>deposit: <a href="coin.md#0x1_coin_Coin">coin::Coin</a>&lt;<a href="topo_coin.md#0x1_topo_coin_TopoCoin">topo_coin::TopoCoin</a>&gt;</code>
</dt>
<dd>
 TOPO coins deposited by this user; held in escrow by the registry
</dd>
<dt>
<code>delegated_to: <b>address</b></code>
</dt>
<dd>
 The validator pool this user is currently delegated to; @0x0 means not delegated
</dd>
<dt>
<code>cooldown_until_secs: u64</code>
</dt>
<dd>
 Unix timestamp (seconds) after which the user may re-delegate or withdraw.
 Set to now + cooldown_secs when the user undelegates. 0 means no cooldown.
</dd>
</dl>


</details>

<a id="@Constants_4"></a>

## Constants


<a id="0x1_staking_registry_MAX_U64"></a>



<pre><code><b>const</b> <a href="staking_registry.md#0x1_staking_registry_MAX_U64">MAX_U64</a>: u128 = 18446744073709551615;
</code></pre>



<a id="0x1_staking_registry_EALREADY_DELEGATED"></a>

User is already delegated to a validator; must undelegate first


<pre><code><b>const</b> <a href="staking_registry.md#0x1_staking_registry_EALREADY_DELEGATED">EALREADY_DELEGATED</a>: u64 = 3;
</code></pre>



<a id="0x1_staking_registry_BPS_DENOMINATOR"></a>



<pre><code><b>const</b> <a href="staking_registry.md#0x1_staking_registry_BPS_DENOMINATOR">BPS_DENOMINATOR</a>: u64 = 10000;
</code></pre>



<a id="0x1_staking_registry_DEFAULT_FORCE_EXIT_POWER_BPS"></a>

Users whose power falls below (min_active_power * force_exit_power_bps / 10000) are force-undelegated


<pre><code><b>const</b> <a href="staking_registry.md#0x1_staking_registry_DEFAULT_FORCE_EXIT_POWER_BPS">DEFAULT_FORCE_EXIT_POWER_BPS</a>: u64 = 8000;
</code></pre>



<a id="0x1_staking_registry_DEFAULT_GENESIS_STAKE_POWER_MULTIPLIER"></a>

At genesis, each octa of stake maps to this many units of power (default 1:1)


<pre><code><b>const</b> <a href="staking_registry.md#0x1_staking_registry_DEFAULT_GENESIS_STAKE_POWER_MULTIPLIER">DEFAULT_GENESIS_STAKE_POWER_MULTIPLIER</a>: u64 = 1;
</code></pre>



<a id="0x1_staking_registry_DEFAULT_MIN_ACTIVE_POWER"></a>

Minimum effective power required to delegate to a validator pool


<pre><code><b>const</b> <a href="staking_registry.md#0x1_staking_registry_DEFAULT_MIN_ACTIVE_POWER">DEFAULT_MIN_ACTIVE_POWER</a>: u64 = 1;
</code></pre>



<a id="0x1_staking_registry_EALREADY_INITIALIZED"></a>

Registry or PendingMintCapability already initialized


<pre><code><b>const</b> <a href="staking_registry.md#0x1_staking_registry_EALREADY_INITIALIZED">EALREADY_INITIALIZED</a>: u64 = 14;
</code></pre>



<a id="0x1_staking_registry_EALREADY_VALIDATOR"></a>

Validator pool already exists for this address


<pre><code><b>const</b> <a href="staking_registry.md#0x1_staking_registry_EALREADY_VALIDATOR">EALREADY_VALIDATOR</a>: u64 = 2;
</code></pre>



<a id="0x1_staking_registry_ECOOLDOWN_ACTIVE"></a>

Cooldown period has not yet elapsed; user must wait before re-delegating or withdrawing


<pre><code><b>const</b> <a href="staking_registry.md#0x1_staking_registry_ECOOLDOWN_ACTIVE">ECOOLDOWN_ACTIVE</a>: u64 = 6;
</code></pre>



<a id="0x1_staking_registry_EDEPOSIT_LOCKED"></a>

Deposit is locked because user is still delegated; must undelegate before withdrawing


<pre><code><b>const</b> <a href="staking_registry.md#0x1_staking_registry_EDEPOSIT_LOCKED">EDEPOSIT_LOCKED</a>: u64 = 5;
</code></pre>



<a id="0x1_staking_registry_EINVALID_COMMISSION"></a>

Commission basis points must be in range [0, 10000]


<pre><code><b>const</b> <a href="staking_registry.md#0x1_staking_registry_EINVALID_COMMISSION">EINVALID_COMMISSION</a>: u64 = 10;
</code></pre>



<a id="0x1_staking_registry_EINVALID_CONFIG"></a>

Invalid configuration parameter


<pre><code><b>const</b> <a href="staking_registry.md#0x1_staking_registry_EINVALID_CONFIG">EINVALID_CONFIG</a>: u64 = 13;
</code></pre>



<a id="0x1_staking_registry_EMAX_DELEGATORS"></a>

Validator pool has reached its maximum delegator capacity


<pre><code><b>const</b> <a href="staking_registry.md#0x1_staking_registry_EMAX_DELEGATORS">EMAX_DELEGATORS</a>: u64 = 8;
</code></pre>



<a id="0x1_staking_registry_EMINT_CAP_NOT_STORED"></a>

MintCapability for TopoCoin has not been stored yet (must call store_topo_coin_mint_cap first)


<pre><code><b>const</b> <a href="staking_registry.md#0x1_staking_registry_EMINT_CAP_NOT_STORED">EMINT_CAP_NOT_STORED</a>: u64 = 12;
</code></pre>



<a id="0x1_staking_registry_ENOT_DELEGATED"></a>

User is not currently delegated to any validator


<pre><code><b>const</b> <a href="staking_registry.md#0x1_staking_registry_ENOT_DELEGATED">ENOT_DELEGATED</a>: u64 = 4;
</code></pre>



<a id="0x1_staking_registry_ENOT_VALIDATOR"></a>

Target address is not a registered validator pool


<pre><code><b>const</b> <a href="staking_registry.md#0x1_staking_registry_ENOT_VALIDATOR">ENOT_VALIDATOR</a>: u64 = 1;
</code></pre>



<a id="0x1_staking_registry_EPOWER_BELOW_MIN_ACTIVE"></a>

User's effective power is below the minimum required to join a validator pool


<pre><code><b>const</b> <a href="staking_registry.md#0x1_staking_registry_EPOWER_BELOW_MIN_ACTIVE">EPOWER_BELOW_MIN_ACTIVE</a>: u64 = 15;
</code></pre>



<a id="0x1_staking_registry_EREGISTRY_NOT_INITIALIZED"></a>

StakingRegistry resource has not been initialized


<pre><code><b>const</b> <a href="staking_registry.md#0x1_staking_registry_EREGISTRY_NOT_INITIALIZED">EREGISTRY_NOT_INITIALIZED</a>: u64 = 11;
</code></pre>



<a id="0x1_staking_registry_EUSER_NOT_FOUND"></a>

No stake info record found for this user address


<pre><code><b>const</b> <a href="staking_registry.md#0x1_staking_registry_EUSER_NOT_FOUND">EUSER_NOT_FOUND</a>: u64 = 9;
</code></pre>



<a id="0x1_staking_registry_EZERO_DEPOSIT"></a>

Deposit amount must be greater than zero


<pre><code><b>const</b> <a href="staking_registry.md#0x1_staking_registry_EZERO_DEPOSIT">EZERO_DEPOSIT</a>: u64 = 7;
</code></pre>



<a id="0x1_staking_registry_POWER_BACKING_SCALE"></a>



<pre><code><b>const</b> <a href="staking_registry.md#0x1_staking_registry_POWER_BACKING_SCALE">POWER_BACKING_SCALE</a>: u128 = 1000000;
</code></pre>



<a id="0x1_staking_registry_VALIDATOR_STATUS_ACTIVE"></a>



<pre><code><b>const</b> <a href="staking_registry.md#0x1_staking_registry_VALIDATOR_STATUS_ACTIVE">VALIDATOR_STATUS_ACTIVE</a>: u64 = 2;
</code></pre>



<a id="0x1_staking_registry_VALIDATOR_STATUS_INACTIVE"></a>



<pre><code><b>const</b> <a href="staking_registry.md#0x1_staking_registry_VALIDATOR_STATUS_INACTIVE">VALIDATOR_STATUS_INACTIVE</a>: u64 = 4;
</code></pre>



<a id="0x1_staking_registry_VALIDATOR_STATUS_PENDING_ACTIVE"></a>



<pre><code><b>const</b> <a href="staking_registry.md#0x1_staking_registry_VALIDATOR_STATUS_PENDING_ACTIVE">VALIDATOR_STATUS_PENDING_ACTIVE</a>: u64 = 1;
</code></pre>



<a id="0x1_staking_registry_VALIDATOR_STATUS_PENDING_INACTIVE"></a>



<pre><code><b>const</b> <a href="staking_registry.md#0x1_staking_registry_VALIDATOR_STATUS_PENDING_INACTIVE">VALIDATOR_STATUS_PENDING_INACTIVE</a>: u64 = 3;
</code></pre>



<a id="0x1_staking_registry_registry_exists"></a>

## Function `registry_exists`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_registry_exists">registry_exists</a>(): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_registry_exists">registry_exists</a>(): bool {
    <b>exists</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework)
}
</code></pre>



</details>

<a id="0x1_staking_registry_store_topo_coin_mint_cap"></a>

## Function `store_topo_coin_mint_cap`

Park the TopoCoin MintCapability before the registry is fully initialized.

Called by <code><a href="genesis.md#0x1_genesis_initialize_topo_coin">genesis::initialize_topo_coin</a></code> immediately after minting capabilities are created.
The cap is stored in a temporary <code><a href="staking_registry.md#0x1_staking_registry_PendingMintCapability">PendingMintCapability</a></code> resource and consumed by <code>initialize</code>.
This two-step approach avoids a circular dependency: the registry needs the mint cap,
but the mint cap is created before the registry config parameters are known.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_store_topo_coin_mint_cap">store_topo_coin_mint_cap</a>(aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, mint_cap: <a href="coin.md#0x1_coin_MintCapability">coin::MintCapability</a>&lt;<a href="topo_coin.md#0x1_topo_coin_TopoCoin">topo_coin::TopoCoin</a>&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_store_topo_coin_mint_cap">store_topo_coin_mint_cap</a>(
    aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>,
    mint_cap: MintCapability&lt;TopoCoin&gt;,
) {
    <a href="system_addresses.md#0x1_system_addresses_assert_aptos_framework">system_addresses::assert_aptos_framework</a>(aptos_framework);
    <b>assert</b>!(
        !<b>exists</b>&lt;<a href="staking_registry.md#0x1_staking_registry_PendingMintCapability">PendingMintCapability</a>&gt;(@aptos_framework)
            && !<b>exists</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework),
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_already_exists">error::already_exists</a>(<a href="staking_registry.md#0x1_staking_registry_EALREADY_INITIALIZED">EALREADY_INITIALIZED</a>),
    );
    <b>move_to</b>(aptos_framework, <a href="staking_registry.md#0x1_staking_registry_PendingMintCapability">PendingMintCapability</a> { mint_cap });
}
</code></pre>



</details>

<a id="0x1_staking_registry_initialize"></a>

## Function `initialize`

Initialize the StakingRegistry with configuration parameters.

Consumes the <code><a href="staking_registry.md#0x1_staking_registry_PendingMintCapability">PendingMintCapability</a></code> parked by <code>store_topo_coin_mint_cap</code>.
Idempotent: if the registry already exists, returns immediately without error.
Called by <code><a href="genesis.md#0x1_genesis_ensure_poc_staking_initialized">genesis::ensure_poc_staking_initialized</a></code>.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_initialize">initialize</a>(aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, octas_per_million_power: u64, max_delegators_per_validator: u64, cooldown_secs: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_initialize">initialize</a>(
    aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>,
    octas_per_million_power: u64,
    max_delegators_per_validator: u64,
    cooldown_secs: u64,
) <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_PendingMintCapability">PendingMintCapability</a> {
    <a href="system_addresses.md#0x1_system_addresses_assert_aptos_framework">system_addresses::assert_aptos_framework</a>(aptos_framework);
    <b>if</b> (<b>exists</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework)) {
        <b>return</b>
    };

    <b>assert</b>!(
        max_delegators_per_validator &gt; 0,
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_invalid_argument">error::invalid_argument</a>(<a href="staking_registry.md#0x1_staking_registry_EINVALID_CONFIG">EINVALID_CONFIG</a>),
    );
    <b>assert</b>!(
        <b>exists</b>&lt;<a href="staking_registry.md#0x1_staking_registry_PendingMintCapability">PendingMintCapability</a>&gt;(@aptos_framework),
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_not_found">error::not_found</a>(<a href="staking_registry.md#0x1_staking_registry_EMINT_CAP_NOT_STORED">EMINT_CAP_NOT_STORED</a>),
    );

    <b>let</b> <a href="staking_registry.md#0x1_staking_registry_PendingMintCapability">PendingMintCapability</a> { mint_cap } = <b>move_from</b>&lt;<a href="staking_registry.md#0x1_staking_registry_PendingMintCapability">PendingMintCapability</a>&gt;(@aptos_framework);
    <b>move_to</b>(aptos_framework, <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
        validators: <a href="../../aptos-stdlib/doc/table.md#0x1_table_new">table::new</a>(),
        users: <a href="../../aptos-stdlib/doc/table.md#0x1_table_new">table::new</a>(),
        total_staked_power: 0,
        mint_cap,
        config: <a href="staking_registry.md#0x1_staking_registry_StakingRegistryConfig">StakingRegistryConfig</a> {
            octas_per_million_power,
            max_delegators_per_validator,
            cooldown_secs,
            genesis_stake_power_multiplier: <a href="staking_registry.md#0x1_staking_registry_DEFAULT_GENESIS_STAKE_POWER_MULTIPLIER">DEFAULT_GENESIS_STAKE_POWER_MULTIPLIER</a>,
            min_active_power: <a href="staking_registry.md#0x1_staking_registry_DEFAULT_MIN_ACTIVE_POWER">DEFAULT_MIN_ACTIVE_POWER</a>,
            force_exit_power_bps: <a href="staking_registry.md#0x1_staking_registry_DEFAULT_FORCE_EXIT_POWER_BPS">DEFAULT_FORCE_EXIT_POWER_BPS</a>,
        },
    });
}
</code></pre>



</details>

<a id="0x1_staking_registry_set_active_power_thresholds"></a>

## Function `set_active_power_thresholds`

Update the minimum active power and force-exit threshold.

<code>min_active_power</code>: minimum effective power a user must have to join a pool.
<code>force_exit_power_bps</code>: users whose power falls below
(min_active_power * force_exit_power_bps / 10000) are force-undelegated at epoch boundaries.
Setting force_exit_power_bps = 8000 means users are ejected when power < 80% of min_active_power,
providing a hysteresis band to prevent thrashing at the boundary.


<pre><code><b>public</b> entry <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_set_active_power_thresholds">set_active_power_thresholds</a>(aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, min_active_power: u64, force_exit_power_bps: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> entry <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_set_active_power_thresholds">set_active_power_thresholds</a>(
    aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>,
    min_active_power: u64,
    force_exit_power_bps: u64,
) <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <a href="system_addresses.md#0x1_system_addresses_assert_aptos_framework">system_addresses::assert_aptos_framework</a>(aptos_framework);
    <a href="staking_registry.md#0x1_staking_registry_assert_registry_exists">assert_registry_exists</a>();
    <a href="staking_registry.md#0x1_staking_registry_assert_valid_active_power_config">assert_valid_active_power_config</a>(min_active_power, force_exit_power_bps);

    <b>let</b> registry = <b>borrow_global_mut</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework);
    registry.config.min_active_power = min_active_power;
    registry.config.force_exit_power_bps = force_exit_power_bps;
}
</code></pre>



</details>

<a id="0x1_staking_registry_set_min_active_power"></a>

## Function `set_min_active_power`

Update only the minimum effective power required to join or remain in a validator pool.

Keeps the existing force-exit BPS unchanged. Only the framework account may change
this parameter.


<pre><code><b>public</b> entry <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_set_min_active_power">set_min_active_power</a>(aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, min_active_power: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> entry <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_set_min_active_power">set_min_active_power</a>(
    aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>,
    min_active_power: u64,
) <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <a href="system_addresses.md#0x1_system_addresses_assert_aptos_framework">system_addresses::assert_aptos_framework</a>(aptos_framework);
    <a href="staking_registry.md#0x1_staking_registry_assert_registry_exists">assert_registry_exists</a>();
    <b>assert</b>!(min_active_power &gt; 0, <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_invalid_argument">error::invalid_argument</a>(<a href="staking_registry.md#0x1_staking_registry_EINVALID_CONFIG">EINVALID_CONFIG</a>));

    <b>borrow_global_mut</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework).config.min_active_power =
        min_active_power;
}
</code></pre>



</details>

<a id="0x1_staking_registry_set_force_exit_power_bps"></a>

## Function `set_force_exit_power_bps`

Update only the force-exit threshold in basis points.

Users whose effective power falls below
<code>(min_active_power * force_exit_power_bps / 10000)</code> are force-undelegated
at epoch boundaries. Keeps the existing min_active_power unchanged.


<pre><code><b>public</b> entry <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_set_force_exit_power_bps">set_force_exit_power_bps</a>(aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, force_exit_power_bps: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> entry <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_set_force_exit_power_bps">set_force_exit_power_bps</a>(
    aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>,
    force_exit_power_bps: u64,
) <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <a href="system_addresses.md#0x1_system_addresses_assert_aptos_framework">system_addresses::assert_aptos_framework</a>(aptos_framework);
    <a href="staking_registry.md#0x1_staking_registry_assert_registry_exists">assert_registry_exists</a>();
    <b>assert</b>!(
        force_exit_power_bps &gt; 0 && force_exit_power_bps &lt;= <a href="staking_registry.md#0x1_staking_registry_BPS_DENOMINATOR">BPS_DENOMINATOR</a>,
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_invalid_argument">error::invalid_argument</a>(<a href="staking_registry.md#0x1_staking_registry_EINVALID_CONFIG">EINVALID_CONFIG</a>),
    );

    <b>borrow_global_mut</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework).config.force_exit_power_bps =
        force_exit_power_bps;
}
</code></pre>



</details>

<a id="0x1_staking_registry_set_octas_per_million_power"></a>

## Function `set_octas_per_million_power`

Update how much deposited TOPO is required to back 1,000,000 units of POC power.

Only the framework account may change this economic parameter. Setting the value
to 0 disables the deposit backing requirement. Lowering a non-zero value
increases the amount of committed POC power that can become effective for a fixed
deposit; raising it can reduce effective power and may cause low-coverage delegators
to be force-undelegated at the next epoch boundary.


<pre><code><b>public</b> entry <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_set_octas_per_million_power">set_octas_per_million_power</a>(aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, octas_per_million_power: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> entry <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_set_octas_per_million_power">set_octas_per_million_power</a>(
    aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>,
    octas_per_million_power: u64,
) <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <a href="system_addresses.md#0x1_system_addresses_assert_aptos_framework">system_addresses::assert_aptos_framework</a>(aptos_framework);
    <a href="staking_registry.md#0x1_staking_registry_assert_registry_exists">assert_registry_exists</a>();

    <b>borrow_global_mut</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework).config.octas_per_million_power =
        octas_per_million_power;
}
</code></pre>



</details>

<a id="0x1_staking_registry_set_cooldown_secs"></a>

## Function `set_cooldown_secs`



<pre><code><b>public</b> entry <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_set_cooldown_secs">set_cooldown_secs</a>(aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, cooldown_secs: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> entry <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_set_cooldown_secs">set_cooldown_secs</a>(
    aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>,
    cooldown_secs: u64,
) <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <a href="system_addresses.md#0x1_system_addresses_assert_aptos_framework">system_addresses::assert_aptos_framework</a>(aptos_framework);
    <a href="staking_registry.md#0x1_staking_registry_assert_registry_exists">assert_registry_exists</a>();

    <b>borrow_global_mut</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework).config.cooldown_secs =
        cooldown_secs;
}
</code></pre>



</details>

<a id="0x1_staking_registry_ensure_min_cooldown_secs"></a>

## Function `ensure_min_cooldown_secs`

Ensure the cooldown period is at least <code>min_cooldown_secs</code>.

Called during governance config updates to keep cooldown >= governance voting duration.
This prevents a user from undelegating, voting, and re-delegating within a single
governance proposal window — which would allow double-influence attacks.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_ensure_min_cooldown_secs">ensure_min_cooldown_secs</a>(aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, min_cooldown_secs: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_ensure_min_cooldown_secs">ensure_min_cooldown_secs</a>(
    aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>,
    min_cooldown_secs: u64,
) <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <a href="system_addresses.md#0x1_system_addresses_assert_aptos_framework">system_addresses::assert_aptos_framework</a>(aptos_framework);
    <b>if</b> (!<b>exists</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework)) {
        <b>return</b>
    };

    <b>let</b> registry = <b>borrow_global_mut</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework);
    <b>if</b> (registry.config.cooldown_secs &lt; min_cooldown_secs) {
        registry.config.cooldown_secs = min_cooldown_secs;
    };
}
</code></pre>



</details>

<a id="0x1_staking_registry_calculate_genesis_power_from_stake"></a>

## Function `calculate_genesis_power_from_stake`

Compute the initial POC power for a genesis validator from their stake amount.

Formula: genesis_power = stake_amount * genesis_stake_power_multiplier
Default multiplier is 1, so 1 octa of stake = 1 unit of genesis power.
This is used in <code><a href="genesis.md#0x1_genesis_create_initialize_validator">genesis::create_initialize_validator</a></code> to seed the power store
before the first epoch begins.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_calculate_genesis_power_from_stake">calculate_genesis_power_from_stake</a>(stake_amount: u64): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_calculate_genesis_power_from_stake">calculate_genesis_power_from_stake</a>(
    stake_amount: u64,
): u64 <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <a href="staking_registry.md#0x1_staking_registry_assert_registry_exists">assert_registry_exists</a>();
    <b>let</b> registry = <b>borrow_global</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework);
    <b>let</b> wide_power =
        (stake_amount <b>as</b> u128) * (registry.config.genesis_stake_power_multiplier <b>as</b> u128);
    <b>assert</b>!(wide_power &lt;= <a href="staking_registry.md#0x1_staking_registry_MAX_U64">MAX_U64</a>, <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_invalid_argument">error::invalid_argument</a>(<a href="staking_registry.md#0x1_staking_registry_EINVALID_CONFIG">EINVALID_CONFIG</a>));
    wide_power <b>as</b> u64
}
</code></pre>



</details>

<a id="0x1_staking_registry_register_validator"></a>

## Function `register_validator`



<pre><code><b>public</b> entry <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_register_validator">register_validator</a>(validator: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, commission_bps: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> entry <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_register_validator">register_validator</a>(
    validator: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>,
    commission_bps: u64,
) <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <a href="staking_registry.md#0x1_staking_registry_assert_registry_exists">assert_registry_exists</a>();
    <a href="staking_registry.md#0x1_staking_registry_register_validator_internal">register_validator_internal</a>(
        <a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer_address_of">signer::address_of</a>(validator),
        <a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer_address_of">signer::address_of</a>(validator),
        commission_bps,
    );
}
</code></pre>



</details>

<a id="0x1_staking_registry_register_validator_for_genesis"></a>

## Function `register_validator_for_genesis`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_register_validator_for_genesis">register_validator_for_genesis</a>(owner_address: <b>address</b>, validator_address: <b>address</b>, commission_bps: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_register_validator_for_genesis">register_validator_for_genesis</a>(
    owner_address: <b>address</b>,
    validator_address: <b>address</b>,
    commission_bps: u64,
) <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <a href="staking_registry.md#0x1_staking_registry_assert_registry_exists">assert_registry_exists</a>();
    <a href="staking_registry.md#0x1_staking_registry_register_validator_internal">register_validator_internal</a>(owner_address, validator_address, commission_bps);
}
</code></pre>



</details>

<a id="0x1_staking_registry_register_validator_for_owner"></a>

## Function `register_validator_for_owner`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_register_validator_for_owner">register_validator_for_owner</a>(owner_address: <b>address</b>, validator_address: <b>address</b>, commission_bps: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_register_validator_for_owner">register_validator_for_owner</a>(
    owner_address: <b>address</b>,
    validator_address: <b>address</b>,
    commission_bps: u64,
) <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <a href="staking_registry.md#0x1_staking_registry_assert_registry_exists">assert_registry_exists</a>();
    <a href="staking_registry.md#0x1_staking_registry_register_validator_internal">register_validator_internal</a>(owner_address, validator_address, commission_bps);
}
</code></pre>



</details>

<a id="0x1_staking_registry_deposit"></a>

## Function `deposit`

Deposit TOPO coins into the registry as staking collateral.

Deposited coins are held in escrow by the registry and cannot be withdrawn
while the user is delegated to a validator. They serve as economic collateral
that backs the user's POC power:
effective_power = min(poc_power, deposit * 1,000,000 / octas_per_million_power).
If octas_per_million_power is 0, no deposit backing is required.

Deposits auto-compound: epoch rewards and fee shares are minted directly into
the user's deposit balance, increasing their deposit coverage over time.


<pre><code><b>public</b> entry <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_deposit">deposit</a>(user: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, amount: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> entry <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_deposit">deposit</a>(
    user: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>,
    amount: u64,
) <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <a href="staking_registry.md#0x1_staking_registry_assert_registry_exists">assert_registry_exists</a>();
    <b>assert</b>!(amount &gt; 0, <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_invalid_argument">error::invalid_argument</a>(<a href="staking_registry.md#0x1_staking_registry_EZERO_DEPOSIT">EZERO_DEPOSIT</a>));

    <b>let</b> user_address = <a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer_address_of">signer::address_of</a>(user);
    <b>let</b> registry = <b>borrow_global_mut</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework);
    <a href="staking_registry.md#0x1_staking_registry_ensure_user_record">ensure_user_record</a>(registry, user_address);

    <b>let</b> coins = <a href="coin.md#0x1_coin_withdraw">coin::withdraw</a>&lt;TopoCoin&gt;(user, amount);
    <b>let</b> info = registry.users.borrow_mut(user_address);
    <a href="coin.md#0x1_coin_merge">coin::merge</a>(&<b>mut</b> info.deposit, coins);
}
</code></pre>



</details>

<a id="0x1_staking_registry_delegate"></a>

## Function `delegate`

Delegate the user's staked deposit to a validator pool.

Prerequisites:
- User must not already be delegated (must call <code>undelegate</code> first)
- Cooldown period must have elapsed (if any)
- User's effective power must be >= min_active_power

After delegation, the user's deposit backs the validator's total power,
and the user begins receiving a proportional share of epoch rewards and fees.


<pre><code><b>public</b> entry <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_delegate">delegate</a>(user: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, validator_address: <b>address</b>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> entry <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_delegate">delegate</a>(
    user: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>,
    validator_address: <b>address</b>,
) <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <a href="staking_registry.md#0x1_staking_registry_assert_registry_exists">assert_registry_exists</a>();
    <b>let</b> user_address = <a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer_address_of">signer::address_of</a>(user);
    <a href="staking_registry.md#0x1_staking_registry_delegate_internal">delegate_internal</a>(user_address, validator_address);
}
</code></pre>



</details>

<a id="0x1_staking_registry_undelegate"></a>

## Function `undelegate`

Remove the user's delegation from their current validator pool.

The user's deposit remains in the registry but no longer backs any validator's power.
A cooldown period begins: the user must wait <code>cooldown_secs</code> before they can
re-delegate or withdraw their deposit.

This cooldown prevents rapid stake-hopping that could destabilize the validator set
or enable governance manipulation (vote, undelegate, re-delegate, vote again).


<pre><code><b>public</b> entry <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_undelegate">undelegate</a>(user: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> entry <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_undelegate">undelegate</a>(
    user: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>,
) <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <a href="staking_registry.md#0x1_staking_registry_assert_registry_exists">assert_registry_exists</a>();
    <b>let</b> user_address = <a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer_address_of">signer::address_of</a>(user);
    <a href="staking_registry.md#0x1_staking_registry_undelegate_internal">undelegate_internal</a>(user_address);
}
</code></pre>



</details>

<a id="0x1_staking_registry_withdraw_deposit"></a>

## Function `withdraw_deposit`

Withdraw the user's full deposit back to their wallet.

Requirements:
- User must not be currently delegated (deposit is locked while delegated)
- Cooldown period must have elapsed since undelegating

After withdrawal, the user's deposit balance becomes zero and cooldown is cleared.


<pre><code><b>public</b> entry <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_withdraw_deposit">withdraw_deposit</a>(user: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> entry <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_withdraw_deposit">withdraw_deposit</a>(
    user: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>,
) <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <a href="staking_registry.md#0x1_staking_registry_assert_registry_exists">assert_registry_exists</a>();
    <b>let</b> user_address = <a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer_address_of">signer::address_of</a>(user);
    <b>let</b> coins = <a href="staking_registry.md#0x1_staking_registry_extract_withdrawable_deposit">extract_withdrawable_deposit</a>(user_address);
    <a href="coin.md#0x1_coin_deposit">coin::deposit</a>&lt;TopoCoin&gt;(user_address, coins);
}
</code></pre>



</details>

<a id="0x1_staking_registry_get_effective_power"></a>

## Function `get_effective_power`

Return the user's current effective power.

Effective power = min(committed_poc_power, deposit_octas * 1,000,000 / octas_per_million_power),
or committed_poc_power when deposit backing is disabled.

Returns 0 if:
- User is not delegated to any validator
- The validator they are delegated to is not ACTIVE or PENDING_INACTIVE
- Committed POC power is zero
- Deposit coverage is zero while deposit backing is enabled

This is the value used for governance voting weight and reward distribution.


<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_effective_power">get_effective_power</a>(user: <b>address</b>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_effective_power">get_effective_power</a>(user: <b>address</b>): u64 <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <b>if</b> (!<b>exists</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework)) {
        <b>return</b> 0
    };

    <b>let</b> registry = <b>borrow_global</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework);
    <b>if</b> (!registry.users.contains(user)) {
        <b>return</b> 0
    };

    <b>let</b> info = registry.users.borrow(user);
    <b>if</b> (info.delegated_to == @0x0) {
        <b>return</b> 0
    };
    <b>if</b> (!registry.validators.contains(info.delegated_to)) {
        <b>return</b> 0
    };

    <b>let</b> pool = registry.validators.borrow(info.delegated_to);
    <b>if</b> (pool.status != <a href="staking_registry.md#0x1_staking_registry_VALIDATOR_STATUS_ACTIVE">VALIDATOR_STATUS_ACTIVE</a>
        && pool.status != <a href="staking_registry.md#0x1_staking_registry_VALIDATOR_STATUS_PENDING_INACTIVE">VALIDATOR_STATUS_PENDING_INACTIVE</a>) {
        <b>return</b> 0
    };

    <a href="staking_registry.md#0x1_staking_registry_calculate_effective_power">calculate_effective_power</a>(info, registry.config.octas_per_million_power, user)
}
</code></pre>



</details>

<a id="0x1_staking_registry_get_validator_joining_power"></a>

## Function `get_validator_joining_power`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_validator_joining_power">get_validator_joining_power</a>(validator_address: <b>address</b>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_validator_joining_power">get_validator_joining_power</a>(
    validator_address: <b>address</b>,
): u64 <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <b>if</b> (!<b>exists</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework)) {
        <b>return</b> 0
    };

    <b>let</b> registry = <b>borrow_global</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework);
    <b>if</b> (!registry.validators.contains(validator_address)) {
        <b>return</b> 0
    };

    <b>let</b> pool = registry.validators.borrow(validator_address);
    <a href="staking_registry.md#0x1_staking_registry_get_user_effective_power_for_validator">get_user_effective_power_for_validator</a>(
        registry,
        pool.owner_address,
        validator_address,
    )
}
</code></pre>



</details>

<a id="0x1_staking_registry_get_validator_total_power"></a>

## Function `get_validator_total_power`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_validator_total_power">get_validator_total_power</a>(validator_address: <b>address</b>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_validator_total_power">get_validator_total_power</a>(
    validator_address: <b>address</b>,
): u64 <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <b>if</b> (!<b>exists</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework)) {
        <b>return</b> 0
    };

    <b>let</b> registry = <b>borrow_global</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework);
    <b>if</b> (!registry.validators.contains(validator_address)) {
        <b>return</b> 0
    };

    <b>let</b> pool = registry.validators.borrow(validator_address);
    <a href="staking_registry.md#0x1_staking_registry_calculate_validator_total_power">calculate_validator_total_power</a>(registry, pool, validator_address)
}
</code></pre>



</details>

<a id="0x1_staking_registry_get_validator_total_power_for_next_epoch"></a>

## Function `get_validator_total_power_for_next_epoch`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_validator_total_power_for_next_epoch">get_validator_total_power_for_next_epoch</a>(validator_address: <b>address</b>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_validator_total_power_for_next_epoch">get_validator_total_power_for_next_epoch</a>(
    validator_address: <b>address</b>,
): u64 <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <b>let</b> extra_deposit_octas_by_user = <a href="../../aptos-stdlib/doc/simple_map.md#0x1_simple_map_create">simple_map::create</a>&lt;<b>address</b>, u64&gt;();
    <b>let</b> (_, _, total_power) = <a href="staking_registry.md#0x1_staking_registry_get_validator_member_powers_for_next_epoch">get_validator_member_powers_for_next_epoch</a>(
        validator_address,
        &extra_deposit_octas_by_user,
    );
    total_power
}
</code></pre>



</details>

<a id="0x1_staking_registry_get_validator_member_powers_for_next_epoch"></a>

## Function `get_validator_member_powers_for_next_epoch`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_validator_member_powers_for_next_epoch">get_validator_member_powers_for_next_epoch</a>(validator_address: <b>address</b>, extra_deposit_octas_by_user: &<a href="../../aptos-stdlib/doc/simple_map.md#0x1_simple_map_SimpleMap">simple_map::SimpleMap</a>&lt;<b>address</b>, u64&gt;): (<a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;, <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt;, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_validator_member_powers_for_next_epoch">get_validator_member_powers_for_next_epoch</a>(
    validator_address: <b>address</b>,
    extra_deposit_octas_by_user: &SimpleMap&lt;<b>address</b>, u64&gt;,
): (<a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;, <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt;, u64) <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <b>if</b> (!<b>exists</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework)) {
        <b>return</b> (<a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[], <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[], 0)
    };

    <b>let</b> registry = <b>borrow_global</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework);
    <b>if</b> (!registry.validators.contains(validator_address)) {
        <b>return</b> (<a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[], <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[], 0)
    };

    <b>let</b> maintain_threshold = <a href="staking_registry.md#0x1_staking_registry_calculate_force_exit_power">calculate_force_exit_power</a>(
        registry.config.min_active_power,
        registry.config.force_exit_power_bps,
    );
    <b>let</b> pool = registry.validators.borrow(validator_address);
    <b>let</b> addresses = <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[];
    <b>let</b> powers = <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[];
    <b>let</b> total_power = 0u128;
    pool.delegator_list.for_each_ref(|member| {
        <b>let</b> extra_deposit_octas =
            <b>if</b> (extra_deposit_octas_by_user.contains_key(member)) {
                *extra_deposit_octas_by_user.borrow(member)
            } <b>else</b> {
                0
            };
        <b>let</b> power = <a href="staking_registry.md#0x1_staking_registry_get_user_effective_power_for_validator_for_next_epoch_with_extra_deposit">get_user_effective_power_for_validator_for_next_epoch_with_extra_deposit</a>(
            registry,
            *member,
            validator_address,
            maintain_threshold,
            extra_deposit_octas,
        );
        addresses.push_back(*member);
        powers.push_back(power);
        total_power += (power <b>as</b> u128);
    });
    (addresses, powers, total_power <b>as</b> u64)
}
</code></pre>



</details>

<a id="0x1_staking_registry_get_validator_member_powers_with_current_power"></a>

## Function `get_validator_member_powers_with_current_power`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_validator_member_powers_with_current_power">get_validator_member_powers_with_current_power</a>(validator_address: <b>address</b>, extra_deposit_octas_by_user: &<a href="../../aptos-stdlib/doc/simple_map.md#0x1_simple_map_SimpleMap">simple_map::SimpleMap</a>&lt;<b>address</b>, u64&gt;): (<a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;, <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt;, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_validator_member_powers_with_current_power">get_validator_member_powers_with_current_power</a>(
    validator_address: <b>address</b>,
    extra_deposit_octas_by_user: &SimpleMap&lt;<b>address</b>, u64&gt;,
): (<a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;, <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt;, u64) <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <b>if</b> (!<b>exists</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework)) {
        <b>return</b> (<a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[], <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[], 0)
    };

    <b>let</b> registry = <b>borrow_global</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework);
    <b>if</b> (!registry.validators.contains(validator_address)) {
        <b>return</b> (<a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[], <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[], 0)
    };

    <b>let</b> pool = registry.validators.borrow(validator_address);
    <b>let</b> addresses = <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[];
    <b>let</b> powers = <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[];
    <b>let</b> total_power = 0u128;
    pool.delegator_list.for_each_ref(|member| {
        <b>let</b> extra_deposit_octas =
            <b>if</b> (extra_deposit_octas_by_user.contains_key(member)) {
                *extra_deposit_octas_by_user.borrow(member)
            } <b>else</b> {
                0
            };
        <b>let</b> power = <a href="staking_registry.md#0x1_staking_registry_get_user_effective_power_for_validator_with_extra_deposit">get_user_effective_power_for_validator_with_extra_deposit</a>(
            registry,
            *member,
            validator_address,
            extra_deposit_octas,
        );
        addresses.push_back(*member);
        powers.push_back(power);
        total_power += (power <b>as</b> u128);
    });
    (addresses, powers, total_power <b>as</b> u64)
}
</code></pre>



</details>

<a id="0x1_staking_registry_get_total_staked_power"></a>

## Function `get_total_staked_power`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_total_staked_power">get_total_staked_power</a>(): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_total_staked_power">get_total_staked_power</a>(): u64 <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <b>if</b> (!<b>exists</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework)) {
        0
    } <b>else</b> {
        <b>borrow_global</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework).total_staked_power
    }
}
</code></pre>



</details>

<a id="0x1_staking_registry_validator_exists"></a>

## Function `validator_exists`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_validator_exists">validator_exists</a>(validator_address: <b>address</b>): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_validator_exists">validator_exists</a>(validator_address: <b>address</b>): bool <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <b>exists</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework)
        && <b>borrow_global</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework).validators.contains(validator_address)
}
</code></pre>



</details>

<a id="0x1_staking_registry_validators_exist"></a>

## Function `validators_exist`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_validators_exist">validators_exist</a>(validators: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;): <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;bool&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_validators_exist">validators_exist</a>(
    validators: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;,
): <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;bool&gt; <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <b>let</b> exists_flags = <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[];
    <b>if</b> (!<b>exists</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework)) {
        <b>return</b> exists_flags
    };
    <b>let</b> registry = <b>borrow_global</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework);
    <b>let</b> len = validators.length();
    <b>let</b> i = 0;
    <b>while</b> (i &lt; len) {
        exists_flags.push_back(registry.validators.contains(*validators.borrow(i)));
        i += 1;
    };
    exists_flags
}
</code></pre>



</details>

<a id="0x1_staking_registry_get_validator_view"></a>

## Function `get_validator_view`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_validator_view">get_validator_view</a>(validator_address: <b>address</b>): (<b>address</b>, <b>address</b>, u64, u64, u64, u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_validator_view">get_validator_view</a>(
    validator_address: <b>address</b>,
): (<b>address</b>, <b>address</b>, u64, u64, u64, u64, u64) <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <b>if</b> (!<b>exists</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework)) {
        <b>return</b> <a href="staking_registry.md#0x1_staking_registry_empty_validator_view">empty_validator_view</a>(validator_address)
    };
    <b>let</b> registry = <b>borrow_global</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework);
    <a href="staking_registry.md#0x1_staking_registry_build_validator_view">build_validator_view</a>(registry, validator_address)
}
</code></pre>



</details>

<a id="0x1_staking_registry_get_validator_views_by_addresses"></a>

## Function `get_validator_views_by_addresses`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_validator_views_by_addresses">get_validator_views_by_addresses</a>(validators: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;): (<a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;, <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;, <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_validator_views_by_addresses">get_validator_views_by_addresses</a>(
    validators: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;,
): (
    <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;,
    <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;,
    <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt;,
    <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt;,
    <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt;,
    <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt;,
    <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt;,
) <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <b>let</b> validator_addresses = <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[];
    <b>let</b> owner_addresses = <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[];
    <b>let</b> commission_bps_values = <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[];
    <b>let</b> statuses = <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[];
    <b>let</b> delegator_counts = <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[];
    <b>let</b> joining_powers = <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[];
    <b>let</b> total_powers = <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[];
    <b>if</b> (!<b>exists</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework)) {
        <b>return</b> (
            validator_addresses,
            owner_addresses,
            commission_bps_values,
            statuses,
            delegator_counts,
            joining_powers,
            total_powers,
        )
    };
    <b>let</b> registry = <b>borrow_global</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework);
    <b>let</b> len = validators.length();
    <b>let</b> i = 0;
    <b>while</b> (i &lt; len) {
        <b>let</b> (
            validator_address,
            owner_address,
            commission_bps,
            status,
            delegator_count,
            joining_power,
            total_power,
        ) = <a href="staking_registry.md#0x1_staking_registry_build_validator_view">build_validator_view</a>(registry, *validators.borrow(i));
        validator_addresses.push_back(validator_address);
        owner_addresses.push_back(owner_address);
        commission_bps_values.push_back(commission_bps);
        statuses.push_back(status);
        delegator_counts.push_back(delegator_count);
        joining_powers.push_back(joining_power);
        total_powers.push_back(total_power);
        i += 1;
    };
    (
        validator_addresses,
        owner_addresses,
        commission_bps_values,
        statuses,
        delegator_counts,
        joining_powers,
        total_powers,
    )
}
</code></pre>



</details>

<a id="0x1_staking_registry_get_user_stake_view"></a>

## Function `get_user_stake_view`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_user_stake_view">get_user_stake_view</a>(user: <b>address</b>): (<b>address</b>, u64, <b>address</b>, u64, u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_user_stake_view">get_user_stake_view</a>(
    user: <b>address</b>,
): (<b>address</b>, u64, <b>address</b>, u64, u64, u64) <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <b>if</b> (!<b>exists</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework)) {
        <b>return</b> <a href="staking_registry.md#0x1_staking_registry_empty_user_stake_view">empty_user_stake_view</a>(user)
    };
    <b>let</b> registry = <b>borrow_global</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework);
    <a href="staking_registry.md#0x1_staking_registry_build_user_stake_view">build_user_stake_view</a>(registry, user)
}
</code></pre>



</details>

<a id="0x1_staking_registry_users_have_stake_records"></a>

## Function `users_have_stake_records`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_users_have_stake_records">users_have_stake_records</a>(users: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;): <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;bool&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_users_have_stake_records">users_have_stake_records</a>(
    users: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;,
): <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;bool&gt; <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <b>let</b> exists_flags = <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[];
    <b>if</b> (!<b>exists</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework)) {
        <b>return</b> exists_flags
    };
    <b>let</b> registry = <b>borrow_global</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework);
    <b>let</b> len = users.length();
    <b>let</b> i = 0;
    <b>while</b> (i &lt; len) {
        exists_flags.push_back(registry.users.contains(*users.borrow(i)));
        i += 1;
    };
    exists_flags
}
</code></pre>



</details>

<a id="0x1_staking_registry_get_user_stake_views_by_addresses"></a>

## Function `get_user_stake_views_by_addresses`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_user_stake_views_by_addresses">get_user_stake_views_by_addresses</a>(users: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;): (<a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;, <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;, <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_user_stake_views_by_addresses">get_user_stake_views_by_addresses</a>(
    users: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;,
): (
    <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;,
    <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt;,
    <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;,
    <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt;,
    <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt;,
    <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt;,
) <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <b>let</b> returned_users = <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[];
    <b>let</b> deposit_octas_values = <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[];
    <b>let</b> delegated_to_values = <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[];
    <b>let</b> cooldown_until_secs_values = <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[];
    <b>let</b> committed_powers = <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[];
    <b>let</b> effective_powers = <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[];
    <b>if</b> (!<b>exists</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework)) {
        <b>return</b> (
            returned_users,
            deposit_octas_values,
            delegated_to_values,
            cooldown_until_secs_values,
            committed_powers,
            effective_powers,
        )
    };
    <b>let</b> registry = <b>borrow_global</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework);
    <b>let</b> len = users.length();
    <b>let</b> i = 0;
    <b>while</b> (i &lt; len) {
        <b>let</b> (
            user,
            deposit_octas,
            delegated_to,
            cooldown_until_secs,
            committed_power,
            effective_power,
        ) = <a href="staking_registry.md#0x1_staking_registry_build_user_stake_view">build_user_stake_view</a>(registry, *users.borrow(i));
        returned_users.push_back(user);
        deposit_octas_values.push_back(deposit_octas);
        delegated_to_values.push_back(delegated_to);
        cooldown_until_secs_values.push_back(cooldown_until_secs);
        committed_powers.push_back(committed_power);
        effective_powers.push_back(effective_power);
        i += 1;
    };
    (
        returned_users,
        deposit_octas_values,
        delegated_to_values,
        cooldown_until_secs_values,
        committed_powers,
        effective_powers,
    )
}
</code></pre>



</details>

<a id="0x1_staking_registry_get_validator_delegator_count"></a>

## Function `get_validator_delegator_count`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_validator_delegator_count">get_validator_delegator_count</a>(validator_address: <b>address</b>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_validator_delegator_count">get_validator_delegator_count</a>(
    validator_address: <b>address</b>,
): u64 <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <b>if</b> (!<b>exists</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework)) {
        <b>return</b> 0
    };
    <b>let</b> registry = <b>borrow_global</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework);
    <b>if</b> (!registry.validators.contains(validator_address)) {
        <b>return</b> 0
    };
    registry.validators.borrow(validator_address).delegator_list.length()
}
</code></pre>



</details>

<a id="0x1_staking_registry_get_validator_delegators"></a>

## Function `get_validator_delegators`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_validator_delegators">get_validator_delegators</a>(validator_address: <b>address</b>, offset: u64, limit: u64): <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_validator_delegators">get_validator_delegators</a>(
    validator_address: <b>address</b>,
    offset: u64,
    limit: u64,
): <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt; <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <b>if</b> (!<b>exists</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework)) {
        <b>return</b> <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[]
    };
    <b>let</b> registry = <b>borrow_global</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework);
    <b>if</b> (!registry.validators.contains(validator_address)) {
        <b>return</b> <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[]
    };
    <b>let</b> pool = registry.validators.borrow(validator_address);
    <a href="staking_registry.md#0x1_staking_registry_copy_address_range">copy_address_range</a>(&pool.delegator_list, offset, limit)
}
</code></pre>



</details>

<a id="0x1_staking_registry_get_validator_delegator_views"></a>

## Function `get_validator_delegator_views`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_validator_delegator_views">get_validator_delegator_views</a>(validator_address: <b>address</b>, offset: u64, limit: u64): (<a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;, <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_validator_delegator_views">get_validator_delegator_views</a>(
    validator_address: <b>address</b>,
    offset: u64,
    limit: u64,
): (<a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;, <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt;) <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <b>let</b> delegators = <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[];
    <b>let</b> deposit_octas_values = <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[];
    <b>let</b> committed_powers = <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[];
    <b>let</b> effective_powers = <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[];
    <b>if</b> (!<b>exists</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework)) {
        <b>return</b> (delegators, deposit_octas_values, committed_powers, effective_powers)
    };
    <b>let</b> registry = <b>borrow_global</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework);
    <b>if</b> (!registry.validators.contains(validator_address)) {
        <b>return</b> (delegators, deposit_octas_values, committed_powers, effective_powers)
    };
    <b>let</b> pool = registry.validators.borrow(validator_address);
    <b>let</b> len = pool.delegator_list.length();
    <b>let</b> i = offset;
    <b>let</b> end = <a href="staking_registry.md#0x1_staking_registry_range_end">range_end</a>(offset, limit, len);
    <b>while</b> (i &lt; end) {
        <b>let</b> delegator = *pool.delegator_list.borrow(i);
        <b>let</b> (deposit_octas, committed_power, effective_power) =
            <a href="staking_registry.md#0x1_staking_registry_build_delegator_view">build_delegator_view</a>(registry, delegator, validator_address);
        delegators.push_back(delegator);
        deposit_octas_values.push_back(deposit_octas);
        committed_powers.push_back(committed_power);
        effective_powers.push_back(effective_power);
        i += 1;
    };
    (delegators, deposit_octas_values, committed_powers, effective_powers)
}
</code></pre>



</details>

<a id="0x1_staking_registry_get_user_stake_info"></a>

## Function `get_user_stake_info`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_user_stake_info">get_user_stake_info</a>(user: <b>address</b>): (u64, <b>address</b>, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_user_stake_info">get_user_stake_info</a>(
    user: <b>address</b>,
): (u64, <b>address</b>, u64) <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <b>if</b> (!<b>exists</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework)) {
        <b>return</b> (0, @0x0, 0)
    };

    <b>let</b> registry = <b>borrow_global</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework);
    <b>if</b> (!registry.users.contains(user)) {
        <b>return</b> (0, @0x0, 0)
    };

    <b>let</b> info = registry.users.borrow(user);
    (<a href="coin.md#0x1_coin_value">coin::value</a>(&info.deposit), info.delegated_to, info.cooldown_until_secs)
}
</code></pre>



</details>

<a id="0x1_staking_registry_get_validator_owner"></a>

## Function `get_validator_owner`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_validator_owner">get_validator_owner</a>(validator_address: <b>address</b>): <b>address</b>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_validator_owner">get_validator_owner</a>(
    validator_address: <b>address</b>,
): <b>address</b> <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <b>if</b> (!<b>exists</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework)) {
        <b>return</b> @0x0
    };

    <b>let</b> registry = <b>borrow_global</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework);
    <b>if</b> (!registry.validators.contains(validator_address)) {
        <b>return</b> @0x0
    };

    registry.validators.borrow(validator_address).owner_address
}
</code></pre>



</details>

<a id="0x1_staking_registry_get_validator_commission_bps"></a>

## Function `get_validator_commission_bps`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_validator_commission_bps">get_validator_commission_bps</a>(validator_address: <b>address</b>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_validator_commission_bps">get_validator_commission_bps</a>(
    validator_address: <b>address</b>,
): u64 <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <b>if</b> (!<b>exists</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework)) {
        <b>return</b> 0
    };

    <b>let</b> registry = <b>borrow_global</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework);
    <b>if</b> (!registry.validators.contains(validator_address)) {
        <b>return</b> 0
    };

    registry.validators.borrow(validator_address).commission_bps
}
</code></pre>



</details>

<a id="0x1_staking_registry_set_total_staked_power"></a>

## Function `set_total_staked_power`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_set_total_staked_power">set_total_staked_power</a>(total_staked_power: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_set_total_staked_power">set_total_staked_power</a>(total_staked_power: u64) <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <b>if</b> (!<b>exists</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework)) {
        <b>return</b>
    };
    <b>borrow_global_mut</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework).total_staked_power = total_staked_power;
}
</code></pre>



</details>

<a id="0x1_staking_registry_get_cooldown_secs"></a>

## Function `get_cooldown_secs`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_cooldown_secs">get_cooldown_secs</a>(): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_cooldown_secs">get_cooldown_secs</a>(): u64 <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <b>if</b> (!<b>exists</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework)) {
        0
    } <b>else</b> {
        <b>borrow_global</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework).config.cooldown_secs
    }
}
</code></pre>



</details>

<a id="0x1_staking_registry_get_octas_per_million_power"></a>

## Function `get_octas_per_million_power`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_octas_per_million_power">get_octas_per_million_power</a>(): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_octas_per_million_power">get_octas_per_million_power</a>(): u64 <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <b>if</b> (!<b>exists</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework)) {
        0
    } <b>else</b> {
        <b>borrow_global</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework).config.octas_per_million_power
    }
}
</code></pre>



</details>

<a id="0x1_staking_registry_get_min_active_power"></a>

## Function `get_min_active_power`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_min_active_power">get_min_active_power</a>(): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_min_active_power">get_min_active_power</a>(): u64 <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <b>if</b> (!<b>exists</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework)) {
        0
    } <b>else</b> {
        <b>borrow_global</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework).config.min_active_power
    }
}
</code></pre>



</details>

<a id="0x1_staking_registry_get_force_exit_power_bps"></a>

## Function `get_force_exit_power_bps`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_force_exit_power_bps">get_force_exit_power_bps</a>(): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_force_exit_power_bps">get_force_exit_power_bps</a>(): u64 <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <b>if</b> (!<b>exists</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework)) {
        0
    } <b>else</b> {
        <b>borrow_global</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework).config.force_exit_power_bps
    }
}
</code></pre>



</details>

<a id="0x1_staking_registry_set_validator_pending_active"></a>

## Function `set_validator_pending_active`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_set_validator_pending_active">set_validator_pending_active</a>(validator_address: <b>address</b>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_set_validator_pending_active">set_validator_pending_active</a>(
    validator_address: <b>address</b>,
) <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <a href="staking_registry.md#0x1_staking_registry_set_validator_status">set_validator_status</a>(validator_address, <a href="staking_registry.md#0x1_staking_registry_VALIDATOR_STATUS_PENDING_ACTIVE">VALIDATOR_STATUS_PENDING_ACTIVE</a>);
}
</code></pre>



</details>

<a id="0x1_staking_registry_set_validator_active"></a>

## Function `set_validator_active`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_set_validator_active">set_validator_active</a>(validator_address: <b>address</b>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_set_validator_active">set_validator_active</a>(
    validator_address: <b>address</b>,
) <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <a href="staking_registry.md#0x1_staking_registry_set_validator_status">set_validator_status</a>(validator_address, <a href="staking_registry.md#0x1_staking_registry_VALIDATOR_STATUS_ACTIVE">VALIDATOR_STATUS_ACTIVE</a>);
}
</code></pre>



</details>

<a id="0x1_staking_registry_set_validator_pending_inactive"></a>

## Function `set_validator_pending_inactive`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_set_validator_pending_inactive">set_validator_pending_inactive</a>(validator_address: <b>address</b>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_set_validator_pending_inactive">set_validator_pending_inactive</a>(
    validator_address: <b>address</b>,
) <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <a href="staking_registry.md#0x1_staking_registry_set_validator_status">set_validator_status</a>(validator_address, <a href="staking_registry.md#0x1_staking_registry_VALIDATOR_STATUS_PENDING_INACTIVE">VALIDATOR_STATUS_PENDING_INACTIVE</a>);
}
</code></pre>



</details>

<a id="0x1_staking_registry_set_validator_inactive"></a>

## Function `set_validator_inactive`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_set_validator_inactive">set_validator_inactive</a>(validator_address: <b>address</b>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_set_validator_inactive">set_validator_inactive</a>(
    validator_address: <b>address</b>,
) <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <a href="staking_registry.md#0x1_staking_registry_set_validator_status">set_validator_status</a>(validator_address, <a href="staking_registry.md#0x1_staking_registry_VALIDATOR_STATUS_INACTIVE">VALIDATOR_STATUS_INACTIVE</a>);
}
</code></pre>



</details>

<a id="0x1_staking_registry_force_undelegate_below_threshold"></a>

## Function `force_undelegate_below_threshold`

Force-undelegate all delegators of a validator pool whose effective power has dropped
below the maintain threshold.

Called by <code><a href="stake.md#0x1_stake_on_new_epoch">stake::on_new_epoch</a></code> for every active, pending_inactive, and pending_active pool.

Why force-undelegate?
- A user's POC power can decay over time (retention) or drop if they stop contributing.
- If their power falls below the maintain threshold, they no longer meaningfully back
the validator and should be removed to keep pool accounting clean.
- maintain_threshold = ceil(min_active_power * force_exit_power_bps / 10000)
The ceiling ensures the threshold is at least 1 when min_active_power > 0.

Force-undelegated users receive the same cooldown as voluntary undelegation.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_force_undelegate_below_threshold">force_undelegate_below_threshold</a>(validator_address: <b>address</b>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_force_undelegate_below_threshold">force_undelegate_below_threshold</a>(
    validator_address: <b>address</b>,
) <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <b>if</b> (!<b>exists</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework)) {
        <b>return</b>
    };

    <b>let</b> registry = <b>borrow_global_mut</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework);
    <b>if</b> (!registry.validators.contains(validator_address)) {
        <b>return</b>
    };

    <b>let</b> maintain_threshold = <a href="staking_registry.md#0x1_staking_registry_calculate_force_exit_power">calculate_force_exit_power</a>(
        registry.config.min_active_power,
        registry.config.force_exit_power_bps,
    );
    <b>let</b> members = {
        <b>let</b> pool = registry.validators.borrow(validator_address);
        <a href="staking_registry.md#0x1_staking_registry_copy_addresses">copy_addresses</a>(&pool.delegator_list)
    };

    <b>let</b> len = members.length();
    <b>let</b> i = 0;
    <b>while</b> (i &lt; len) {
        <b>let</b> member = *members.borrow(i);
        <b>if</b> (<a href="staking_registry.md#0x1_staking_registry_should_force_undelegate">should_force_undelegate</a>(
            registry,
            member,
            validator_address,
            maintain_threshold,
        )) {
            <a href="staking_registry.md#0x1_staking_registry_force_undelegate_member">force_undelegate_member</a>(registry, member, validator_address);
        };
        i += 1;
    };
}
</code></pre>



</details>

<a id="0x1_staking_registry_update_validator_commission"></a>

## Function `update_validator_commission`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_update_validator_commission">update_validator_commission</a>(validator_address: <b>address</b>, commission_bps: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_update_validator_commission">update_validator_commission</a>(
    validator_address: <b>address</b>,
    commission_bps: u64,
) <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <a href="staking_registry.md#0x1_staking_registry_assert_valid_commission">assert_valid_commission</a>(commission_bps);
    <b>if</b> (!<b>exists</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework)) {
        <b>return</b>
    };

    <b>let</b> registry = <b>borrow_global_mut</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework);
    <b>if</b> (!registry.validators.contains(validator_address)) {
        <b>return</b>
    };
    registry.validators.borrow_mut(validator_address).commission_bps = commission_bps;
}
</code></pre>



</details>

<a id="0x1_staking_registry_distribute_epoch_rewards"></a>

## Function `distribute_epoch_rewards`

Distribute epoch staking rewards to all delegators of a validator pool.

Called by <code><a href="stake.md#0x1_stake_on_new_epoch">stake::on_new_epoch</a></code> for each active and pending_inactive validator.

Reward formula:
epoch_reward = pool_power * rewards_rate * num_successful_proposals
/ (rewards_rate_denominator * num_total_proposals)

Distribution:
commission = epoch_reward * commission_bps / 10000  → minted to owner's deposit
distributable = epoch_reward - commission
each delegator gets: distributable * member_power / pool_power
rounding dust (distributable - sum_distributed) goes to the owner

All rewards are minted as new TopoCoin and deposited directly into each user's
registry deposit balance (auto-compounding — no separate claim step needed).

If pool_power == 0 or epoch_reward == 0, this is a no-op.


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_distribute_epoch_rewards">distribute_epoch_rewards</a>(validator_address: <b>address</b>, num_successful_proposals: u64, num_total_proposals: u64, rewards_rate: u64, rewards_rate_denominator: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_distribute_epoch_rewards">distribute_epoch_rewards</a>(
    validator_address: <b>address</b>,
    num_successful_proposals: u64,
    num_total_proposals: u64,
    rewards_rate: u64,
    rewards_rate_denominator: u64,
) <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <b>if</b> (!<b>exists</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework)) {
        <b>return</b>
    };

    <b>let</b> registry = <b>borrow_global</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework);
    <b>if</b> (!registry.validators.contains(validator_address)) {
        <b>return</b>
    };

    <b>let</b> pool = registry.validators.borrow(validator_address);
    <b>let</b> owner_address = pool.owner_address;
    <b>let</b> commission_bps = pool.commission_bps;
    <b>let</b> members = <a href="staking_registry.md#0x1_staking_registry_copy_addresses">copy_addresses</a>(&pool.delegator_list);
    <b>let</b> member_powers = <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt;[];
    <b>let</b> pool_power = 0u128;
    members.for_each_ref(|member| {
        <b>let</b> power = <a href="staking_registry.md#0x1_staking_registry_get_user_effective_power_for_validator">get_user_effective_power_for_validator</a>(registry, *member, validator_address);
        member_powers.push_back(power);
        pool_power += (power <b>as</b> u128);
    });

    <b>if</b> (pool_power == 0) {
        <b>return</b>
    };

    <b>let</b> epoch_reward = <a href="staking_registry.md#0x1_staking_registry_calculate_rewards_amount">calculate_rewards_amount</a>(
        pool_power <b>as</b> u64,
        num_successful_proposals,
        num_total_proposals,
        rewards_rate,
        rewards_rate_denominator,
    );
    <b>if</b> (epoch_reward == 0) {
        <b>return</b>
    };

    <b>let</b> commission = (((epoch_reward <b>as</b> u128) * (commission_bps <b>as</b> u128)) / 10000) <b>as</b> u64;
    <b>let</b> distributable = epoch_reward - commission;

    <b>let</b> registry = <b>borrow_global_mut</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework);
    <b>let</b> mint_cap = &registry.mint_cap;
    <b>let</b> users = &<b>mut</b> registry.users;

    <b>let</b> sum_distributed = 0u64;
    <b>let</b> len = members.length();
    <b>let</b> i = 0;
    <b>while</b> (i &lt; len) {
        <b>let</b> member = *members.borrow(i);
        <b>let</b> member_power = *member_powers.borrow(i);
        <b>if</b> (member_power &gt; 0) {
            <b>let</b> reward = (((distributable <b>as</b> u128) * (member_power <b>as</b> u128)) / pool_power) <b>as</b> u64;
            <b>if</b> (reward &gt; 0) {
                <a href="staking_registry.md#0x1_staking_registry_mint_to_user_deposit">mint_to_user_deposit</a>(users, mint_cap, member, reward);
            };
            sum_distributed += reward;
        };
        i += 1;
    };

    <b>let</b> owner_reward = commission + (distributable - sum_distributed);
    <b>if</b> (owner_reward &gt; 0) {
        <a href="staking_registry.md#0x1_staking_registry_mint_to_user_deposit">mint_to_user_deposit</a>(users, mint_cap, owner_address, owner_reward);
    };
}
</code></pre>



</details>

<a id="0x1_staking_registry_distribute_transaction_fees"></a>

## Function `distribute_transaction_fees`

Distribute transaction fees collected during an epoch to all delegators of a validator pool.

Called by <code><a href="stake.md#0x1_stake_on_new_epoch">stake::on_new_epoch</a></code> after <code>distribute_epoch_rewards</code>, for each validator
that has a non-zero fee share (requires the distribute_transaction_fee feature flag).

Distribution logic is identical to <code>distribute_epoch_rewards</code>:
commission = fee_amount * commission_bps / 10000  → owner's deposit
remainder split pro-rata by effective power among delegators
rounding dust goes to the owner

Fees are minted as new TopoCoin (the fee was already burned at the protocol level;
this re-mints the validator's share as a reward).


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_distribute_transaction_fees">distribute_transaction_fees</a>(validator_address: <b>address</b>, fee_amount_octa: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_distribute_transaction_fees">distribute_transaction_fees</a>(
    validator_address: <b>address</b>,
    fee_amount_octa: u64,
) <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <b>if</b> (!<b>exists</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework) || fee_amount_octa == 0) {
        <b>return</b>
    };

    <b>let</b> registry = <b>borrow_global</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework);
    <b>if</b> (!registry.validators.contains(validator_address)) {
        <b>return</b>
    };

    <b>let</b> pool = registry.validators.borrow(validator_address);
    <b>let</b> owner_address = pool.owner_address;
    <b>let</b> commission_bps = pool.commission_bps;
    <b>let</b> members = <a href="staking_registry.md#0x1_staking_registry_copy_addresses">copy_addresses</a>(&pool.delegator_list);
    <b>let</b> member_powers = <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt;[];
    <b>let</b> pool_power = 0u128;
    members.for_each_ref(|member| {
        <b>let</b> power = <a href="staking_registry.md#0x1_staking_registry_get_user_effective_power_for_validator">get_user_effective_power_for_validator</a>(registry, *member, validator_address);
        member_powers.push_back(power);
        pool_power += (power <b>as</b> u128);
    });

    <b>if</b> (pool_power == 0) {
        <b>return</b>
    };

    <b>let</b> commission = (((fee_amount_octa <b>as</b> u128) * (commission_bps <b>as</b> u128)) / 10000) <b>as</b> u64;
    <b>let</b> distributable = fee_amount_octa - commission;

    <b>let</b> registry = <b>borrow_global_mut</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework);
    <b>let</b> mint_cap = &registry.mint_cap;
    <b>let</b> users = &<b>mut</b> registry.users;

    <b>let</b> sum_distributed = 0u64;
    <b>let</b> len = members.length();
    <b>let</b> i = 0;
    <b>while</b> (i &lt; len) {
        <b>let</b> member = *members.borrow(i);
        <b>let</b> member_power = *member_powers.borrow(i);
        <b>if</b> (member_power &gt; 0) {
            <b>let</b> fee_share =
                (((distributable <b>as</b> u128) * (member_power <b>as</b> u128)) / pool_power) <b>as</b> u64;
            <b>if</b> (fee_share &gt; 0) {
                <a href="staking_registry.md#0x1_staking_registry_mint_to_user_deposit">mint_to_user_deposit</a>(users, mint_cap, member, fee_share);
            };
            sum_distributed += fee_share;
        };
        i += 1;
    };

    <b>let</b> owner_fee = commission + (distributable - sum_distributed);
    <b>if</b> (owner_fee &gt; 0) {
        <a href="staking_registry.md#0x1_staking_registry_mint_to_user_deposit">mint_to_user_deposit</a>(users, mint_cap, owner_address, owner_fee);
    };
}
</code></pre>



</details>

<a id="0x1_staking_registry_register_validator_internal"></a>

## Function `register_validator_internal`



<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_register_validator_internal">register_validator_internal</a>(owner_address: <b>address</b>, validator_address: <b>address</b>, commission_bps: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_register_validator_internal">register_validator_internal</a>(
    owner_address: <b>address</b>,
    validator_address: <b>address</b>,
    commission_bps: u64,
) <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <a href="staking_registry.md#0x1_staking_registry_assert_valid_commission">assert_valid_commission</a>(commission_bps);
    <b>let</b> registry = <b>borrow_global_mut</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework);
    <b>assert</b>!(
        !registry.validators.contains(validator_address),
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_already_exists">error::already_exists</a>(<a href="staking_registry.md#0x1_staking_registry_EALREADY_VALIDATOR">EALREADY_VALIDATOR</a>),
    );

    <a href="staking_registry.md#0x1_staking_registry_ensure_user_record">ensure_user_record</a>(registry, owner_address);

    registry.validators.add(validator_address, <a href="staking_registry.md#0x1_staking_registry_ValidatorPool">ValidatorPool</a> {
        owner_address,
        delegator_index: <a href="../../aptos-stdlib/doc/smart_table.md#0x1_smart_table_new">smart_table::new</a>(),
        delegator_list: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[],
        commission_bps,
        status: <a href="staking_registry.md#0x1_staking_registry_VALIDATOR_STATUS_INACTIVE">VALIDATOR_STATUS_INACTIVE</a>,
    });
}
</code></pre>



</details>

<a id="0x1_staking_registry_delegate_internal"></a>

## Function `delegate_internal`

Internal delegation logic shared by <code>delegate</code> and genesis paths.

Checks:
1. Validator pool must exist
2. User must not already be delegated
3. Cooldown must have elapsed
4. User's effective power must be >= min_active_power
5. Pool must not exceed max_delegators_per_validator

On success: adds user to pool's delegator_list, sets delegated_to, clears cooldown.


<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_delegate_internal">delegate_internal</a>(user_address: <b>address</b>, validator_address: <b>address</b>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_delegate_internal">delegate_internal</a>(
    user_address: <b>address</b>,
    validator_address: <b>address</b>,
) <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <b>let</b> registry = <b>borrow_global_mut</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework);
    <b>assert</b>!(
        registry.validators.contains(validator_address),
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_invalid_argument">error::invalid_argument</a>(<a href="staking_registry.md#0x1_staking_registry_ENOT_VALIDATOR">ENOT_VALIDATOR</a>),
    );

    <a href="staking_registry.md#0x1_staking_registry_ensure_user_record">ensure_user_record</a>(registry, user_address);

    <b>let</b> now_seconds = <a href="timestamp.md#0x1_timestamp_now_seconds">timestamp::now_seconds</a>();
    <b>let</b> info = registry.users.borrow(user_address);
    <b>assert</b>!(info.delegated_to == @0x0, <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_invalid_state">error::invalid_state</a>(<a href="staking_registry.md#0x1_staking_registry_EALREADY_DELEGATED">EALREADY_DELEGATED</a>));
    <b>assert</b>!(
        info.cooldown_until_secs == 0 || now_seconds &gt;= info.cooldown_until_secs,
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_invalid_state">error::invalid_state</a>(<a href="staking_registry.md#0x1_staking_registry_ECOOLDOWN_ACTIVE">ECOOLDOWN_ACTIVE</a>),
    );
    <b>let</b> effective_power =
        <a href="staking_registry.md#0x1_staking_registry_calculate_effective_power">calculate_effective_power</a>(info, registry.config.octas_per_million_power, user_address);
    <b>assert</b>!(
        effective_power &gt;= registry.config.min_active_power,
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_invalid_argument">error::invalid_argument</a>(<a href="staking_registry.md#0x1_staking_registry_EPOWER_BELOW_MIN_ACTIVE">EPOWER_BELOW_MIN_ACTIVE</a>),
    );

    <b>let</b> max_delegators = registry.config.max_delegators_per_validator;
    <b>let</b> pool = registry.validators.borrow_mut(validator_address);
    <a href="staking_registry.md#0x1_staking_registry_add_delegator">add_delegator</a>(pool, user_address, max_delegators);

    <b>let</b> info = registry.users.borrow_mut(user_address);
    info.delegated_to = validator_address;
    info.cooldown_until_secs = 0;
}
</code></pre>



</details>

<a id="0x1_staking_registry_undelegate_internal"></a>

## Function `undelegate_internal`



<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_undelegate_internal">undelegate_internal</a>(user_address: <b>address</b>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_undelegate_internal">undelegate_internal</a>(
    user_address: <b>address</b>,
) <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <b>let</b> registry = <b>borrow_global_mut</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework);
    <b>assert</b>!(registry.users.contains(user_address), <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_not_found">error::not_found</a>(<a href="staking_registry.md#0x1_staking_registry_EUSER_NOT_FOUND">EUSER_NOT_FOUND</a>));

    <b>let</b> delegated_to = registry.users.borrow(user_address).delegated_to;
    <b>assert</b>!(delegated_to != @0x0, <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_invalid_state">error::invalid_state</a>(<a href="staking_registry.md#0x1_staking_registry_ENOT_DELEGATED">ENOT_DELEGATED</a>));

    <b>let</b> pool = registry.validators.borrow_mut(delegated_to);
    <a href="staking_registry.md#0x1_staking_registry_remove_delegator">remove_delegator</a>(pool, user_address);

    <b>let</b> info = registry.users.borrow_mut(user_address);
    info.delegated_to = @0x0;
    info.cooldown_until_secs = <a href="timestamp.md#0x1_timestamp_now_seconds">timestamp::now_seconds</a>() + registry.config.cooldown_secs;
}
</code></pre>



</details>

<a id="0x1_staking_registry_assert_registry_exists"></a>

## Function `assert_registry_exists`



<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_assert_registry_exists">assert_registry_exists</a>()
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_assert_registry_exists">assert_registry_exists</a>() {
    <b>assert</b>!(
        <b>exists</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework),
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_not_found">error::not_found</a>(<a href="staking_registry.md#0x1_staking_registry_EREGISTRY_NOT_INITIALIZED">EREGISTRY_NOT_INITIALIZED</a>),
    );
}
</code></pre>



</details>

<a id="0x1_staking_registry_assert_valid_commission"></a>

## Function `assert_valid_commission`



<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_assert_valid_commission">assert_valid_commission</a>(commission_bps: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_assert_valid_commission">assert_valid_commission</a>(commission_bps: u64) {
    <b>assert</b>!(commission_bps &lt;= 10000, <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_invalid_argument">error::invalid_argument</a>(<a href="staking_registry.md#0x1_staking_registry_EINVALID_COMMISSION">EINVALID_COMMISSION</a>));
}
</code></pre>



</details>

<a id="0x1_staking_registry_assert_valid_active_power_config"></a>

## Function `assert_valid_active_power_config`



<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_assert_valid_active_power_config">assert_valid_active_power_config</a>(min_active_power: u64, force_exit_power_bps: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_assert_valid_active_power_config">assert_valid_active_power_config</a>(
    min_active_power: u64,
    force_exit_power_bps: u64,
) {
    <b>assert</b>!(min_active_power &gt; 0, <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_invalid_argument">error::invalid_argument</a>(<a href="staking_registry.md#0x1_staking_registry_EINVALID_CONFIG">EINVALID_CONFIG</a>));
    <b>assert</b>!(
        force_exit_power_bps &gt; 0 && force_exit_power_bps &lt;= <a href="staking_registry.md#0x1_staking_registry_BPS_DENOMINATOR">BPS_DENOMINATOR</a>,
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_invalid_argument">error::invalid_argument</a>(<a href="staking_registry.md#0x1_staking_registry_EINVALID_CONFIG">EINVALID_CONFIG</a>),
    );
}
</code></pre>



</details>

<a id="0x1_staking_registry_extract_withdrawable_deposit"></a>

## Function `extract_withdrawable_deposit`



<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_extract_withdrawable_deposit">extract_withdrawable_deposit</a>(user_address: <b>address</b>): <a href="coin.md#0x1_coin_Coin">coin::Coin</a>&lt;<a href="topo_coin.md#0x1_topo_coin_TopoCoin">topo_coin::TopoCoin</a>&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_extract_withdrawable_deposit">extract_withdrawable_deposit</a>(
    user_address: <b>address</b>,
): Coin&lt;TopoCoin&gt; <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <b>let</b> registry = <b>borrow_global_mut</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework);
    <b>assert</b>!(registry.users.contains(user_address), <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_not_found">error::not_found</a>(<a href="staking_registry.md#0x1_staking_registry_EUSER_NOT_FOUND">EUSER_NOT_FOUND</a>));

    <b>let</b> info = registry.users.borrow(user_address);
    <b>assert</b>!(info.delegated_to == @0x0, <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_invalid_state">error::invalid_state</a>(<a href="staking_registry.md#0x1_staking_registry_EDEPOSIT_LOCKED">EDEPOSIT_LOCKED</a>));
    <b>assert</b>!(
        info.cooldown_until_secs == 0 || <a href="timestamp.md#0x1_timestamp_now_seconds">timestamp::now_seconds</a>() &gt;= info.cooldown_until_secs,
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_invalid_state">error::invalid_state</a>(<a href="staking_registry.md#0x1_staking_registry_ECOOLDOWN_ACTIVE">ECOOLDOWN_ACTIVE</a>),
    );

    <b>let</b> info = registry.users.borrow_mut(user_address);
    <b>let</b> coins = <a href="coin.md#0x1_coin_extract_all">coin::extract_all</a>(&<b>mut</b> info.deposit);
    info.cooldown_until_secs = 0;
    coins
}
</code></pre>



</details>

<a id="0x1_staking_registry_new_user_info"></a>

## Function `new_user_info`



<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_new_user_info">new_user_info</a>(): <a href="staking_registry.md#0x1_staking_registry_UserStakeInfo">staking_registry::UserStakeInfo</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_new_user_info">new_user_info</a>(): <a href="staking_registry.md#0x1_staking_registry_UserStakeInfo">UserStakeInfo</a> {
    <a href="staking_registry.md#0x1_staking_registry_UserStakeInfo">UserStakeInfo</a> {
        deposit: <a href="coin.md#0x1_coin_zero">coin::zero</a>&lt;TopoCoin&gt;(),
        delegated_to: @0x0,
        cooldown_until_secs: 0,
    }
}
</code></pre>



</details>

<a id="0x1_staking_registry_ensure_user_record"></a>

## Function `ensure_user_record`



<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_ensure_user_record">ensure_user_record</a>(registry: &<b>mut</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">staking_registry::StakingRegistry</a>, user_address: <b>address</b>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_ensure_user_record">ensure_user_record</a>(registry: &<b>mut</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>, user_address: <b>address</b>) {
    <b>if</b> (!registry.users.contains(user_address)) {
        registry.users.add(user_address, <a href="staking_registry.md#0x1_staking_registry_new_user_info">new_user_info</a>());
    };
}
</code></pre>



</details>

<a id="0x1_staking_registry_mint_to_user_deposit"></a>

## Function `mint_to_user_deposit`



<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_mint_to_user_deposit">mint_to_user_deposit</a>(users: &<b>mut</b> <a href="../../aptos-stdlib/doc/table.md#0x1_table_Table">table::Table</a>&lt;<b>address</b>, <a href="staking_registry.md#0x1_staking_registry_UserStakeInfo">staking_registry::UserStakeInfo</a>&gt;, mint_cap: &<a href="coin.md#0x1_coin_MintCapability">coin::MintCapability</a>&lt;<a href="topo_coin.md#0x1_topo_coin_TopoCoin">topo_coin::TopoCoin</a>&gt;, user_address: <b>address</b>, amount: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_mint_to_user_deposit">mint_to_user_deposit</a>(
    users: &<b>mut</b> Table&lt;<b>address</b>, <a href="staking_registry.md#0x1_staking_registry_UserStakeInfo">UserStakeInfo</a>&gt;,
    mint_cap: &MintCapability&lt;TopoCoin&gt;,
    user_address: <b>address</b>,
    amount: u64,
) {
    <b>if</b> (amount == 0) {
        <b>return</b>
    };
    <b>if</b> (!users.contains(user_address)) {
        users.add(user_address, <a href="staking_registry.md#0x1_staking_registry_new_user_info">new_user_info</a>());
    };
    <b>let</b> minted = <a href="coin.md#0x1_coin_mint">coin::mint</a>&lt;TopoCoin&gt;(amount, mint_cap);
    <b>let</b> info = users.borrow_mut(user_address);
    <a href="coin.md#0x1_coin_merge">coin::merge</a>(&<b>mut</b> info.deposit, minted);
}
</code></pre>



</details>

<a id="0x1_staking_registry_add_delegator"></a>

## Function `add_delegator`

Add a delegator to a validator pool using a swap-remove index for O(1) future removal.

The delegator_index SmartTable maps address → position in delegator_list,
enabling O(1) removal via swap-remove without scanning the full list.


<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_add_delegator">add_delegator</a>(pool: &<b>mut</b> <a href="staking_registry.md#0x1_staking_registry_ValidatorPool">staking_registry::ValidatorPool</a>, delegator: <b>address</b>, max_delegators: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_add_delegator">add_delegator</a>(
    pool: &<b>mut</b> <a href="staking_registry.md#0x1_staking_registry_ValidatorPool">ValidatorPool</a>,
    delegator: <b>address</b>,
    max_delegators: u64,
) {
    <b>assert</b>!(
        !pool.delegator_index.contains(delegator),
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_already_exists">error::already_exists</a>(<a href="staking_registry.md#0x1_staking_registry_EALREADY_DELEGATED">EALREADY_DELEGATED</a>),
    );
    <b>assert</b>!(
        pool.delegator_list.length() &lt; max_delegators,
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_invalid_argument">error::invalid_argument</a>(<a href="staking_registry.md#0x1_staking_registry_EMAX_DELEGATORS">EMAX_DELEGATORS</a>),
    );
    <b>let</b> index = pool.delegator_list.length();
    pool.delegator_list.push_back(delegator);
    pool.delegator_index.add(delegator, index);
}
</code></pre>



</details>

<a id="0x1_staking_registry_remove_delegator"></a>

## Function `remove_delegator`

Remove a delegator from a validator pool using swap-remove for O(1) complexity.

Swap-remove: the target delegator's slot is filled by the last element in the list,
then the list is shrunk by one. The index table is updated accordingly.
This avoids O(n) shifting while keeping the list compact.


<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_remove_delegator">remove_delegator</a>(pool: &<b>mut</b> <a href="staking_registry.md#0x1_staking_registry_ValidatorPool">staking_registry::ValidatorPool</a>, delegator: <b>address</b>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_remove_delegator">remove_delegator</a>(
    pool: &<b>mut</b> <a href="staking_registry.md#0x1_staking_registry_ValidatorPool">ValidatorPool</a>,
    delegator: <b>address</b>,
) {
    <b>assert</b>!(
        pool.delegator_index.contains(delegator),
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_invalid_state">error::invalid_state</a>(<a href="staking_registry.md#0x1_staking_registry_ENOT_DELEGATED">ENOT_DELEGATED</a>),
    );
    <b>let</b> index = pool.delegator_index.remove(delegator);
    <b>let</b> last_index = pool.delegator_list.length() - 1;

    <b>if</b> (index != last_index) {
        <b>let</b> last_addr = *pool.delegator_list.borrow(last_index);
        *pool.delegator_list.borrow_mut(index) = last_addr;
        *pool.delegator_index.borrow_mut(last_addr) = index;
    };
    pool.delegator_list.pop_back();
}
</code></pre>



</details>

<a id="0x1_staking_registry_set_validator_status"></a>

## Function `set_validator_status`



<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_set_validator_status">set_validator_status</a>(validator_address: <b>address</b>, status: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_set_validator_status">set_validator_status</a>(
    validator_address: <b>address</b>,
    status: u64,
) <b>acquires</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a> {
    <b>if</b> (!<b>exists</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework)) {
        <b>return</b>
    };

    <b>let</b> registry = <b>borrow_global_mut</b>&lt;<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>&gt;(@aptos_framework);
    <b>if</b> (!registry.validators.contains(validator_address)) {
        <b>return</b>
    };

    registry.validators.borrow_mut(validator_address).status = status;
}
</code></pre>



</details>

<a id="0x1_staking_registry_calculate_force_exit_power"></a>

## Function `calculate_force_exit_power`

Compute the maintain threshold for force-undelegation using ceiling division.

maintain_threshold = ceil(min_active_power * force_exit_power_bps / BPS_DENOMINATOR)

Ceiling division ensures the threshold is at least 1 when min_active_power > 0,
preventing a threshold of 0 that would never trigger force-undelegation.

Example: min_active_power=10, force_exit_power_bps=8000
threshold = ceil(10 * 8000 / 10000) = ceil(8.0) = 8
Users with effective_power < 8 are force-undelegated.


<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_calculate_force_exit_power">calculate_force_exit_power</a>(min_active_power: u64, force_exit_power_bps: u64): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_calculate_force_exit_power">calculate_force_exit_power</a>(
    min_active_power: u64,
    force_exit_power_bps: u64,
): u64 {
    <b>let</b> numerator =
        ((min_active_power <b>as</b> u128) * (force_exit_power_bps <b>as</b> u128))
            + ((<a href="staking_registry.md#0x1_staking_registry_BPS_DENOMINATOR">BPS_DENOMINATOR</a> - 1) <b>as</b> u128);
    (numerator / (<a href="staking_registry.md#0x1_staking_registry_BPS_DENOMINATOR">BPS_DENOMINATOR</a> <b>as</b> u128)) <b>as</b> u64
}
</code></pre>



</details>

<a id="0x1_staking_registry_should_force_undelegate"></a>

## Function `should_force_undelegate`



<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_should_force_undelegate">should_force_undelegate</a>(registry: &<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">staking_registry::StakingRegistry</a>, user: <b>address</b>, validator_address: <b>address</b>, maintain_threshold: u64): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_should_force_undelegate">should_force_undelegate</a>(
    registry: &<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>,
    user: <b>address</b>,
    validator_address: <b>address</b>,
    maintain_threshold: u64,
): bool {
    <b>if</b> (!registry.users.contains(user)) {
        <b>return</b> <b>false</b>
    };

    <b>let</b> info = registry.users.borrow(user);
    <b>if</b> (info.delegated_to != validator_address) {
        <b>return</b> <b>false</b>
    };

    <a href="staking_registry.md#0x1_staking_registry_calculate_effective_power">calculate_effective_power</a>(info, registry.config.octas_per_million_power, user) &lt; maintain_threshold
}
</code></pre>



</details>

<a id="0x1_staking_registry_force_undelegate_member"></a>

## Function `force_undelegate_member`



<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_force_undelegate_member">force_undelegate_member</a>(registry: &<b>mut</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">staking_registry::StakingRegistry</a>, user_address: <b>address</b>, validator_address: <b>address</b>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_force_undelegate_member">force_undelegate_member</a>(
    registry: &<b>mut</b> <a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>,
    user_address: <b>address</b>,
    validator_address: <b>address</b>,
) {
    <b>let</b> pool = registry.validators.borrow_mut(validator_address);
    <a href="staking_registry.md#0x1_staking_registry_remove_delegator">remove_delegator</a>(pool, user_address);

    <b>let</b> info = registry.users.borrow_mut(user_address);
    info.delegated_to = @0x0;
    info.cooldown_until_secs = <a href="timestamp.md#0x1_timestamp_now_seconds">timestamp::now_seconds</a>() + registry.config.cooldown_secs;
}
</code></pre>



</details>

<a id="0x1_staking_registry_calculate_effective_power"></a>

## Function `calculate_effective_power`

Compute a user's effective power from their current stake info.

effective_power = min(committed_poc_power, deposit_octas * 1,000,000 / octas_per_million_power)
If octas_per_million_power is 0, deposit backing is disabled and effective power
equals committed POC power.

The dual-constraint design:
- <code>committed_poc_power</code> (from poc_power_store) represents contribution-based weight.
It is computed off-chain from ContributionEvents and uploaded by the operator.
- <code>deposit_cover</code> represents economic skin-in-the-game: how much power the user's
deposited TOPO coins can back at the current octas_per_million_power exchange rate.

Taking the minimum ensures both dimensions must be maintained simultaneously.
A user who stops contributing loses poc_power (via decay) and their effective power drops.
A user who withdraws their deposit loses deposit_cover and their effective power drops.


<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_calculate_effective_power">calculate_effective_power</a>(info: &<a href="staking_registry.md#0x1_staking_registry_UserStakeInfo">staking_registry::UserStakeInfo</a>, octas_per_million_power: u64, user: <b>address</b>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_calculate_effective_power">calculate_effective_power</a>(
    info: &<a href="staking_registry.md#0x1_staking_registry_UserStakeInfo">UserStakeInfo</a>,
    octas_per_million_power: u64,
    user: <b>address</b>,
): u64 {
    <b>let</b> committed_power = <a href="poc_power_store.md#0x1_poc_power_store_get_user_committed_power">poc_power_store::get_user_committed_power</a>(user);
    <b>let</b> deposit_octas = <a href="coin.md#0x1_coin_value">coin::value</a>(&info.deposit) <b>as</b> u128;
    <a href="staking_registry.md#0x1_staking_registry_calculate_effective_power_from_deposit">calculate_effective_power_from_deposit</a>(
        committed_power,
        deposit_octas,
        octas_per_million_power,
    )
}
</code></pre>



</details>

<a id="0x1_staking_registry_get_user_effective_power_for_validator"></a>

## Function `get_user_effective_power_for_validator`



<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_user_effective_power_for_validator">get_user_effective_power_for_validator</a>(registry: &<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">staking_registry::StakingRegistry</a>, user: <b>address</b>, validator_address: <b>address</b>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_user_effective_power_for_validator">get_user_effective_power_for_validator</a>(
    registry: &<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>,
    user: <b>address</b>,
    validator_address: <b>address</b>,
): u64 {
    <a href="staking_registry.md#0x1_staking_registry_get_user_effective_power_for_validator_with_extra_deposit">get_user_effective_power_for_validator_with_extra_deposit</a>(
        registry,
        user,
        validator_address,
        0,
    )
}
</code></pre>



</details>

<a id="0x1_staking_registry_get_user_effective_power_for_validator_with_extra_deposit"></a>

## Function `get_user_effective_power_for_validator_with_extra_deposit`



<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_user_effective_power_for_validator_with_extra_deposit">get_user_effective_power_for_validator_with_extra_deposit</a>(registry: &<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">staking_registry::StakingRegistry</a>, user: <b>address</b>, validator_address: <b>address</b>, extra_deposit_octas: u64): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_user_effective_power_for_validator_with_extra_deposit">get_user_effective_power_for_validator_with_extra_deposit</a>(
    registry: &<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>,
    user: <b>address</b>,
    validator_address: <b>address</b>,
    extra_deposit_octas: u64,
): u64 {
    <b>if</b> (!registry.users.contains(user)) {
        <b>return</b> 0
    };

    <b>let</b> info = registry.users.borrow(user);
    <b>if</b> (info.delegated_to != validator_address) {
        <b>return</b> 0
    };

    <b>let</b> committed_power = <a href="poc_power_store.md#0x1_poc_power_store_get_user_committed_power">poc_power_store::get_user_committed_power</a>(user);
    <b>let</b> deposit_octas = (<a href="coin.md#0x1_coin_value">coin::value</a>(&info.deposit) <b>as</b> u128)
        + (extra_deposit_octas <b>as</b> u128);
    <a href="staking_registry.md#0x1_staking_registry_calculate_effective_power_from_deposit">calculate_effective_power_from_deposit</a>(
        committed_power,
        deposit_octas,
        registry.config.octas_per_million_power,
    )
}
</code></pre>



</details>

<a id="0x1_staking_registry_get_user_effective_power_for_validator_for_next_epoch"></a>

## Function `get_user_effective_power_for_validator_for_next_epoch`



<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_user_effective_power_for_validator_for_next_epoch">get_user_effective_power_for_validator_for_next_epoch</a>(registry: &<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">staking_registry::StakingRegistry</a>, user: <b>address</b>, validator_address: <b>address</b>, maintain_threshold: u64): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_user_effective_power_for_validator_for_next_epoch">get_user_effective_power_for_validator_for_next_epoch</a>(
    registry: &<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>,
    user: <b>address</b>,
    validator_address: <b>address</b>,
    maintain_threshold: u64,
): u64 {
    <a href="staking_registry.md#0x1_staking_registry_get_user_effective_power_for_validator_for_next_epoch_with_extra_deposit">get_user_effective_power_for_validator_for_next_epoch_with_extra_deposit</a>(
        registry,
        user,
        validator_address,
        maintain_threshold,
        0,
    )
}
</code></pre>



</details>

<a id="0x1_staking_registry_get_user_effective_power_for_validator_for_next_epoch_with_extra_deposit"></a>

## Function `get_user_effective_power_for_validator_for_next_epoch_with_extra_deposit`



<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_user_effective_power_for_validator_for_next_epoch_with_extra_deposit">get_user_effective_power_for_validator_for_next_epoch_with_extra_deposit</a>(registry: &<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">staking_registry::StakingRegistry</a>, user: <b>address</b>, validator_address: <b>address</b>, maintain_threshold: u64, extra_deposit_octas: u64): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_user_effective_power_for_validator_for_next_epoch_with_extra_deposit">get_user_effective_power_for_validator_for_next_epoch_with_extra_deposit</a>(
    registry: &<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>,
    user: <b>address</b>,
    validator_address: <b>address</b>,
    maintain_threshold: u64,
    extra_deposit_octas: u64,
): u64 {
    <b>if</b> (!registry.users.contains(user)) {
        <b>return</b> 0
    };

    <b>let</b> info = registry.users.borrow(user);
    <b>if</b> (info.delegated_to != validator_address) {
        <b>return</b> 0
    };

    <b>let</b> committed_power = <a href="poc_power_store.md#0x1_poc_power_store_get_user_committed_power_for_next_epoch">poc_power_store::get_user_committed_power_for_next_epoch</a>(user);
    <b>let</b> deposit_octas = (<a href="coin.md#0x1_coin_value">coin::value</a>(&info.deposit) <b>as</b> u128)
        + (extra_deposit_octas <b>as</b> u128);
    <b>let</b> effective_power = <a href="staking_registry.md#0x1_staking_registry_calculate_effective_power_from_deposit">calculate_effective_power_from_deposit</a>(
        committed_power,
        deposit_octas,
        registry.config.octas_per_million_power,
    );
    <b>if</b> (effective_power &lt; maintain_threshold) {
        0
    } <b>else</b> {
        effective_power
    }
}
</code></pre>



</details>

<a id="0x1_staking_registry_calculate_effective_power_from_deposit"></a>

## Function `calculate_effective_power_from_deposit`



<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_calculate_effective_power_from_deposit">calculate_effective_power_from_deposit</a>(committed_power: u64, deposit_octas: u128, octas_per_million_power: u64): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_calculate_effective_power_from_deposit">calculate_effective_power_from_deposit</a>(
    committed_power: u64,
    deposit_octas: u128,
    octas_per_million_power: u64,
): u64 {
    <b>if</b> (committed_power == 0) {
        <b>return</b> 0
    };
    <b>if</b> (octas_per_million_power == 0) {
        <b>return</b> committed_power
    };

    <b>let</b> deposit_cover =
        (deposit_octas * <a href="staking_registry.md#0x1_staking_registry_POWER_BACKING_SCALE">POWER_BACKING_SCALE</a>) / (octas_per_million_power <b>as</b> u128);
    <b>if</b> (deposit_cover &gt;= (committed_power <b>as</b> u128)) {
        committed_power
    } <b>else</b> {
        deposit_cover <b>as</b> u64
    }
}
</code></pre>



</details>

<a id="0x1_staking_registry_copy_addresses"></a>

## Function `copy_addresses`



<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_copy_addresses">copy_addresses</a>(addresses: &<a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;): <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_copy_addresses">copy_addresses</a>(addresses: &<a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;): <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt; {
    <b>let</b> copied = <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[];
    addresses.for_each_ref(|addr| copied.push_back(*addr));
    copied
}
</code></pre>



</details>

<a id="0x1_staking_registry_build_validator_view"></a>

## Function `build_validator_view`



<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_build_validator_view">build_validator_view</a>(registry: &<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">staking_registry::StakingRegistry</a>, validator_address: <b>address</b>): (<b>address</b>, <b>address</b>, u64, u64, u64, u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_build_validator_view">build_validator_view</a>(
    registry: &<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>,
    validator_address: <b>address</b>,
): (<b>address</b>, <b>address</b>, u64, u64, u64, u64, u64) {
    <b>if</b> (!registry.validators.contains(validator_address)) {
        <b>return</b> <a href="staking_registry.md#0x1_staking_registry_empty_validator_view">empty_validator_view</a>(validator_address)
    };
    <b>let</b> pool = registry.validators.borrow(validator_address);
    (
        validator_address,
        pool.owner_address,
        pool.commission_bps,
        pool.status,
        pool.delegator_list.length(),
        <a href="staking_registry.md#0x1_staking_registry_get_user_effective_power_for_validator">get_user_effective_power_for_validator</a>(
            registry,
            pool.owner_address,
            validator_address,
        ),
        <a href="staking_registry.md#0x1_staking_registry_calculate_validator_total_power">calculate_validator_total_power</a>(registry, pool, validator_address),
    )
}
</code></pre>



</details>

<a id="0x1_staking_registry_empty_validator_view"></a>

## Function `empty_validator_view`



<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_empty_validator_view">empty_validator_view</a>(validator_address: <b>address</b>): (<b>address</b>, <b>address</b>, u64, u64, u64, u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_empty_validator_view">empty_validator_view</a>(
    validator_address: <b>address</b>,
): (<b>address</b>, <b>address</b>, u64, u64, u64, u64, u64) {
    (validator_address, @0x0, 0, <a href="staking_registry.md#0x1_staking_registry_VALIDATOR_STATUS_INACTIVE">VALIDATOR_STATUS_INACTIVE</a>, 0, 0, 0)
}
</code></pre>



</details>

<a id="0x1_staking_registry_build_user_stake_view"></a>

## Function `build_user_stake_view`



<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_build_user_stake_view">build_user_stake_view</a>(registry: &<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">staking_registry::StakingRegistry</a>, user: <b>address</b>): (<b>address</b>, u64, <b>address</b>, u64, u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_build_user_stake_view">build_user_stake_view</a>(
    registry: &<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>,
    user: <b>address</b>,
): (<b>address</b>, u64, <b>address</b>, u64, u64, u64) {
    <b>if</b> (!registry.users.contains(user)) {
        <b>return</b> <a href="staking_registry.md#0x1_staking_registry_empty_user_stake_view">empty_user_stake_view</a>(user)
    };
    <b>let</b> info = registry.users.borrow(user);
    (
        user,
        <a href="coin.md#0x1_coin_value">coin::value</a>(&info.deposit),
        info.delegated_to,
        info.cooldown_until_secs,
        <a href="poc_power_store.md#0x1_poc_power_store_get_user_committed_power">poc_power_store::get_user_committed_power</a>(user),
        <a href="staking_registry.md#0x1_staking_registry_get_active_effective_power">get_active_effective_power</a>(registry, user),
    )
}
</code></pre>



</details>

<a id="0x1_staking_registry_empty_user_stake_view"></a>

## Function `empty_user_stake_view`



<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_empty_user_stake_view">empty_user_stake_view</a>(user: <b>address</b>): (<b>address</b>, u64, <b>address</b>, u64, u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_empty_user_stake_view">empty_user_stake_view</a>(user: <b>address</b>): (<b>address</b>, u64, <b>address</b>, u64, u64, u64) {
    (user, 0, @0x0, 0, <a href="poc_power_store.md#0x1_poc_power_store_get_user_committed_power">poc_power_store::get_user_committed_power</a>(user), 0)
}
</code></pre>



</details>

<a id="0x1_staking_registry_build_delegator_view"></a>

## Function `build_delegator_view`



<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_build_delegator_view">build_delegator_view</a>(registry: &<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">staking_registry::StakingRegistry</a>, delegator: <b>address</b>, validator_address: <b>address</b>): (u64, u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_build_delegator_view">build_delegator_view</a>(
    registry: &<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>,
    delegator: <b>address</b>,
    validator_address: <b>address</b>,
): (u64, u64, u64) {
    <b>if</b> (!registry.users.contains(delegator)) {
        <b>return</b> (0, <a href="poc_power_store.md#0x1_poc_power_store_get_user_committed_power">poc_power_store::get_user_committed_power</a>(delegator), 0)
    };
    <b>let</b> info = registry.users.borrow(delegator);
    (
        <a href="coin.md#0x1_coin_value">coin::value</a>(&info.deposit),
        <a href="poc_power_store.md#0x1_poc_power_store_get_user_committed_power">poc_power_store::get_user_committed_power</a>(delegator),
        <a href="staking_registry.md#0x1_staking_registry_get_user_effective_power_for_validator">get_user_effective_power_for_validator</a>(
            registry,
            delegator,
            validator_address,
        ),
    )
}
</code></pre>



</details>

<a id="0x1_staking_registry_get_active_effective_power"></a>

## Function `get_active_effective_power`



<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_active_effective_power">get_active_effective_power</a>(registry: &<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">staking_registry::StakingRegistry</a>, user: <b>address</b>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_active_effective_power">get_active_effective_power</a>(
    registry: &<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>,
    user: <b>address</b>,
): u64 {
    <b>if</b> (!registry.users.contains(user)) {
        <b>return</b> 0
    };
    <b>let</b> info = registry.users.borrow(user);
    <b>if</b> (info.delegated_to == @0x0 || !registry.validators.contains(info.delegated_to)) {
        <b>return</b> 0
    };
    <b>let</b> pool = registry.validators.borrow(info.delegated_to);
    <b>if</b> (pool.status != <a href="staking_registry.md#0x1_staking_registry_VALIDATOR_STATUS_ACTIVE">VALIDATOR_STATUS_ACTIVE</a>
        && pool.status != <a href="staking_registry.md#0x1_staking_registry_VALIDATOR_STATUS_PENDING_INACTIVE">VALIDATOR_STATUS_PENDING_INACTIVE</a>) {
        <b>return</b> 0
    };
    <a href="staking_registry.md#0x1_staking_registry_calculate_effective_power">calculate_effective_power</a>(info, registry.config.octas_per_million_power, user)
}
</code></pre>



</details>

<a id="0x1_staking_registry_calculate_validator_total_power"></a>

## Function `calculate_validator_total_power`



<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_calculate_validator_total_power">calculate_validator_total_power</a>(registry: &<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">staking_registry::StakingRegistry</a>, pool: &<a href="staking_registry.md#0x1_staking_registry_ValidatorPool">staking_registry::ValidatorPool</a>, validator_address: <b>address</b>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_calculate_validator_total_power">calculate_validator_total_power</a>(
    registry: &<a href="staking_registry.md#0x1_staking_registry_StakingRegistry">StakingRegistry</a>,
    pool: &<a href="staking_registry.md#0x1_staking_registry_ValidatorPool">ValidatorPool</a>,
    validator_address: <b>address</b>,
): u64 {
    <b>let</b> total_power = 0u128;
    pool.delegator_list.for_each_ref(|member| {
        <b>let</b> member_address = *member;
        total_power += (<a href="staking_registry.md#0x1_staking_registry_get_user_effective_power_for_validator">get_user_effective_power_for_validator</a>(
            registry,
            member_address,
            validator_address,
        ) <b>as</b> u128);
    });
    total_power <b>as</b> u64
}
</code></pre>



</details>

<a id="0x1_staking_registry_copy_address_range"></a>

## Function `copy_address_range`



<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_copy_address_range">copy_address_range</a>(addresses: &<a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;, offset: u64, limit: u64): <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_copy_address_range">copy_address_range</a>(
    addresses: &<a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;,
    offset: u64,
    limit: u64,
): <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt; {
    <b>let</b> copied = <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[];
    <b>let</b> len = addresses.length();
    <b>let</b> i = offset;
    <b>let</b> end = <a href="staking_registry.md#0x1_staking_registry_range_end">range_end</a>(offset, limit, len);
    <b>while</b> (i &lt; end) {
        copied.push_back(*addresses.borrow(i));
        i += 1;
    };
    copied
}
</code></pre>



</details>

<a id="0x1_staking_registry_range_end"></a>

## Function `range_end`



<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_range_end">range_end</a>(offset: u64, limit: u64, len: u64): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_range_end">range_end</a>(offset: u64, limit: u64, len: u64): u64 {
    <b>if</b> (offset &gt;= len || limit == 0) {
        <b>return</b> offset
    };
    <b>let</b> remaining = len - offset;
    <b>if</b> (limit &gt;= remaining) {
        len
    } <b>else</b> {
        offset + limit
    }
}
</code></pre>



</details>

<a id="0x1_staking_registry_calculate_rewards_amount"></a>

## Function `calculate_rewards_amount`

Compute epoch rewards for a validator pool.

Formula: reward = pool_power * rewards_rate * num_successful_proposals
/ (rewards_rate_denominator * num_total_proposals)

All arithmetic is done in u128 to avoid overflow before the final division.
Returns 0 if any of pool_power, num_total_proposals, or rewards_rate is zero.


<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_calculate_rewards_amount">calculate_rewards_amount</a>(pool_power: u64, num_successful_proposals: u64, num_total_proposals: u64, rewards_rate: u64, rewards_rate_denominator: u64): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_calculate_rewards_amount">calculate_rewards_amount</a>(
    pool_power: u64,
    num_successful_proposals: u64,
    num_total_proposals: u64,
    rewards_rate: u64,
    rewards_rate_denominator: u64,
): u64 {
    <b>if</b> (pool_power == 0 || num_total_proposals == 0 || rewards_rate == 0) {
        <b>return</b> 0
    };

    <b>let</b> rewards_numerator =
        (pool_power <b>as</b> u128) * (rewards_rate <b>as</b> u128) * (num_successful_proposals <b>as</b> u128);
    <b>let</b> rewards_denominator =
        (rewards_rate_denominator <b>as</b> u128) * (num_total_proposals <b>as</b> u128);
    <b>if</b> (rewards_denominator == 0) {
        0
    } <b>else</b> {
        (rewards_numerator / rewards_denominator) <b>as</b> u64
    }
}
</code></pre>



</details>

<a id="@Specification_5"></a>

## Specification


<a id="@Specification_5_get_effective_power"></a>

### Function `get_effective_power`


<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_effective_power">get_effective_power</a>(user: <b>address</b>): u64
</code></pre>




<pre><code><b>ensures</b> result == <a href="staking_registry.md#0x1_staking_registry_spec_get_effective_power">spec_get_effective_power</a>(user);
</code></pre>



<a id="@Specification_5_get_validator_total_power"></a>

### Function `get_validator_total_power`


<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="staking_registry.md#0x1_staking_registry_get_validator_total_power">get_validator_total_power</a>(validator_address: <b>address</b>): u64
</code></pre>




<pre><code><b>ensures</b> result == <a href="staking_registry.md#0x1_staking_registry_spec_get_validator_total_power">spec_get_validator_total_power</a>(validator_address);
</code></pre>




<a id="0x1_staking_registry_spec_get_effective_power"></a>


<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_spec_get_effective_power">spec_get_effective_power</a>(user: <b>address</b>): u64;
</code></pre>




<a id="0x1_staking_registry_spec_get_validator_total_power"></a>


<pre><code><b>fun</b> <a href="staking_registry.md#0x1_staking_registry_spec_get_validator_total_power">spec_get_validator_total_power</a>(validator_address: <b>address</b>): u64;
</code></pre>


[move-book]: https://aptos.dev/move/book/SUMMARY
