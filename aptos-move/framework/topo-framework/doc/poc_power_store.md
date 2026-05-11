
<a id="0x1_poc_power_store"></a>

# Module `0x1::poc_power_store`

POC Power Store Contract — Maintains the most recent two power versions per user, selecting the effective version based on target period.

Design Boundaries:
- Off-chain service is responsible for computing final power results
- On-chain storage only keeps the most recent two versions per user, no longer maintaining a global pending cache
- Within the current power period, reads always select the latest version where <code>effective_period &lt;= current_period</code>
- Mid-period uploads only write to <code>effective_period = current_period + 1</code> (future version), not affecting current-period stake/governance/reward reads
- Historical users without updates don't need full rewrite at epoch boundaries; reads apply lazy decay based on version and retention

Architecture Overview:
This module serves as the on-chain power registry for the Proof of Contribution (POC) system.
Power values represent a user's contribution-based voting weight, computed off-chain from ContributionEvents
and uploaded periodically by a trusted operator or framework governance. The two-version sliding window design ensures:
1. Current epoch reads remain stable even when next-period data is being staged
2. Smooth transitions at period boundaries without requiring atomic global updates
3. Automatic decay for inactive users via retention_bps_per_period

Key Concepts:
- Power Period: A configurable number of on-chain epochs (default 60). Power values are updated once per period.
Period advancement is driven by an epoch countdown, so changing the configured period length
only affects future periods and never reinterprets historical epochs.
- Effective Period: The period from which a power version becomes active. Versions with effective_period > current_period are "staged" for future use.
- Retention: A decay factor (in basis points) applied per period to power values that haven't been refreshed.
Default 9950 bps (99.5%) means power decays by 0.5% per period if not updated.

Lifecycle Example:
1. Genesis: operator uploads initial power for validators at period 0
2. Period 0 (epochs 1-60): reads return period-0 power
3. During period 0: operator stages period-1 power (effective_period=1)
4. Epoch 61 starts → period transitions to 1 → reads now return period-1 power
5. If a user's power wasn't updated for period 1, their period-0 value is read with 1-period decay applied


