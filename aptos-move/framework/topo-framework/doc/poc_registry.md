
<a id="0x1_poc_registry"></a>

# Module `0x1::poc_registry`



-  [Resource `Registry`](#0x1_poc_registry_Registry)
-  [Struct `AppInfo`](#0x1_poc_registry_AppInfo)
-  [Struct `AppRegisteredEvent`](#0x1_poc_registry_AppRegisteredEvent)
-  [Struct `AppAddressUpdatedEvent`](#0x1_poc_registry_AppAddressUpdatedEvent)
-  [Struct `AppEquityTokenUpdatedEvent`](#0x1_poc_registry_AppEquityTokenUpdatedEvent)
-  [Struct `AppCustodyUpdatedEvent`](#0x1_poc_registry_AppCustodyUpdatedEvent)
-  [Struct `AppStateChangedEvent`](#0x1_poc_registry_AppStateChangedEvent)
-  [Struct `AppPocListingStatusChangedEvent`](#0x1_poc_registry_AppPocListingStatusChangedEvent)
-  [Struct `AppEffectiveWeightUpdatedEvent`](#0x1_poc_registry_AppEffectiveWeightUpdatedEvent)
-  [Constants](#@Constants_0)
-  [Function `initialize`](#0x1_poc_registry_initialize)
-  [Function `initialize_registry`](#0x1_poc_registry_initialize_registry)
-  [Function `register_app`](#0x1_poc_registry_register_app)
-  [Function `update_app_address`](#0x1_poc_registry_update_app_address)
-  [Function `update_equity_token_address`](#0x1_poc_registry_update_equity_token_address)
-  [Function `update_custody_address`](#0x1_poc_registry_update_custody_address)
-  [Function `pause_app`](#0x1_poc_registry_pause_app)
-  [Function `resume_app`](#0x1_poc_registry_resume_app)
-  [Function `stop_app`](#0x1_poc_registry_stop_app)
-  [Function `set_poc_listing_status`](#0x1_poc_registry_set_poc_listing_status)
-  [Function `suspend_poc_listing`](#0x1_poc_registry_suspend_poc_listing)
-  [Function `whitelist_app_for_poc`](#0x1_poc_registry_whitelist_app_for_poc)
-  [Function `set_effective_weight_pbs`](#0x1_poc_registry_set_effective_weight_pbs)
-  [Function `exists_app`](#0x1_poc_registry_exists_app)
-  [Function `exists_apps`](#0x1_poc_registry_exists_apps)
-  [Function `get_app_infos_by_admins`](#0x1_poc_registry_get_app_infos_by_admins)
-  [Function `get_app_admins_by_app_addresses`](#0x1_poc_registry_get_app_admins_by_app_addresses)
-  [Function `get_app_admin_by_app_address`](#0x1_poc_registry_get_app_admin_by_app_address)
-  [Function `get_app_admin_by_custody_address`](#0x1_poc_registry_get_app_admin_by_custody_address)
-  [Function `get_app_admin_by_equity_token`](#0x1_poc_registry_get_app_admin_by_equity_token)
-  [Function `get_app_info`](#0x1_poc_registry_get_app_info)
-  [Function `get_app_info_by_app_address`](#0x1_poc_registry_get_app_info_by_app_address)
-  [Function `get_app_address`](#0x1_poc_registry_get_app_address)
-  [Function `get_equity_token_address`](#0x1_poc_registry_get_equity_token_address)
-  [Function `get_custody_address`](#0x1_poc_registry_get_custody_address)
-  [Function `get_app_state`](#0x1_poc_registry_get_app_state)
-  [Function `get_poc_listing_status`](#0x1_poc_registry_get_poc_listing_status)
-  [Function `get_metadata_uri`](#0x1_poc_registry_get_metadata_uri)
-  [Function `get_effective_weight_pbs`](#0x1_poc_registry_get_effective_weight_pbs)
-  [Function `is_app_active`](#0x1_poc_registry_is_app_active)
-  [Function `is_poc_listed`](#0x1_poc_registry_is_poc_listed)
-  [Function `is_app_eligible_for_poc`](#0x1_poc_registry_is_app_eligible_for_poc)
-  [Function `borrow_app_info_mut`](#0x1_poc_registry_borrow_app_info_mut)
-  [Function `update_app_state`](#0x1_poc_registry_update_app_state)
-  [Function `update_poc_listing_status`](#0x1_poc_registry_update_poc_listing_status)
-  [Function `reset_poc_listing_status_if_needed`](#0x1_poc_registry_reset_poc_listing_status_if_needed)
-  [Function `assert_valid_app_state`](#0x1_poc_registry_assert_valid_app_state)
-  [Function `assert_valid_poc_listing_status`](#0x1_poc_registry_assert_valid_poc_listing_status)


<pre><code><b>use</b> <a href="event.md#0x1_event">0x1::event</a>;
<b>use</b> <a href="fungible_asset.md#0x1_fungible_asset">0x1::fungible_asset</a>;
<b>use</b> <a href="object.md#0x1_object">0x1::object</a>;
<b>use</b> <a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">0x1::signer</a>;
<b>use</b> <a href="../../aptos-stdlib/../move-stdlib/doc/string.md#0x1_string">0x1::string</a>;
<b>use</b> <a href="system_addresses.md#0x1_system_addresses">0x1::system_addresses</a>;
<b>use</b> <a href="../../aptos-stdlib/doc/table.md#0x1_table">0x1::table</a>;
</code></pre>



<a id="0x1_poc_registry_Registry"></a>

## Resource `Registry`

Global registry, stored under @topo_framework, initialized at genesis.

Maintains 4 lookup tables to support reverse-lookup from any of:
admin address, contract address, custody address, or equity token address
back to the same registered entity.

The multi-index design allows <code><a href="poc_contribution.md#0x1_poc_contribution">poc_contribution</a></code> to efficiently validate
all three address dimensions (app_address, custody_address, equity_token)
in O(1) without scanning the full registry.


<pre><code><b>struct</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> <b>has</b> key
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>apps: <a href="../../aptos-stdlib/doc/table.md#0x1_table_Table">table::Table</a>&lt;<b>address</b>, <a href="poc_registry.md#0x1_poc_registry_AppInfo">poc_registry::AppInfo</a>&gt;</code>
</dt>
<dd>
 Primary table: admin address → full AppInfo
</dd>
<dt>
<code>app_address_to_admin: <a href="../../aptos-stdlib/doc/table.md#0x1_table_Table">table::Table</a>&lt;<b>address</b>, <b>address</b>&gt;</code>
</dt>
<dd>
 Reverse lookup: contract deployment address → admin address
</dd>
<dt>
<code>custody_address_to_admin: <a href="../../aptos-stdlib/doc/table.md#0x1_table_Table">table::Table</a>&lt;<b>address</b>, <b>address</b>&gt;</code>
</dt>
<dd>
 Reverse lookup: custody address → admin address
</dd>
<dt>
<code>equity_token_to_admin: <a href="../../aptos-stdlib/doc/table.md#0x1_table_Table">table::Table</a>&lt;<b>address</b>, <b>address</b>&gt;</code>
</dt>
<dd>
 Reverse lookup: equity token address → admin address
</dd>
</dl>


</details>

<a id="0x1_poc_registry_AppInfo"></a>

## Struct `AppInfo`

Complete registration record for a Dapp application.


<pre><code><b>struct</b> <a href="poc_registry.md#0x1_poc_registry_AppInfo">AppInfo</a> <b>has</b> <b>copy</b>, drop, store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>app_admin: <b>address</b></code>
</dt>
<dd>
 Administrator identity address (primary key); holds highest management authority for this app
</dd>
<dt>
<code>app_address: <b>address</b></code>
</dt>
<dd>
 Contract deployment address; the on-chain entry module address for this application.
 Can be updated by the admin (e.g., after contract upgrade/redeployment), but must remain globally unique.
</dd>
<dt>
<code>equity_token_address: <b>address</b></code>
</dt>
<dd>
 Equity token address (analogous to an ERC-20 contract address on Ethereum).
 Must be a valid Fungible Asset Metadata object address.
 IMPORTANT: Changing this resets poc_listing_status to REGISTERED, requiring platform re-review.
</dd>
<dt>
<code>custody_address: <b>address</b></code>
</dt>
<dd>
 Custody address holding equity tokens pending distribution.
 During trusted contribution events, only this address's signer can transfer tokens out.
</dd>
<dt>
<code>app_state: u8</code>
</dt>
<dd>
 Application's self-managed operational state (APP_STATE_ACTIVE / PAUSED / STOPPED).
 Controlled exclusively by the app_admin.
</dd>
<dt>
<code>poc_listing_status: u8</code>
</dt>
<dd>
 Platform POC inclusion status (POC_LISTING_STATUS_REGISTERED / WHITELISTED / SUSPENDED).
 Controlled by the chain's DAO governance organization (currently @topo_framework).
</dd>
<dt>
<code>metadata_uri: <a href="../../aptos-stdlib/../move-stdlib/doc/string.md#0x1_string_String">string::String</a></code>
</dt>
<dd>
 Application's official website or authoritative information link
</dd>
<dt>
<code>effective_weight_pbs: u64</code>
</dt>
<dd>
 Effective weight in per-basis-points (0–10000). 10000 = 100% weight.
 Controlled by @topo_framework / DAO governance to adjust the app's actual contribution weight.
</dd>
</dl>


</details>

<a id="0x1_poc_registry_AppRegisteredEvent"></a>

## Struct `AppRegisteredEvent`

Emitted when a new application is successfully registered


<pre><code>#[<a href="event.md#0x1_event">event</a>]
<b>struct</b> <a href="poc_registry.md#0x1_poc_registry_AppRegisteredEvent">AppRegisteredEvent</a> <b>has</b> drop, store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>app_admin: <b>address</b></code>
</dt>
<dd>

</dd>
<dt>
<code>app_address: <b>address</b></code>
</dt>
<dd>

</dd>
<dt>
<code>equity_token_address: <b>address</b></code>
</dt>
<dd>

</dd>
<dt>
<code>custody_address: <b>address</b></code>
</dt>
<dd>

</dd>
</dl>


</details>

<a id="0x1_poc_registry_AppAddressUpdatedEvent"></a>

## Struct `AppAddressUpdatedEvent`

Emitted when the contract deployment address is updated (e.g., after contract upgrade)


<pre><code>#[<a href="event.md#0x1_event">event</a>]
<b>struct</b> <a href="poc_registry.md#0x1_poc_registry_AppAddressUpdatedEvent">AppAddressUpdatedEvent</a> <b>has</b> drop, store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>app_admin: <b>address</b></code>
</dt>
<dd>

</dd>
<dt>
<code>old_app_address: <b>address</b></code>
</dt>
<dd>

</dd>
<dt>
<code>new_app_address: <b>address</b></code>
</dt>
<dd>

</dd>
</dl>


</details>

<a id="0x1_poc_registry_AppEquityTokenUpdatedEvent"></a>

## Struct `AppEquityTokenUpdatedEvent`

Emitted when the equity token address is updated.
Note: this also triggers an automatic reset of poc_listing_status to REGISTERED.


<pre><code>#[<a href="event.md#0x1_event">event</a>]
<b>struct</b> <a href="poc_registry.md#0x1_poc_registry_AppEquityTokenUpdatedEvent">AppEquityTokenUpdatedEvent</a> <b>has</b> drop, store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>app_admin: <b>address</b></code>
</dt>
<dd>

</dd>
<dt>
<code>old_equity_token_address: <b>address</b></code>
</dt>
<dd>

</dd>
<dt>
<code>new_equity_token_address: <b>address</b></code>
</dt>
<dd>

</dd>
</dl>


</details>

<a id="0x1_poc_registry_AppCustodyUpdatedEvent"></a>

## Struct `AppCustodyUpdatedEvent`

Emitted when the custody address is updated


<pre><code>#[<a href="event.md#0x1_event">event</a>]
<b>struct</b> <a href="poc_registry.md#0x1_poc_registry_AppCustodyUpdatedEvent">AppCustodyUpdatedEvent</a> <b>has</b> drop, store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>app_admin: <b>address</b></code>
</dt>
<dd>

</dd>
<dt>
<code>old_custody_address: <b>address</b></code>
</dt>
<dd>

</dd>
<dt>
<code>new_custody_address: <b>address</b></code>
</dt>
<dd>

</dd>
</dl>


</details>

<a id="0x1_poc_registry_AppStateChangedEvent"></a>

## Struct `AppStateChangedEvent`

Emitted when the application's self-managed operational state changes


<pre><code>#[<a href="event.md#0x1_event">event</a>]
<b>struct</b> <a href="poc_registry.md#0x1_poc_registry_AppStateChangedEvent">AppStateChangedEvent</a> <b>has</b> drop, store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>app_admin: <b>address</b></code>
</dt>
<dd>

</dd>
<dt>
<code>old_app_state: u8</code>
</dt>
<dd>

</dd>
<dt>
<code>new_app_state: u8</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a id="0x1_poc_registry_AppPocListingStatusChangedEvent"></a>

## Struct `AppPocListingStatusChangedEvent`

Emitted when the platform POC inclusion status changes


<pre><code>#[<a href="event.md#0x1_event">event</a>]
<b>struct</b> <a href="poc_registry.md#0x1_poc_registry_AppPocListingStatusChangedEvent">AppPocListingStatusChangedEvent</a> <b>has</b> drop, store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>app_admin: <b>address</b></code>
</dt>
<dd>

</dd>
<dt>
<code>old_poc_listing_status: u8</code>
</dt>
<dd>

</dd>
<dt>
<code>new_poc_listing_status: u8</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a id="0x1_poc_registry_AppEffectiveWeightUpdatedEvent"></a>

## Struct `AppEffectiveWeightUpdatedEvent`

Emitted when the effective weight is updated by the platform


<pre><code>#[<a href="event.md#0x1_event">event</a>]
<b>struct</b> <a href="poc_registry.md#0x1_poc_registry_AppEffectiveWeightUpdatedEvent">AppEffectiveWeightUpdatedEvent</a> <b>has</b> drop, store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>app_admin: <b>address</b></code>
</dt>
<dd>

</dd>
<dt>
<code>old_effective_weight_pbs: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>new_effective_weight_pbs: u64</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a id="@Constants_0"></a>

## Constants


<a id="0x1_poc_registry_EREGISTRY_NOT_INITIALIZED"></a>

Registry resource has not been initialized (genesis not executed or skipped)


<pre><code><b>const</b> <a href="poc_registry.md#0x1_poc_registry_EREGISTRY_NOT_INITIALIZED">EREGISTRY_NOT_INITIALIZED</a>: u64 = 1;
</code></pre>



<a id="0x1_poc_registry_APP_STATE_ACTIVE"></a>



<pre><code><b>const</b> <a href="poc_registry.md#0x1_poc_registry_APP_STATE_ACTIVE">APP_STATE_ACTIVE</a>: u8 = 1;
</code></pre>



<a id="0x1_poc_registry_APP_STATE_PAUSED"></a>



<pre><code><b>const</b> <a href="poc_registry.md#0x1_poc_registry_APP_STATE_PAUSED">APP_STATE_PAUSED</a>: u8 = 2;
</code></pre>



<a id="0x1_poc_registry_APP_STATE_STOPPED"></a>



<pre><code><b>const</b> <a href="poc_registry.md#0x1_poc_registry_APP_STATE_STOPPED">APP_STATE_STOPPED</a>: u8 = 3;
</code></pre>



<a id="0x1_poc_registry_DEFAULT_EFFECTIVE_WEIGHT_PBS"></a>

Default effective weight in basis points (10000 = 100%)


<pre><code><b>const</b> <a href="poc_registry.md#0x1_poc_registry_DEFAULT_EFFECTIVE_WEIGHT_PBS">DEFAULT_EFFECTIVE_WEIGHT_PBS</a>: u64 = 10000;
</code></pre>



<a id="0x1_poc_registry_EAPP_ADDRESS_ALREADY_EXISTS"></a>

This contract deployment address is already occupied by another registered application


<pre><code><b>const</b> <a href="poc_registry.md#0x1_poc_registry_EAPP_ADDRESS_ALREADY_EXISTS">EAPP_ADDRESS_ALREADY_EXISTS</a>: u64 = 3;
</code></pre>



<a id="0x1_poc_registry_EAPP_ADDRESS_NOT_FOUND"></a>

No registration record found for this contract deployment address


<pre><code><b>const</b> <a href="poc_registry.md#0x1_poc_registry_EAPP_ADDRESS_NOT_FOUND">EAPP_ADDRESS_NOT_FOUND</a>: u64 = 7;
</code></pre>



<a id="0x1_poc_registry_EAPP_ADMIN_ALREADY_EXISTS"></a>

An application is already registered under this admin address; duplicate registration not allowed


<pre><code><b>const</b> <a href="poc_registry.md#0x1_poc_registry_EAPP_ADMIN_ALREADY_EXISTS">EAPP_ADMIN_ALREADY_EXISTS</a>: u64 = 2;
</code></pre>



<a id="0x1_poc_registry_EAPP_ADMIN_NOT_FOUND"></a>

No registration record found for this admin address


<pre><code><b>const</b> <a href="poc_registry.md#0x1_poc_registry_EAPP_ADMIN_NOT_FOUND">EAPP_ADMIN_NOT_FOUND</a>: u64 = 6;
</code></pre>



<a id="0x1_poc_registry_EAPP_NOT_ACTIVE"></a>

Application is not currently in ACTIVE state; trusted contribution events cannot be emitted


<pre><code><b>const</b> <a href="poc_registry.md#0x1_poc_registry_EAPP_NOT_ACTIVE">EAPP_NOT_ACTIVE</a>: u64 = 12;
</code></pre>



<a id="0x1_poc_registry_EAPP_NOT_WHITELISTED_FOR_POC"></a>

Application has not been whitelisted for POC; trusted contribution events cannot be emitted


<pre><code><b>const</b> <a href="poc_registry.md#0x1_poc_registry_EAPP_NOT_WHITELISTED_FOR_POC">EAPP_NOT_WHITELISTED_FOR_POC</a>: u64 = 13;
</code></pre>



<a id="0x1_poc_registry_EAPP_STOPPED"></a>

Application has been permanently stopped; cannot be resumed


<pre><code><b>const</b> <a href="poc_registry.md#0x1_poc_registry_EAPP_STOPPED">EAPP_STOPPED</a>: u64 = 14;
</code></pre>



<a id="0x1_poc_registry_ECUSTODY_ADDRESS_ALREADY_EXISTS"></a>

This custody address is already bound to another registered application


<pre><code><b>const</b> <a href="poc_registry.md#0x1_poc_registry_ECUSTODY_ADDRESS_ALREADY_EXISTS">ECUSTODY_ADDRESS_ALREADY_EXISTS</a>: u64 = 5;
</code></pre>



<a id="0x1_poc_registry_ECUSTODY_ADDRESS_NOT_FOUND"></a>

No registration record found for this custody address


<pre><code><b>const</b> <a href="poc_registry.md#0x1_poc_registry_ECUSTODY_ADDRESS_NOT_FOUND">ECUSTODY_ADDRESS_NOT_FOUND</a>: u64 = 8;
</code></pre>



<a id="0x1_poc_registry_EEQUITY_TOKEN_ALREADY_EXISTS"></a>

This equity token address is already bound to another registered application


<pre><code><b>const</b> <a href="poc_registry.md#0x1_poc_registry_EEQUITY_TOKEN_ALREADY_EXISTS">EEQUITY_TOKEN_ALREADY_EXISTS</a>: u64 = 4;
</code></pre>



<a id="0x1_poc_registry_EEQUITY_TOKEN_NOT_FOUND"></a>

No registration record found for this equity token address


<pre><code><b>const</b> <a href="poc_registry.md#0x1_poc_registry_EEQUITY_TOKEN_NOT_FOUND">EEQUITY_TOKEN_NOT_FOUND</a>: u64 = 9;
</code></pre>



<a id="0x1_poc_registry_EINVALID_APP_STATE"></a>

Invalid app state value (must be one of APP_STATE_ACTIVE / PAUSED / STOPPED)


<pre><code><b>const</b> <a href="poc_registry.md#0x1_poc_registry_EINVALID_APP_STATE">EINVALID_APP_STATE</a>: u64 = 10;
</code></pre>



<a id="0x1_poc_registry_EINVALID_EFFECTIVE_WEIGHT"></a>

Invalid effective weight value (must be <= MAX_EFFECTIVE_WEIGHT_PBS)


<pre><code><b>const</b> <a href="poc_registry.md#0x1_poc_registry_EINVALID_EFFECTIVE_WEIGHT">EINVALID_EFFECTIVE_WEIGHT</a>: u64 = 15;
</code></pre>



<a id="0x1_poc_registry_EINVALID_POC_LISTING_STATUS"></a>

Invalid POC listing status value (must be one of REGISTERED / WHITELISTED / SUSPENDED)


<pre><code><b>const</b> <a href="poc_registry.md#0x1_poc_registry_EINVALID_POC_LISTING_STATUS">EINVALID_POC_LISTING_STATUS</a>: u64 = 11;
</code></pre>



<a id="0x1_poc_registry_MAX_EFFECTIVE_WEIGHT_PBS"></a>

Maximum effective weight in basis points (10000 = 100%)


<pre><code><b>const</b> <a href="poc_registry.md#0x1_poc_registry_MAX_EFFECTIVE_WEIGHT_PBS">MAX_EFFECTIVE_WEIGHT_PBS</a>: u64 = 10000;
</code></pre>



<a id="0x1_poc_registry_POC_LISTING_STATUS_REGISTERED"></a>



<pre><code><b>const</b> <a href="poc_registry.md#0x1_poc_registry_POC_LISTING_STATUS_REGISTERED">POC_LISTING_STATUS_REGISTERED</a>: u8 = 1;
</code></pre>



<a id="0x1_poc_registry_POC_LISTING_STATUS_SUSPENDED"></a>



<pre><code><b>const</b> <a href="poc_registry.md#0x1_poc_registry_POC_LISTING_STATUS_SUSPENDED">POC_LISTING_STATUS_SUSPENDED</a>: u8 = 3;
</code></pre>



<a id="0x1_poc_registry_POC_LISTING_STATUS_WHITELISTED"></a>



<pre><code><b>const</b> <a href="poc_registry.md#0x1_poc_registry_POC_LISTING_STATUS_WHITELISTED">POC_LISTING_STATUS_WHITELISTED</a>: u8 = 2;
</code></pre>



<a id="0x1_poc_registry_initialize"></a>

## Function `initialize`

Called by the genesis module to initialize the registry at chain genesis.
Only callable by friend modules (genesis).


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_initialize">initialize</a>(topo_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>friend</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_initialize">initialize</a>(topo_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>) {
    <a href="poc_registry.md#0x1_poc_registry_initialize_registry">initialize_registry</a>(topo_framework);
}
</code></pre>



</details>

<a id="0x1_poc_registry_initialize_registry"></a>

## Function `initialize_registry`

Initialize the Registry resource.
Only callable by @topo_framework. Idempotent — skips if already initialized.


<pre><code><b>public</b> entry <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_initialize_registry">initialize_registry</a>(topo_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> entry <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_initialize_registry">initialize_registry</a>(topo_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>) {
    <a href="system_addresses.md#0x1_system_addresses_assert_aptos_framework">system_addresses::assert_aptos_framework</a>(topo_framework);
    <b>if</b> (!<b>exists</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@topo_framework)) {
        <b>move_to</b>(topo_framework, <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
            apps: <a href="../../aptos-stdlib/doc/table.md#0x1_table_new">table::new</a>(),
            app_address_to_admin: <a href="../../aptos-stdlib/doc/table.md#0x1_table_new">table::new</a>(),
            custody_address_to_admin: <a href="../../aptos-stdlib/doc/table.md#0x1_table_new">table::new</a>(),
            equity_token_to_admin: <a href="../../aptos-stdlib/doc/table.md#0x1_table_new">table::new</a>(),
        });
    };
}
</code></pre>



</details>

<a id="0x1_poc_registry_register_app"></a>

## Function `register_app`

Dapp application registration entry point.

Any address may call this function to register as a Dapp application administrator.
After successful registration, the application defaults to ACTIVE state with
POC listing status REGISTERED (not yet whitelisted by the platform).

Uniqueness constraints (all enforced atomically):
- One admin address can only register one application
- app_address / equity_token_address / custody_address must each be globally unique
across all registered applications

The equity_token_address is validated as a real Fungible Asset Metadata object
via <code><a href="object.md#0x1_object_address_to_object">object::address_to_object</a>&lt;Metadata&gt;</code> — this aborts if the address is not
a valid FA metadata object, preventing registration with fake token addresses.

Parameters:
- app_admin: Administrator signer (the caller becomes the admin)
- app_address: Contract deployment address (the on-chain entry module address)
- equity_token_address: Equity token address; must be a valid FA Metadata object
- custody_address: Custody address holding equity tokens pending distribution
- metadata_uri: Application's official website or authoritative information link


<pre><code><b>public</b> entry <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_register_app">register_app</a>(app_admin: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, app_address: <b>address</b>, equity_token_address: <b>address</b>, custody_address: <b>address</b>, metadata_uri: <a href="../../aptos-stdlib/../move-stdlib/doc/string.md#0x1_string_String">string::String</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> entry <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_register_app">register_app</a>(
    app_admin: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>,
    app_address: <b>address</b>,
    equity_token_address: <b>address</b>,
    custody_address: <b>address</b>,
    metadata_uri: String,
) <b>acquires</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
    <b>let</b> app_admin_address = <a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer_address_of">signer::address_of</a>(app_admin);
    <b>assert</b>!(
        <b>exists</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@topo_framework),
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_not_found">error::not_found</a>(<a href="poc_registry.md#0x1_poc_registry_EREGISTRY_NOT_INITIALIZED">EREGISTRY_NOT_INITIALIZED</a>),
    );
    <b>let</b> registry = <b>borrow_global_mut</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@topo_framework);

    <b>assert</b>!(
        !registry.apps.contains(app_admin_address),
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_already_exists">error::already_exists</a>(<a href="poc_registry.md#0x1_poc_registry_EAPP_ADMIN_ALREADY_EXISTS">EAPP_ADMIN_ALREADY_EXISTS</a>),
    );
    <b>assert</b>!(
        !registry.app_address_to_admin.contains(app_address),
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_already_exists">error::already_exists</a>(<a href="poc_registry.md#0x1_poc_registry_EAPP_ADDRESS_ALREADY_EXISTS">EAPP_ADDRESS_ALREADY_EXISTS</a>),
    );
    <b>assert</b>!(
        !registry.custody_address_to_admin.contains(custody_address),
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_already_exists">error::already_exists</a>(<a href="poc_registry.md#0x1_poc_registry_ECUSTODY_ADDRESS_ALREADY_EXISTS">ECUSTODY_ADDRESS_ALREADY_EXISTS</a>),
    );
    <b>assert</b>!(
        !registry.equity_token_to_admin.contains(equity_token_address),
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_already_exists">error::already_exists</a>(<a href="poc_registry.md#0x1_poc_registry_EEQUITY_TOKEN_ALREADY_EXISTS">EEQUITY_TOKEN_ALREADY_EXISTS</a>),
    );

    <a href="object.md#0x1_object_address_to_object">object::address_to_object</a>&lt;Metadata&gt;(equity_token_address);

    <b>let</b> info = <a href="poc_registry.md#0x1_poc_registry_AppInfo">AppInfo</a> {
        app_admin: app_admin_address,
        app_address,
        equity_token_address,
        custody_address,
        app_state: <a href="poc_registry.md#0x1_poc_registry_APP_STATE_ACTIVE">APP_STATE_ACTIVE</a>,
        poc_listing_status: <a href="poc_registry.md#0x1_poc_registry_POC_LISTING_STATUS_REGISTERED">POC_LISTING_STATUS_REGISTERED</a>,
        metadata_uri,
        effective_weight_pbs: <a href="poc_registry.md#0x1_poc_registry_DEFAULT_EFFECTIVE_WEIGHT_PBS">DEFAULT_EFFECTIVE_WEIGHT_PBS</a>,
    };

    registry.apps.add(app_admin_address, info);
    registry.app_address_to_admin.add(app_address, app_admin_address);
    registry.custody_address_to_admin.add(custody_address, app_admin_address);
    registry.equity_token_to_admin.add(equity_token_address, app_admin_address);

    <a href="event.md#0x1_event_emit">event::emit</a>(<a href="poc_registry.md#0x1_poc_registry_AppRegisteredEvent">AppRegisteredEvent</a> {
        app_admin: app_admin_address,
        app_address,
        equity_token_address,
        custody_address,
    });
}
</code></pre>



</details>

<a id="0x1_poc_registry_update_app_address"></a>

## Function `update_app_address`

Update the contract deployment address.

Use case: after a contract upgrade or redeployment, bind the new deployment address
to the same admin. The new address must be globally unique.
Idempotent: if the new address equals the current address, returns immediately.

This does NOT reset poc_listing_status — only equity token changes trigger a reset.


<pre><code><b>public</b> entry <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_update_app_address">update_app_address</a>(app_admin: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, new_app_address: <b>address</b>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> entry <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_update_app_address">update_app_address</a>(
    app_admin: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>,
    new_app_address: <b>address</b>,
) <b>acquires</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
    <b>let</b> app_admin_address = <a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer_address_of">signer::address_of</a>(app_admin);
    <b>let</b> current_info = <a href="poc_registry.md#0x1_poc_registry_get_app_info">get_app_info</a>(app_admin_address);
    <b>if</b> (current_info.app_address == new_app_address) {
        <b>return</b>
    };

    <b>assert</b>!(
        <b>exists</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@topo_framework),
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_not_found">error::not_found</a>(<a href="poc_registry.md#0x1_poc_registry_EREGISTRY_NOT_INITIALIZED">EREGISTRY_NOT_INITIALIZED</a>),
    );
    <b>let</b> registry = <b>borrow_global_mut</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@topo_framework);
    <b>assert</b>!(
        !registry.app_address_to_admin.contains(new_app_address),
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_already_exists">error::already_exists</a>(<a href="poc_registry.md#0x1_poc_registry_EAPP_ADDRESS_ALREADY_EXISTS">EAPP_ADDRESS_ALREADY_EXISTS</a>),
    );

    <b>let</b> old_app_address = current_info.app_address;
    registry.app_address_to_admin.remove(old_app_address);
    registry.app_address_to_admin.add(new_app_address, app_admin_address);

    <b>let</b> info = <a href="poc_registry.md#0x1_poc_registry_borrow_app_info_mut">borrow_app_info_mut</a>(registry, app_admin_address);
    info.app_address = new_app_address;

    <a href="event.md#0x1_event_emit">event::emit</a>(<a href="poc_registry.md#0x1_poc_registry_AppAddressUpdatedEvent">AppAddressUpdatedEvent</a> {
        app_admin: app_admin_address,
        old_app_address,
        new_app_address,
    });
}
</code></pre>



</details>

<a id="0x1_poc_registry_update_equity_token_address"></a>

## Function `update_equity_token_address`

Update the equity token address.

The new address must be a valid FA Metadata object and globally unique.

IMPORTANT SECURITY INVARIANT: Changing the equity token address automatically resets
poc_listing_status to REGISTERED, requiring platform re-review before the app can
regain WHITELISTED status. This is intentional:
- The equity token is the core asset identifier for the application.
- Previous platform audits were conducted against the old token; a new token means
the audit assumptions may no longer hold (different supply, different transfer hooks, etc.).
- Requiring re-review prevents an app from swapping to a malicious token while retaining
its trusted whitelist status.

Idempotent: if the new address equals the current address, returns immediately.


<pre><code><b>public</b> entry <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_update_equity_token_address">update_equity_token_address</a>(app_admin: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, new_equity_token_address: <b>address</b>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> entry <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_update_equity_token_address">update_equity_token_address</a>(
    app_admin: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>,
    new_equity_token_address: <b>address</b>,
) <b>acquires</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
    <b>let</b> app_admin_address = <a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer_address_of">signer::address_of</a>(app_admin);
    <b>let</b> current_info = <a href="poc_registry.md#0x1_poc_registry_get_app_info">get_app_info</a>(app_admin_address);
    <b>if</b> (current_info.equity_token_address == new_equity_token_address) {
        <b>return</b>
    };

    <b>assert</b>!(
        <b>exists</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@topo_framework),
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_not_found">error::not_found</a>(<a href="poc_registry.md#0x1_poc_registry_EREGISTRY_NOT_INITIALIZED">EREGISTRY_NOT_INITIALIZED</a>),
    );
    <b>let</b> registry = <b>borrow_global_mut</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@topo_framework);
    <b>assert</b>!(
        !registry.equity_token_to_admin.contains(new_equity_token_address),
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_already_exists">error::already_exists</a>(<a href="poc_registry.md#0x1_poc_registry_EEQUITY_TOKEN_ALREADY_EXISTS">EEQUITY_TOKEN_ALREADY_EXISTS</a>),
    );
    <a href="object.md#0x1_object_address_to_object">object::address_to_object</a>&lt;Metadata&gt;(new_equity_token_address);

    <b>let</b> old_equity_token_address = current_info.equity_token_address;
    registry.equity_token_to_admin.remove(old_equity_token_address);
    registry.equity_token_to_admin.add(new_equity_token_address, app_admin_address);

    <b>let</b> info = <a href="poc_registry.md#0x1_poc_registry_borrow_app_info_mut">borrow_app_info_mut</a>(registry, app_admin_address);
    info.equity_token_address = new_equity_token_address;

    <a href="event.md#0x1_event_emit">event::emit</a>(<a href="poc_registry.md#0x1_poc_registry_AppEquityTokenUpdatedEvent">AppEquityTokenUpdatedEvent</a> {
        app_admin: app_admin_address,
        old_equity_token_address,
        new_equity_token_address,
    });

    <a href="poc_registry.md#0x1_poc_registry_reset_poc_listing_status_if_needed">reset_poc_listing_status_if_needed</a>(info, app_admin_address);
}
</code></pre>



</details>

<a id="0x1_poc_registry_update_custody_address"></a>

## Function `update_custody_address`

Update the custody address.

The new address must be globally unique across all registered applications.
The custody address is the signer that authorizes token transfers during trusted
contribution events. Changing it does NOT reset poc_listing_status.

Idempotent: if the new address equals the current address, returns immediately.


<pre><code><b>public</b> entry <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_update_custody_address">update_custody_address</a>(app_admin: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, new_custody_address: <b>address</b>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> entry <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_update_custody_address">update_custody_address</a>(
    app_admin: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>,
    new_custody_address: <b>address</b>,
) <b>acquires</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
    <b>let</b> app_admin_address = <a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer_address_of">signer::address_of</a>(app_admin);
    <b>let</b> current_info = <a href="poc_registry.md#0x1_poc_registry_get_app_info">get_app_info</a>(app_admin_address);
    <b>if</b> (current_info.custody_address == new_custody_address) {
        <b>return</b>
    };

    <b>assert</b>!(
        <b>exists</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@topo_framework),
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_not_found">error::not_found</a>(<a href="poc_registry.md#0x1_poc_registry_EREGISTRY_NOT_INITIALIZED">EREGISTRY_NOT_INITIALIZED</a>),
    );
    <b>let</b> registry = <b>borrow_global_mut</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@topo_framework);
    <b>assert</b>!(
        !registry.custody_address_to_admin.contains(new_custody_address),
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_already_exists">error::already_exists</a>(<a href="poc_registry.md#0x1_poc_registry_ECUSTODY_ADDRESS_ALREADY_EXISTS">ECUSTODY_ADDRESS_ALREADY_EXISTS</a>),
    );

    <b>let</b> old_custody_address = current_info.custody_address;
    registry.custody_address_to_admin.remove(old_custody_address);
    registry.custody_address_to_admin.add(new_custody_address, app_admin_address);

    <b>let</b> info = <a href="poc_registry.md#0x1_poc_registry_borrow_app_info_mut">borrow_app_info_mut</a>(registry, app_admin_address);
    info.custody_address = new_custody_address;

    <a href="event.md#0x1_event_emit">event::emit</a>(<a href="poc_registry.md#0x1_poc_registry_AppCustodyUpdatedEvent">AppCustodyUpdatedEvent</a> {
        app_admin: app_admin_address,
        old_custody_address,
        new_custody_address,
    });
}
</code></pre>



</details>

<a id="0x1_poc_registry_pause_app"></a>

## Function `pause_app`

Pause the application. The admin voluntarily suspends operations (e.g., emergency response).

While paused, trusted contribution events cannot be emitted via <code><a href="poc_contribution.md#0x1_poc_contribution">poc_contribution</a></code>.
The application can be resumed via <code>resume_app</code> as long as it has not been permanently stopped.


<pre><code><b>public</b> entry <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_pause_app">pause_app</a>(app_admin: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> entry <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_pause_app">pause_app</a>(app_admin: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>) <b>acquires</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
    <a href="poc_registry.md#0x1_poc_registry_update_app_state">update_app_state</a>(<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer_address_of">signer::address_of</a>(app_admin), <a href="poc_registry.md#0x1_poc_registry_APP_STATE_PAUSED">APP_STATE_PAUSED</a>);
}
</code></pre>



</details>

<a id="0x1_poc_registry_resume_app"></a>

## Function `resume_app`

Resume the application from PAUSED state back to ACTIVE.

Aborts if the application is in STOPPED state — permanent stops cannot be reversed.
This guard prevents accidental resurrection of a stopped application.


<pre><code><b>public</b> entry <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_resume_app">resume_app</a>(app_admin: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> entry <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_resume_app">resume_app</a>(app_admin: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>) <b>acquires</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
    <b>let</b> app_admin_address = <a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer_address_of">signer::address_of</a>(app_admin);
    <b>assert</b>!(
        <a href="poc_registry.md#0x1_poc_registry_get_app_state">get_app_state</a>(app_admin_address) != <a href="poc_registry.md#0x1_poc_registry_APP_STATE_STOPPED">APP_STATE_STOPPED</a>,
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_permission_denied">error::permission_denied</a>(<a href="poc_registry.md#0x1_poc_registry_EAPP_STOPPED">EAPP_STOPPED</a>),
    );
    <a href="poc_registry.md#0x1_poc_registry_update_app_state">update_app_state</a>(app_admin_address, <a href="poc_registry.md#0x1_poc_registry_APP_STATE_ACTIVE">APP_STATE_ACTIVE</a>);
}
</code></pre>



</details>

<a id="0x1_poc_registry_stop_app"></a>

## Function `stop_app`

Permanently stop the application. This operation is irreversible.

Once stopped, the application cannot be restored to ACTIVE or PAUSED state.
Use this only when the application is being permanently decommissioned.


<pre><code><b>public</b> entry <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_stop_app">stop_app</a>(app_admin: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> entry <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_stop_app">stop_app</a>(app_admin: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>) <b>acquires</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
    <a href="poc_registry.md#0x1_poc_registry_update_app_state">update_app_state</a>(<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer_address_of">signer::address_of</a>(app_admin), <a href="poc_registry.md#0x1_poc_registry_APP_STATE_STOPPED">APP_STATE_STOPPED</a>);
}
</code></pre>



</details>

<a id="0x1_poc_registry_set_poc_listing_status"></a>

## Function `set_poc_listing_status`

Set the POC inclusion status for an application.

Only callable by @topo_framework (currently centralized governance; can be migrated to DAO later).
Valid values: REGISTERED / WHITELISTED / SUSPENDED.

This is the master setter; <code>whitelist_app_for_poc</code> and <code>suspend_poc_listing</code> are
convenience wrappers around this function.


<pre><code><b>public</b> entry <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_set_poc_listing_status">set_poc_listing_status</a>(topo_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, app_admin: <b>address</b>, new_poc_listing_status: u8)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> entry <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_set_poc_listing_status">set_poc_listing_status</a>(
    topo_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>,
    app_admin: <b>address</b>,
    new_poc_listing_status: u8,
) <b>acquires</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
    <a href="system_addresses.md#0x1_system_addresses_assert_aptos_framework">system_addresses::assert_aptos_framework</a>(topo_framework);
    <a href="poc_registry.md#0x1_poc_registry_assert_valid_poc_listing_status">assert_valid_poc_listing_status</a>(new_poc_listing_status);
    <a href="poc_registry.md#0x1_poc_registry_update_poc_listing_status">update_poc_listing_status</a>(app_admin, new_poc_listing_status);
}
</code></pre>



</details>

<a id="0x1_poc_registry_suspend_poc_listing"></a>

## Function `suspend_poc_listing`

Suspend an application's POC inclusion (e.g., suspected fraud, under investigation).

While suspended, the application's contribution events are NOT counted toward POC power.
The suspension can be lifted by calling <code>whitelist_app_for_poc</code> after investigation.
Only callable by @topo_framework.


<pre><code><b>public</b> entry <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_suspend_poc_listing">suspend_poc_listing</a>(topo_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, app_admin: <b>address</b>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> entry <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_suspend_poc_listing">suspend_poc_listing</a>(
    topo_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>,
    app_admin: <b>address</b>,
) <b>acquires</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
    <a href="poc_registry.md#0x1_poc_registry_set_poc_listing_status">set_poc_listing_status</a>(topo_framework, app_admin, <a href="poc_registry.md#0x1_poc_registry_POC_LISTING_STATUS_SUSPENDED">POC_LISTING_STATUS_SUSPENDED</a>);
}
</code></pre>



</details>

<a id="0x1_poc_registry_whitelist_app_for_poc"></a>

## Function `whitelist_app_for_poc`

Add an application to the POC whitelist (WHITELISTED / active state).

After whitelisting, contribution events emitted by this application are scanned
by off-chain indexers and counted toward POC power, which can participate in governance voting.
Only callable by @topo_framework.


<pre><code><b>public</b> entry <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_whitelist_app_for_poc">whitelist_app_for_poc</a>(topo_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, app_admin: <b>address</b>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> entry <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_whitelist_app_for_poc">whitelist_app_for_poc</a>(
    topo_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>,
    app_admin: <b>address</b>,
) <b>acquires</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
    <a href="poc_registry.md#0x1_poc_registry_set_poc_listing_status">set_poc_listing_status</a>(topo_framework, app_admin, <a href="poc_registry.md#0x1_poc_registry_POC_LISTING_STATUS_WHITELISTED">POC_LISTING_STATUS_WHITELISTED</a>);
}
</code></pre>



</details>

<a id="0x1_poc_registry_set_effective_weight_pbs"></a>

## Function `set_effective_weight_pbs`

Set the effective weight for an application (in per-basis-points, 0–10000).

Only callable by @topo_framework (DAO governance).
10000 means 100% weight (full contribution counted); 5000 means 50%, etc.
Idempotent: if the new value equals the current value, returns without emitting an event.


<pre><code><b>public</b> entry <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_set_effective_weight_pbs">set_effective_weight_pbs</a>(topo_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, app_admin: <b>address</b>, new_effective_weight_pbs: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> entry <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_set_effective_weight_pbs">set_effective_weight_pbs</a>(
    topo_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>,
    app_admin: <b>address</b>,
    new_effective_weight_pbs: u64,
) <b>acquires</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
    <a href="system_addresses.md#0x1_system_addresses_assert_aptos_framework">system_addresses::assert_aptos_framework</a>(topo_framework);
    <b>assert</b>!(
        new_effective_weight_pbs &lt;= <a href="poc_registry.md#0x1_poc_registry_MAX_EFFECTIVE_WEIGHT_PBS">MAX_EFFECTIVE_WEIGHT_PBS</a>,
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_invalid_argument">error::invalid_argument</a>(<a href="poc_registry.md#0x1_poc_registry_EINVALID_EFFECTIVE_WEIGHT">EINVALID_EFFECTIVE_WEIGHT</a>),
    );
    <b>assert</b>!(
        <b>exists</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@topo_framework),
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_not_found">error::not_found</a>(<a href="poc_registry.md#0x1_poc_registry_EREGISTRY_NOT_INITIALIZED">EREGISTRY_NOT_INITIALIZED</a>),
    );
    <b>let</b> registry = <b>borrow_global_mut</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@topo_framework);
    <b>let</b> info = <a href="poc_registry.md#0x1_poc_registry_borrow_app_info_mut">borrow_app_info_mut</a>(registry, app_admin);
    <b>let</b> old_effective_weight_pbs = info.effective_weight_pbs;
    <b>if</b> (old_effective_weight_pbs == new_effective_weight_pbs) {
        <b>return</b>
    };

    info.effective_weight_pbs = new_effective_weight_pbs;

    <a href="event.md#0x1_event_emit">event::emit</a>(<a href="poc_registry.md#0x1_poc_registry_AppEffectiveWeightUpdatedEvent">AppEffectiveWeightUpdatedEvent</a> {
        app_admin,
        old_effective_weight_pbs,
        new_effective_weight_pbs,
    });
}
</code></pre>



</details>

<a id="0x1_poc_registry_exists_app"></a>

## Function `exists_app`

Check whether an application is registered under the given admin address.


<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_exists_app">exists_app</a>(app_admin: <b>address</b>): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_exists_app">exists_app</a>(app_admin: <b>address</b>): bool <b>acquires</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
    <b>if</b> (!<b>exists</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@topo_framework)) {
        <b>return</b> <b>false</b>
    };
    <b>borrow_global</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@topo_framework).apps.contains(app_admin)
}
</code></pre>



</details>

<a id="0x1_poc_registry_exists_apps"></a>

## Function `exists_apps`

Batch-check app registration for caller-provided admin addresses.


<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_exists_apps">exists_apps</a>(app_admins: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;): <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;bool&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_exists_apps">exists_apps</a>(app_admins: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;): <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;bool&gt; <b>acquires</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
    <b>let</b> exists_flags = <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[];
    <b>let</b> len = app_admins.length();
    <b>if</b> (!<b>exists</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@topo_framework)) {
        <b>let</b> i = 0;
        <b>while</b> (i &lt; len) {
            exists_flags.push_back(<b>false</b>);
            i += 1;
        };
        <b>return</b> exists_flags
    };
    <b>let</b> registry = <b>borrow_global</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@topo_framework);
    <b>let</b> i = 0;
    <b>while</b> (i &lt; len) {
        exists_flags.push_back(registry.apps.contains(*app_admins.borrow(i)));
        i += 1;
    };
    exists_flags
}
</code></pre>



</details>

<a id="0x1_poc_registry_get_app_infos_by_admins"></a>

## Function `get_app_infos_by_admins`

Return full app records for explicit admin addresses.


<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_get_app_infos_by_admins">get_app_infos_by_admins</a>(app_admins: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;): <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<a href="poc_registry.md#0x1_poc_registry_AppInfo">poc_registry::AppInfo</a>&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_get_app_infos_by_admins">get_app_infos_by_admins</a>(
    app_admins: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;,
): <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<a href="poc_registry.md#0x1_poc_registry_AppInfo">AppInfo</a>&gt; <b>acquires</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
    <b>if</b> (!<b>exists</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@topo_framework)) {
        <b>return</b> <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[]
    };
    <b>let</b> registry = <b>borrow_global</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@topo_framework);
    <b>let</b> infos = <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[];
    <b>let</b> len = app_admins.length();
    <b>let</b> i = 0;
    <b>while</b> (i &lt; len) {
        <b>let</b> app_admin = *app_admins.borrow(i);
        <b>assert</b>!(
            registry.apps.contains(app_admin),
            <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_not_found">error::not_found</a>(<a href="poc_registry.md#0x1_poc_registry_EAPP_ADMIN_NOT_FOUND">EAPP_ADMIN_NOT_FOUND</a>),
        );
        infos.push_back(*registry.apps.borrow(app_admin));
        i += 1;
    };
    infos
}
</code></pre>



</details>

<a id="0x1_poc_registry_get_app_admins_by_app_addresses"></a>

## Function `get_app_admins_by_app_addresses`

Batch reverse-lookup admin addresses by app contract addresses.
Missing app addresses are returned as @0x0 to keep the batch response total.


<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_get_app_admins_by_app_addresses">get_app_admins_by_app_addresses</a>(app_addresses: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;): <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_get_app_admins_by_app_addresses">get_app_admins_by_app_addresses</a>(
    app_addresses: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;,
): <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt; <b>acquires</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
    <b>let</b> app_admins = <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>[];
    <b>let</b> len = app_addresses.length();
    <b>if</b> (!<b>exists</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@topo_framework)) {
        <b>let</b> i = 0;
        <b>while</b> (i &lt; len) {
            app_admins.push_back(@0x0);
            i += 1;
        };
        <b>return</b> app_admins
    };
    <b>let</b> registry = <b>borrow_global</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@topo_framework);
    <b>let</b> i = 0;
    <b>while</b> (i &lt; len) {
        <b>let</b> app_address = *app_addresses.borrow(i);
        <b>if</b> (registry.app_address_to_admin.contains(app_address)) {
            app_admins.push_back(*registry.app_address_to_admin.borrow(app_address));
        } <b>else</b> {
            app_admins.push_back(@0x0);
        };
        i += 1;
    };
    app_admins
}
</code></pre>



</details>

<a id="0x1_poc_registry_get_app_admin_by_app_address"></a>

## Function `get_app_admin_by_app_address`

Reverse-lookup: get admin address from contract deployment address.

Aborts if the registry is not initialized or the address is not registered.
Used by <code><a href="poc_contribution.md#0x1_poc_contribution">poc_contribution</a></code> in the trusted contribution path to resolve
app_signer → app_admin → equity_token / custody_address.


<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_get_app_admin_by_app_address">get_app_admin_by_app_address</a>(app_address: <b>address</b>): <b>address</b>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_get_app_admin_by_app_address">get_app_admin_by_app_address</a>(
    app_address: <b>address</b>,
): <b>address</b> <b>acquires</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
    <b>assert</b>!(
        <b>exists</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@topo_framework),
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_not_found">error::not_found</a>(<a href="poc_registry.md#0x1_poc_registry_EREGISTRY_NOT_INITIALIZED">EREGISTRY_NOT_INITIALIZED</a>),
    );
    <b>let</b> registry = <b>borrow_global</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@topo_framework);
    <b>assert</b>!(
        registry.app_address_to_admin.contains(app_address),
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_not_found">error::not_found</a>(<a href="poc_registry.md#0x1_poc_registry_EAPP_ADDRESS_NOT_FOUND">EAPP_ADDRESS_NOT_FOUND</a>),
    );
    *registry.app_address_to_admin.borrow(app_address)
}
</code></pre>



</details>

<a id="0x1_poc_registry_get_app_admin_by_custody_address"></a>

## Function `get_app_admin_by_custody_address`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_get_app_admin_by_custody_address">get_app_admin_by_custody_address</a>(custody_address: <b>address</b>): <b>address</b>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_get_app_admin_by_custody_address">get_app_admin_by_custody_address</a>(
        custody_address: <b>address</b>,
    ): <b>address</b> <b>acquires</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
        <b>assert</b>!(
            <b>exists</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@topo_framework),
            <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_not_found">error::not_found</a>(<a href="poc_registry.md#0x1_poc_registry_EREGISTRY_NOT_INITIALIZED">EREGISTRY_NOT_INITIALIZED</a>),
        );
        <b>let</b> registry = <b>borrow_global</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@topo_framework);
        <b>assert</b>!(
            registry.custody_address_to_admin.contains(custody_address),
            <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_not_found">error::not_found</a>(<a href="poc_registry.md#0x1_poc_registry_ECUSTODY_ADDRESS_NOT_FOUND">ECUSTODY_ADDRESS_NOT_FOUND</a>),
        );
        *registry.custody_address_to_admin.borrow(custody_address)
    }
</code></pre>



</details>

<a id="0x1_poc_registry_get_app_admin_by_equity_token"></a>

## Function `get_app_admin_by_equity_token`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_get_app_admin_by_equity_token">get_app_admin_by_equity_token</a>(equity_token_address: <b>address</b>): <b>address</b>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_get_app_admin_by_equity_token">get_app_admin_by_equity_token</a>(
        equity_token_address: <b>address</b>,
    ): <b>address</b> <b>acquires</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
        <b>assert</b>!(
            <b>exists</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@topo_framework),
            <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_not_found">error::not_found</a>(<a href="poc_registry.md#0x1_poc_registry_EREGISTRY_NOT_INITIALIZED">EREGISTRY_NOT_INITIALIZED</a>),
        );
        <b>let</b> registry = <b>borrow_global</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@topo_framework);
        <b>assert</b>!(
            registry.equity_token_to_admin.contains(equity_token_address),
            <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_not_found">error::not_found</a>(<a href="poc_registry.md#0x1_poc_registry_EEQUITY_TOKEN_NOT_FOUND">EEQUITY_TOKEN_NOT_FOUND</a>),
        );
        *registry.equity_token_to_admin.borrow(equity_token_address)
    }
</code></pre>



</details>

<a id="0x1_poc_registry_get_app_info"></a>

## Function `get_app_info`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_get_app_info">get_app_info</a>(app_admin: <b>address</b>): <a href="poc_registry.md#0x1_poc_registry_AppInfo">poc_registry::AppInfo</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_get_app_info">get_app_info</a>(app_admin: <b>address</b>): <a href="poc_registry.md#0x1_poc_registry_AppInfo">AppInfo</a> <b>acquires</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
        <b>assert</b>!(
            <b>exists</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@topo_framework),
            <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_not_found">error::not_found</a>(<a href="poc_registry.md#0x1_poc_registry_EREGISTRY_NOT_INITIALIZED">EREGISTRY_NOT_INITIALIZED</a>),
        );
        <b>let</b> registry = <b>borrow_global</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@topo_framework);
        <b>assert</b>!(
            registry.apps.contains(app_admin),
            <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_not_found">error::not_found</a>(<a href="poc_registry.md#0x1_poc_registry_EAPP_ADMIN_NOT_FOUND">EAPP_ADMIN_NOT_FOUND</a>),
        );
        *registry.apps.borrow(app_admin)
    }
