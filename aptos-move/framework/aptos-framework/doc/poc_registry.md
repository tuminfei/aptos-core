
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
-  [Function `exists_app`](#0x1_poc_registry_exists_app)
-  [Function `resolve_app_admin_by_app_address`](#0x1_poc_registry_resolve_app_admin_by_app_address)
-  [Function `resolve_app_admin_by_custody_address`](#0x1_poc_registry_resolve_app_admin_by_custody_address)
-  [Function `resolve_app_admin_by_equity_token`](#0x1_poc_registry_resolve_app_admin_by_equity_token)
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
-  [Function `get_metadata_uri_by_app_address`](#0x1_poc_registry_get_metadata_uri_by_app_address)
-  [Function `is_app_active`](#0x1_poc_registry_is_app_active)
-  [Function `is_poc_listed`](#0x1_poc_registry_is_poc_listed)
-  [Function `is_app_eligible_for_poc`](#0x1_poc_registry_is_app_eligible_for_poc)
-  [Function `assert_app_eligible_for_poc`](#0x1_poc_registry_assert_app_eligible_for_poc)
-  [Function `borrow_app_info_mut`](#0x1_poc_registry_borrow_app_info_mut)
-  [Function `update_app_state`](#0x1_poc_registry_update_app_state)
-  [Function `update_poc_listing_status`](#0x1_poc_registry_update_poc_listing_status)
-  [Function `reset_poc_listing_status_if_needed`](#0x1_poc_registry_reset_poc_listing_status_if_needed)
-  [Function `assert_valid_app_state`](#0x1_poc_registry_assert_valid_app_state)
-  [Function `assert_valid_poc_listing_status`](#0x1_poc_registry_assert_valid_poc_listing_status)


<pre><code><b>use</b> <a href="event.md#0x1_event">0x1::event</a>;
<b>use</b> <a href="fungible_asset.md#0x1_fungible_asset">0x1::fungible_asset</a>;
<b>use</b> <a href="object.md#0x1_object">0x1::object</a>;
<b>use</b> <a href="../../aptos-stdlib/../move-stdlib/doc/option.md#0x1_option">0x1::option</a>;
<b>use</b> <a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">0x1::signer</a>;
<b>use</b> <a href="../../aptos-stdlib/../move-stdlib/doc/string.md#0x1_string">0x1::string</a>;
<b>use</b> <a href="system_addresses.md#0x1_system_addresses">0x1::system_addresses</a>;
<b>use</b> <a href="../../aptos-stdlib/doc/table.md#0x1_table">0x1::table</a>;
</code></pre>



<a id="0x1_poc_registry_Registry"></a>

## Resource `Registry`



<pre><code><b>struct</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> <b>has</b> key
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>apps: <a href="../../aptos-stdlib/doc/table.md#0x1_table_Table">table::Table</a>&lt;<b>address</b>, <a href="poc_registry.md#0x1_poc_registry_AppInfo">poc_registry::AppInfo</a>&gt;</code>
</dt>
<dd>

</dd>
<dt>
<code>app_address_to_admin: <a href="../../aptos-stdlib/doc/table.md#0x1_table_Table">table::Table</a>&lt;<b>address</b>, <b>address</b>&gt;</code>
</dt>
<dd>

</dd>
<dt>
<code>custody_address_to_admin: <a href="../../aptos-stdlib/doc/table.md#0x1_table_Table">table::Table</a>&lt;<b>address</b>, <b>address</b>&gt;</code>
</dt>
<dd>

</dd>
<dt>
<code>equity_token_to_admin: <a href="../../aptos-stdlib/doc/table.md#0x1_table_Table">table::Table</a>&lt;<b>address</b>, <b>address</b>&gt;</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a id="0x1_poc_registry_AppInfo"></a>

## Struct `AppInfo`



<pre><code><b>struct</b> <a href="poc_registry.md#0x1_poc_registry_AppInfo">AppInfo</a> <b>has</b> <b>copy</b>, drop, store
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
<dt>
<code>app_state: u8</code>
</dt>
<dd>

</dd>
<dt>
<code>poc_listing_status: u8</code>
</dt>
<dd>

</dd>
<dt>
<code>metadata_uri: <a href="../../aptos-stdlib/../move-stdlib/doc/string.md#0x1_string_String">string::String</a></code>
</dt>
<dd>

</dd>
</dl>


</details>

<a id="0x1_poc_registry_AppRegisteredEvent"></a>

## Struct `AppRegisteredEvent`



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

<a id="@Constants_0"></a>

## Constants


<a id="0x1_poc_registry_APP_STATE_ACTIVE"></a>



<pre><code><b>const</b> <a href="poc_registry.md#0x1_poc_registry_APP_STATE_ACTIVE">APP_STATE_ACTIVE</a>: u8 = 1;
</code></pre>



<a id="0x1_poc_registry_APP_STATE_PAUSED"></a>



<pre><code><b>const</b> <a href="poc_registry.md#0x1_poc_registry_APP_STATE_PAUSED">APP_STATE_PAUSED</a>: u8 = 2;
</code></pre>



<a id="0x1_poc_registry_APP_STATE_STOPPED"></a>



<pre><code><b>const</b> <a href="poc_registry.md#0x1_poc_registry_APP_STATE_STOPPED">APP_STATE_STOPPED</a>: u8 = 3;
</code></pre>



<a id="0x1_poc_registry_EAPP_ADDRESS_ALREADY_EXISTS"></a>



<pre><code><b>const</b> <a href="poc_registry.md#0x1_poc_registry_EAPP_ADDRESS_ALREADY_EXISTS">EAPP_ADDRESS_ALREADY_EXISTS</a>: u64 = 3;
</code></pre>



<a id="0x1_poc_registry_EAPP_ADDRESS_NOT_FOUND"></a>



<pre><code><b>const</b> <a href="poc_registry.md#0x1_poc_registry_EAPP_ADDRESS_NOT_FOUND">EAPP_ADDRESS_NOT_FOUND</a>: u64 = 7;
</code></pre>



<a id="0x1_poc_registry_EAPP_ADMIN_ALREADY_EXISTS"></a>



<pre><code><b>const</b> <a href="poc_registry.md#0x1_poc_registry_EAPP_ADMIN_ALREADY_EXISTS">EAPP_ADMIN_ALREADY_EXISTS</a>: u64 = 2;
</code></pre>



<a id="0x1_poc_registry_EAPP_ADMIN_NOT_FOUND"></a>



<pre><code><b>const</b> <a href="poc_registry.md#0x1_poc_registry_EAPP_ADMIN_NOT_FOUND">EAPP_ADMIN_NOT_FOUND</a>: u64 = 6;
</code></pre>



<a id="0x1_poc_registry_EAPP_NOT_ACTIVE"></a>



<pre><code><b>const</b> <a href="poc_registry.md#0x1_poc_registry_EAPP_NOT_ACTIVE">EAPP_NOT_ACTIVE</a>: u64 = 12;
</code></pre>



<a id="0x1_poc_registry_EAPP_NOT_WHITELISTED_FOR_POC"></a>



<pre><code><b>const</b> <a href="poc_registry.md#0x1_poc_registry_EAPP_NOT_WHITELISTED_FOR_POC">EAPP_NOT_WHITELISTED_FOR_POC</a>: u64 = 13;
</code></pre>



<a id="0x1_poc_registry_EAPP_STOPPED"></a>



<pre><code><b>const</b> <a href="poc_registry.md#0x1_poc_registry_EAPP_STOPPED">EAPP_STOPPED</a>: u64 = 14;
</code></pre>



<a id="0x1_poc_registry_ECUSTODY_ADDRESS_ALREADY_EXISTS"></a>



<pre><code><b>const</b> <a href="poc_registry.md#0x1_poc_registry_ECUSTODY_ADDRESS_ALREADY_EXISTS">ECUSTODY_ADDRESS_ALREADY_EXISTS</a>: u64 = 5;
</code></pre>



<a id="0x1_poc_registry_ECUSTODY_ADDRESS_NOT_FOUND"></a>



<pre><code><b>const</b> <a href="poc_registry.md#0x1_poc_registry_ECUSTODY_ADDRESS_NOT_FOUND">ECUSTODY_ADDRESS_NOT_FOUND</a>: u64 = 8;
</code></pre>



<a id="0x1_poc_registry_EEQUITY_TOKEN_ALREADY_EXISTS"></a>



<pre><code><b>const</b> <a href="poc_registry.md#0x1_poc_registry_EEQUITY_TOKEN_ALREADY_EXISTS">EEQUITY_TOKEN_ALREADY_EXISTS</a>: u64 = 4;
</code></pre>



<a id="0x1_poc_registry_EEQUITY_TOKEN_NOT_FOUND"></a>



<pre><code><b>const</b> <a href="poc_registry.md#0x1_poc_registry_EEQUITY_TOKEN_NOT_FOUND">EEQUITY_TOKEN_NOT_FOUND</a>: u64 = 9;
</code></pre>



<a id="0x1_poc_registry_EINVALID_APP_STATE"></a>



<pre><code><b>const</b> <a href="poc_registry.md#0x1_poc_registry_EINVALID_APP_STATE">EINVALID_APP_STATE</a>: u64 = 10;
</code></pre>



<a id="0x1_poc_registry_EINVALID_POC_LISTING_STATUS"></a>



<pre><code><b>const</b> <a href="poc_registry.md#0x1_poc_registry_EINVALID_POC_LISTING_STATUS">EINVALID_POC_LISTING_STATUS</a>: u64 = 11;
</code></pre>



<a id="0x1_poc_registry_EREGISTRY_NOT_INITIALIZED"></a>



<pre><code><b>const</b> <a href="poc_registry.md#0x1_poc_registry_EREGISTRY_NOT_INITIALIZED">EREGISTRY_NOT_INITIALIZED</a>: u64 = 1;
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



<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_initialize">initialize</a>(aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_initialize">initialize</a>(aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>) {
        <a href="poc_registry.md#0x1_poc_registry_initialize_registry">initialize_registry</a>(aptos_framework);
    }
</code></pre>



</details>

<a id="0x1_poc_registry_initialize_registry"></a>

## Function `initialize_registry`



<pre><code><b>public</b> entry <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_initialize_registry">initialize_registry</a>(aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> entry <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_initialize_registry">initialize_registry</a>(aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>) {
        <a href="system_addresses.md#0x1_system_addresses_assert_aptos_framework">system_addresses::assert_aptos_framework</a>(aptos_framework);
        <b>if</b> (!<b>exists</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@aptos_framework)) {
            <b>move_to</b>(aptos_framework, <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
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
        <b>exists</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@aptos_framework),
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_not_found">error::not_found</a>(<a href="poc_registry.md#0x1_poc_registry_EREGISTRY_NOT_INITIALIZED">EREGISTRY_NOT_INITIALIZED</a>),
    );
    <b>let</b> registry = <b>borrow_global_mut</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@aptos_framework);

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
        <b>exists</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@aptos_framework),
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_not_found">error::not_found</a>(<a href="poc_registry.md#0x1_poc_registry_EREGISTRY_NOT_INITIALIZED">EREGISTRY_NOT_INITIALIZED</a>),
    );
    <b>let</b> registry = <b>borrow_global_mut</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@aptos_framework);
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
            <b>exists</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@aptos_framework),
            <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_not_found">error::not_found</a>(<a href="poc_registry.md#0x1_poc_registry_EREGISTRY_NOT_INITIALIZED">EREGISTRY_NOT_INITIALIZED</a>),
        );
        <b>let</b> registry = <b>borrow_global_mut</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@aptos_framework);
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
            <b>exists</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@aptos_framework),
            <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_not_found">error::not_found</a>(<a href="poc_registry.md#0x1_poc_registry_EREGISTRY_NOT_INITIALIZED">EREGISTRY_NOT_INITIALIZED</a>),
        );
        <b>let</b> registry = <b>borrow_global_mut</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@aptos_framework);
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



<pre><code><b>public</b> entry <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_set_poc_listing_status">set_poc_listing_status</a>(aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, app_admin: <b>address</b>, new_poc_listing_status: u8)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> entry <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_set_poc_listing_status">set_poc_listing_status</a>(
    aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>,
    app_admin: <b>address</b>,
    new_poc_listing_status: u8,
) <b>acquires</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
    <a href="system_addresses.md#0x1_system_addresses_assert_aptos_framework">system_addresses::assert_aptos_framework</a>(aptos_framework);
    <a href="poc_registry.md#0x1_poc_registry_assert_valid_poc_listing_status">assert_valid_poc_listing_status</a>(new_poc_listing_status);
    <a href="poc_registry.md#0x1_poc_registry_update_poc_listing_status">update_poc_listing_status</a>(app_admin, new_poc_listing_status);
}
</code></pre>



</details>

<a id="0x1_poc_registry_suspend_poc_listing"></a>

## Function `suspend_poc_listing`



<pre><code><b>public</b> entry <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_suspend_poc_listing">suspend_poc_listing</a>(aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, app_admin: <b>address</b>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> entry <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_suspend_poc_listing">suspend_poc_listing</a>(
    aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>,
    app_admin: <b>address</b>,
) <b>acquires</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
    <a href="poc_registry.md#0x1_poc_registry_set_poc_listing_status">set_poc_listing_status</a>(aptos_framework, app_admin, <a href="poc_registry.md#0x1_poc_registry_POC_LISTING_STATUS_SUSPENDED">POC_LISTING_STATUS_SUSPENDED</a>);
}
</code></pre>



</details>

<a id="0x1_poc_registry_whitelist_app_for_poc"></a>

## Function `whitelist_app_for_poc`



<pre><code><b>public</b> entry <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_whitelist_app_for_poc">whitelist_app_for_poc</a>(aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, app_admin: <b>address</b>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> entry <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_whitelist_app_for_poc">whitelist_app_for_poc</a>(
    aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>,
    app_admin: <b>address</b>,
) <b>acquires</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
    <a href="poc_registry.md#0x1_poc_registry_set_poc_listing_status">set_poc_listing_status</a>(aptos_framework, app_admin, <a href="poc_registry.md#0x1_poc_registry_POC_LISTING_STATUS_WHITELISTED">POC_LISTING_STATUS_WHITELISTED</a>);
}
</code></pre>



</details>

<a id="0x1_poc_registry_exists_app"></a>

## Function `exists_app`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_exists_app">exists_app</a>(app_admin: <b>address</b>): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_exists_app">exists_app</a>(app_admin: <b>address</b>): bool <b>acquires</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
        <b>if</b> (!<b>exists</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@aptos_framework)) {
            <b>return</b> <b>false</b>
        };
        <b>borrow_global</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@aptos_framework).apps.contains(app_admin)
    }
