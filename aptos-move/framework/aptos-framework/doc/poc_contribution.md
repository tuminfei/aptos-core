
<a id="0x1_poc_contribution"></a>

# Module `0x1::poc_contribution`

POC Trusted Contribution Emission Contract — the sole trusted path for emitting contribution events.


<a id="@Overview_0"></a>

### Overview


This module is the execution entry point for the Topo chain's POC (Proof of Contribution) system.
It integrates equity token transfer + registry validation + contribution event emission into a
single atomic function call.


<a id="@Core_Design_Principle:_Non-Interference_with_Application_Business_Logic_1"></a>

### Core Design Principle: Non-Interference with Application Business Logic


The equity token transfer ALWAYS executes, regardless of POC validation results.
Validation results only determine whether a <code><a href="poc_contribution.md#0x1_poc_contribution_ContributionEvent">ContributionEvent</a></code> is emitted.
This means:
- A failed validation never blocks the token transfer (the user always receives their tokens)
- Only the POC power accounting is affected by validation failures
- Applications can safely call this function without worrying about POC validation
causing unexpected transaction failures


<a id="@Why_This_Module_Exists_(Trust_Boundary)_2"></a>

### Why This Module Exists (Trust Boundary)


Without this module, any Dapp could emit arbitrary <code><a href="poc_contribution.md#0x1_poc_contribution_ContributionEvent">ContributionEvent</a></code>s to inflate
their users' POC power. This module enforces that:
1. A real equity token transfer occurred in the same transaction
2. The application is registered in poc_registry and currently ACTIVE
3. The application has been whitelisted by the platform (WHITELISTED status)
4. The custody signer matches the registered custody address (prevents impersonation)
5. All key asset parameters (equity token address, custody address) come from the
registry — they are NOT trusted from external input


<a id="@Call_Pattern_3"></a>

### Call Pattern


This module's core function is <code><b>public</b> <b>fun</b></code> (not <code>entry <b>fun</b></code>). Dapp applications
must call it from within their own <code>entry <b>fun</b></code>. This design allows off-chain indexers
to attribute contribution events to specific applications by inspecting the transaction
payload's entry module address.


<a id="@Typical_Call_Sequence_4"></a>

### Typical Call Sequence


1. User calls the Dapp application's <code>entry <b>fun</b></code> (business entry point)
2. Application completes its own business validation
3. Application generates <code>app_signer</code> (signer for the contract deployment address)
and <code>custody_actor</code> (signer for the custody address)
4. Application calls <code><a href="poc_contribution.md#0x1_poc_contribution_grant_equity_with_contribution">grant_equity_with_contribution</a>(app_signer, custody_actor, contributor, equity_amount)</code>
5. This module executes the equity token transfer (always, regardless of validation)
6. This module validates app identity, POC eligibility, and custody address from the registry
7. If all validations pass → emit <code><a href="poc_contribution.md#0x1_poc_contribution_ContributionEvent">ContributionEvent</a></code>; otherwise → no event, transfer already done


<a id="@Behavioral_Guarantees_5"></a>

### Behavioral Guarantees