</code></pre>



</details>

<a id="0x1_poc_registry_get_app_info_by_app_address"></a>

## Function `get_app_info_by_app_address`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_get_app_info_by_app_address">get_app_info_by_app_address</a>(app_address: <b>address</b>): <a href="poc_registry.md#0x1_poc_registry_AppInfo">poc_registry::AppInfo</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_get_app_info_by_app_address">get_app_info_by_app_address</a>(
        app_address: <b>address</b>,
    ): <a href="poc_registry.md#0x1_poc_registry_AppInfo">AppInfo</a> <b>acquires</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
        <a href="poc_registry.md#0x1_poc_registry_get_app_info">get_app_info</a>(<a href="poc_registry.md#0x1_poc_registry_get_app_admin_by_app_address">get_app_admin_by_app_address</a>(app_address))
    }
</code></pre>



</details>

<a id="0x1_poc_registry_get_app_address"></a>

## Function `get_app_address`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_get_app_address">get_app_address</a>(app_admin: <b>address</b>): <b>address</b>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_get_app_address">get_app_address</a>(app_admin: <b>address</b>): <b>address</b> <b>acquires</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
    <a href="poc_registry.md#0x1_poc_registry_get_app_info">get_app_info</a>(app_admin).app_address
}
</code></pre>



</details>

