
<a id="0x1_genesis"></a>

# Module `0x1::genesis`

Genesis module — bootstraps the entire Topo chain from a blank state.


<a id="@Responsibilities_0"></a>

### Responsibilities


This module is the single entry point called by the Rust genesis builder to initialize
every on-chain resource before the first block is produced. It wires together all
framework modules in the correct dependency order.


<a id="@Initialization_Sequence_1"></a>

### Initialization Sequence


Step 1 — <code>initialize</code>: Core framework accounts and protocol modules
- Create @aptos_framework account; hand control to topo_governance
- Reserve framework addresses @0x2–@0xa under governance
- Initialize: consensus_config, execution_config, version, stake, staking_config,
storage_gas, gas_schedule, aggregator_factory, chain_id, reconfiguration,
block, state_storage, nonce_validation, transaction_validation

Step 2 — <code>initialize_topo_coin</code>: Mint/burn capabilities
- Create TopoCoin with mint + burn caps
- Distribute caps: stake (mint for rewards), staking_registry (mint for rewards),
transaction_fee (burn for gas, mint for refunds)

Step 3 — <code>create_accounts</code>: Fund initial accounts from the genesis config

Step 4 — <code>create_initialize_validators_with_commission</code>: Bootstrap the validator set
- <code>ensure_poc_staking_initialized</code>: Initialize poc_power_store and staking_registry
- For each validator: create account, initialize stake pool, register in staking_registry,
seed genesis POC power, deposit stake, delegate, join validator set
- Destroy the framework mint cap (no more minting outside of reward distribution)
- <code><a href="stake.md#0x1_stake_on_new_epoch">stake::on_new_epoch</a></code>: activate the genesis validator set

Step 5 — <code>set_genesis_end</code>: Mark chain as operational


<a id="@Key_Design_Decisions_2"></a>

### Key Design Decisions