</code></pre>



</details>

<a id="0x1_poc_registry_resolve_app_admin_by_app_address"></a>

## Function `resolve_app_admin_by_app_address`



<pre><code><b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_resolve_app_admin_by_app_address">resolve_app_admin_by_app_address</a>(app_address: <b>address</b>): <a href="../../aptos-stdlib/../move-stdlib/doc/option.md#0x1_option_Option">option::Option</a>&lt;<b>address</b>&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_resolve_app_admin_by_app_address">resolve_app_admin_by_app_address</a>(
        app_address: <b>address</b>,
    ): Option&lt;<b>address</b>&gt; <b>acquires</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
        <b>if</b> (!<b>exists</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@aptos_framework)) {
            <b>return</b> <a href="../../aptos-stdlib/../move-stdlib/doc/option.md#0x1_option_none">option::none</a>()
        };

        <b>let</b> registry = <b>borrow_global</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@aptos_framework);
        <b>if</b> (registry.app_address_to_admin.contains(app_address)) {
            <a href="../../aptos-stdlib/../move-stdlib/doc/option.md#0x1_option_some">option::some</a>(*registry.app_address_to_admin.borrow(app_address))
        } <b>else</b> {
            <a href="../../aptos-stdlib/../move-stdlib/doc/option.md#0x1_option_none">option::none</a>()
        }
    }