<a id="0x1_poc_registry_get_equity_token_address"></a>

## Function `get_equity_token_address`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_get_equity_token_address">get_equity_token_address</a>(app_admin: <b>address</b>): <b>address</b>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_get_equity_token_address">get_equity_token_address</a>(app_admin: <b>address</b>): <b>address</b> <b>acquires</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
    <a href="poc_registry.md#0x1_poc_registry_get_app_info">get_app_info</a>(app_admin).equity_token_address
}
</code></pre>



</details>

<a id="0x1_poc_registry_get_custody_address"></a>

## Function `get_custody_address`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_get_custody_address">get_custody_address</a>(app_admin: <b>address</b>): <b>address</b>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_get_custody_address">get_custody_address</a>(app_admin: <b>address</b>): <b>address</b> <b>acquires</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
    <a href="poc_registry.md#0x1_poc_registry_get_app_info">get_app_info</a>(app_admin).custody_address
}
</code></pre>



</details>

<a id="0x1_poc_registry_get_app_state"></a>

## Function `get_app_state`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_get_app_state">get_app_state</a>(app_admin: <b>address</b>): u8
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_get_app_state">get_app_state</a>(app_admin: <b>address</b>): u8 <b>acquires</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
    <a href="poc_registry.md#0x1_poc_registry_get_app_info">get_app_info</a>(app_admin).app_state
}
</code></pre>



