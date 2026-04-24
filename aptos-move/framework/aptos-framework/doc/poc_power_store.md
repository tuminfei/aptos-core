
<a id="0x1_poc_power_store"></a>

# Module `0x1::poc_power_store`

POC 算力存储合约 —— 只负责保存用户当前算力值并发出更新事件

设计边界：
- 链下服务负责计算最终算力结果
- 链上只保存 <code>user -&gt; power</code> 和最后更新周期
- 更新时发出事件
- 链下自行查询用户值或事件，确认写入是否成功
- 不负责周期终局、批次幂等、治理、共识等语义
- 为防止乱序写回，旧周期写入不会覆盖链上已存在的新周期结果


-  [Resource `PowerStore`](#0x1_poc_power_store_PowerStore)
-  [Struct `UserPowerInfo`](#0x1_poc_power_store_UserPowerInfo)
-  [Struct `OperatorChangedEvent`](#0x1_poc_power_store_OperatorChangedEvent)
-  [Struct `PowerUpdatedEvent`](#0x1_poc_power_store_PowerUpdatedEvent)
-  [Constants](#@Constants_0)
-  [Function `initialize`](#0x1_poc_power_store_initialize)
-  [Function `initialize_power_store`](#0x1_poc_power_store_initialize_power_store)
-  [Function `set_operator`](#0x1_poc_power_store_set_operator)
-  [Function `batch_update`](#0x1_poc_power_store_batch_update)
-  [Function `get_power_deciamls`](#0x1_poc_power_store_get_power_deciamls)
-  [Function `get_user_power`](#0x1_poc_power_store_get_user_power)
-  [Function `get_user_power_info`](#0x1_poc_power_store_get_user_power_info)
-  [Function `get_operator`](#0x1_poc_power_store_get_operator)
-  [Function `assert_store_exists`](#0x1_poc_power_store_assert_store_exists)
-  [Function `assert_operator`](#0x1_poc_power_store_assert_operator)
-  [Function `upsert_user_power_if_not_stale`](#0x1_poc_power_store_upsert_user_power_if_not_stale)
-  [Function `empty_user_power_info`](#0x1_poc_power_store_empty_user_power_info)


<pre><code><b>use</b> <a href="event.md#0x1_event">0x1::event</a>;
<b>use</b> <a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">0x1::signer</a>;
<b>use</b> <a href="system_addresses.md#0x1_system_addresses">0x1::system_addresses</a>;
<b>use</b> <a href="../../aptos-stdlib/doc/table.md#0x1_table">0x1::table</a>;
</code></pre>



<a id="0x1_poc_power_store_PowerStore"></a>

## Resource `PowerStore`

全局算力存储，挂在 @aptos_framework 地址下。


<pre><code><b>struct</b> <a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a> <b>has</b> key
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>operator: <b>address</b></code>
</dt>
<dd>
 唯一写入者
</dd>
<dt>
<code>users: <a href="../../aptos-stdlib/doc/table.md#0x1_table_Table">table::Table</a>&lt;<b>address</b>, <a href="poc_power_store.md#0x1_poc_power_store_UserPowerInfo">poc_power_store::UserPowerInfo</a>&gt;</code>
</dt>
<dd>
 用户当前最新算力
</dd>
</dl>


</details>

<a id="0x1_poc_power_store_UserPowerInfo"></a>

## Struct `UserPowerInfo`

用户当前算力信息。


<pre><code><b>struct</b> <a href="poc_power_store.md#0x1_poc_power_store_UserPowerInfo">UserPowerInfo</a> <b>has</b> <b>copy</b>, drop, store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>power: u128</code>
</dt>
<dd>

</dd>
<dt>
<code>last_updated_period: u64</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a id="0x1_poc_power_store_OperatorChangedEvent"></a>

## Struct `OperatorChangedEvent`



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

<a id="0x1_poc_power_store_PowerUpdatedEvent"></a>

## Struct `PowerUpdatedEvent`



<pre><code>#[<a href="event.md#0x1_event">event</a>]
<b>struct</b> <a href="poc_power_store.md#0x1_poc_power_store_PowerUpdatedEvent">PowerUpdatedEvent</a> <b>has</b> drop, store
</code></pre>



<details>
<summary>Fields</summary>


<dl>
<dt>
<code>period: u64</code>
</dt>
<dd>

</dd>
<dt>
<code>user: <b>address</b></code>
</dt>
<dd>

</dd>
<dt>
<code>power: u128</code>
</dt>
<dd>

</dd>
</dl>


</details>

<a id="@Constants_0"></a>

## Constants


<a id="0x1_poc_power_store_ENOT_OPERATOR"></a>

调用者不是唯一 operator


<pre><code><b>const</b> <a href="poc_power_store.md#0x1_poc_power_store_ENOT_OPERATOR">ENOT_OPERATOR</a>: u64 = 2;
</code></pre>



<a id="0x1_poc_power_store_EINVALID_BATCH_LENGTH"></a>

<code>users</code> 与 <code>powers</code> 长度不一致


<pre><code><b>const</b> <a href="poc_power_store.md#0x1_poc_power_store_EINVALID_BATCH_LENGTH">EINVALID_BATCH_LENGTH</a>: u64 = 3;
</code></pre>



<a id="0x1_poc_power_store_ESTORE_NOT_INITIALIZED"></a>

算力存储尚未初始化


<pre><code><b>const</b> <a href="poc_power_store.md#0x1_poc_power_store_ESTORE_NOT_INITIALIZED">ESTORE_NOT_INITIALIZED</a>: u64 = 1;
</code></pre>



<a id="0x1_poc_power_store_POWER_DECIMALS"></a>



<pre><code><b>const</b> <a href="poc_power_store.md#0x1_poc_power_store_POWER_DECIMALS">POWER_DECIMALS</a>: u64 = 18;
</code></pre>



<a id="0x1_poc_power_store_initialize"></a>

## Function `initialize`

由 genesis 调用的 friend 初始化入口。


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_initialize">initialize</a>(aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, operator: <b>address</b>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b>(<b>friend</b>) <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_initialize">initialize</a>(aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, operator: <b>address</b>) {
    <a href="poc_power_store.md#0x1_poc_power_store_initialize_power_store">initialize_power_store</a>(aptos_framework, operator);
}
</code></pre>



</details>

<a id="0x1_poc_power_store_initialize_power_store"></a>

## Function `initialize_power_store`

初始化全局算力存储。
仅限 @aptos_framework 地址调用，幂等执行。


<pre><code><b>public</b> entry <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_initialize_power_store">initialize_power_store</a>(aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, operator: <b>address</b>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> entry <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_initialize_power_store">initialize_power_store</a>(
    aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>,
    operator: <b>address</b>,
) {
    <a href="system_addresses.md#0x1_system_addresses_assert_aptos_framework">system_addresses::assert_aptos_framework</a>(aptos_framework);
    <b>if</b> (!<b>exists</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>&gt;(@aptos_framework)) {
        <b>move_to</b>(aptos_framework, <a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a> {
            operator,
            users: <a href="../../aptos-stdlib/doc/table.md#0x1_table_new">table::new</a>(),
        });
    };
}
</code></pre>



</details>

<a id="0x1_poc_power_store_set_operator"></a>

## Function `set_operator`

更新唯一 operator 地址。
仅限 @aptos_framework 调用；新旧地址相同则幂等返回。


<pre><code><b>public</b> entry <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_set_operator">set_operator</a>(aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, new_operator: <b>address</b>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> entry <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_set_operator">set_operator</a>(
    aptos_framework: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>,
    new_operator: <b>address</b>,
) <b>acquires</b> <a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a> {
    <a href="system_addresses.md#0x1_system_addresses_assert_aptos_framework">system_addresses::assert_aptos_framework</a>(aptos_framework);
    <a href="poc_power_store.md#0x1_poc_power_store_assert_store_exists">assert_store_exists</a>();

    <b>let</b> store = <b>borrow_global_mut</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>&gt;(@aptos_framework);
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

<a id="0x1_poc_power_store_batch_update"></a>

## Function `batch_update`

批量更新用户算力。

说明：
- 本模块不做链上批次幂等
- 同一用户被再次写入时：
- 若 <code>period &gt;= last_updated_period</code>，则覆盖旧值和最后更新周期
- 若 <code>period &lt; last_updated_period</code>，则跳过该用户，防止旧周期回退覆盖
- 只有实际发生写入的用户才会发出 <code><a href="poc_power_store.md#0x1_poc_power_store_PowerUpdatedEvent">PowerUpdatedEvent</a></code>


<pre><code><b>public</b> entry <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_batch_update">batch_update</a>(operator: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>, period: u64, users: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;, powers: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u128&gt;)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> entry <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_batch_update">batch_update</a>(
        operator: &<a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer">signer</a>,
        period: u64,
        users: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;<b>address</b>&gt;,
        powers: <a href="../../aptos-stdlib/../move-stdlib/doc/vector.md#0x1_vector">vector</a>&lt;u128&gt;,
    ) <b>acquires</b> <a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a> {
        <a href="poc_power_store.md#0x1_poc_power_store_assert_store_exists">assert_store_exists</a>();
        <b>assert</b>!(
            users.length() == powers.length(),
            <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_invalid_argument">error::invalid_argument</a>(<a href="poc_power_store.md#0x1_poc_power_store_EINVALID_BATCH_LENGTH">EINVALID_BATCH_LENGTH</a>),
        );

        <b>let</b> store = <b>borrow_global_mut</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>&gt;(@aptos_framework);
        <a href="poc_power_store.md#0x1_poc_power_store_assert_operator">assert_operator</a>(store, <a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer_address_of">signer::address_of</a>(operator));

        <b>let</b> length = users.length();
        <b>let</b> i = 0;
        <b>while</b> (i &lt; length) {
            <b>let</b> user = *users.borrow(i);
            <b>let</b> power = *powers.borrow(i);
            <b>if</b> (<a href="poc_power_store.md#0x1_poc_power_store_upsert_user_power_if_not_stale">upsert_user_power_if_not_stale</a>(store, user, power, period)) {
                <a href="event.md#0x1_event_emit">event::emit</a>(<a href="poc_power_store.md#0x1_poc_power_store_PowerUpdatedEvent">PowerUpdatedEvent</a> { period, user, power });
            };
            i += 1;
        };
    }
</code></pre>



</details>

<a id="0x1_poc_power_store_get_power_deciamls"></a>

## Function `get_power_deciamls`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_get_power_deciamls">get_power_deciamls</a>(): u64
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_get_power_deciamls">get_power_deciamls</a>(): u64 {
    <a href="poc_power_store.md#0x1_poc_power_store_POWER_DECIMALS">POWER_DECIMALS</a>
}
</code></pre>



</details>

<a id="0x1_poc_power_store_get_user_power"></a>

## Function `get_user_power`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_get_user_power">get_user_power</a>(user: <b>address</b>): u128
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_get_user_power">get_user_power</a>(user: <b>address</b>): u128 <b>acquires</b> <a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a> {
        <a href="poc_power_store.md#0x1_poc_power_store_get_user_power_info">get_user_power_info</a>(user).power
    }
</code></pre>



</details>

<a id="0x1_poc_power_store_get_user_power_info"></a>

## Function `get_user_power_info`



<pre><code>#[view]
<b>public</b> <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_get_user_power_info">get_user_power_info</a>(user: <b>address</b>): <a href="poc_power_store.md#0x1_poc_power_store_UserPowerInfo">poc_power_store::UserPowerInfo</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>public</b> <b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_get_user_power_info">get_user_power_info</a>(user: <b>address</b>): <a href="poc_power_store.md#0x1_poc_power_store_UserPowerInfo">UserPowerInfo</a> <b>acquires</b> <a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a> {
        <b>if</b> (!<b>exists</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>&gt;(@aptos_framework)) {
            <b>return</b> <a href="poc_power_store.md#0x1_poc_power_store_empty_user_power_info">empty_user_power_info</a>()
        };
        <b>let</b> store = <b>borrow_global</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>&gt;(@aptos_framework);
        <b>if</b> (!store.users.contains(user)) {
            <b>return</b> <a href="poc_power_store.md#0x1_poc_power_store_empty_user_power_info">empty_user_power_info</a>()
        };
        *store.users.borrow(user)
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
    <b>if</b> (!<b>exists</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>&gt;(@aptos_framework)) {
        <b>return</b> @0x0
    };
    <b>borrow_global</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>&gt;(@aptos_framework).operator
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
        <b>exists</b>&lt;<a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>&gt;(@aptos_framework),
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_not_found">error::not_found</a>(<a href="poc_power_store.md#0x1_poc_power_store_ESTORE_NOT_INITIALIZED">ESTORE_NOT_INITIALIZED</a>),
    );
}
</code></pre>



</details>

<a id="0x1_poc_power_store_assert_operator"></a>

## Function `assert_operator`



<pre><code><b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_assert_operator">assert_operator</a>(store: &<a href="poc_power_store.md#0x1_poc_power_store_PowerStore">poc_power_store::PowerStore</a>, caller: <b>address</b>)
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_assert_operator">assert_operator</a>(store: &<a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>, caller: <b>address</b>) {
    <b>assert</b>!(
        store.operator == caller,
        <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_permission_denied">error::permission_denied</a>(<a href="poc_power_store.md#0x1_poc_power_store_ENOT_OPERATOR">ENOT_OPERATOR</a>),
    );
}
</code></pre>



</details>

<a id="0x1_poc_power_store_upsert_user_power_if_not_stale"></a>

## Function `upsert_user_power_if_not_stale`



<pre><code><b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_upsert_user_power_if_not_stale">upsert_user_power_if_not_stale</a>(store: &<b>mut</b> <a href="poc_power_store.md#0x1_poc_power_store_PowerStore">poc_power_store::PowerStore</a>, user: <b>address</b>, power: u128, period: u64): bool
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_upsert_user_power_if_not_stale">upsert_user_power_if_not_stale</a>(
    store: &<b>mut</b> <a href="poc_power_store.md#0x1_poc_power_store_PowerStore">PowerStore</a>,
    user: <b>address</b>,
    power: u128,
    period: u64,
): bool {
    <b>if</b> (store.users.contains(user)) {
        <b>let</b> info = store.users.borrow_mut(user);
        <b>if</b> (period &lt; info.last_updated_period) {
            <b>return</b> <b>false</b>
        };
        info.power = power;
        info.last_updated_period = period;
        <b>true</b>
    } <b>else</b> {
        store.users.add(user, <a href="poc_power_store.md#0x1_poc_power_store_UserPowerInfo">UserPowerInfo</a> {
            power,
            last_updated_period: period,
        });
        <b>true</b>
    }
}
</code></pre>



</details>

<a id="0x1_poc_power_store_empty_user_power_info"></a>

## Function `empty_user_power_info`



<pre><code><b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_empty_user_power_info">empty_user_power_info</a>(): <a href="poc_power_store.md#0x1_poc_power_store_UserPowerInfo">poc_power_store::UserPowerInfo</a>
</code></pre>



<details>
<summary>Implementation</summary>


<pre><code><b>fun</b> <a href="poc_power_store.md#0x1_poc_power_store_empty_user_power_info">empty_user_power_info</a>(): <a href="poc_power_store.md#0x1_poc_power_store_UserPowerInfo">UserPowerInfo</a> {
    <a href="poc_power_store.md#0x1_poc_power_store_UserPowerInfo">UserPowerInfo</a> {
        power: 0,
        last_updated_period: 0,
    }
}
</code></pre>



</details>


[move-book]: https://aptos.dev/move/book/SUMMARY