</code></pre>



</details>

<a id="0x1_poc_registry_resolve_app_admin_by_custody_address"></a>

## Function `resolve_app_admin_by_custody_address`



<pre><code><b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_resolve_app_admin_by_custody_address">resolve_app_admin_by_custody_address</a>(custody_address: <b>address</b>): <a href="../../aptos-stdlib/../move-stdlib/doc/option.md#0x1_option_Option">option::Option</a>&lt;<b>address</b>&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_resolve_app_admin_by_custody_address">resolve_app_admin_by_custody_address</a>(
        custody_address: <b>address</b>,
    ): Option&lt;<b>address</b>&gt; <b>acquires</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
        <b>if</b> (!<b>exists</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@aptos_framework)) {
            <b>return</b> <a href="../../aptos-stdlib/../move-stdlib/doc/option.md#0x1_option_none">option::none</a>()
        };

        <b>let</b> registry = <b>borrow_global</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@aptos_framework);
        <b>if</b> (registry.custody_address_to_admin.contains(custody_address)) {
            <a href="../../aptos-stdlib/../move-stdlib/doc/option.md#0x1_option_some">option::some</a>(*registry.custody_address_to_admin.borrow(custody_address))
        } <b>else</b> {
            <a href="../../aptos-stdlib/../move-stdlib/doc/option.md#0x1_option_none">option::none</a>()
        }
    }