</details>

<a id="0x1_poc_registry_get_poc_listing_status"></a>

## Function `get_poc_listing_status`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_get_poc_listing_status">get_poc_listing_status</a>(app_admin: <b>address</b>): u8
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_get_poc_listing_status">get_poc_listing_status</a>(app_admin: <b>address</b>): u8 <b>acquires</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
    <a href="poc_registry.md#0x1_poc_registry_get_app_info">get_app_info</a>(app_admin).poc_listing_status
}
</code></pre>



</details>

<a id="0x1_poc_registry_get_metadata_uri"></a>

## Function `get_metadata_uri`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_get_metadata_uri">get_metadata_uri</a>(app_admin: <b>address</b>): <a href="../../aptos-stdlib/../move-stdlib/doc/string.md#0x1_string_String">string::String</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_get_metadata_uri">get_metadata_uri</a>(app_admin: <b>address</b>): String <b>acquires</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
    <a href="poc_registry.md#0x1_poc_registry_get_app_info">get_app_info</a>(app_admin).metadata_uri
}
</code></pre>



</details>

<a id="0x1_poc_registry_get_effective_weight_pbs"></a>

## Function `get_effective_weight_pbs`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_get_effective_weight_pbs">get_effective_weight_pbs</a>(app_admin: <b>address</b>): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_get_effective_weight_pbs">get_effective_weight_pbs</a>(app_admin: <b>address</b>): u64 <b>acquires</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
    <a href="poc_registry.md#0x1_poc_registry_get_app_info">get_app_info</a>(app_admin).effective_weight_pbs
}
</code></pre>