-  [Resource `PowerStore`](#0x1_poc_power_store_PowerStore)
-  [Resource `PeriodClock`](#0x1_poc_power_store_PeriodClock)
-  [Struct `PowerVersion`](#0x1_poc_power_store_PowerVersion)
-  [Struct `UserPowerInfo`](#0x1_poc_power_store_UserPowerInfo)
-  [Struct `OperatorChangedEvent`](#0x1_poc_power_store_OperatorChangedEvent)
-  [Struct `PowerUpdateStagedEvent`](#0x1_poc_power_store_PowerUpdateStagedEvent)
-  [Struct `PowerPeriodCommittedEvent`](#0x1_poc_power_store_PowerPeriodCommittedEvent)
-  [Constants](#@Constants_0)
-  [Function `initialize`](#0x1_poc_power_store_initialize)
-  [Function `initialize_with_power_period`](#0x1_poc_power_store_initialize_with_power_period)
-  [Function `initialize_power_store`](#0x1_poc_power_store_initialize_power_store)
-  [Function `initialize_power_store_with_period`](#0x1_poc_power_store_initialize_power_store_with_period)
-  [Function `set_retention_bps_per_period`](#0x1_poc_power_store_set_retention_bps_per_period)
-  [Function `set_power_period_in_epochs`](#0x1_poc_power_store_set_power_period_in_epochs)
-  [Function `set_operator`](#0x1_poc_power_store_set_operator)
-  [Function `stage_batch_update`](#0x1_poc_power_store_stage_batch_update)
-  [Function `set_genesis_committed_power`](#0x1_poc_power_store_set_genesis_committed_power)
-  [Function `commit_next_period_if_boundary`](#0x1_poc_power_store_commit_next_period_if_boundary)
-  [Function `get_user_power`](#0x1_poc_power_store_get_user_power)
-  [Function `get_user_committed_power`](#0x1_poc_power_store_get_user_committed_power)
-  [Function `get_user_committed_power_for_next_epoch`](#0x1_poc_power_store_get_user_committed_power_for_next_epoch)
-  [Function `get_user_power_for_period`](#0x1_poc_power_store_get_user_power_for_period)
-  [Function `get_user_committed_powers`](#0x1_poc_power_store_get_user_committed_powers)
-  [Function `get_user_powers_for_period`](#0x1_poc_power_store_get_user_powers_for_period)
-  [Function `get_user_power_version`](#0x1_poc_power_store_get_user_power_version)
-  [Function `get_user_power_versions_by_addresses`](#0x1_poc_power_store_get_user_power_versions_by_addresses)
-  [Function `get_user_decayed_power`](#0x1_poc_power_store_get_user_decayed_power)
-  [Function `get_operator`](#0x1_poc_power_store_get_operator)
-  [Function `get_current_period`](#0x1_poc_power_store_get_current_period)
-  [Function `get_power_period_in_epochs`](#0x1_poc_power_store_get_power_period_in_epochs)
-  [Function `get_retention_bps_per_period`](#0x1_poc_power_store_get_retention_bps_per_period)
-  [Function `initialize_power_store_internal`](#0x1_poc_power_store_initialize_power_store_internal)
-  [Function `assert_store_exists`](#0x1_poc_power_store_assert_store_exists)
-  [Function `assert_clock_exists`](#0x1_poc_power_store_assert_clock_exists)
-  [Function `assert_power_update_authority`](#0x1_poc_power_store_assert_power_update_authority)
-  [Function `assert_valid_retention_bps`](#0x1_poc_power_store_assert_valid_retention_bps)
-  [Function `assert_valid_power_period`](#0x1_poc_power_store_assert_valid_power_period)
-  [Function `upsert_power_version`](#0x1_poc_power_store_upsert_power_version)
-  [Function `normalize_user_power_info`](#0x1_poc_power_store_normalize_user_power_info)
-  [Function `get_user_power_for_period_internal`](#0x1_poc_power_store_get_user_power_for_period_internal)
-  [Function `build_user_power_version`](#0x1_poc_power_store_build_user_power_version)
-  [Function `select_effective_version`](#0x1_poc_power_store_select_effective_version)
-  [Function `has_power_version`](#0x1_poc_power_store_has_power_version)
-  [Function `apply_retention`](#0x1_poc_power_store_apply_retention)
-  [Function `empty_power_version`](#0x1_poc_power_store_empty_power_version)


<pre><code><b>use</b> <a href="event.md#0x1_event">0x1::event</a>;
<b>use</b> <a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">0x1::signer</a>;
<b>use</b> <a href="system_addresses.md#0x1_system_addresses">0x1::system_addresses</a>;
<b>use</b> <a href="../../aptos-stdlib/doc/table.md#0x1_table">0x1::table</a>;
</code></pre>



<a id="0x1_poc_power_store_PowerStore"></a>

## Resource `PowerStore`

Global power store, stored under @topo_framework.

Invariants:
- Only <code>operator</code> or @topo_framework may call <code>stage_batch_update</code>
- Each user has at most two PowerVersion slots (older + newer)


<pre><code><b>struct</b> <a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a> <b>has</b> key
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>operator: <b>address</b></code>
</dt>
<dd>
 The single trusted address allowed to upload power updates
</dd>
<dt>
<code>users: <a href="../../aptos-stdlib/doc/table.md#0x1_table_Table">table::Table</a>&lt;<b>address</b>, <a href="poc_power_store.md#0x1_poc_power_store_UserPowerInfo">poc_power_store::UserPowerInfo</a>&gt;</code>
</dt>
<dd>
 Per-user storage: address → two-slot power version window
</dd>
<dt>
<code>retention_bps_per_period: u64</code>
</dt>
<dd>
 Decay factor applied per period to stale power values (in basis points, e.g. 9950 = 99.5%)
</dd>
</dl>


</details>

<a id="0x1_poc_power_store_PeriodClock"></a>

## Resource `PeriodClock`

Global power-period clock, stored under @topo_framework.

Invariants:
- <code>current_period</code> only advances forward, never backward
- <code>last_epoch</code> is incremented once per on-chain epoch via <code>commit_next_period_if_boundary</code>
- <code>current_period</code> advances by at most one per committed epoch


<pre><code><b>struct</b> <a href="poc_power_store.md#0x1_poc_power_store_PeriodClock">PeriodClock</a> <b>has</b> key
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>power_period_in_epochs: u64</code>
</dt>
<dd>
 Number of on-chain epochs used when starting the next power period
</dd>
<dt>
<code>last_epoch: u64</code>
</dt>
<dd>
 Monotonically increasing count of epochs that have been committed
</dd>
<dt>
<code>current_period: u64</code>
</dt>
<dd>
 The current power period index
</dd>
<dt>
<code>epochs_until_next_power_period: u64</code>
</dt>
<dd>
 Number of epoch transitions remaining before the next power period starts
</dd>
</dl>


</details>

<a id="0x1_poc_power_store_PowerVersion"></a>

## Struct `PowerVersion`

A single versioned power snapshot for a user.
<code>effective_period</code> is the first period in which this value becomes the active reading.


<pre><code><b>struct</b> <a href="poc_power_store.md#0x1_poc_power_store_PowerVersion">PowerVersion</a> <b>has</b> <b>copy</b>, drop, store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>effective_period: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>power: u64</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a id="0x1_poc_power_store_UserPowerInfo"></a>

## Struct `UserPowerInfo`

Two-slot sliding window of power versions per user.

Invariant: older.effective_period <= newer.effective_period (enforced by normalize_user_power_info).

Why two slots?
- When the operator stages period P+1 data while the chain is still in period P,
we must keep the period-P value so current reads remain stable.
- At the period boundary, current_period advances to P+1 and reads switch to the newer slot.
- The older slot is then free to be overwritten by the next staging call.


<pre><code><b>struct</b> <a href="poc_power_store.md#0x1_poc_power_store_UserPowerInfo">UserPowerInfo</a> <b>has</b> <b>copy</b>, drop, store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>older: <a href="poc_power_store.md#0x1_poc_power_store_PowerVersion">poc_power_store::PowerVersion</a></code>
</dt>
<dd>

</dd>
<dt>
<code>newer: <a href="poc_power_store.md#0x1_poc_power_store_PowerVersion">poc_power_store::PowerVersion</a></code>
</dt>
<dd>

</dd>
</dl>


</details>

<a id="0x1_poc_power_store_OperatorChangedEvent"></a>

## Struct `OperatorChangedEvent`

Emitted when the operator address is changed via <code>set_operator</code>.


<pre><code>#[<a href="event.md#0x1_event">event</a>]
<b>struct</b> <a href="poc_power_store.md#0x1_poc_power_store_OperatorChangedEvent">OperatorChangedEvent</a> <b>has</b> drop, store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>old_operator: <b>address</b></code>
</dt>
<dd>

</dd>
<dt>
<code>new_operator: <b>address</b></code>
</dt>
<dd>

</dd>
</dl>


</details>

<a id="0x1_poc_power_store_PowerUpdateStagedEvent"></a>

## Struct `PowerUpdateStagedEvent`

Emitted for each user entry written by <code>stage_batch_update</code>.
Allows off-chain indexers to track exactly what was staged and when.


<pre><code>#[<a href="event.md#0x1_event">event</a>]
<b>struct</b> <a href="poc_power_store.md#0x1_poc_power_store_PowerUpdateStagedEvent">PowerUpdateStagedEvent</a> <b>has</b> drop, store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>target_period: u64</code>
</dt>
<dd>
 The period the caller requested to stage for (must equal current_period + 1)
</dd>
<dt>
<code>effective_period: u64</code>
</dt>
<dd>
 The period at which this power value becomes effective (equals target_period)
</dd>
<dt>
<code>user: <b>address</b></code>
</dt>
<dd>

</dd>
<dt>
<code>power: u64</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a id="0x1_poc_power_store_PowerPeriodCommittedEvent"></a>

## Struct `PowerPeriodCommittedEvent`

Emitted when <code>commit_next_period_if_boundary</code> advances current_period.
Off-chain services use this to know when a new period has started on-chain.


<pre><code>#[<a href="event.md#0x1_event">event</a>]
<b>struct</b> <a href="poc_power_store.md#0x1_poc_power_store_PowerPeriodCommittedEvent">PowerPeriodCommittedEvent</a> <b>has</b> drop, store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>previous_period: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>current_period: u64</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a id="@Constants_0"></a>

## Constants


<a id="0x1_poc_power_store_BPS_DENOMINATOR"></a>



<pre><code><b>const</b> <a href="poc_power_store.md#0x1_poc_power_store_BPS_DENOMINATOR">BPS_DENOMINATOR</a>: u64 = 10000;
</code></pre>



<a id="0x1_poc_power_store_DEFAULT_POWER_PERIOD_IN_EPOCHS"></a>



<pre><code><b>const</b> <a href="poc_power_store.md#0x1_poc_power_store_DEFAULT_POWER_PERIOD_IN_EPOCHS">DEFAULT_POWER_PERIOD_IN_EPOCHS</a>: u64 = 60;
</code></pre>



<a id="0x1_poc_power_store_DEFAULT_RETENTION_BPS_PER_PERIOD"></a>



<pre><code><b>const</b> <a href="poc_power_store.md#0x1_poc_power_store_DEFAULT_RETENTION_BPS_PER_PERIOD">DEFAULT_RETENTION_BPS_PER_PERIOD</a>: u64 = 9995;
</code></pre>



<a id="0x1_poc_power_store_EGENESIS_COMMIT_ONLY"></a>

Genesis committed snapshots can only be written during the initialization phase (last_epoch == 0 && current_period == 0)


<pre><code><b>const</b> <a href="poc_power_store.md#0x1_poc_power_store_EGENESIS_COMMIT_ONLY">EGENESIS_COMMIT_ONLY</a>: u64 = 7;
</code></pre>



<a id="0x1_poc_power_store_EINVALID_BATCH_LENGTH"></a>

<code>users</code> and <code>powers</code> vectors have different lengths in a batch update


<pre><code><b>const</b> <a href="poc_power_store.md#0x1_poc_power_store_EINVALID_BATCH_LENGTH">EINVALID_BATCH_LENGTH</a>: u64 = 3;
</code></pre>



<a id="0x1_poc_power_store_EINVALID_POWER_PERIOD"></a>

power_period_in_epochs must be > 0


<pre><code><b>const</b> <a href="poc_power_store.md#0x1_poc_power_store_EINVALID_POWER_PERIOD">EINVALID_POWER_PERIOD</a>: u64 = 5;
</code></pre>



<a id="0x1_poc_power_store_EINVALID_RETENTION_BPS"></a>

retention_bps_per_period is out of valid range (must be > 0 and <= 10000)


<pre><code><b>const</b> <a href="poc_power_store.md#0x1_poc_power_store_EINVALID_RETENTION_BPS">EINVALID_RETENTION_BPS</a>: u64 = 4;
</code></pre>



<a id="0x1_poc_power_store_EINVALID_TARGET_PERIOD"></a>

target_period must equal current_period + 1; staging further ahead is not allowed


<pre><code><b>const</b> <a href="poc_power_store.md#0x1_poc_power_store_EINVALID_TARGET_PERIOD">EINVALID_TARGET_PERIOD</a>: u64 = 6;
</code></pre>



<a id="0x1_poc_power_store_ENOT_OPERATOR"></a>

Caller is not the designated operator


<pre><code><b>const</b> <a href="poc_power_store.md#0x1_poc_power_store_ENOT_OPERATOR">ENOT_OPERATOR</a>: u64 = 2;
</code></pre>



<a id="0x1_poc_power_store_ESTORE_NOT_INITIALIZED"></a>

PowerStore resource has not been initialized yet


<pre><code><b>const</b> <a href="poc_power_store.md#0x1_poc_power_store_ESTORE_NOT_INITIALIZED">ESTORE_NOT_INITIALIZED</a>: u64 = 1;
</code></pre>



<a id="0x1_poc_power_store_initialize"></a>

## Function `initialize`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_initialize">initialize</a>(topo_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, operator: <b>address</b>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>friend</b> <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_initialize">initialize</a>(topo_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, operator: <b>address</b>) {
    <a href="poc_power_store.md#0x1_poc_power_store_initialize_power_store_internal">initialize_power_store_internal</a>(
        topo_framework,
        operator,
        <a href="poc_power_store.md#0x1_poc_power_store_DEFAULT_RETENTION_BPS_PER_PERIOD">DEFAULT_RETENTION_BPS_PER_PERIOD</a>,
        <a href="poc_power_store.md#0x1_poc_power_store_DEFAULT_POWER_PERIOD_IN_EPOCHS">DEFAULT_POWER_PERIOD_IN_EPOCHS</a>,
    );
}
</code></pre>



</details>

<a id="0x1_poc_power_store_initialize_with_power_period"></a>

## Function `initialize_with_power_period`



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_initialize_with_power_period">initialize_with_power_period</a>(topo_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, operator: <b>address</b>, power_period_in_epochs: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>friend</b> <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_initialize_with_power_period">initialize_with_power_period</a>(
    topo_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>,
    operator: <b>address</b>,
    power_period_in_epochs: u64,
) {
    <a href="poc_power_store.md#0x1_poc_power_store_initialize_power_store_internal">initialize_power_store_internal</a>(
        topo_framework,
        operator,
        <a href="poc_power_store.md#0x1_poc_power_store_DEFAULT_RETENTION_BPS_PER_PERIOD">DEFAULT_RETENTION_BPS_PER_PERIOD</a>,
        power_period_in_epochs,
    );
}
</code></pre>



</details>

<a id="0x1_poc_power_store_initialize_power_store"></a>

## Function `initialize_power_store`



<pre><code><b>public</b> entry <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_initialize_power_store">initialize_power_store</a>(topo_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, operator: <b>address</b>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> entry <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_initialize_power_store">initialize_power_store</a>(
    topo_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>,
    operator: <b>address</b>,
) {
    <a href="poc_power_store.md#0x1_poc_power_store_initialize_power_store_internal">initialize_power_store_internal</a>(
        topo_framework,
        operator,
        <a href="poc_power_store.md#0x1_poc_power_store_DEFAULT_RETENTION_BPS_PER_PERIOD">DEFAULT_RETENTION_BPS_PER_PERIOD</a>,
        <a href="poc_power_store.md#0x1_poc_power_store_DEFAULT_POWER_PERIOD_IN_EPOCHS">DEFAULT_POWER_PERIOD_IN_EPOCHS</a>,
    );
}
</code></pre>



</details>

<a id="0x1_poc_power_store_initialize_power_store_with_period"></a>

## Function `initialize_power_store_with_period`



<pre><code><b>public</b> entry <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_initialize_power_store_with_period">initialize_power_store_with_period</a>(topo_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, operator: <b>address</b>, power_period_in_epochs: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> entry <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_initialize_power_store_with_period">initialize_power_store_with_period</a>(
    topo_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>,
    operator: <b>address</b>,
    power_period_in_epochs: u64,
) {
    <a href="poc_power_store.md#0x1_poc_power_store_initialize_power_store_internal">initialize_power_store_internal</a>(
        topo_framework,
        operator,
        <a href="poc_power_store.md#0x1_poc_power_store_DEFAULT_RETENTION_BPS_PER_PERIOD">DEFAULT_RETENTION_BPS_PER_PERIOD</a>,
        power_period_in_epochs,
    );
}
</code></pre>



</details>

<a id="0x1_poc_power_store_set_retention_bps_per_period"></a>

## Function `set_retention_bps_per_period`



<pre><code><b>public</b> entry <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_set_retention_bps_per_period">set_retention_bps_per_period</a>(topo_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, retention_bps_per_period: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> entry <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_set_retention_bps_per_period">set_retention_bps_per_period</a>(
    topo_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>,
    retention_bps_per_period: u64,
) <b>acquires</b> <a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a> {
    <a href="system_addresses.md#0x1_system_addresses_assert_aptos_framework">system_addresses::assert_aptos_framework</a>(topo_framework);
    <a href="poc_power_store.md#0x1_poc_power_store_assert_store_exists">assert_store_exists</a>();
    <a href="poc_power_store.md#0x1_poc_power_store_assert_valid_retention_bps">assert_valid_retention_bps</a>(retention_bps_per_period);
    <b>borrow_global_mut</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>&gt;(@topo_framework).retention_bps_per_period =
        retention_bps_per_period;
}
</code></pre>



</details>

<a id="0x1_poc_power_store_set_power_period_in_epochs"></a>

## Function `set_power_period_in_epochs`

Update the power-period length used when the next power period starts.

The current period's remaining countdown is not recomputed. This prevents a
parameter change from reinterpreting historical epochs and making
<code>current_period</code> jump by more than one at the next epoch boundary.


<pre><code><b>public</b> entry <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_set_power_period_in_epochs">set_power_period_in_epochs</a>(topo_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, power_period_in_epochs: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> entry <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_set_power_period_in_epochs">set_power_period_in_epochs</a>(
    topo_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>,
    power_period_in_epochs: u64,
) <b>acquires</b> <a href="poc_power_store.md#0x1_poc_power_store_PeriodClock">PeriodClock</a> {
    <a href="system_addresses.md#0x1_system_addresses_assert_aptos_framework">system_addresses::assert_aptos_framework</a>(topo_framework);
    <a href="poc_power_store.md#0x1_poc_power_store_assert_store_exists">assert_store_exists</a>();
    <a href="poc_power_store.md#0x1_poc_power_store_assert_clock_exists">assert_clock_exists</a>();
    <a href="poc_power_store.md#0x1_poc_power_store_assert_valid_power_period">assert_valid_power_period</a>(power_period_in_epochs);
    <b>borrow_global_mut</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PeriodClock">PeriodClock</a>&gt;(@topo_framework).power_period_in_epochs =
        power_period_in_epochs;
}
</code></pre>



</details>

<a id="0x1_poc_power_store_set_operator"></a>

## Function `set_operator`



<pre><code><b>public</b> entry <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_set_operator">set_operator</a>(topo_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, new_operator: <b>address</b>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> entry <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_set_operator">set_operator</a>(
    topo_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>,
    new_operator: <b>address</b>,
) <b>acquires</b> <a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a> {
    <a href="system_addresses.md#0x1_system_addresses_assert_aptos_framework">system_addresses::assert_aptos_framework</a>(topo_framework);
    <a href="poc_power_store.md#0x1_poc_power_store_assert_store_exists">assert_store_exists</a>();

    <b>let</b> store = <b>borrow_global_mut</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>&gt;(@topo_framework);
    <b>let</b> old_operator = store.operator;
    <b>if</b> (old_operator == new_operator) {
        <b>return</b>
    };

    store.operator = new_operator;
    <a href="event.md#0x1_event_emit">event::emit</a>(<a href="poc_power_store.md#0x1_poc_power_store_OperatorChangedEvent">OperatorChangedEvent</a> {
        old_operator,
        new_operator,
    });
}
</code></pre>



</details>

<a id="0x1_poc_power_store_stage_batch_update"></a>

## Function `stage_batch_update`

Batch-write power versions for the next power period.

Convention:
- When on-chain current_period = P, the off-chain service uploads results computed from period P-1 data.
- However, those results only take effect starting from period P+1, so this function writes
<code>effective_period = current_period + 1</code> (i.e., target_period).

Constraints:
- Only the designated <code>operator</code> or @topo_framework may call this.
- <code>target_period</code> must equal <code>current_period + 1</code>; staging further ahead is not allowed
to prevent the operator from pre-loading multiple future periods at once.
- <code>users</code> and <code>powers</code> must have the same length.

Idempotency: calling this multiple times for the same target_period overwrites the previous value.
This allows the operator to correct a mistake before the period boundary is crossed.


<pre><code><b>public</b> entry <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_stage_batch_update">stage_batch_update</a>(operator: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, target_period: u64, users: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;, powers: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> entry <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_stage_batch_update">stage_batch_update</a>(
    operator: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>,
    target_period: u64,
    users: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;,
    powers: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt;,
) <b>acquires</b> <a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>, <a href="poc_power_store.md#0x1_poc_power_store_PeriodClock">PeriodClock</a> {
    <a href="poc_power_store.md#0x1_poc_power_store_assert_store_exists">assert_store_exists</a>();
    <a href="poc_power_store.md#0x1_poc_power_store_assert_clock_exists">assert_clock_exists</a>();
    <b>assert</b>!(
        users.length() == powers.length(),
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_invalid_argument">error::invalid_argument</a>(<a href="poc_power_store.md#0x1_poc_power_store_EINVALID_BATCH_LENGTH">EINVALID_BATCH_LENGTH</a>),
    );

    <b>let</b> clock = <b>borrow_global</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PeriodClock">PeriodClock</a>&gt;(@topo_framework);
    <b>let</b> store = <b>borrow_global_mut</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>&gt;(@topo_framework);
    <a href="poc_power_store.md#0x1_poc_power_store_assert_power_update_authority">assert_power_update_authority</a>(store, <a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer_address_of">signer::address_of</a>(operator));
    <b>assert</b>!(
        target_period == clock.current_period + 1,
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_invalid_argument">error::invalid_argument</a>(<a href="poc_power_store.md#0x1_poc_power_store_EINVALID_TARGET_PERIOD">EINVALID_TARGET_PERIOD</a>),
    );

    <b>let</b> effective_period = target_period;
    <b>let</b> length = users.length();
    <b>let</b> i = 0;
    <b>while</b> (i &lt; length) {
        <b>let</b> user = *users.borrow(i);
        <b>let</b> power = *powers.borrow(i);
        <a href="poc_power_store.md#0x1_poc_power_store_upsert_power_version">upsert_power_version</a>(store, user, effective_period, power);
        <a href="event.md#0x1_event_emit">event::emit</a>(<a href="poc_power_store.md#0x1_poc_power_store_PowerUpdateStagedEvent">PowerUpdateStagedEvent</a> {
            target_period,
            effective_period,
            user,
            power,
        });
        i += 1;
    };
}
</code></pre>



</details>

<a id="0x1_poc_power_store_set_genesis_committed_power"></a>

## Function `set_genesis_committed_power`

Genesis / test special case: directly write a committed snapshot at period 0.

This bypasses the normal staging flow and is only valid when the chain is still at
last_epoch == 0 && current_period == 0 (i.e., during genesis initialization).
Used to seed initial validator power values before the first epoch begins.


<pre><code><b>public</b> entry <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_set_genesis_committed_power">set_genesis_committed_power</a>(topo_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, user: <b>address</b>, power: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> entry <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_set_genesis_committed_power">set_genesis_committed_power</a>(
    topo_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>,
    user: <b>address</b>,
    power: u64,
) <b>acquires</b> <a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>, <a href="poc_power_store.md#0x1_poc_power_store_PeriodClock">PeriodClock</a> {
    <a href="system_addresses.md#0x1_system_addresses_assert_aptos_framework">system_addresses::assert_aptos_framework</a>(topo_framework);
    <a href="poc_power_store.md#0x1_poc_power_store_assert_store_exists">assert_store_exists</a>();
    <a href="poc_power_store.md#0x1_poc_power_store_assert_clock_exists">assert_clock_exists</a>();

    <b>let</b> clock = <b>borrow_global</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PeriodClock">PeriodClock</a>&gt;(@topo_framework);
    <b>let</b> store = <b>borrow_global_mut</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>&gt;(@topo_framework);
    <b>assert</b>!(
        clock.last_epoch == 0 && clock.current_period == 0,
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_invalid_state">error::invalid_state</a>(<a href="poc_power_store.md#0x1_poc_power_store_EGENESIS_COMMIT_ONLY">EGENESIS_COMMIT_ONLY</a>),
    );
    <a href="poc_power_store.md#0x1_poc_power_store_upsert_power_version">upsert_power_version</a>(store, user, 0, power);
}
</code></pre>



</details>

<a id="0x1_poc_power_store_commit_next_period_if_boundary"></a>

## Function `commit_next_period_if_boundary`

Advance the local epoch counter on each new on-chain epoch.
If the new epoch is the first epoch of a new power period, advance current_period.

Called by <code><a href="stake.md#0x1_stake_on_new_epoch">stake::on_new_epoch</a></code> at every epoch boundary.
This is the only place where <code>current_period</code> advances, ensuring all reads
within an epoch see a consistent period value.

Period boundary rule:
- <code>epochs_until_next_power_period</code> is decremented once per committed epoch.
- When it reaches zero, the next committed epoch advances <code>current_period</code> by one
and reloads the countdown from <code>power_period_in_epochs</code>.

Example with power_period_in_epochs = 60:
first 60 committed epochs   → period 0
next 60 committed epochs    → period 1
next 60 committed epochs    → period 2


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_commit_next_period_if_boundary">commit_next_period_if_boundary</a>()
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>friend</b> <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_commit_next_period_if_boundary">commit_next_period_if_boundary</a>() <b>acquires</b> <a href="poc_power_store.md#0x1_poc_power_store_PeriodClock">PeriodClock</a> {
    <b>if</b> (!<b>exists</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PeriodClock">PeriodClock</a>&gt;(@topo_framework)) {
        <b>return</b>
    };

    <b>let</b> clock = <b>borrow_global_mut</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PeriodClock">PeriodClock</a>&gt;(@topo_framework);
    clock.last_epoch += 1;
    <b>if</b> (clock.epochs_until_next_power_period == 0) {
        <b>let</b> previous_period = clock.current_period;
        <b>let</b> target_period = previous_period + 1;
        clock.current_period = target_period;
        clock.epochs_until_next_power_period = clock.power_period_in_epochs;
        <a href="event.md#0x1_event_emit">event::emit</a>(<a href="poc_power_store.md#0x1_poc_power_store_PowerPeriodCommittedEvent">PowerPeriodCommittedEvent</a> {
            previous_period,
            current_period: target_period,
        });
    };

    clock.epochs_until_next_power_period -= 1;
}
</code></pre>



</details>

<a id="0x1_poc_power_store_get_user_power"></a>

## Function `get_user_power`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_get_user_power">get_user_power</a>(user: <b>address</b>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_get_user_power">get_user_power</a>(user: <b>address</b>): u64 <b>acquires</b> <a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>, <a href="poc_power_store.md#0x1_poc_power_store_PeriodClock">PeriodClock</a> {
    <a href="poc_power_store.md#0x1_poc_power_store_get_user_committed_power">get_user_committed_power</a>(user)
}
</code></pre>



</details>

<a id="0x1_poc_power_store_get_user_committed_power"></a>

## Function `get_user_committed_power`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_get_user_committed_power">get_user_committed_power</a>(user: <b>address</b>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_get_user_committed_power">get_user_committed_power</a>(user: <b>address</b>): u64 <b>acquires</b> <a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>, <a href="poc_power_store.md#0x1_poc_power_store_PeriodClock">PeriodClock</a> {
    <b>if</b> (!<b>exists</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>&gt;(@topo_framework) || !<b>exists</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PeriodClock">PeriodClock</a>&gt;(@topo_framework)) {
        <b>return</b> 0
    };
    <b>let</b> clock = <b>borrow_global</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PeriodClock">PeriodClock</a>&gt;(@topo_framework);
    <b>let</b> store = <b>borrow_global</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>&gt;(@topo_framework);
    <a href="poc_power_store.md#0x1_poc_power_store_get_user_power_for_period_internal">get_user_power_for_period_internal</a>(store, user, clock.current_period)
}
</code></pre>



</details>

<a id="0x1_poc_power_store_get_user_committed_power_for_next_epoch"></a>

## Function `get_user_committed_power_for_next_epoch`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_get_user_committed_power_for_next_epoch">get_user_committed_power_for_next_epoch</a>(user: <b>address</b>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_get_user_committed_power_for_next_epoch">get_user_committed_power_for_next_epoch</a>(
    user: <b>address</b>,
): u64 <b>acquires</b> <a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>, <a href="poc_power_store.md#0x1_poc_power_store_PeriodClock">PeriodClock</a> {
    <b>if</b> (!<b>exists</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>&gt;(@topo_framework) || !<b>exists</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PeriodClock">PeriodClock</a>&gt;(@topo_framework)) {
        <b>return</b> 0
    };

    <b>let</b> store = <b>borrow_global</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>&gt;(@topo_framework);
    <b>let</b> clock = <b>borrow_global</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PeriodClock">PeriodClock</a>&gt;(@topo_framework);
    <b>let</b> target_period = <b>if</b> (clock.epochs_until_next_power_period == 0) {
            clock.current_period + 1
        } <b>else</b> {
            clock.current_period
        };
    <a href="poc_power_store.md#0x1_poc_power_store_get_user_power_for_period_internal">get_user_power_for_period_internal</a>(store, user, target_period)
}
</code></pre>



</details>

<a id="0x1_poc_power_store_get_user_power_for_period"></a>

## Function `get_user_power_for_period`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_get_user_power_for_period">get_user_power_for_period</a>(user: <b>address</b>, target_period: u64): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_get_user_power_for_period">get_user_power_for_period</a>(
    user: <b>address</b>,
    target_period: u64,
): u64 <b>acquires</b> <a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a> {
    <b>if</b> (!<b>exists</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>&gt;(@topo_framework)) {
        <b>return</b> 0
    };
    <b>let</b> store = <b>borrow_global</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>&gt;(@topo_framework);
    <a href="poc_power_store.md#0x1_poc_power_store_get_user_power_for_period_internal">get_user_power_for_period_internal</a>(store, user, target_period)
}
</code></pre>



</details>

<a id="0x1_poc_power_store_get_user_committed_powers"></a>

## Function `get_user_committed_powers`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_get_user_committed_powers">get_user_committed_powers</a>(users: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;): <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_get_user_committed_powers">get_user_committed_powers</a>(
    users: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;,
): <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt; <b>acquires</b> <a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>, <a href="poc_power_store.md#0x1_poc_power_store_PeriodClock">PeriodClock</a> {
    <b>let</b> powers = <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[];
    <b>if</b> (!<b>exists</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>&gt;(@topo_framework) || !<b>exists</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PeriodClock">PeriodClock</a>&gt;(@topo_framework)) {
        <b>return</b> powers
    };
    <b>let</b> clock = <b>borrow_global</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PeriodClock">PeriodClock</a>&gt;(@topo_framework);
    <b>let</b> store = <b>borrow_global</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>&gt;(@topo_framework);
    <b>let</b> len = users.length();
    <b>let</b> i = 0;
    <b>while</b> (i &lt; len) {
        powers.push_back(<a href="poc_power_store.md#0x1_poc_power_store_get_user_power_for_period_internal">get_user_power_for_period_internal</a>(
            store,
            *users.borrow(i),
            clock.current_period,
        ));
        i += 1;
    };
    powers
}
</code></pre>



</details>

<a id="0x1_poc_power_store_get_user_powers_for_period"></a>

## Function `get_user_powers_for_period`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_get_user_powers_for_period">get_user_powers_for_period</a>(users: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;, target_period: u64): <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_get_user_powers_for_period">get_user_powers_for_period</a>(
    users: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;,
    target_period: u64,
): <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt; <b>acquires</b> <a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a> {
    <b>let</b> powers = <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[];
    <b>if</b> (!<b>exists</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>&gt;(@topo_framework)) {
        <b>return</b> powers
    };
    <b>let</b> store = <b>borrow_global</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>&gt;(@topo_framework);
    <b>let</b> len = users.length();
    <b>let</b> i = 0;
    <b>while</b> (i &lt; len) {
        powers.push_back(<a href="poc_power_store.md#0x1_poc_power_store_get_user_power_for_period_internal">get_user_power_for_period_internal</a>(
            store,
            *users.borrow(i),
            target_period,
        ));
        i += 1;
    };
    powers
}
</code></pre>



</details>

<a id="0x1_poc_power_store_get_user_power_version"></a>

## Function `get_user_power_version`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_get_user_power_version">get_user_power_version</a>(user: <b>address</b>): (u64, u64, u64, u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_get_user_power_version">get_user_power_version</a>(
    user: <b>address</b>,
): (u64, u64, u64, u64, u64) <b>acquires</b> <a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>, <a href="poc_power_store.md#0x1_poc_power_store_PeriodClock">PeriodClock</a> {
    <b>if</b> (!<b>exists</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>&gt;(@topo_framework) || !<b>exists</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PeriodClock">PeriodClock</a>&gt;(@topo_framework)) {
        <b>return</b> (0, 0, 0, 0, 0)
    };
    <b>let</b> clock = <b>borrow_global</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PeriodClock">PeriodClock</a>&gt;(@topo_framework);
    <b>let</b> store = <b>borrow_global</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>&gt;(@topo_framework);
    <a href="poc_power_store.md#0x1_poc_power_store_build_user_power_version">build_user_power_version</a>(store, user, clock.current_period)
}
</code></pre>



</details>

<a id="0x1_poc_power_store_get_user_power_versions_by_addresses"></a>

## Function `get_user_power_versions_by_addresses`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_get_user_power_versions_by_addresses">get_user_power_versions_by_addresses</a>(users: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;): (<a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;, <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt;, <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_get_user_power_versions_by_addresses">get_user_power_versions_by_addresses</a>(
    users: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;,
): (
    <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;,
    <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt;,
    <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt;,
    <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt;,
    <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt;,
    <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u64&gt;,
) <b>acquires</b> <a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>, <a href="poc_power_store.md#0x1_poc_power_store_PeriodClock">PeriodClock</a> {
    <b>let</b> returned_users = <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[];
    <b>let</b> older_effective_periods = <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[];
    <b>let</b> older_powers = <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[];
    <b>let</b> newer_effective_periods = <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[];
    <b>let</b> newer_powers = <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[];
    <b>let</b> committed_powers = <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[];
    <b>if</b> (!<b>exists</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>&gt;(@topo_framework) || !<b>exists</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PeriodClock">PeriodClock</a>&gt;(@topo_framework)) {
        <b>return</b> (
            returned_users,
            older_effective_periods,
            older_powers,
            newer_effective_periods,
            newer_powers,
            committed_powers,
        )
    };
    <b>let</b> clock = <b>borrow_global</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PeriodClock">PeriodClock</a>&gt;(@topo_framework);
    <b>let</b> store = <b>borrow_global</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>&gt;(@topo_framework);
    <b>let</b> len = users.length();
    <b>let</b> i = 0;
    <b>while</b> (i &lt; len) {
        <b>let</b> user = *users.borrow(i);
        <b>let</b> (
            older_effective_period,
            older_power,
            newer_effective_period,
            newer_power,
            committed_power,
        ) = <a href="poc_power_store.md#0x1_poc_power_store_build_user_power_version">build_user_power_version</a>(store, user, clock.current_period);
        returned_users.push_back(user);
        older_effective_periods.push_back(older_effective_period);
        older_powers.push_back(older_power);
        newer_effective_periods.push_back(newer_effective_period);
        newer_powers.push_back(newer_power);
        committed_powers.push_back(committed_power);
        i += 1;
    };
    (
        returned_users,
        older_effective_periods,
        older_powers,
        newer_effective_periods,
        newer_powers,
        committed_powers,
    )
}
</code></pre>



</details>

<a id="0x1_poc_power_store_get_user_decayed_power"></a>

## Function `get_user_decayed_power`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_get_user_decayed_power">get_user_decayed_power</a>(user: <b>address</b>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_get_user_decayed_power">get_user_decayed_power</a>(user: <b>address</b>): u64 <b>acquires</b> <a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>, <a href="poc_power_store.md#0x1_poc_power_store_PeriodClock">PeriodClock</a> {
    <a href="poc_power_store.md#0x1_poc_power_store_get_user_committed_power">get_user_committed_power</a>(user)
}
</code></pre>



</details>

<a id="0x1_poc_power_store_get_operator"></a>

## Function `get_operator`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_get_operator">get_operator</a>(): <b>address</b>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_get_operator">get_operator</a>(): <b>address</b> <b>acquires</b> <a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a> {
    <b>if</b> (!<b>exists</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>&gt;(@topo_framework)) {
        <b>return</b> @0x0
    };
    <b>borrow_global</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>&gt;(@topo_framework).operator
}
</code></pre>



</details>

<a id="0x1_poc_power_store_get_current_period"></a>

## Function `get_current_period`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_get_current_period">get_current_period</a>(): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_get_current_period">get_current_period</a>(): u64 <b>acquires</b> <a href="poc_power_store.md#0x1_poc_power_store_PeriodClock">PeriodClock</a> {
    <b>if</b> (!<b>exists</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PeriodClock">PeriodClock</a>&gt;(@topo_framework)) {
        0
    } <b>else</b> {
        <b>borrow_global</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PeriodClock">PeriodClock</a>&gt;(@topo_framework).current_period
    }
}
</code></pre>



</details>

<a id="0x1_poc_power_store_get_power_period_in_epochs"></a>

## Function `get_power_period_in_epochs`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_get_power_period_in_epochs">get_power_period_in_epochs</a>(): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_get_power_period_in_epochs">get_power_period_in_epochs</a>(): u64 <b>acquires</b> <a href="poc_power_store.md#0x1_poc_power_store_PeriodClock">PeriodClock</a> {
    <b>if</b> (!<b>exists</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PeriodClock">PeriodClock</a>&gt;(@topo_framework)) {
        0
    } <b>else</b> {
        <b>borrow_global</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PeriodClock">PeriodClock</a>&gt;(@topo_framework).power_period_in_epochs
    }
}
</code></pre>



</details>

<a id="0x1_poc_power_store_get_retention_bps_per_period"></a>

## Function `get_retention_bps_per_period`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_get_retention_bps_per_period">get_retention_bps_per_period</a>(): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_get_retention_bps_per_period">get_retention_bps_per_period</a>(): u64 <b>acquires</b> <a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a> {
    <b>if</b> (!<b>exists</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>&gt;(@topo_framework)) {
        0
    } <b>else</b> {
        <b>borrow_global</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>&gt;(@topo_framework).retention_bps_per_period
    }
}
</code></pre>



</details>

<a id="0x1_poc_power_store_initialize_power_store_internal"></a>

## Function `initialize_power_store_internal`



<pre><code><b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_initialize_power_store_internal">initialize_power_store_internal</a>(topo_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, operator: <b>address</b>, retention_bps_per_period: u64, power_period_in_epochs: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_initialize_power_store_internal">initialize_power_store_internal</a>(
    topo_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>,
    operator: <b>address</b>,
    retention_bps_per_period: u64,
    power_period_in_epochs: u64,
) {
    <a href="system_addresses.md#0x1_system_addresses_assert_aptos_framework">system_addresses::assert_aptos_framework</a>(topo_framework);
    <a href="poc_power_store.md#0x1_poc_power_store_assert_valid_retention_bps">assert_valid_retention_bps</a>(retention_bps_per_period);
    <a href="poc_power_store.md#0x1_poc_power_store_assert_valid_power_period">assert_valid_power_period</a>(power_period_in_epochs);
    <b>move_to</b>(topo_framework, <a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a> {
        operator,
        users: <a href="../../aptos-stdlib/doc/table.md#0x1_table_new">table::new</a>(),
        retention_bps_per_period,
    });
    <b>move_to</b>(topo_framework, <a href="poc_power_store.md#0x1_poc_power_store_PeriodClock">PeriodClock</a> {
        power_period_in_epochs,
        last_epoch: 0,
        current_period: 0,
        epochs_until_next_power_period: power_period_in_epochs,
    });
}
</code></pre>



</details>

<a id="0x1_poc_power_store_assert_store_exists"></a>

## Function `assert_store_exists`



<pre><code><b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_assert_store_exists">assert_store_exists</a>()
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_assert_store_exists">assert_store_exists</a>() {
    <b>assert</b>!(
        <b>exists</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>&gt;(@topo_framework),
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_not_found">error::not_found</a>(<a href="poc_power_store.md#0x1_poc_power_store_ESTORE_NOT_INITIALIZED">ESTORE_NOT_INITIALIZED</a>),
    );
}
</code></pre>



</details>

<a id="0x1_poc_power_store_assert_clock_exists"></a>

## Function `assert_clock_exists`



<pre><code><b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_assert_clock_exists">assert_clock_exists</a>()
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_assert_clock_exists">assert_clock_exists</a>() {
    <b>assert</b>!(
        <b>exists</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PeriodClock">PeriodClock</a>&gt;(@topo_framework),
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_not_found">error::not_found</a>(<a href="poc_power_store.md#0x1_poc_power_store_ESTORE_NOT_INITIALIZED">ESTORE_NOT_INITIALIZED</a>),
    );
}
</code></pre>



</details>

<a id="0x1_poc_power_store_assert_power_update_authority"></a>

## Function `assert_power_update_authority`



<pre><code><b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_assert_power_update_authority">assert_power_update_authority</a>(store: &<a href="poc_power_store.md#0x1_poc_power_store_PowerStore">poc_power_store::PowerStore</a>, caller: <b>address</b>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_assert_power_update_authority">assert_power_update_authority</a>(store: &<a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>, caller: <b>address</b>) {
    <b>assert</b>!(
        store.operator == caller || <a href="system_addresses.md#0x1_system_addresses_is_aptos_framework_address">system_addresses::is_aptos_framework_address</a>(caller),
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_permission_denied">error::permission_denied</a>(<a href="poc_power_store.md#0x1_poc_power_store_ENOT_OPERATOR">ENOT_OPERATOR</a>),
    );
}
</code></pre>



</details>

<a id="0x1_poc_power_store_assert_valid_retention_bps"></a>

## Function `assert_valid_retention_bps`



<pre><code><b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_assert_valid_retention_bps">assert_valid_retention_bps</a>(retention_bps_per_period: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_assert_valid_retention_bps">assert_valid_retention_bps</a>(retention_bps_per_period: u64) {
    <b>assert</b>!(
        retention_bps_per_period &gt; 0
            && retention_bps_per_period &lt;= <a href="poc_power_store.md#0x1_poc_power_store_BPS_DENOMINATOR">BPS_DENOMINATOR</a>,
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_invalid_argument">error::invalid_argument</a>(<a href="poc_power_store.md#0x1_poc_power_store_EINVALID_RETENTION_BPS">EINVALID_RETENTION_BPS</a>),
    );
}
</code></pre>



</details>

<a id="0x1_poc_power_store_assert_valid_power_period"></a>

## Function `assert_valid_power_period`



<pre><code><b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_assert_valid_power_period">assert_valid_power_period</a>(power_period_in_epochs: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_assert_valid_power_period">assert_valid_power_period</a>(power_period_in_epochs: u64) {
    <b>assert</b>!(
        power_period_in_epochs &gt; 0,
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_invalid_argument">error::invalid_argument</a>(<a href="poc_power_store.md#0x1_poc_power_store_EINVALID_POWER_PERIOD">EINVALID_POWER_PERIOD</a>),
    );
}
</code></pre>



</details>

<a id="0x1_poc_power_store_upsert_power_version"></a>

## Function `upsert_power_version`

Insert or update a user's power version in the two-slot window.

Slot selection logic:
1. User not yet in table → create a new entry with <code>newer</code> = this version (skip if power == 0)
2. <code>effective_period</code> matches <code>newer</code> → overwrite <code>newer.power</code> in-place (idempotent update)
3. <code>effective_period</code> matches <code>older</code> → overwrite <code>older.power</code> in-place (idempotent update)
4. Neither slot matches → shift: <code>older = newer</code>, <code>newer = new <a href="version.md#0x1_version">version</a></code>
(the oldest slot is evicted; only the two most recent periods are retained)

After any write, <code>normalize_user_power_info</code> ensures older.effective_period <= newer.effective_period.


<pre><code><b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_upsert_power_version">upsert_power_version</a>(store: &<b>mut</b> <a href="poc_power_store.md#0x1_poc_power_store_PowerStore">poc_power_store::PowerStore</a>, user: <b>address</b>, effective_period: u64, power: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_upsert_power_version">upsert_power_version</a>(
    store: &<b>mut</b> <a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>,
    user: <b>address</b>,
    effective_period: u64,
    power: u64,
) {
    <b>if</b> (!store.users.contains(user)) {
        <b>if</b> (power == 0) {
            <b>return</b>
        };
        store.users.add(user, <a href="poc_power_store.md#0x1_poc_power_store_UserPowerInfo">UserPowerInfo</a> {
            older: <a href="poc_power_store.md#0x1_poc_power_store_empty_power_version">empty_power_version</a>(),
            newer: <a href="poc_power_store.md#0x1_poc_power_store_PowerVersion">PowerVersion</a> {
                effective_period,
                power,
            },
        });
        <b>return</b>
    };

    <b>let</b> info = store.users.borrow_mut(user);
    <b>if</b> (info.newer.effective_period == effective_period) {
        info.newer.power = power;
        <a href="poc_power_store.md#0x1_poc_power_store_normalize_user_power_info">normalize_user_power_info</a>(info);
        <b>return</b>
    };

    <b>if</b> (info.older.effective_period == effective_period) {
        info.older.power = power;
        <a href="poc_power_store.md#0x1_poc_power_store_normalize_user_power_info">normalize_user_power_info</a>(info);
        <b>return</b>
    };

    // Evict the oldest slot and write the new <a href="version.md#0x1_version">version</a> into `newer`
    info.older = info.newer;
    info.newer = <a href="poc_power_store.md#0x1_poc_power_store_PowerVersion">PowerVersion</a> {
        effective_period,
        power,
    };
    <a href="poc_power_store.md#0x1_poc_power_store_normalize_user_power_info">normalize_user_power_info</a>(info);
}
</code></pre>



</details>

<a id="0x1_poc_power_store_normalize_user_power_info"></a>

## Function `normalize_user_power_info`

Ensure the two slots are ordered: older.effective_period <= newer.effective_period.
Swaps the slots if they are out of order (can happen after an in-place overwrite).


<pre><code><b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_normalize_user_power_info">normalize_user_power_info</a>(info: &<b>mut</b> <a href="poc_power_store.md#0x1_poc_power_store_UserPowerInfo">poc_power_store::UserPowerInfo</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_normalize_user_power_info">normalize_user_power_info</a>(info: &<b>mut</b> <a href="poc_power_store.md#0x1_poc_power_store_UserPowerInfo">UserPowerInfo</a>) {
    <b>if</b> (info.older.effective_period &gt; info.newer.effective_period) {
        <b>let</b> swapped = info.older;
        info.older = info.newer;
        info.newer = swapped;
    };
}
</code></pre>



</details>

<a id="0x1_poc_power_store_get_user_power_for_period_internal"></a>

## Function `get_user_power_for_period_internal`

Core read path: find the best power value for a given target_period and apply decay.

Steps:
1. Select the effective version: the slot with the highest effective_period that is <= target_period
2. Compute periods_elapsed = target_period - base_period
3. Apply retention decay: power * (retention_bps ^ periods_elapsed) / (BPS_DENOMINATOR ^ periods_elapsed)

Returns 0 if the user has no record or no version is effective for target_period.


<pre><code><b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_get_user_power_for_period_internal">get_user_power_for_period_internal</a>(store: &<a href="poc_power_store.md#0x1_poc_power_store_PowerStore">poc_power_store::PowerStore</a>, user: <b>address</b>, target_period: u64): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_get_user_power_for_period_internal">get_user_power_for_period_internal</a>(
    store: &<a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>,
    user: <b>address</b>,
    target_period: u64,
): u64 {
    <b>if</b> (!store.users.contains(user)) {
        <b>return</b> 0
    };

    <b>let</b> info = store.users.borrow(user);
    <b>let</b> (base_period, base_power) = <a href="poc_power_store.md#0x1_poc_power_store_select_effective_version">select_effective_version</a>(info, target_period);
    <b>if</b> (base_power == 0) {
        <b>return</b> 0
    };
    <a href="poc_power_store.md#0x1_poc_power_store_apply_retention">apply_retention</a>(
        base_power,
        target_period - base_period,
        store.retention_bps_per_period,
    )
}
</code></pre>



</details>

<a id="0x1_poc_power_store_build_user_power_version"></a>

## Function `build_user_power_version`



<pre><code><b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_build_user_power_version">build_user_power_version</a>(store: &<a href="poc_power_store.md#0x1_poc_power_store_PowerStore">poc_power_store::PowerStore</a>, user: <b>address</b>, current_period: u64): (u64, u64, u64, u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_build_user_power_version">build_user_power_version</a>(
    store: &<a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>,
    user: <b>address</b>,
    current_period: u64,
): (u64, u64, u64, u64, u64) {
    <b>if</b> (!store.users.contains(user)) {
        <b>return</b> (0, 0, 0, 0, 0)
    };
    <b>let</b> info = store.users.borrow(user);
    (
        info.older.effective_period,
        info.older.power,
        info.newer.effective_period,
        info.newer.power,
        <a href="poc_power_store.md#0x1_poc_power_store_get_user_power_for_period_internal">get_user_power_for_period_internal</a>(
            store,
            user,
            current_period,
        ),
    )
}
</code></pre>



</details>

<a id="0x1_poc_power_store_select_effective_version"></a>

## Function `select_effective_version`

Select the most recent version whose effective_period <= target_period.
Prefers <code>newer</code> over <code>older</code> when both qualify (newer has higher effective_period).
Returns (0, 0) if neither slot qualifies.


<pre><code><b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_select_effective_version">select_effective_version</a>(info: &<a href="poc_power_store.md#0x1_poc_power_store_UserPowerInfo">poc_power_store::UserPowerInfo</a>, target_period: u64): (u64, u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_select_effective_version">select_effective_version</a>(
    info: &<a href="poc_power_store.md#0x1_poc_power_store_UserPowerInfo">UserPowerInfo</a>,
    target_period: u64,
): (u64, u64) {
    <b>let</b> newer = info.newer;
    <b>if</b> (newer.effective_period &lt;= target_period && <a href="poc_power_store.md#0x1_poc_power_store_has_power_version">has_power_version</a>(newer)) {
        <b>return</b> (newer.effective_period, newer.power)
    };

    <b>let</b> older = info.older;
    <b>if</b> (older.effective_period &lt;= target_period && <a href="poc_power_store.md#0x1_poc_power_store_has_power_version">has_power_version</a>(older)) {
        <b>return</b> (older.effective_period, older.power)
    };

    (0, 0)
}
</code></pre>



</details>

<a id="0x1_poc_power_store_has_power_version"></a>

## Function `has_power_version`

A PowerVersion is considered "present" if either field is non-zero.
The zero value (effective_period=0, power=0) is used as the empty sentinel.
Note: a version at period 0 with power > 0 is valid (genesis snapshot).


<pre><code><b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_has_power_version">has_power_version</a>(<a href="version.md#0x1_version">version</a>: <a href="poc_power_store.md#0x1_poc_power_store_PowerVersion">poc_power_store::PowerVersion</a>): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_has_power_version">has_power_version</a>(<a href="version.md#0x1_version">version</a>: <a href="poc_power_store.md#0x1_poc_power_store_PowerVersion">PowerVersion</a>): bool {
    <a href="version.md#0x1_version">version</a>.effective_period &gt; 0 || <a href="version.md#0x1_version">version</a>.power &gt; 0
}
</code></pre>



</details>

<a id="0x1_poc_power_store_apply_retention"></a>

## Function `apply_retention`

Apply per-period retention decay to a base power value.

Formula: retained = power * (retention_bps / BPS_DENOMINATOR) ^ periods_elapsed
Computed iteratively to avoid u64 overflow in intermediate exponentiation.
Uses u128 for each multiplication step to prevent overflow before the division.

Example: power=1000, retention_bps=9950, periods_elapsed=2
step 1: 1000 * 9950 / 10000 = 995
step 2: 995 * 9950 / 10000 = 990 (truncated)


<pre><code><b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_apply_retention">apply_retention</a>(power: u64, periods_elapsed: u64, retention_bps_per_period: u64): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_apply_retention">apply_retention</a>(
    power: u64,
    periods_elapsed: u64,
    retention_bps_per_period: u64,
): u64 {
    <b>if</b> (power == 0 || periods_elapsed == 0) {
        <b>return</b> power
    };

    <b>let</b> retained_power = power;
    <b>let</b> i = 0;
    <b>while</b> (i &lt; periods_elapsed) {
        <b>if</b> (retained_power == 0) {
            <b>return</b> 0
        };
        retained_power =
            (((retained_power <b>as</b> u128) * (retention_bps_per_period <b>as</b> u128))
                / (<a href="poc_power_store.md#0x1_poc_power_store_BPS_DENOMINATOR">BPS_DENOMINATOR</a> <b>as</b> u128)) <b>as</b> u64;
        i += 1;
    };
    retained_power
}
</code></pre>



</details>

<a id="0x1_poc_power_store_empty_power_version"></a>

## Function `empty_power_version`

Returns the zero-value sentinel PowerVersion used to initialize empty slots.


<pre><code><b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_empty_power_version">empty_power_version</a>(): <a href="poc_power_store.md#0x1_poc_power_store_PowerVersion">poc_power_store::PowerVersion</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_empty_power_version">empty_power_version</a>(): <a href="poc_power_store.md#0x1_poc_power_store_PowerVersion">PowerVersion</a> {
    <a href="poc_power_store.md#0x1_poc_power_store_PowerVersion">PowerVersion</a> {
        effective_period: 0,
        power: 0,
    }
}
</code></pre>



</details>


[move-book]: https://aptos.dev/move/book/SUMMARY