</code></pre>



</details>

<a id="0x1_poc_registry_resolve_app_admin_by_equity_token"></a>

## Function `resolve_app_admin_by_equity_token`



<pre><code><b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_resolve_app_admin_by_equity_token">resolve_app_admin_by_equity_token</a>(equity_token_address: <b>address</b>): <a href="../../aptos-stdlib/../move-stdlib/doc/option.md#0x1_option_Option">option::Option</a>&lt;<b>address</b>&gt;
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_resolve_app_admin_by_equity_token">resolve_app_admin_by_equity_token</a>(
        equity_token_address: <b>address</b>,
    ): Option&lt;<b>address</b>&gt; <b>acquires</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
        <b>if</b> (!<b>exists</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@aptos_framework)) {
            <b>return</b> <a href="../../aptos-stdlib/../move-stdlib/doc/option.md#0x1_option_none">option::none</a>()
        };

        <b>let</b> registry = <b>borrow_global</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@aptos_framework);
        <b>if</b> (registry.equity_token_to_admin.contains(equity_token_address)) {
            <a href="../../aptos-stdlib/../move-stdlib/doc/option.md#0x1_option_some">option::some</a>(*registry.equity_token_to_admin.borrow(equity_token_address))
        } <b>else</b> {
            <a href="../../aptos-stdlib/../move-stdlib/doc/option.md#0x1_option_none">option::none</a>()
        }
    }