</details>

<a id="0x1_poc_registry_is_app_active"></a>

## Function `is_app_active`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_is_app_active">is_app_active</a>(app_admin: <b>address</b>): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_is_app_active">is_app_active</a>(app_admin: <b>address</b>): bool <b>acquires</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
        <b>if</b> (!<a href="poc_registry.md#0x1_poc_registry_exists_app">exists_app</a>(app_admin)) {
            <b>return</b> <b>false</b>
        };
        <a href="poc_registry.md#0x1_poc_registry_get_app_state">get_app_state</a>(app_admin) == <a href="poc_registry.md#0x1_poc_registry_APP_STATE_ACTIVE">APP_STATE_ACTIVE</a>
    }
</code></pre>



</details>

<a id="0x1_poc_registry_is_poc_listed"></a>

## Function `is_poc_listed`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_is_poc_listed">is_poc_listed</a>(app_admin: <b>address</b>): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_is_poc_listed">is_poc_listed</a>(app_admin: <b>address</b>): bool <b>acquires</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
        <b>if</b> (!<a href="poc_registry.md#0x1_poc_registry_exists_app">exists_app</a>(app_admin)) {
            <b>return</b> <b>false</b>
        };
        <a href="poc_registry.md#0x1_poc_registry_get_poc_listing_status">get_poc_listing_status</a>(app_admin) == <a href="poc_registry.md#0x1_poc_registry_POC_LISTING_STATUS_WHITELISTED">POC_LISTING_STATUS_WHITELISTED</a>
    }