- <code>ensure_poc_staking_initialized</code> is idempotent and computes cooldown_secs as
max(recurring_lockup_duration, governance_voting_duration) to prevent governance attacks.
- Genesis validators receive POC power seeded from their stake amount via
<code><a href="staking_registry.md#0x1_staking_registry_calculate_genesis_power_from_stake">staking_registry::calculate_genesis_power_from_stake</a></code>, bootstrapping the POC system
before any real contribution events have been emitted.
- The framework mint cap is destroyed after genesis; all subsequent TopoCoin minting
goes through the staking_registry's stored mint cap (for rewards only).


    -  [Responsibilities](#@Responsibilities_0)
    -  [Initialization Sequence](#@Initialization_Sequence_1)
    -  [Key Design Decisions](#@Key_Design_Decisions_2)
-  [Struct `AccountMap`](#0x1_genesis_AccountMap)
-  [Struct `ValidatorConfiguration`](#0x1_genesis_ValidatorConfiguration)
-  [Struct `ValidatorConfigurationWithCommission`](#0x1_genesis_ValidatorConfigurationWithCommission)
-  [Constants](#@Constants_3)
-  [Function `initialize`](#0x1_genesis_initialize)
-  [Function `initialize_topo_coin`](#0x1_genesis_initialize_topo_coin)
-  [Function `initialize_core_resources_and_topo_coin`](#0x1_genesis_initialize_core_resources_and_topo_coin)
-  [Function `create_accounts`](#0x1_genesis_create_accounts)
-  [Function `create_account`](#0x1_genesis_create_account)
-  [Function `ensure_poc_staking_initialized`](#0x1_genesis_ensure_poc_staking_initialized)
-  [Function `create_initialize_validators_with_commission`](#0x1_genesis_create_initialize_validators_with_commission)
-  [Function `create_initialize_validators`](#0x1_genesis_create_initialize_validators)
-  [Function `create_initialize_validator`](#0x1_genesis_create_initialize_validator)
-  [Function `initialize_validator`](#0x1_genesis_initialize_validator)
-  [Function `set_genesis_end`](#0x1_genesis_set_genesis_end)
-  [Specification](#@Specification_4)
    -  [High-level Requirements](#high-level-req)
    -  [Module-level Specification](#module-level-spec)
    -  [Function `initialize`](#@Specification_4_initialize)
    -  [Function `initialize_topo_coin`](#@Specification_4_initialize_topo_coin)
    -  [Function `create_initialize_validators_with_commission`](#@Specification_4_create_initialize_validators_with_commission)
    -  [Function `create_initialize_validators`](#@Specification_4_create_initialize_validators)
    -  [Function `create_initialize_validator`](#@Specification_4_create_initialize_validator)
    -  [Function `initialize_validator`](#@Specification_4_initialize_validator)
    -  [Function `set_genesis_end`](#@Specification_4_set_genesis_end)


<pre><code><b>use</b> <a href="account.md#0x1_account">0x1::account</a>;
<b>use</b> <a href="aggregator_factory.md#0x1_aggregator_factory">0x1::aggregator_factory</a>;
<b>use</b> <a href="block.md#0x1_block">0x1::block</a>;
<b>use</b> <a href="chain_id.md#0x1_chain_id">0x1::chain_id</a>;
<b>use</b> <a href="chain_status.md#0x1_chain_status">0x1::chain_status</a>;
<b>use</b> <a href="coin.md#0x1_coin">0x1::coin</a>;
<b>use</b> <a href="consensus_config.md#0x1_consensus_config">0x1::consensus_config</a>;
<b>use</b> <a href="create_signer.md#0x1_create_signer">0x1::create_signer</a>;
<b>use</b> <a href="execution_config.md#0x1_execution_config">0x1::execution_config</a>;
<b>use</b> <a href="fungible_asset.md#0x1_fungible_asset">0x1::fungible_asset</a>;
<b>use</b> <a href="gas_schedule.md#0x1_gas_schedule">0x1::gas_schedule</a>;
<b>use</b> <a href="nonce_validation.md#0x1_nonce_validation">0x1::nonce_validation</a>;
<b>use</b> <a href="object.md#0x1_object">0x1::object</a>;
<b>use</b> <a href="poc_power_store.md#0x1_poc_power_store">0x1::poc_power_store</a>;
<b>use</b> <a href="primary_fungible_store.md#0x1_primary_fungible_store">0x1::primary_fungible_store</a>;
<b>use</b> <a href="reconfiguration.md#0x1_reconfiguration">0x1::reconfiguration</a>;
<b>use</b> <a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">0x1::signer</a>;
<b>use</b> <a href="stake.md#0x1_stake">0x1::stake</a>;
<b>use</b> <a href="staking_config.md#0x1_staking_config">0x1::staking_config</a>;
<b>use</b> <a href="staking_registry.md#0x1_staking_registry">0x1::staking_registry</a>;
<b>use</b> <a href="state_storage.md#0x1_state_storage">0x1::state_storage</a>;
<b>use</b> <a href="storage_gas.md#0x1_storage_gas">0x1::storage_gas</a>;
<b>use</b> <a href="timestamp.md#0x1_timestamp">0x1::timestamp</a>;
<b>use</b> <a href="topo_coin.md#0x1_topo_coin">0x1::topo_coin</a>;
<b>use</b> <a href="topo_governance.md#0x1_topo_governance">0x1::topo_governance</a>;
<b>use</b> <a href="transaction_fee.md#0x1_transaction_fee">0x1::transaction_fee</a>;
<b>use</b> <a href="transaction_validation.md#0x1_transaction_validation">0x1::transaction_validation</a>;
<b>use</b> <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">0x1::vector</a>;
<b>use</b> <a href="version.md#0x1_version">0x1::version</a>;
</code></pre>



<a id="0x1_genesis_AccountMap"></a>

## Struct `AccountMap`



<pre><code><b>struct</b> <a href="genesis.md#0x1_genesis_AccountMap">AccountMap</a> <b>has</b> drop
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>account_address: <b>address</b></code>
</dt>
<dd>

</dd>
<dt>
<code>balance: u64</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a id="0x1_genesis_ValidatorConfiguration"></a>

## Struct `ValidatorConfiguration`



<pre><code><b>struct</b> <a href="genesis.md#0x1_genesis_ValidatorConfiguration">ValidatorConfiguration</a> <b>has</b> <b>copy</b>, drop
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>owner_address: <b>address</b></code>
</dt>
<dd>

</dd>
<dt>
<code>operator_address: <b>address</b></code>
</dt>
<dd>

</dd>
<dt>
<code>voter_address: <b>address</b></code>
</dt>
<dd>

</dd>
<dt>
<code>stake_amount: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>consensus_pubkey: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u8&gt;</code>
</dt>
<dd>

</dd>
<dt>
<code>proof_of_possession: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u8&gt;</code>
</dt>
<dd>

</dd>
<dt>
<code>network_addresses: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u8&gt;</code>
</dt>
<dd>

</dd>
<dt>
<code>full_node_network_addresses: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u8&gt;</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a id="0x1_genesis_ValidatorConfigurationWithCommission"></a>

## Struct `ValidatorConfigurationWithCommission`



<pre><code><b>struct</b> <a href="genesis.md#0x1_genesis_ValidatorConfigurationWithCommission">ValidatorConfigurationWithCommission</a> <b>has</b> <b>copy</b>, drop
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>validator_config: <a href="genesis.md#0x1_genesis_ValidatorConfiguration">genesis::ValidatorConfiguration</a></code>
</dt>
<dd>

</dd>
<dt>
<code>commission_percentage: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>join_during_genesis: bool</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a id="@Constants_3"></a>

## Constants


<a id="0x1_genesis_DEFAULT_MAX_DELEGATORS_PER_VALIDATOR"></a>



<pre><code><b>const</b> <a href="genesis.md#0x1_genesis_DEFAULT_MAX_DELEGATORS_PER_VALIDATOR">DEFAULT_MAX_DELEGATORS_PER_VALIDATOR</a>: u64 = 1000;
</code></pre>



<a id="0x1_genesis_DEFAULT_OCTAS_PER_MILLION_POWER"></a>



<pre><code><b>const</b> <a href="genesis.md#0x1_genesis_DEFAULT_OCTAS_PER_MILLION_POWER">DEFAULT_OCTAS_PER_MILLION_POWER</a>: u64 = 1000000;
</code></pre>



<a id="0x1_genesis_EDUPLICATE_ACCOUNT"></a>



<pre><code><b>const</b> <a href="genesis.md#0x1_genesis_EDUPLICATE_ACCOUNT">EDUPLICATE_ACCOUNT</a>: u64 = 1;
</code></pre>



<a id="0x1_genesis_initialize"></a>

## Function `initialize`

Genesis step 1: Initialize aptos framework account and core modules on chain.

Called first by the Rust genesis builder. Sets up every protocol-level resource
that must exist before any transaction can be processed.

Key actions:
- Creates @aptos_framework as a framework-reserved account and hands its
SignerCapability to topo_governance (decentralized on-chain governance owns the framework).
- Reserves @0x2–@0xa under governance as well (future protocol expansion slots).
- Initializes staking_config with the genesis validator set parameters
(minimum/maximum stake, lockup duration, rewards rate, voting power increase limit).
- Initializes block module with epoch_interval_microsecs (controls epoch length).


<pre><code><b>fun</b> <a href="genesis.md#0x1_genesis_initialize">initialize</a>(<a href="gas_schedule.md#0x1_gas_schedule">gas_schedule</a>: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u8&gt;, <a href="chain_id.md#0x1_chain_id">chain_id</a>: u8, initial_version: u64, <a href="consensus_config.md#0x1_consensus_config">consensus_config</a>: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u8&gt;, <a href="execution_config.md#0x1_execution_config">execution_config</a>: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u8&gt;, epoch_interval_microsecs: u64, minimum_stake: u64, maximum_stake: u64, recurring_lockup_duration_secs: u64, allow_validator_set_change: bool, rewards_rate: u64, rewards_rate_denominator: u64, voting_power_increase_limit: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="genesis.md#0x1_genesis_initialize">initialize</a>(
    <a href="gas_schedule.md#0x1_gas_schedule">gas_schedule</a>: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u8&gt;,
    <a href="chain_id.md#0x1_chain_id">chain_id</a>: u8,
    initial_version: u64,
    <a href="consensus_config.md#0x1_consensus_config">consensus_config</a>: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u8&gt;,
    <a href="execution_config.md#0x1_execution_config">execution_config</a>: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u8&gt;,
    epoch_interval_microsecs: u64,
    minimum_stake: u64,
    maximum_stake: u64,
    recurring_lockup_duration_secs: u64,
    allow_validator_set_change: bool,
    rewards_rate: u64,
    rewards_rate_denominator: u64,
    voting_power_increase_limit: u64,
) {
    // Initialize the aptos framework <a href="account.md#0x1_account">account</a>. This is the <a href="account.md#0x1_account">account</a> <b>where</b> system resources and modules will be
    // deployed <b>to</b>. This will be entirely managed by on-chain governance and no entities have the key or privileges
    // <b>to</b> <b>use</b> this <a href="account.md#0x1_account">account</a>.
    <b>let</b> (aptos_framework_account, aptos_framework_signer_cap) = <a href="account.md#0x1_account_create_framework_reserved_account">account::create_framework_reserved_account</a>(@aptos_framework);
    // Initialize <a href="account.md#0x1_account">account</a> configs on aptos framework <a href="account.md#0x1_account">account</a>.
    <a href="account.md#0x1_account_initialize">account::initialize</a>(&aptos_framework_account);

    <a href="transaction_validation.md#0x1_transaction_validation_initialize">transaction_validation::initialize</a>(
        &aptos_framework_account,
        b"script_prologue",
        b"module_prologue",
        b"multi_agent_script_prologue",
        b"epilogue",
    );
    // Give the decentralized on-chain governance control over the core framework <a href="account.md#0x1_account">account</a>.
    <a href="topo_governance.md#0x1_topo_governance_store_signer_cap">topo_governance::store_signer_cap</a>(&aptos_framework_account, @aptos_framework, aptos_framework_signer_cap);

    // put reserved framework reserved accounts under aptos governance
    <b>let</b> framework_reserved_addresses = <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;[@0x2, @0x3, @0x4, @0x5, @0x6, @0x7, @0x8, @0x9, @0xa];
    <b>while</b> (!framework_reserved_addresses.is_empty()) {
        <b>let</b> <b>address</b> = framework_reserved_addresses.pop_back();
        <b>let</b> (_, framework_signer_cap) = <a href="account.md#0x1_account_create_framework_reserved_account">account::create_framework_reserved_account</a>(<b>address</b>);
        <a href="topo_governance.md#0x1_topo_governance_store_signer_cap">topo_governance::store_signer_cap</a>(&aptos_framework_account, <b>address</b>, framework_signer_cap);
    };

    <a href="consensus_config.md#0x1_consensus_config_initialize">consensus_config::initialize</a>(&aptos_framework_account, <a href="consensus_config.md#0x1_consensus_config">consensus_config</a>);
    <a href="execution_config.md#0x1_execution_config_set">execution_config::set</a>(&aptos_framework_account, <a href="execution_config.md#0x1_execution_config">execution_config</a>);
    <a href="version.md#0x1_version_initialize">version::initialize</a>(&aptos_framework_account, initial_version);
    <a href="stake.md#0x1_stake_initialize">stake::initialize</a>(&aptos_framework_account);
    <a href="stake.md#0x1_stake_initialize_pending_transaction_fee">stake::initialize_pending_transaction_fee</a>(&aptos_framework_account);
    <a href="timestamp.md#0x1_timestamp_set_time_has_started">timestamp::set_time_has_started</a>(&aptos_framework_account);
    <a href="staking_config.md#0x1_staking_config_initialize">staking_config::initialize</a>(
        &aptos_framework_account,
        minimum_stake,
        maximum_stake,
        recurring_lockup_duration_secs,
        allow_validator_set_change,
        rewards_rate,
        rewards_rate_denominator,
        voting_power_increase_limit,
    );
    <a href="storage_gas.md#0x1_storage_gas_initialize">storage_gas::initialize</a>(&aptos_framework_account);
    <a href="gas_schedule.md#0x1_gas_schedule_initialize">gas_schedule::initialize</a>(&aptos_framework_account, <a href="gas_schedule.md#0x1_gas_schedule">gas_schedule</a>);

    // Ensure we can create aggregators for supply, but not enable it for common <b>use</b> just yet.
    <a href="aggregator_factory.md#0x1_aggregator_factory_initialize_aggregator_factory">aggregator_factory::initialize_aggregator_factory</a>(&aptos_framework_account);

    <a href="chain_id.md#0x1_chain_id_initialize">chain_id::initialize</a>(&aptos_framework_account, <a href="chain_id.md#0x1_chain_id">chain_id</a>);
    <a href="reconfiguration.md#0x1_reconfiguration_initialize">reconfiguration::initialize</a>(&aptos_framework_account);
    <a href="block.md#0x1_block_initialize">block::initialize</a>(&aptos_framework_account, epoch_interval_microsecs);
    <a href="state_storage.md#0x1_state_storage_initialize">state_storage::initialize</a>(&aptos_framework_account);
    <a href="nonce_validation.md#0x1_nonce_validation_initialize">nonce_validation::initialize</a>(&aptos_framework_account);
}
</code></pre>



</details>

<a id="0x1_genesis_initialize_topo_coin"></a>

## Function `initialize_topo_coin`

Genesis step 2: Initialize Topo coin and distribute mint/burn capabilities.

Creates TopoCoin with both mint and burn capabilities, then distributes them:
- stake module gets MintCapability to mint staking rewards each epoch
- staking_registry gets a copy of MintCapability for its own reward distribution path
- transaction_fee module gets BurnCapability (to burn gas fees) and MintCapability (to mint refunds)

After <code>create_initialize_validators_with_commission</code> completes, the framework's
own mint cap is destroyed — no entity outside of the stored caps can mint TopoCoin.


<pre><code><b>fun</b> <a href="genesis.md#0x1_genesis_initialize_topo_coin">initialize_topo_coin</a>(aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="genesis.md#0x1_genesis_initialize_topo_coin">initialize_topo_coin</a>(aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>) {
    <b>let</b> (burn_cap, mint_cap) = <a href="topo_coin.md#0x1_topo_coin_initialize">topo_coin::initialize</a>(aptos_framework);

    <a href="coin.md#0x1_coin_create_coin_conversion_map">coin::create_coin_conversion_map</a>(aptos_framework);
    <a href="coin.md#0x1_coin_create_pairing">coin::create_pairing</a>&lt;TopoCoin&gt;(aptos_framework);

    // Give <a href="stake.md#0x1_stake">stake</a> <b>module</b> MintCapability&lt;TopoCoin&gt; so it can mint rewards.
    <a href="stake.md#0x1_stake_store_topo_coin_mint_cap">stake::store_topo_coin_mint_cap</a>(aptos_framework, mint_cap);
    // Cache a <b>copy</b> for <a href="staking_registry.md#0x1_staking_registry">staking_registry</a> so <a href="genesis.md#0x1_genesis">genesis</a> can initialize it later without Rust changes.
    <a href="staking_registry.md#0x1_staking_registry_store_topo_coin_mint_cap">staking_registry::store_topo_coin_mint_cap</a>(aptos_framework, mint_cap);
    // Give <a href="transaction_fee.md#0x1_transaction_fee">transaction_fee</a> <b>module</b> BurnCapability&lt;TopoCoin&gt; so it can burn gas.
    <a href="transaction_fee.md#0x1_transaction_fee_store_topo_coin_burn_cap">transaction_fee::store_topo_coin_burn_cap</a>(aptos_framework, burn_cap);
    // Give <a href="transaction_fee.md#0x1_transaction_fee">transaction_fee</a> <b>module</b> MintCapability&lt;TopoCoin&gt; so it can mint refunds.
    <a href="transaction_fee.md#0x1_transaction_fee_store_topo_coin_mint_cap">transaction_fee::store_topo_coin_mint_cap</a>(aptos_framework, mint_cap);
}
</code></pre>



</details>

<a id="0x1_genesis_initialize_core_resources_and_topo_coin"></a>

## Function `initialize_core_resources_and_topo_coin`

Only called for testnets and e2e tests.


<pre><code><b>public</b> <b>fun</b> <a href="genesis.md#0x1_genesis_initialize_core_resources_and_topo_coin">initialize_core_resources_and_topo_coin</a>(aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, core_resources_auth_key: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u8&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="genesis.md#0x1_genesis_initialize_core_resources_and_topo_coin">initialize_core_resources_and_topo_coin</a>(
    aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>,
    core_resources_auth_key: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u8&gt;,
) {
    <b>let</b> (burn_cap, mint_cap) = <a href="topo_coin.md#0x1_topo_coin_initialize">topo_coin::initialize</a>(aptos_framework);

    <a href="coin.md#0x1_coin_create_coin_conversion_map">coin::create_coin_conversion_map</a>(aptos_framework);
    <a href="coin.md#0x1_coin_create_pairing">coin::create_pairing</a>&lt;TopoCoin&gt;(aptos_framework);

    // Give <a href="stake.md#0x1_stake">stake</a> <b>module</b> MintCapability&lt;TopoCoin&gt; so it can mint rewards.
    <a href="stake.md#0x1_stake_store_topo_coin_mint_cap">stake::store_topo_coin_mint_cap</a>(aptos_framework, mint_cap);
    // Cache a <b>copy</b> for <a href="staking_registry.md#0x1_staking_registry">staking_registry</a> so test-only flows can opt into the new path.
    <a href="staking_registry.md#0x1_staking_registry_store_topo_coin_mint_cap">staking_registry::store_topo_coin_mint_cap</a>(aptos_framework, mint_cap);
    // Give <a href="transaction_fee.md#0x1_transaction_fee">transaction_fee</a> <b>module</b> BurnCapability&lt;TopoCoin&gt; so it can burn gas.
    <a href="transaction_fee.md#0x1_transaction_fee_store_topo_coin_burn_cap">transaction_fee::store_topo_coin_burn_cap</a>(aptos_framework, burn_cap);
    // Give <a href="transaction_fee.md#0x1_transaction_fee">transaction_fee</a> <b>module</b> MintCapability&lt;TopoCoin&gt; so it can mint refunds.
    <a href="transaction_fee.md#0x1_transaction_fee_store_topo_coin_mint_cap">transaction_fee::store_topo_coin_mint_cap</a>(aptos_framework, mint_cap);

    <b>let</b> core_resources = <a href="account.md#0x1_account_create_account">account::create_account</a>(@core_resources);
    <a href="account.md#0x1_account_rotate_authentication_key_internal">account::rotate_authentication_key_internal</a>(&core_resources, core_resources_auth_key);
    <a href="topo_account.md#0x1_topo_account_register_topo">topo_account::register_topo</a>(&core_resources); // registers TOPO store
    <a href="topo_coin.md#0x1_topo_coin_configure_accounts_for_test">topo_coin::configure_accounts_for_test</a>(aptos_framework, &core_resources, mint_cap);
}
</code></pre>



</details>

<a id="0x1_genesis_create_accounts"></a>

## Function `create_accounts`



<pre><code><b>fun</b> <a href="genesis.md#0x1_genesis_create_accounts">create_accounts</a>(aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, accounts: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<a href="genesis.md#0x1_genesis_AccountMap">genesis::AccountMap</a>&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="genesis.md#0x1_genesis_create_accounts">create_accounts</a>(aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, accounts: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<a href="genesis.md#0x1_genesis_AccountMap">AccountMap</a>&gt;) {
    <b>let</b> unique_accounts = <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector_empty">vector::empty</a>();
    accounts.for_each_ref(|account_map| {
        <b>let</b> account_map: &<a href="genesis.md#0x1_genesis_AccountMap">AccountMap</a> = account_map;
        <b>assert</b>!(
            !unique_accounts.contains(&account_map.account_address),
            <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_already_exists">error::already_exists</a>(<a href="genesis.md#0x1_genesis_EDUPLICATE_ACCOUNT">EDUPLICATE_ACCOUNT</a>),
        );
        unique_accounts.push_back(account_map.account_address);

        <a href="genesis.md#0x1_genesis_create_account">create_account</a>(
            aptos_framework,
            account_map.account_address,
            account_map.balance,
        );
    });
}
</code></pre>



</details>

<a id="0x1_genesis_create_account"></a>

## Function `create_account`

This creates an funds an account if it doesn't exist.
If it exists, it just returns the signer.


<pre><code><b>fun</b> <a href="genesis.md#0x1_genesis_create_account">create_account</a>(aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, account_address: <b>address</b>, balance: u64): <a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="genesis.md#0x1_genesis_create_account">create_account</a>(aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, account_address: <b>address</b>, balance: u64): <a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a> {
    <b>let</b> <a href="account.md#0x1_account">account</a> = <b>if</b> (<a href="account.md#0x1_account_exists_at">account::exists_at</a>(account_address)) {
        <a href="create_signer.md#0x1_create_signer">create_signer</a>(account_address)
    } <b>else</b> {
        <a href="account.md#0x1_account_create_account">account::create_account</a>(account_address)
    };

    <b>if</b> (<a href="coin.md#0x1_coin_balance">coin::balance</a>&lt;TopoCoin&gt;(account_address) == 0) {
        <a href="coin.md#0x1_coin_register">coin::register</a>&lt;TopoCoin&gt;(&<a href="account.md#0x1_account">account</a>);
        <a href="topo_coin.md#0x1_topo_coin_mint">topo_coin::mint</a>(aptos_framework, account_address, balance);
    };
    <a href="account.md#0x1_account">account</a>
}
</code></pre>



</details>

<a id="0x1_genesis_ensure_poc_staking_initialized"></a>

## Function `ensure_poc_staking_initialized`

Initialize poc_power_store and staking_registry if not already done.

Idempotent: safe to call multiple times (both sub-initializations guard themselves).

cooldown_secs is set to max(recurring_lockup_duration, governance_voting_duration).
This ensures a user who undelegates cannot re-delegate and vote again within the same
governance proposal window, preventing double-influence attacks.

poc_power_store is initialized with @aptos_framework as the operator, meaning only
the framework (via governance) can upload power updates initially. The operator can
be changed later via <code><a href="poc_power_store.md#0x1_poc_power_store_set_operator">poc_power_store::set_operator</a></code>.


<pre><code><b>fun</b> <a href="genesis.md#0x1_genesis_ensure_poc_staking_initialized">ensure_poc_staking_initialized</a>(aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="genesis.md#0x1_genesis_ensure_poc_staking_initialized">ensure_poc_staking_initialized</a>(aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>) {
    <b>if</b> (<a href="poc_power_store.md#0x1_poc_power_store_get_operator">poc_power_store::get_operator</a>() == @0x0) {
        <a href="poc_power_store.md#0x1_poc_power_store_initialize">poc_power_store::initialize</a>(aptos_framework, @aptos_framework);
    };

    <b>let</b> recurring_lockup_duration =
        <a href="staking_config.md#0x1_staking_config_get_recurring_lockup_duration">staking_config::get_recurring_lockup_duration</a>(&<a href="staking_config.md#0x1_staking_config_get">staking_config::get</a>());
    <b>let</b> governance_voting_duration =
        <b>if</b> (<a href="topo_governance.md#0x1_topo_governance_has_governance_config">topo_governance::has_governance_config</a>()) {
            <a href="topo_governance.md#0x1_topo_governance_get_voting_duration_secs">topo_governance::get_voting_duration_secs</a>()
        } <b>else</b> {
            0
        };
    // Use the longer of the two durations <b>to</b> prevent governance timing attacks
    <b>let</b> cooldown_secs =
        <b>if</b> (recurring_lockup_duration &gt; governance_voting_duration) {
            recurring_lockup_duration
        } <b>else</b> {
            governance_voting_duration
        };
    <a href="staking_registry.md#0x1_staking_registry_initialize">staking_registry::initialize</a>(
        aptos_framework,
        <a href="genesis.md#0x1_genesis_DEFAULT_OCTAS_PER_MILLION_POWER">DEFAULT_OCTAS_PER_MILLION_POWER</a>,
        <a href="genesis.md#0x1_genesis_DEFAULT_MAX_DELEGATORS_PER_VALIDATOR">DEFAULT_MAX_DELEGATORS_PER_VALIDATOR</a>,
        cooldown_secs,
    );
}
</code></pre>



</details>

<a id="0x1_genesis_create_initialize_validators_with_commission"></a>

## Function `create_initialize_validators_with_commission`



<pre><code><b>fun</b> <a href="genesis.md#0x1_genesis_create_initialize_validators_with_commission">create_initialize_validators_with_commission</a>(aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, validators: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<a href="genesis.md#0x1_genesis_ValidatorConfigurationWithCommission">genesis::ValidatorConfigurationWithCommission</a>&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="genesis.md#0x1_genesis_create_initialize_validators_with_commission">create_initialize_validators_with_commission</a>(
    aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>,
    validators: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<a href="genesis.md#0x1_genesis_ValidatorConfigurationWithCommission">ValidatorConfigurationWithCommission</a>&gt;,
) {
    <a href="genesis.md#0x1_genesis_ensure_poc_staking_initialized">ensure_poc_staking_initialized</a>(aptos_framework);
    validators.for_each_ref(|validator| {
        <b>let</b> validator: &<a href="genesis.md#0x1_genesis_ValidatorConfigurationWithCommission">ValidatorConfigurationWithCommission</a> = validator;
        <a href="genesis.md#0x1_genesis_create_initialize_validator">create_initialize_validator</a>(aptos_framework, validator);
    });

    // Destroy the aptos framework <a href="account.md#0x1_account">account</a>'s ability <b>to</b> mint coins now that we're done <b>with</b> setting up the initial
    // validators.
    <a href="topo_coin.md#0x1_topo_coin_destroy_mint_cap">topo_coin::destroy_mint_cap</a>(aptos_framework);

    <a href="stake.md#0x1_stake_on_new_epoch">stake::on_new_epoch</a>();
}
</code></pre>



</details>

<a id="0x1_genesis_create_initialize_validators"></a>

## Function `create_initialize_validators`

Sets up the initial validator set for the network.
The validator "owner" accounts, and their authentication
Addresses (and keys) are encoded in the <code>owners</code>
Each validator signs consensus messages with the private key corresponding to the Ed25519
public key in <code>consensus_pubkeys</code>.
Finally, each validator must specify the network address
(see types/src/network_address/mod.rs) for itself and its full nodes.

Network address fields are a vector per account, where each entry is a vector of addresses
encoded in a single BCS byte array.


<pre><code><b>fun</b> <a href="genesis.md#0x1_genesis_create_initialize_validators">create_initialize_validators</a>(aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, validators: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<a href="genesis.md#0x1_genesis_ValidatorConfiguration">genesis::ValidatorConfiguration</a>&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="genesis.md#0x1_genesis_create_initialize_validators">create_initialize_validators</a>(aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, validators: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<a href="genesis.md#0x1_genesis_ValidatorConfiguration">ValidatorConfiguration</a>&gt;) {
    <b>let</b> validators_with_commission = <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector_empty">vector::empty</a>();
    validators.for_each_reverse(|validator| {
        <b>let</b> validator_with_commission = <a href="genesis.md#0x1_genesis_ValidatorConfigurationWithCommission">ValidatorConfigurationWithCommission</a> {
            validator_config: validator,
            commission_percentage: 0,
            join_during_genesis: <b>true</b>,
        };
        validators_with_commission.push_back(validator_with_commission);
    });

    <a href="genesis.md#0x1_genesis_create_initialize_validators_with_commission">create_initialize_validators_with_commission</a>(aptos_framework, validators_with_commission);
}
</code></pre>



</details>

<a id="0x1_genesis_create_initialize_validator"></a>

## Function `create_initialize_validator`

Initialize a single genesis validator: create accounts, register in staking_registry,
seed POC power, deposit stake, delegate, and optionally join the validator set.

Full sequence for each genesis validator:
1. Create owner account funded with stake_amount TopoCoin
2. Create operator account (zero balance; operator earns via commission)
3. Initialize stake pool (StakePool + ValidatorConfig resources at owner address)
4. Register validator pool in staking_registry (if not already registered)
5. Seed genesis POC power: poc_power_store gets a period-0 committed snapshot
derived from stake_amount * genesis_stake_power_multiplier
6. Deposit stake_amount into staking_registry (owner's deposit balance)
7. Delegate owner's deposit to their own validator pool
8. If join_during_genesis: set consensus key + network addresses, then join validator set

Why seed POC power from stake?
At genesis there are no ContributionEvents yet, so the POC power store is empty.
Seeding from stake bootstraps the system so validators have non-zero effective power
from day one, allowing the first epoch to proceed normally.


<pre><code><b>fun</b> <a href="genesis.md#0x1_genesis_create_initialize_validator">create_initialize_validator</a>(aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, commission_config: &<a href="genesis.md#0x1_genesis_ValidatorConfigurationWithCommission">genesis::ValidatorConfigurationWithCommission</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="genesis.md#0x1_genesis_create_initialize_validator">create_initialize_validator</a>(
    aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>,
    commission_config: &<a href="genesis.md#0x1_genesis_ValidatorConfigurationWithCommission">ValidatorConfigurationWithCommission</a>,
) {
    <b>let</b> validator = &commission_config.validator_config;
    <b>let</b> commission_percentage = commission_config.commission_percentage;
    <b>let</b> genesis_power =
        <a href="staking_registry.md#0x1_staking_registry_calculate_genesis_power_from_stake">staking_registry::calculate_genesis_power_from_stake</a>(validator.stake_amount);

    <b>let</b> owner = &<a href="genesis.md#0x1_genesis_create_account">create_account</a>(aptos_framework, validator.owner_address, validator.stake_amount);
    <a href="genesis.md#0x1_genesis_create_account">create_account</a>(aptos_framework, validator.operator_address, 0);

    <a href="stake.md#0x1_stake_initialize_stake_owner">stake::initialize_stake_owner</a>(
        owner,
        0,
        validator.operator_address,
    );
    <b>let</b> pool_address = validator.owner_address;

    <b>if</b> (!<a href="staking_registry.md#0x1_staking_registry_validator_exists">staking_registry::validator_exists</a>(pool_address)) {
        <a href="staking_registry.md#0x1_staking_registry_register_validator_for_genesis">staking_registry::register_validator_for_genesis</a>(
            validator.owner_address,
            pool_address,
            commission_percentage * 100,
        );
    };
    <a href="poc_power_store.md#0x1_poc_power_store_set_genesis_committed_power">poc_power_store::set_genesis_committed_power</a>(
        aptos_framework,
        validator.owner_address,
        genesis_power,
    );
    <a href="staking_registry.md#0x1_staking_registry_deposit">staking_registry::deposit</a>(owner, validator.stake_amount);
    <a href="staking_registry.md#0x1_staking_registry_delegate">staking_registry::delegate</a>(owner, pool_address);

    <b>if</b> (commission_config.join_during_genesis) {
        <a href="genesis.md#0x1_genesis_initialize_validator">initialize_validator</a>(pool_address, validator);
    };
}
</code></pre>



</details>

<a id="0x1_genesis_initialize_validator"></a>

## Function `initialize_validator`



<pre><code><b>fun</b> <a href="genesis.md#0x1_genesis_initialize_validator">initialize_validator</a>(pool_address: <b>address</b>, validator: &<a href="genesis.md#0x1_genesis_ValidatorConfiguration">genesis::ValidatorConfiguration</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="genesis.md#0x1_genesis_initialize_validator">initialize_validator</a>(pool_address: <b>address</b>, validator: &<a href="genesis.md#0x1_genesis_ValidatorConfiguration">ValidatorConfiguration</a>) {
    <b>let</b> operator = &<a href="create_signer.md#0x1_create_signer">create_signer</a>(validator.operator_address);

    <a href="stake.md#0x1_stake_rotate_consensus_key">stake::rotate_consensus_key</a>(
        operator,
        pool_address,
        validator.consensus_pubkey,
        validator.proof_of_possession,
    );
    <a href="stake.md#0x1_stake_update_network_and_fullnode_addresses">stake::update_network_and_fullnode_addresses</a>(
        operator,
        pool_address,
        validator.network_addresses,
        validator.full_node_network_addresses,
    );
    <a href="stake.md#0x1_stake_join_validator_set_internal">stake::join_validator_set_internal</a>(operator, pool_address);
}
</code></pre>



</details>

<a id="0x1_genesis_set_genesis_end"></a>

## Function `set_genesis_end`

The last step of genesis.


<pre><code><b>fun</b> <a href="genesis.md#0x1_genesis_set_genesis_end">set_genesis_end</a>(aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="genesis.md#0x1_genesis_set_genesis_end">set_genesis_end</a>(aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>) {
    <a href="chain_status.md#0x1_chain_status_set_genesis_end">chain_status::set_genesis_end</a>(aptos_framework);
}
</code></pre>



</details>

<a id="@Specification_4"></a>

## Specification




<a id="high-level-req"></a>

### High-level Requirements

<table>
<tr>
<th>No.</th><th>Requirement</th><th>Criticality</th><th>Implementation</th><th>Enforcement</th>
</tr>

<tr>
<td>1</td>
<td>All the core resources and modules should be created during genesis and owned by the Aptos framework account.</td>
<td>Critical</td>
<td>Resources created during genesis initialization: GovernanceResponsbility, ConsensusConfig, ExecutionConfig, Version, SetVersionCapability, ValidatorSet, ValidatorPerformance, StakingConfig, StorageGasConfig, StorageGas, GasScheduleV2, AggregatorFactory, SupplyConfig, ChainId, Configuration, BlockResource, StateStorageUsage, CurrentTimeMicroseconds. If some of the resources were to be owned by a malicious account, it could lead to the compromise of the chain, as these are core resources. It should be formally verified by a post condition to ensure that all the critical resources are owned by the Aptos framework.</td>
<td>Formally verified via <a href="#high-level-req-1">initialize</a>.</td>
</tr>

<tr>
<td>2</td>
<td>Addresses ranging from 0x0 - 0xa should be reserved for the framework and part of aptos governance.</td>
<td>Critical</td>
<td>The function genesis::initialize calls account::create_framework_reserved_account for addresses 0x0, 0x2, 0x3, 0x4, ..., 0xa which creates an account and authentication_key for them. This should be formally verified by ensuring that at the beginning of the genesis::initialize function no Account resource exists for the reserved addresses, and at the end of the function, an Account resource exists.</td>
<td>Formally verified via <a href="#high-level-req-2">initialize</a>.</td>
</tr>

<tr>
<td>3</td>
<td>The Aptos coin should be initialized during genesis and only the Aptos framework account should own the mint and burn capabilities for the TOPO token.</td>
<td>Critical</td>
<td>Both mint and burn capabilities are wrapped inside the stake::TopoCoinCapabilities and transaction_fee::TopoCoinCapabilities resources which are stored under the aptos framework account.</td>
<td>Formally verified via <a href="#high-level-req-3">initialize_topo_coin</a>.</td>
</tr>

<tr>
<td>4</td>
<td>An initial set of validators should exist before the end of genesis.</td>
<td>Low</td>
<td>To ensure that there will be a set of validators available to validate the genesis block, the length of the ValidatorSet.active_validators vector should be > 0.</td>
<td>Formally verified via <a href="#high-level-req-4">set_genesis_end</a>.</td>
</tr>

<tr>
<td>5</td>
<td>The end of genesis should be marked on chain.</td>
<td>Low</td>
<td>The end of genesis is marked, on chain, via the chain_status::GenesisEndMarker resource. The ownership of this resource marks the operating state of the chain.</td>
<td>Formally verified via <a href="#high-level-req-5">set_genesis_end</a>.</td>
</tr>

</table>



<a id="module-level-spec"></a>

### Module-level Specification


<pre><code><b>pragma</b> verify = <b>true</b>;
</code></pre>



<a id="@Specification_4_initialize"></a>

### Function `initialize`


<pre><code><b>fun</b> <a href="genesis.md#0x1_genesis_initialize">initialize</a>(<a href="gas_schedule.md#0x1_gas_schedule">gas_schedule</a>: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u8&gt;, <a href="chain_id.md#0x1_chain_id">chain_id</a>: u8, initial_version: u64, <a href="consensus_config.md#0x1_consensus_config">consensus_config</a>: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u8&gt;, <a href="execution_config.md#0x1_execution_config">execution_config</a>: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u8&gt;, epoch_interval_microsecs: u64, minimum_stake: u64, maximum_stake: u64, recurring_lockup_duration_secs: u64, allow_validator_set_change: bool, rewards_rate: u64, rewards_rate_denominator: u64, voting_power_increase_limit: u64)
</code></pre>




<pre><code><b>pragma</b> aborts_if_is_partial;
<b>include</b> <a href="genesis.md#0x1_genesis_InitalizeRequires">InitalizeRequires</a>;
// This enforces <a id="high-level-req-2" href="#high-level-req">high-level requirement 2</a>:
<b>aborts_if</b> <b>exists</b>&lt;<a href="account.md#0x1_account_Account">account::Account</a>&gt;(@0x0);
<b>aborts_if</b> <b>exists</b>&lt;<a href="account.md#0x1_account_Account">account::Account</a>&gt;(@0x2);
<b>aborts_if</b> <b>exists</b>&lt;<a href="account.md#0x1_account_Account">account::Account</a>&gt;(@0x3);
<b>aborts_if</b> <b>exists</b>&lt;<a href="account.md#0x1_account_Account">account::Account</a>&gt;(@0x4);
<b>aborts_if</b> <b>exists</b>&lt;<a href="account.md#0x1_account_Account">account::Account</a>&gt;(@0x5);
<b>aborts_if</b> <b>exists</b>&lt;<a href="account.md#0x1_account_Account">account::Account</a>&gt;(@0x6);
<b>aborts_if</b> <b>exists</b>&lt;<a href="account.md#0x1_account_Account">account::Account</a>&gt;(@0x7);
<b>aborts_if</b> <b>exists</b>&lt;<a href="account.md#0x1_account_Account">account::Account</a>&gt;(@0x8);
<b>aborts_if</b> <b>exists</b>&lt;<a href="account.md#0x1_account_Account">account::Account</a>&gt;(@0x9);
<b>aborts_if</b> <b>exists</b>&lt;<a href="account.md#0x1_account_Account">account::Account</a>&gt;(@0xa);
<b>ensures</b> <b>exists</b>&lt;<a href="account.md#0x1_account_Account">account::Account</a>&gt;(@0x0);
<b>ensures</b> <b>exists</b>&lt;<a href="account.md#0x1_account_Account">account::Account</a>&gt;(@0x2);
<b>ensures</b> <b>exists</b>&lt;<a href="account.md#0x1_account_Account">account::Account</a>&gt;(@0x3);
<b>ensures</b> <b>exists</b>&lt;<a href="account.md#0x1_account_Account">account::Account</a>&gt;(@0x4);
<b>ensures</b> <b>exists</b>&lt;<a href="account.md#0x1_account_Account">account::Account</a>&gt;(@0x5);
<b>ensures</b> <b>exists</b>&lt;<a href="account.md#0x1_account_Account">account::Account</a>&gt;(@0x6);
<b>ensures</b> <b>exists</b>&lt;<a href="account.md#0x1_account_Account">account::Account</a>&gt;(@0x7);
<b>ensures</b> <b>exists</b>&lt;<a href="account.md#0x1_account_Account">account::Account</a>&gt;(@0x8);
<b>ensures</b> <b>exists</b>&lt;<a href="account.md#0x1_account_Account">account::Account</a>&gt;(@0x9);
<b>ensures</b> <b>exists</b>&lt;<a href="account.md#0x1_account_Account">account::Account</a>&gt;(@0xa);
// This enforces <a id="high-level-req-1" href="#high-level-req">high-level requirement 1</a>:
<b>ensures</b> <b>exists</b>&lt;<a href="topo_governance.md#0x1_topo_governance_GovernanceResponsbility">topo_governance::GovernanceResponsbility</a>&gt;(@aptos_framework);
<b>ensures</b> <b>exists</b>&lt;<a href="consensus_config.md#0x1_consensus_config_ConsensusConfig">consensus_config::ConsensusConfig</a>&gt;(@aptos_framework);
<b>ensures</b> <b>exists</b>&lt;<a href="execution_config.md#0x1_execution_config_ExecutionConfig">execution_config::ExecutionConfig</a>&gt;(@aptos_framework);
<b>ensures</b> <b>exists</b>&lt;<a href="version.md#0x1_version_Version">version::Version</a>&gt;(@aptos_framework);
<b>ensures</b> <b>exists</b>&lt;<a href="stake.md#0x1_stake_ValidatorSet">stake::ValidatorSet</a>&gt;(@aptos_framework);
<b>ensures</b> <b>exists</b>&lt;<a href="stake.md#0x1_stake_ValidatorPerformance">stake::ValidatorPerformance</a>&gt;(@aptos_framework);
<b>ensures</b> <b>exists</b>&lt;<a href="storage_gas.md#0x1_storage_gas_StorageGasConfig">storage_gas::StorageGasConfig</a>&gt;(@aptos_framework);
<b>ensures</b> <b>exists</b>&lt;<a href="storage_gas.md#0x1_storage_gas_StorageGas">storage_gas::StorageGas</a>&gt;(@aptos_framework);
<b>ensures</b> <b>exists</b>&lt;<a href="gas_schedule.md#0x1_gas_schedule_GasScheduleV2">gas_schedule::GasScheduleV2</a>&gt;(@aptos_framework);
<b>ensures</b> <b>exists</b>&lt;<a href="aggregator_factory.md#0x1_aggregator_factory_AggregatorFactory">aggregator_factory::AggregatorFactory</a>&gt;(@aptos_framework);
<b>ensures</b> <b>exists</b>&lt;<a href="coin.md#0x1_coin_SupplyConfig">coin::SupplyConfig</a>&gt;(@aptos_framework);
<b>ensures</b> <b>exists</b>&lt;<a href="chain_id.md#0x1_chain_id_ChainId">chain_id::ChainId</a>&gt;(@aptos_framework);
<b>ensures</b> <b>exists</b>&lt;<a href="reconfiguration.md#0x1_reconfiguration_Configuration">reconfiguration::Configuration</a>&gt;(@aptos_framework);
<b>ensures</b> <b>exists</b>&lt;<a href="block.md#0x1_block_BlockResource">block::BlockResource</a>&gt;(@aptos_framework);
<b>ensures</b> <b>exists</b>&lt;<a href="state_storage.md#0x1_state_storage_StateStorageUsage">state_storage::StateStorageUsage</a>&gt;(@aptos_framework);
<b>ensures</b> <b>exists</b>&lt;<a href="timestamp.md#0x1_timestamp_CurrentTimeMicroseconds">timestamp::CurrentTimeMicroseconds</a>&gt;(@aptos_framework);
<b>ensures</b> <b>exists</b>&lt;<a href="account.md#0x1_account_Account">account::Account</a>&gt;(@aptos_framework);
<b>ensures</b> <b>exists</b>&lt;<a href="version.md#0x1_version_SetVersionCapability">version::SetVersionCapability</a>&gt;(@aptos_framework);
<b>ensures</b> <b>exists</b>&lt;<a href="staking_config.md#0x1_staking_config_StakingConfig">staking_config::StakingConfig</a>&gt;(@aptos_framework);
</code></pre>



<a id="@Specification_4_initialize_topo_coin"></a>

### Function `initialize_topo_coin`


<pre><code><b>fun</b> <a href="genesis.md#0x1_genesis_initialize_topo_coin">initialize_topo_coin</a>(aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>)
</code></pre>




<pre><code>// This enforces <a id="high-level-req-3" href="#high-level-req">high-level requirement 3</a>:
<b>requires</b> !<b>exists</b>&lt;<a href="stake.md#0x1_stake_TopoCoinCapabilities">stake::TopoCoinCapabilities</a>&gt;(@aptos_framework);
<b>ensures</b> <b>exists</b>&lt;<a href="stake.md#0x1_stake_TopoCoinCapabilities">stake::TopoCoinCapabilities</a>&gt;(@aptos_framework);
<b>requires</b> <b>exists</b>&lt;<a href="transaction_fee.md#0x1_transaction_fee_TopoCoinCapabilities">transaction_fee::TopoCoinCapabilities</a>&gt;(@aptos_framework);
<b>ensures</b> <b>exists</b>&lt;<a href="transaction_fee.md#0x1_transaction_fee_TopoCoinCapabilities">transaction_fee::TopoCoinCapabilities</a>&gt;(@aptos_framework);
</code></pre>



<a id="@Specification_4_create_initialize_validators_with_commission"></a>

### Function `create_initialize_validators_with_commission`


<pre><code><b>fun</b> <a href="genesis.md#0x1_genesis_create_initialize_validators_with_commission">create_initialize_validators_with_commission</a>(aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, validators: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<a href="genesis.md#0x1_genesis_ValidatorConfigurationWithCommission">genesis::ValidatorConfigurationWithCommission</a>&gt;)
</code></pre>




<pre><code><b>pragma</b> verify_duration_estimate = 120;
<b>include</b> <a href="stake.md#0x1_stake_ResourceRequirement">stake::ResourceRequirement</a>;
<b>include</b> <a href="stake.md#0x1_stake_GetReconfigStartTimeRequirement">stake::GetReconfigStartTimeRequirement</a>;
<b>include</b> <a href="genesis.md#0x1_genesis_CompareTimeRequires">CompareTimeRequires</a>;
<b>include</b> <a href="topo_coin.md#0x1_topo_coin_ExistsTopoCoin">topo_coin::ExistsTopoCoin</a>;
</code></pre>



<a id="@Specification_4_create_initialize_validators"></a>

### Function `create_initialize_validators`


<pre><code><b>fun</b> <a href="genesis.md#0x1_genesis_create_initialize_validators">create_initialize_validators</a>(aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, validators: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<a href="genesis.md#0x1_genesis_ValidatorConfiguration">genesis::ValidatorConfiguration</a>&gt;)
</code></pre>




<pre><code><b>pragma</b> verify_duration_estimate = 120;
<b>include</b> <a href="stake.md#0x1_stake_ResourceRequirement">stake::ResourceRequirement</a>;
<b>include</b> <a href="stake.md#0x1_stake_GetReconfigStartTimeRequirement">stake::GetReconfigStartTimeRequirement</a>;
<b>include</b> <a href="genesis.md#0x1_genesis_CompareTimeRequires">CompareTimeRequires</a>;
<b>include</b> <a href="topo_coin.md#0x1_topo_coin_ExistsTopoCoin">topo_coin::ExistsTopoCoin</a>;
</code></pre>



<a id="@Specification_4_create_initialize_validator"></a>

### Function `create_initialize_validator`


<pre><code><b>fun</b> <a href="genesis.md#0x1_genesis_create_initialize_validator">create_initialize_validator</a>(aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, commission_config: &<a href="genesis.md#0x1_genesis_ValidatorConfigurationWithCommission">genesis::ValidatorConfigurationWithCommission</a>)
</code></pre>




<pre><code><b>pragma</b> verify_duration_estimate = 120;
<b>include</b> <a href="stake.md#0x1_stake_ResourceRequirement">stake::ResourceRequirement</a>;
</code></pre>



<a id="@Specification_4_initialize_validator"></a>

### Function `initialize_validator`


<pre><code><b>fun</b> <a href="genesis.md#0x1_genesis_initialize_validator">initialize_validator</a>(pool_address: <b>address</b>, validator: &<a href="genesis.md#0x1_genesis_ValidatorConfiguration">genesis::ValidatorConfiguration</a>)
</code></pre>




<pre><code><b>pragma</b> verify_duration_estimate = 120;
</code></pre>



<a id="@Specification_4_set_genesis_end"></a>

### Function `set_genesis_end`


<pre><code><b>fun</b> <a href="genesis.md#0x1_genesis_set_genesis_end">set_genesis_end</a>(aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>)
</code></pre>




<pre><code><b>pragma</b> delegate_invariants_to_caller;
// This enforces <a id="high-level-req-4" href="#high-level-req">high-level requirement 4</a>:
<b>requires</b> len(<b>global</b>&lt;<a href="stake.md#0x1_stake_ValidatorSet">stake::ValidatorSet</a>&gt;(@aptos_framework).active_validators) &gt;= 1;
// This enforces <a id="high-level-req-5" href="#high-level-req">high-level requirement 5</a>:
<b>let</b> addr = std::signer::address_of(aptos_framework);
<b>aborts_if</b> addr != @aptos_framework;
<b>aborts_if</b> <b>exists</b>&lt;<a href="chain_status.md#0x1_chain_status_GenesisEndMarker">chain_status::GenesisEndMarker</a>&gt;(@aptos_framework);
<b>ensures</b> <b>global</b>&lt;<a href="chain_status.md#0x1_chain_status_GenesisEndMarker">chain_status::GenesisEndMarker</a>&gt;(@aptos_framework) == <a href="chain_status.md#0x1_chain_status_GenesisEndMarker">chain_status::GenesisEndMarker</a> {};
</code></pre>




<a id="0x1_genesis_InitalizeRequires"></a>


<pre><code><b>schema</b> <a href="genesis.md#0x1_genesis_InitalizeRequires">InitalizeRequires</a> {
    <a href="execution_config.md#0x1_execution_config">execution_config</a>: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u8&gt;;
    <b>requires</b> !<b>exists</b>&lt;<a href="account.md#0x1_account_Account">account::Account</a>&gt;(@aptos_framework);
    <b>requires</b> <a href="chain_status.md#0x1_chain_status_is_operating">chain_status::is_operating</a>();
    <b>requires</b> len(<a href="execution_config.md#0x1_execution_config">execution_config</a>) &gt; 0;
    <b>requires</b> <b>exists</b>&lt;<a href="staking_config.md#0x1_staking_config_StakingRewardsConfig">staking_config::StakingRewardsConfig</a>&gt;(@aptos_framework);
    <b>requires</b> <b>exists</b>&lt;<a href="coin.md#0x1_coin_CoinInfo">coin::CoinInfo</a>&lt;TopoCoin&gt;&gt;(@aptos_framework);
    <b>include</b> <a href="genesis.md#0x1_genesis_CompareTimeRequires">CompareTimeRequires</a>;
}
</code></pre>




<a id="0x1_genesis_CompareTimeRequires"></a>


<pre><code><b>schema</b> <a href="genesis.md#0x1_genesis_CompareTimeRequires">CompareTimeRequires</a> {
    <b>let</b> staking_rewards_config = <b>global</b>&lt;<a href="staking_config.md#0x1_staking_config_StakingRewardsConfig">staking_config::StakingRewardsConfig</a>&gt;(@aptos_framework);
    <b>requires</b> staking_rewards_config.last_rewards_rate_period_start_in_secs &lt;= <a href="timestamp.md#0x1_timestamp_spec_now_seconds">timestamp::spec_now_seconds</a>();
}
</code></pre>


[move-book]: https://aptos.dev/move/book/SUMMARY