</code></pre>



</details>

<a id="0x1_poc_registry_get_app_admin_by_app_address"></a>

## Function `get_app_admin_by_app_address`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_get_app_admin_by_app_address">get_app_admin_by_app_address</a>(app_address: <b>address</b>): <b>address</b>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_get_app_admin_by_app_address">get_app_admin_by_app_address</a>(
        app_address: <b>address</b>,
    ): <b>address</b> <b>acquires</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
        <b>let</b> maybe_app_admin = <a href="poc_registry.md#0x1_poc_registry_resolve_app_admin_by_app_address">resolve_app_admin_by_app_address</a>(app_address);
        <b>assert</b>!(maybe_app_admin.is_some(), <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_not_found">error::not_found</a>(<a href="poc_registry.md#0x1_poc_registry_EAPP_ADDRESS_NOT_FOUND">EAPP_ADDRESS_NOT_FOUND</a>));
        maybe_app_admin.extract()
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
        <b>let</b> maybe_app_admin = <a href="poc_registry.md#0x1_poc_registry_resolve_app_admin_by_custody_address">resolve_app_admin_by_custody_address</a>(custody_address);
        <b>assert</b>!(maybe_app_admin.is_some(), <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_not_found">error::not_found</a>(<a href="poc_registry.md#0x1_poc_registry_ECUSTODY_ADDRESS_NOT_FOUND">ECUSTODY_ADDRESS_NOT_FOUND</a>));
        maybe_app_admin.extract()
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
        <b>let</b> maybe_app_admin = <a href="poc_registry.md#0x1_poc_registry_resolve_app_admin_by_equity_token">resolve_app_admin_by_equity_token</a>(equity_token_address);
        <b>assert</b>!(maybe_app_admin.is_some(), <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_not_found">error::not_found</a>(<a href="poc_registry.md#0x1_poc_registry_EEQUITY_TOKEN_NOT_FOUND">EEQUITY_TOKEN_NOT_FOUND</a>));
        maybe_app_admin.extract()
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
            <b>exists</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@aptos_framework),
            <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_not_found">error::not_found</a>(<a href="poc_registry.md#0x1_poc_registry_EREGISTRY_NOT_INITIALIZED">EREGISTRY_NOT_INITIALIZED</a>),
        );
        <b>let</b> registry = <b>borrow_global</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@aptos_framework);
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