</code></pre>



</details>

<a id="0x1_poc_registry_is_app_eligible_for_poc"></a>

## Function `is_app_eligible_for_poc`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_is_app_eligible_for_poc">is_app_eligible_for_poc</a>(app_admin: <b>address</b>): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_is_app_eligible_for_poc">is_app_eligible_for_poc</a>(app_admin: <b>address</b>): bool <b>acquires</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
        <b>if</b> (!<a href="poc_registry.md#0x1_poc_registry_exists_app">exists_app</a>(app_admin)) {
            <b>return</b> <b>false</b>
        };
        <b>let</b> info = <a href="poc_registry.md#0x1_poc_registry_get_app_info">get_app_info</a>(app_admin);
        info.app_state == <a href="poc_registry.md#0x1_poc_registry_APP_STATE_ACTIVE">APP_STATE_ACTIVE</a> &&
            info.poc_listing_status == <a href="poc_registry.md#0x1_poc_registry_POC_LISTING_STATUS_WHITELISTED">POC_LISTING_STATUS_WHITELISTED</a>
    }
</code></pre>



</details>

<a id="0x1_poc_registry_borrow_app_info_mut"></a>

## Function `borrow_app_info_mut`

Borrow a mutable reference to an AppInfo entry by admin address (internal use only).
Aborts if the admin address is not found in the registry.