- Transfer fails → transaction aborts (transfer errors still propagate normally)
- Transfer succeeds but validation fails → transfer takes effect, no event emitted
- Transfer succeeds and validation passes → transfer takes effect, <code><a href="poc_contribution.md#0x1_poc_contribution_ContributionEvent">ContributionEvent</a></code> emitted


    -  [Overview](#@Overview_0)
    -  [Core Design Principle: Non-Interference with Application Business Logic](#@Core_Design_Principle:_Non-Interference_with_Application_Business_Logic_1)
    -  [Why This Module Exists (Trust Boundary)](#@Why_This_Module_Exists_(Trust_Boundary)_2)
    -  [Call Pattern](#@Call_Pattern_3)
    -  [Typical Call Sequence](#@Typical_Call_Sequence_4)
    -  [Behavioral Guarantees](#@Behavioral_Guarantees_5)
-  [Struct `ContributionEvent`](#0x1_poc_contribution_ContributionEvent)
-  [Constants](#@Constants_6)
-  [Function `grant_equity_with_contribution`](#0x1_poc_contribution_grant_equity_with_contribution)


<pre><code><b>use</b> <a href="event.md#0x1_event">0x1::event</a>;
<b>use</b> <a href="fungible_asset.md#0x1_fungible_asset">0x1::fungible_asset</a>;
<b>use</b> <a href="object.md#0x1_object">0x1::object</a>;
<b>use</b> <a href="poc_registry.md#0x1_poc_registry">0x1::poc_registry</a>;
<b>use</b> <a href="primary_fungible_store.md#0x1_primary_fungible_store">0x1::primary_fungible_store</a>;
<b>use</b> <a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">0x1::signer</a>;
</code></pre>



<a id="0x1_poc_contribution_ContributionEvent"></a>

## Struct `ContributionEvent`

Trusted contribution event — the protocol boundary of the POC power system.

This event signifies: this module has completed a registry-validated standard equity
distribution within the current transaction. The recipient is <code>contributor</code> and the
platform-recognized target received amount is <code>equity_amount</code>.

Sources of trustworthiness:
- Event is emitted by the <code><a href="poc_contribution.md#0x1_poc_contribution">poc_contribution</a></code> module (not by the application itself)
- Event is only emitted after a real token transfer has succeeded
- Key asset parameters (equity_token, custody_address) come from the registry, not external input
- Off-chain indexers can cross-validate against the FA transfer event in the same transaction

Off-chain indexers use this event to:
1. Identify which application made the contribution (via app_address)
2. Record the contributor's equity receipt for POC power calculation
3. Aggregate contribution data across periods for the operator to upload to poc_power_store


<pre><code>#[<a href="event.md#0x1_event">event</a>]
<b>struct</b> <a href="poc_contribution.md#0x1_poc_contribution_ContributionEvent">ContributionEvent</a> <b>has</b> drop, store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>contributor: <b>address</b></code>
</dt>
<dd>
 The address that received the equity tokens (the contributor being rewarded)
</dd>
<dt>
<code>equity_token: <a href="object.md#0x1_object_Object">object::Object</a>&lt;<a href="fungible_asset.md#0x1_fungible_asset_Metadata">fungible_asset::Metadata</a>&gt;</code>
</dt>
<dd>
 The Fungible Asset metadata object for the equity token transferred
</dd>
<dt>
<code>equity_amount: u64</code>
</dt>
<dd>
 The amount of equity tokens transferred (guaranteed to be the minimum received amount)
</dd>
<dt>
<code>app_address: <b>address</b></code>
</dt>
<dd>
 The application's contract deployment address (used for off-chain attribution)
</dd>
</dl>


</details>

<a id="@Constants_6"></a>

## Constants


<a id="0x1_poc_contribution_EZERO_AMOUNT"></a>

Equity amount must be greater than zero


<pre><code><b>const</b> <a href="poc_contribution.md#0x1_poc_contribution_EZERO_AMOUNT">EZERO_AMOUNT</a>: u64 = 1;
</code></pre>



<a id="0x1_poc_contribution_grant_equity_with_contribution"></a>

## Function `grant_equity_with_contribution`

Trusted contribution distribution — transfer + validate + conditionally emit event.

This is the ONLY entry point through which a Dapp application can emit a
platform-recognized contribution event.

Core principle: non-interference with application business logic.
- Equity token transfer always executes, regardless of POC validation results
- Validation results only determine whether a ContributionEvent is emitted
- If validation fails, the transfer still completes; only the POC record is absent

Execution flow:
1. Assert equity_amount > 0 (pre-condition for the transfer; aborts if violated)
2. Resolve equity_token from registry using app_signer's address (not from caller input)
3. Execute equity token transfer via transfer_assert_minimum_deposit (always executes)
4. Check POC eligibility: app must be ACTIVE and WHITELISTED
5. If eligible: verify custody_actor's address matches the registered custody address
6. If both checks pass → emit ContributionEvent; otherwise → no event, transfer already done

Parameters:
- app_signer: Signer for the Dapp application's contract deployment address.
Typically generated by the application via SignerCapability for a resource account.
Used to look up the app's registration in poc_registry.
- custody_actor: Signer for the custody address that holds equity tokens pending distribution.
Typically generated by the application via SignerCapability for a custody resource account.
Must match the custody_address registered in poc_registry.
- contributor: The recipient address for the equity tokens (the user being rewarded)
- equity_amount: The number of equity token units to transfer

Why use transfer_assert_minimum_deposit instead of a plain transfer?
- Some Fungible Assets may have dispatchable hooks, transfer fees, or special deposit logic
that cause the actual received amount to differ from the requested amount.
- The platform's recognized contribution amount must equal the minimum amount the user
actually receives — not the amount requested.
- Without the minimum deposit assertion, ContributionEvent.equity_amount could exceed
the true received amount, inflating POC power calculations.


<pre><code><b>public</b> <b>fun</b> <a href="poc_contribution.md#0x1_poc_contribution_grant_equity_with_contribution">grant_equity_with_contribution</a>(app_signer: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, custody_actor: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, contributor: <b>address</b>, equity_amount: u64)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="poc_contribution.md#0x1_poc_contribution_grant_equity_with_contribution">grant_equity_with_contribution</a>(
    app_signer: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>,
    custody_actor: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>,
    contributor: <b>address</b>,
    equity_amount: u64,
) {
    // Step 1: Validate equity_amount &gt; 0.
    // This is a hard pre-condition: a zero-amount transfer is meaningless and
    // would produce a misleading <a href="poc_contribution.md#0x1_poc_contribution_ContributionEvent">ContributionEvent</a> <b>with</b> equity_amount = 0.
    <b>assert</b>!(equity_amount &gt; 0, <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_invalid_argument">error::invalid_argument</a>(<a href="poc_contribution.md#0x1_poc_contribution_EZERO_AMOUNT">EZERO_AMOUNT</a>));

    // Step 2: Resolve the equity token from the registry and execute the transfer.
    //
    // Key security property: the equity_token_address is read from <a href="poc_registry.md#0x1_poc_registry">poc_registry</a>
    // using the app_signer's <b>address</b> <b>as</b> the lookup key — it is NOT accepted <b>as</b> a
    // parameter from the caller. This prevents a malicious app from passing a
    // different token <b>address</b> <b>to</b> transfer a cheaper token <b>while</b> claiming credit
    // for a more valuable one.
    //
    // transfer_assert_minimum_deposit is used instead of a plain transfer <b>to</b>
    // guarantee that the actual received amount equals equity_amount. If the FA
    // <b>has</b> hooks or fees that reduce the received amount, the transaction aborts
    // rather than emitting a <a href="poc_contribution.md#0x1_poc_contribution_ContributionEvent">ContributionEvent</a> <b>with</b> an inflated equity_amount.
    <b>let</b> app_address = <a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer_address_of">signer::address_of</a>(app_signer);
    <b>let</b> app_admin = <a href="poc_registry.md#0x1_poc_registry_get_app_admin_by_app_address">poc_registry::get_app_admin_by_app_address</a>(app_address);
    <b>let</b> equity_token_address = <a href="poc_registry.md#0x1_poc_registry_get_equity_token_address">poc_registry::get_equity_token_address</a>(app_admin);
    <b>let</b> metadata = <a href="object.md#0x1_object_address_to_object">object::address_to_object</a>&lt;Metadata&gt;(equity_token_address);
    <a href="primary_fungible_store.md#0x1_primary_fungible_store_transfer_assert_minimum_deposit">primary_fungible_store::transfer_assert_minimum_deposit</a>(
        custody_actor,
        metadata,
        contributor,
        equity_amount,
        equity_amount,
    );

    // Step 3: Conditionally emit <a href="poc_contribution.md#0x1_poc_contribution_ContributionEvent">ContributionEvent</a> based on POC eligibility checks.
    //
    // This <a href="block.md#0x1_block">block</a> only affects whether the <a href="event.md#0x1_event">event</a> is emitted — the transfer above
    // <b>has</b> already completed and cannot be rolled back by anything in this <a href="block.md#0x1_block">block</a>.
    //
    // Two checks must both pass:
    // a) is_app_eligible_for_poc: app_state == ACTIVE && poc_listing_status == WHITELISTED
    //    If the app is paused, stopped, or not yet whitelisted, no <a href="event.md#0x1_event">event</a> is emitted.
    // b) custody <b>address</b> match: the actual <a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a> of custody_actor must equal the
    //    custody_address registered in <a href="poc_registry.md#0x1_poc_registry">poc_registry</a>. This prevents a whitelisted app
    //    from using an unregistered custody <a href="account.md#0x1_account">account</a> <b>to</b> emit contribution events.
    <b>if</b> (<a href="poc_registry.md#0x1_poc_registry_is_app_eligible_for_poc">poc_registry::is_app_eligible_for_poc</a>(app_admin)) {
        <b>let</b> registered_custody_address = <a href="poc_registry.md#0x1_poc_registry_get_custody_address">poc_registry::get_custody_address</a>(app_admin);
        <b>let</b> actual_custody_address = <a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer_address_of">signer::address_of</a>(custody_actor);
        <b>if</b> (actual_custody_address == registered_custody_address) {
            <a href="event.md#0x1_event_emit">event::emit</a>(<a href="poc_contribution.md#0x1_poc_contribution_ContributionEvent">ContributionEvent</a> {
                contributor,
                equity_token: metadata,
                equity_amount,
                app_address
            });
        };
    };
}
</code></pre>



</details>


[move-book]: https://aptos.dev/move/book/SUMMARY