<a id="0x1_poc_registry_get_metadata_uri_by_app_address"></a>

## Function `get_metadata_uri_by_app_address`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_get_metadata_uri_by_app_address">get_metadata_uri_by_app_address</a>(app_address: <b>address</b>): <a href="../../aptos-stdlib/../move-stdlib/doc/string.md#0x1_string_String">string::String</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_get_metadata_uri_by_app_address">get_metadata_uri_by_app_address</a>(
        app_address: <b>address</b>,
    ): String <b>acquires</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
        <a href="poc_registry.md#0x1_poc_registry_get_app_info_by_app_address">get_app_info_by_app_address</a>(app_address).metadata_uri
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

<a id="0x1_poc_registry_assert_app_eligible_for_poc"></a>

## Function `assert_app_eligible_for_poc`



<pre><code><b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_assert_app_eligible_for_poc">assert_app_eligible_for_poc</a>(app_admin: <b>address</b>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="poc_registry.md#0x1_poc_registry_assert_app_eligible_for_poc">assert_app_eligible_for_poc</a>(app_admin: <b>address</b>) <b>acquires</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
    <b>let</b> info = <a href="poc_registry.md#0x1_poc_registry_get_app_info">get_app_info</a>(app_admin);
    <b>assert</b>!(
        info.app_state == <a href="poc_registry.md#0x1_poc_registry_APP_STATE_ACTIVE">APP_STATE_ACTIVE</a>,
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_permission_denied">error::permission_denied</a>(<a href="poc_registry.md#0x1_poc_registry_EAPP_NOT_ACTIVE">EAPP_NOT_ACTIVE</a>),
    );
    <b>assert</b>!(
        info.poc_listing_status == <a href="poc_registry.md#0x1_poc_registry_POC_LISTING_STATUS_WHITELISTED">POC_LISTING_STATUS_WHITELISTED</a>,
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_permission_denied">error::permission_denied</a>(<a href="poc_registry.md#0x1_poc_registry_EAPP_NOT_WHITELISTED_FOR_POC">EAPP_NOT_WHITELISTED_FOR_POC</a>),
    );
}
</code></pre>



</details>

<a id="0x1_poc_registry_borrow_app_info_mut"></a>

## Function `borrow_app_info_mut`



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
            <b>exists</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@aptos_framework),
            <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_not_found">error::not_found</a>(<a href="poc_registry.md#0x1_poc_registry_EREGISTRY_NOT_INITIALIZED">EREGISTRY_NOT_INITIALIZED</a>),
        );
        <b>let</b> registry = <b>borrow_global_mut</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@aptos_framework);
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



<pre><code><b>fun</b> <a href="poc_registry.md#0x1_poc_registry_update_poc_listing_status">update_poc_listing_status</a>(app_admin: <b>address</b>, new_poc_listing_status: u8)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="poc_registry.md#0x1_poc_registry_update_poc_listing_status">update_poc_listing_status</a>(
        app_admin: <b>address</b>,
        new_poc_listing_status: u8,
    ) <b>acquires</b> <a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a> {
        <b>assert</b>!(
            <b>exists</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@aptos_framework),
            <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_not_found">error::not_found</a>(<a href="poc_registry.md#0x1_poc_registry_EREGISTRY_NOT_INITIALIZED">EREGISTRY_NOT_INITIALIZED</a>),
        );
        <b>let</b> registry = <b>borrow_global_mut</b>&lt;<a href="poc_registry.md#0x1_poc_registry_Registry">Registry</a>&gt;(@aptos_framework);
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