<pre><code><b>fun</b> <a href="poc_registry.md#0x1_poc_registry_borrow_app_info_mut">borrow_app_info_mut</a>(registry: &<b>mut</b> <a href="poc_registry.md#0x1_poc_registry_Registry">poc_registry::Registry</a>, app_admin: <b>address</b>): &<b>mut</b> <a href="poc_registry.md#0x1_poc_registry_AppInfo">poc_registry::AppInfo</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="poc_registry.md#0x1_poc_registry_borrow_app_info_mut">borrow_app_info_mut</a>(
    registry: &<b>mut</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>,
    app_admin: <b>address</b>,
): &<b>mut</b> <a href="poc_registry.md#0x1_poc_registry_AppInfo">AppInfo</a> {
    <b>assert</b>!(
        registry.apps.contains(app_admin),
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_not_found">error::not_found</a>(<a href="poc_registry.md#0x1_poc_registry_EAPP_ADMIN_NOT_FOUND">EAPP_ADMIN_NOT_FOUND</a>),
    );
    registry.apps.borrow_mut(app_admin)
}
</code></pre>



</details>

<a id="0x1_poc_registry_update_app_state"></a>

## Function `update_app_state`

Update the application's self-managed operational state (internal use only).
Idempotent: if the new state equals the current state, returns without emitting an event.


