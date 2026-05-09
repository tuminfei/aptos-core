
<a id="0x1_staking_proxy"></a>

# Module `0x1::staking_proxy`



-  [Struct `StakeProxyPermission`](#0x1_staking_proxy_StakeProxyPermission)
-  [Constants](#@Constants_0)
-  [Function `check_stake_proxy_permission`](#0x1_staking_proxy_check_stake_proxy_permission)
-  [Function `grant_permission`](#0x1_staking_proxy_grant_permission)
-  [Function `set_operator`](#0x1_staking_proxy_set_operator)
-  [Function `set_stake_pool_operator`](#0x1_staking_proxy_set_stake_pool_operator)
-  [Specification](#@Specification_1)
    -  [High-level Requirements](#high-level-req)
    -  [Module-level Specification](#module-level-spec)
    -  [Function `grant_permission`](#@Specification_1_grant_permission)
    -  [Function `set_operator`](#@Specification_1_set_operator)
    -  [Function `set_stake_pool_operator`](#@Specification_1_set_stake_pool_operator)


<pre><code><b>use</b> <a href="permissioned_signer.md#0x1_permissioned_signer">0x1::permissioned_signer</a>;
<b>use</b> <a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">0x1::signer</a>;
<b>use</b> <a href="stake.md#0x1_stake">0x1::stake</a>;
</code></pre>



<a id="0x1_staking_proxy_StakeProxyPermission"></a>

## Struct `StakeProxyPermission`



<pre><code><b>struct</b> <a href="staking_proxy.md#0x1_staking_proxy_StakeProxyPermission">StakeProxyPermission</a> <b>has</b> <b>copy</b>, drop, store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>dummy_field: bool</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a id="@Constants_0"></a>

## Constants


<a id="0x1_staking_proxy_ENO_STAKE_PERMISSION"></a>

Signer does not have permission to perform stake proxy logic.


<pre><code><b>const</b> <a href="staking_proxy.md#0x1_staking_proxy_ENO_STAKE_PERMISSION">ENO_STAKE_PERMISSION</a>: u64 = 28;
</code></pre>



<a id="0x1_staking_proxy_check_stake_proxy_permission"></a>

## Function `check_stake_proxy_permission`

Permissions


<pre><code><b>fun</b> <a href="staking_proxy.md#0x1_staking_proxy_check_stake_proxy_permission">check_stake_proxy_permission</a>(s: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code>inline <b>fun</b> <a href="staking_proxy.md#0x1_staking_proxy_check_stake_proxy_permission">check_stake_proxy_permission</a>(s: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>) {
    <b>assert</b>!(
        <a href="permissioned_signer.md#0x1_permissioned_signer_check_permission_exists">permissioned_signer::check_permission_exists</a>(s, <a href="staking_proxy.md#0x1_staking_proxy_StakeProxyPermission">StakeProxyPermission</a> {}),
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_permission_denied">error::permission_denied</a>(<a href="staking_proxy.md#0x1_staking_proxy_ENO_STAKE_PERMISSION">ENO_STAKE_PERMISSION</a>),
    );
}
</code></pre>



</details>

<a id="0x1_staking_proxy_grant_permission"></a>

## Function `grant_permission`

Grant permission to mutate staking on behalf of the master signer.


<pre><code><b>public</b> <b>fun</b> <a href="staking_proxy.md#0x1_staking_proxy_grant_permission">grant_permission</a>(master: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, <a href="permissioned_signer.md#0x1_permissioned_signer">permissioned_signer</a>: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="staking_proxy.md#0x1_staking_proxy_grant_permission">grant_permission</a>(master: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, <a href="permissioned_signer.md#0x1_permissioned_signer">permissioned_signer</a>: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>) {
    <a href="permissioned_signer.md#0x1_permissioned_signer_authorize_unlimited">permissioned_signer::authorize_unlimited</a>(master, <a href="permissioned_signer.md#0x1_permissioned_signer">permissioned_signer</a>, <a href="staking_proxy.md#0x1_staking_proxy_StakeProxyPermission">StakeProxyPermission</a> {})
}
</code></pre>



</details>

<a id="0x1_staking_proxy_set_operator"></a>

## Function `set_operator`



<pre><code><b>public</b> entry <b>fun</b> <a href="staking_proxy.md#0x1_staking_proxy_set_operator">set_operator</a>(owner: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, new_operator: <b>address</b>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> entry <b>fun</b> <a href="staking_proxy.md#0x1_staking_proxy_set_operator">set_operator</a>(owner: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, new_operator: <b>address</b>) {
    <a href="staking_proxy.md#0x1_staking_proxy_set_stake_pool_operator">set_stake_pool_operator</a>(owner, new_operator);
}
</code></pre>



</details>

<a id="0x1_staking_proxy_set_stake_pool_operator"></a>

## Function `set_stake_pool_operator`



<pre><code><b>public</b> entry <b>fun</b> <a href="staking_proxy.md#0x1_staking_proxy_set_stake_pool_operator">set_stake_pool_operator</a>(owner: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, new_operator: <b>address</b>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> entry <b>fun</b> <a href="staking_proxy.md#0x1_staking_proxy_set_stake_pool_operator">set_stake_pool_operator</a>(owner: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, new_operator: <b>address</b>) {
    <a href="staking_proxy.md#0x1_staking_proxy_check_stake_proxy_permission">check_stake_proxy_permission</a>(owner);
    <b>let</b> owner_address = <a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer_address_of">signer::address_of</a>(owner);
    <b>if</b> (<a href="stake.md#0x1_stake_stake_pool_exists">stake::stake_pool_exists</a>(owner_address)) {
        <a href="stake.md#0x1_stake_set_operator">stake::set_operator</a>(owner, new_operator);
    };
}
</code></pre>



</details>

<a id="@Specification_1"></a>

## Specification




<a id="high-level-req"></a>

### High-level Requirements

<table>
<tr>
<th>No.</th><th>Requirement</th><th>Criticality</th><th>Implementation</th><th>Enforcement</th>
</tr>

<tr>
<td>1</td>
<td>When updating the operator through the proxy, the direct stake pool owned by the caller should follow it.</td>
<td>Medium</td>
<td>The proxy updates the direct stake pool owned by the caller.</td>
<td>Spec schemas below constrain the mutation to the direct stake pool path.</td>
</tr>

<tr>
<td>2</td>
<td>Proxy staking mutations should only be available to explicitly authorized permissioned signers.</td>
<td>High</td>
<td>All mutation entrypoints first validate <code><a href="staking_proxy.md#0x1_staking_proxy_StakeProxyPermission">StakeProxyPermission</a></code>.</td>
<td>Spec schemas below gate mutations on the permission check.</td>
</tr>

</table>



<a id="module-level-spec"></a>

### Module-level Specification


<pre><code><b>pragma</b> verify = <b>true</b>;
<b>pragma</b> aborts_if_is_partial;
</code></pre>



<a id="@Specification_1_grant_permission"></a>

### Function `grant_permission`


<pre><code><b>public</b> <b>fun</b> <a href="staking_proxy.md#0x1_staking_proxy_grant_permission">grant_permission</a>(master: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, <a href="permissioned_signer.md#0x1_permissioned_signer">permissioned_signer</a>: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>)
</code></pre>




<pre><code><b>pragma</b> aborts_if_is_partial;
<b>aborts_if</b> !<a href="permissioned_signer.md#0x1_permissioned_signer_spec_is_permissioned_signer">permissioned_signer::spec_is_permissioned_signer</a>(<a href="permissioned_signer.md#0x1_permissioned_signer">permissioned_signer</a>);
<b>aborts_if</b> <a href="permissioned_signer.md#0x1_permissioned_signer_spec_is_permissioned_signer">permissioned_signer::spec_is_permissioned_signer</a>(master);
<b>aborts_if</b> <a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer_address_of">signer::address_of</a>(master) != <a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer_address_of">signer::address_of</a>(<a href="permissioned_signer.md#0x1_permissioned_signer">permissioned_signer</a>);
</code></pre>



<a id="@Specification_1_set_operator"></a>

### Function `set_operator`


<pre><code><b>public</b> entry <b>fun</b> <a href="staking_proxy.md#0x1_staking_proxy_set_operator">set_operator</a>(owner: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, new_operator: <b>address</b>)
</code></pre>




<pre><code><b>pragma</b> aborts_if_is_partial;
<b>include</b> <a href="staking_proxy.md#0x1_staking_proxy_SetStakePoolOperator">SetStakePoolOperator</a>;
</code></pre>



<a id="@Specification_1_set_stake_pool_operator"></a>

### Function `set_stake_pool_operator`


<pre><code><b>public</b> entry <b>fun</b> <a href="staking_proxy.md#0x1_staking_proxy_set_stake_pool_operator">set_stake_pool_operator</a>(owner: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, new_operator: <b>address</b>)
</code></pre>




<pre><code><b>include</b> <a href="staking_proxy.md#0x1_staking_proxy_SetStakePoolOperator">SetStakePoolOperator</a>;
<b>include</b> <b>exists</b>&lt;<a href="stake.md#0x1_stake_StakePool">stake::StakePool</a>&gt;(<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer_address_of">signer::address_of</a>(owner)) ==&gt; <a href="stake.md#0x1_stake_AbortsIfSignerPermissionStake">stake::AbortsIfSignerPermissionStake</a> {
    s: owner
};
</code></pre>




<a id="0x1_staking_proxy_SetStakePoolOperator"></a>


<pre><code><b>schema</b> <a href="staking_proxy.md#0x1_staking_proxy_SetStakePoolOperator">SetStakePoolOperator</a> {
    owner: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>;
    new_operator: <b>address</b>;
    <b>include</b> <a href="staking_proxy.md#0x1_staking_proxy_AbortsIfSignerPermissionStakeProxy">AbortsIfSignerPermissionStakeProxy</a> {
        s: owner
    };
    <b>let</b> owner_address = <a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer_address_of">signer::address_of</a>(owner);
    <b>let</b> ownership_cap = <b>borrow_global</b>&lt;<a href="stake.md#0x1_stake_OwnerCapability">stake::OwnerCapability</a>&gt;(owner_address);
    <b>let</b> pool_address = ownership_cap.pool_address;
    <b>aborts_if</b> <a href="stake.md#0x1_stake_stake_pool_exists">stake::stake_pool_exists</a>(owner_address)
        && !(<b>exists</b>&lt;<a href="stake.md#0x1_stake_OwnerCapability">stake::OwnerCapability</a>&gt;(owner_address) && <a href="stake.md#0x1_stake_stake_pool_exists">stake::stake_pool_exists</a>(pool_address));
    <b>ensures</b> <a href="stake.md#0x1_stake_stake_pool_exists">stake::stake_pool_exists</a>(owner_address)
        ==&gt; <b>global</b>&lt;<a href="stake.md#0x1_stake_StakePool">stake::StakePool</a>&gt;(pool_address).operator_address == new_operator;
}
</code></pre>




<a id="0x1_staking_proxy_AbortsIfSignerPermissionStakeProxy"></a>


<pre><code><b>schema</b> <a href="staking_proxy.md#0x1_staking_proxy_AbortsIfSignerPermissionStakeProxy">AbortsIfSignerPermissionStakeProxy</a> {
    s: <a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>;
    <b>let</b> perm = <a href="staking_proxy.md#0x1_staking_proxy_StakeProxyPermission">StakeProxyPermission</a> {};
    <b>aborts_if</b> !<a href="permissioned_signer.md#0x1_permissioned_signer_spec_check_permission_exists">permissioned_signer::spec_check_permission_exists</a>(s, perm);
}
</code></pre>


[move-book]: https://aptos.dev/move/book/SUMMARY