<pre><code><b>fun</b> <a href="poc_registry.md#0x1_poc_registry_update_app_state">update_app_state</a>(app_admin: <b>address</b>, new_app_state: u8)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="poc_registry.md#0x1_poc_registry_update_app_state">update_app_state</a>(
    app_admin: <b>address</b>,
    new_app_state: u8,
) <b>acquires</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
    <a href="poc_registry.md#0x1_poc_registry_assert_valid_app_state">assert_valid_app_state</a>(new_app_state);
    <b>assert</b>!(
        <b>exists</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@topo_framework),
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_not_found">error::not_found</a>(<a href="poc_registry.md#0x1_poc_registry_EREGISTRY_NOT_INITIALIZED">EREGISTRY_NOT_INITIALIZED</a>),
    );
    <b>let</b> registry = <b>borrow_global_mut</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@topo_framework);
    <b>let</b> info = <a href="poc_registry.md#0x1_poc_registry_borrow_app_info_mut">borrow_app_info_mut</a>(registry, app_admin);
    <b>let</b> old_app_state = info.app_state;
    <b>if</b> (old_app_state == new_app_state) {
        <b>return</b>
    };

    info.app_state = new_app_state;

    <a href="event.md#0x1_event_emit">event::emit</a>(<a href="poc_registry.md#0x1_poc_registry_AppStateChangedEvent">AppStateChangedEvent</a> {
        app_admin,
        old_app_state,
        new_app_state,
    });
}
</code></pre>



</details>

<a id="0x1_poc_registry_update_poc_listing_status"></a>

## Function `update_poc_listing_status`

Update the platform POC inclusion status (internal use only).
Idempotent: if the new status equals the current status, returns without emitting an event.


<pre><code><b>fun</b> <a href="poc_registry.md#0x1_poc_registry_update_poc_listing_status">update_poc_listing_status</a>(app_admin: <b>address</b>, new_poc_listing_status: u8)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="poc_registry.md#0x1_poc_registry_update_poc_listing_status">update_poc_listing_status</a>(
    app_admin: <b>address</b>,
    new_poc_listing_status: u8,
) <b>acquires</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
    <b>assert</b>!(
        <b>exists</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@topo_framework),
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_not_found">error::not_found</a>(<a href="poc_registry.md#0x1_poc_registry_EREGISTRY_NOT_INITIALIZED">EREGISTRY_NOT_INITIALIZED</a>),
    );
    <b>let</b> registry = <b>borrow_global_mut</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@topo_framework);
    <b>let</b> info = <a href="poc_registry.md#0x1_poc_registry_borrow_app_info_mut">borrow_app_info_mut</a>(registry, app_admin);
    <b>let</b> old_poc_listing_status = info.poc_listing_status;
    <b>if</b> (old_poc_listing_status == new_poc_listing_status) {
        <b>return</b>
    };

    info.poc_listing_status = new_poc_listing_status;

    <a href="event.md#0x1_event_emit">event::emit</a>(<a href="poc_registry.md#0x1_poc_registry_AppPocListingStatusChangedEvent">AppPocListingStatusChangedEvent</a> {
        app_admin,
        old_poc_listing_status,
        new_poc_listing_status,
    });
}
</code></pre>



</details>

<a id="0x1_poc_registry_reset_poc_listing_status_if_needed"></a>

## Function `reset_poc_listing_status_if_needed`

Auto-reset POC inclusion status to REGISTERED after an equity token address change (internal use only).

Skips if the current status is already REGISTERED.

Design intent: the equity token is the core asset identifier for the application.
When it changes, previous platform audit assumptions may no longer hold
(different supply cap, different transfer hooks, different burn mechanics, etc.).
Requiring re-review prevents an app from swapping to a malicious token while
retaining its trusted whitelist status.


<pre><code><b>fun</b> <a href="poc_registry.md#0x1_poc_registry_reset_poc_listing_status_if_needed">reset_poc_listing_status_if_needed</a>(info: &<b>mut</b> <a href="poc_registry.md#0x1_poc_registry_AppInfo">poc_registry::AppInfo</a>, app_admin: <b>address</b>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="poc_registry.md#0x1_poc_registry_reset_poc_listing_status_if_needed">reset_poc_listing_status_if_needed</a>(
    info: &<b>mut</b> <a href="poc_registry.md#0x1_poc_registry_AppInfo">AppInfo</a>,
    app_admin: <b>address</b>,
) {
    <b>let</b> old_poc_listing_status = info.poc_listing_status;
    <b>if</b> (old_poc_listing_status == <a href="poc_registry.md#0x1_poc_registry_POC_LISTING_STATUS_REGISTERED">POC_LISTING_STATUS_REGISTERED</a>) {
        <b>return</b>
    };

    info.poc_listing_status = <a href="poc_registry.md#0x1_poc_registry_POC_LISTING_STATUS_REGISTERED">POC_LISTING_STATUS_REGISTERED</a>;
    <a href="event.md#0x1_event_emit">event::emit</a>(<a href="poc_registry.md#0x1_poc_registry_AppPocListingStatusChangedEvent">AppPocListingStatusChangedEvent</a> {
        app_admin,
        old_poc_listing_status,
        new_poc_listing_status: <a href="poc_registry.md#0x1_poc_registry_POC_LISTING_STATUS_REGISTERED">POC_LISTING_STATUS_REGISTERED</a>,
    });
}
</code></pre>



</details>

<a id="0x1_poc_registry_assert_valid_app_state"></a>

## Function `assert_valid_app_state`

Validate that an app_state value is one of the three legal constants (internal use only).


<pre><code><b>fun</b> <a href="poc_registry.md#0x1_poc_registry_assert_valid_app_state">assert_valid_app_state</a>(app_state: u8)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="poc_registry.md#0x1_poc_registry_assert_valid_app_state">assert_valid_app_state</a>(app_state: u8) {
    <b>assert</b>!(
        app_state == <a href="poc_registry.md#0x1_poc_registry_APP_STATE_ACTIVE">APP_STATE_ACTIVE</a> ||
            app_state == <a href="poc_registry.md#0x1_poc_registry_APP_STATE_PAUSED">APP_STATE_PAUSED</a> ||
            app_state == <a href="poc_registry.md#0x1_poc_registry_APP_STATE_STOPPED">APP_STATE_STOPPED</a>,
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_invalid_argument">error::invalid_argument</a>(<a href="poc_registry.md#0x1_poc_registry_EINVALID_APP_STATE">EINVALID_APP_STATE</a>),
    );
}
</code></pre>



</details>

<a id="0x1_poc_registry_assert_valid_poc_listing_status"></a>

## Function `assert_valid_poc_listing_status`

Validate that a poc_listing_status value is one of the three legal constants (internal use only).


<pre><code><b>fun</b> <a href="poc_registry.md#0x1_poc_registry_assert_valid_poc_listing_status">assert_valid_poc_listing_status</a>(poc_listing_status: u8)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="poc_registry.md#0x1_poc_registry_assert_valid_poc_listing_status">assert_valid_poc_listing_status</a>(poc_listing_status: u8) {
    <b>assert</b>!(
        poc_listing_status == <a href="poc_registry.md#0x1_poc_registry_POC_LISTING_STATUS_REGISTERED">POC_LISTING_STATUS_REGISTERED</a> ||
            poc_listing_status == <a href="poc_registry.md#0x1_poc_registry_POC_LISTING_STATUS_WHITELISTED">POC_LISTING_STATUS_WHITELISTED</a> ||
            poc_listing_status == <a href="poc_registry.md#0x1_poc_registry_POC_LISTING_STATUS_SUSPENDED">POC_LISTING_STATUS_SUSPENDED</a>,
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_invalid_argument">error::invalid_argument</a>(<a href="poc_registry.md#0x1_poc_registry_EINVALID_POC_LISTING_STATUS">EINVALID_POC_LISTING_STATUS</a>),
    );
}
</code></pre>



</details>


[move-book]: https://aptos.dev/move/book/SUMMARY
