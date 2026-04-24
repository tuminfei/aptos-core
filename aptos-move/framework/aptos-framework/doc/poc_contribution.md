
<a id="0x1_poc_contribution"></a>

# Module `0x1::poc_contribution`

POC 可信贡献发放合约 —— 贡献事件的唯一可信发出路径

本模块是 Topo 链 POC（Proof of Contribution）体系的执行入口，
负责把"股权代币转账 + 注册表校验 + 贡献事件发出"整合到一个函数中。

核心设计原则：
- 不干涉应用主业务：股权代币转账始终执行，不受 POC 校验结果影响。
校验结果只决定是否发出 ContributionEvent，不会阻断转账。
- 贡献事件（ContributionEvent）不能由 Dapp 独立应用随意发出，
必须经过本模块提供的核心函数，在完成身份校验和真实转账后才能发出。
- 关键资产参数（股权代币地址、托管地址等）全部从 poc_registry 注册表读取，
不信任外部传入，防止伪造。

调用方式：
- 本模块的核心函数是 <code><b>public</b> <b>fun</b></code>（而非 <code>entry <b>fun</b></code>），
Dapp 独立应用需要在自己的 entry fun 中调用本函数。
这样链下索引器可以通过交易 payload 的入口模块地址做应用归因。

典型调用时序：
1. 用户调用 Dapp 独立应用的 entry fun（业务入口）
2. 应用完成自身业务校验
3. 应用生成 app_signer（合约部署地址的签名者）和 custody_actor（托管地址的签名者）
4. 应用调用 grant_equity_with_contribution(app_signer, custody_actor, contributor, equity_amount)
5. 本模块先执行股权代币转账（始终执行，不受校验影响）
6. 本模块从注册表校验应用身份、POC 资格、托管地址
7. 校验全部通过后才发出 ContributionEvent；校验不通过则不发事件，但转账已完成

行为保证：
- 转账失败 -> 交易失败（转账本身的错误仍会 abort）
- 转账成功但校验不通过 -> 转账生效，不发事件
- 转账成功且校验通过 -> 转账生效，发出 ContributionEvent


-  [Struct `ContributionEvent`](#0x1_poc_contribution_ContributionEvent)
-  [Constants](#@Constants_0)
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

可信贡献事件 —— POC 算力体系的协议边界。

该事件表示：本模块已在当前交易内完成一笔通过注册表校验的标准股权发放，
收款人为 contributor，平台认可的目标到账金额为 equity_amount。

可信性来源：
- 事件由 poc_contribution 模块发出（非应用自行 emit）
- 事件只在真实转账成功后发出
- 关键资产参数由注册表给出，非外部传入
- 链下还能看到同交易的 FA 转账事实做交叉验证


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
 贡献者（接收股权代币的用户地址）
</dd>
<dt>
<code>equity_amount: u64</code>
</dt>
<dd>
 本次发放的股权代币数量（平台认可的目标到账金额）
</dd>
</dl>


</details>

<a id="@Constants_0"></a>

## Constants


<a id="0x1_poc_contribution_EZERO_AMOUNT"></a>

发放数量不能为 0


<pre><code><b>const</b> <a href="poc_contribution.md#0x1_poc_contribution_EZERO_AMOUNT">EZERO_AMOUNT</a>: u64 = 1;
</code></pre>



<a id="0x1_poc_contribution_grant_equity_with_contribution"></a>

## Function `grant_equity_with_contribution`

可信贡献发放 —— 转账 + 校验 + 条件发事件。

这是 Dapp 独立应用发出平台认可的贡献事件的唯一入口。

核心原则：不干涉应用主业务。
- 股权代币转账始终执行，不受 POC 校验结果影响
- 校验结果只决定是否发出 ContributionEvent
- 校验不通过时转账照常完成，只是不产生可信贡献记录

执行流程：
1. 校验发放数量大于 0（这是转账本身的前置条件，不通过会 abort）
2. 执行股权代币转账（始终执行）
3. 校验应用身份：app_signer 地址是否在注册表中
4. 校验 POC 资格：应用是否处于运行状态且在白名单中
5. 校验托管地址：custody_actor 签名地址是否与注册表一致
6. 以上校验全部通过 -> 发出 ContributionEvent；任一不通过 -> 不发事件

参数：
- app_signer: Dapp 独立应用的合约部署地址签名者
（通常由应用通过 SignerCapability 生成资源账户的 signer）
- custody_actor: 托管地址的签名者，拥有转出股权代币的权限
（通常由应用通过 SignerCapability 生成托管资源账户的 signer）
- contributor: 贡献者地址（接收股权代币的用户）
- equity_amount: 本次发放的股权代币数量

为什么使用 transfer_assert_minimum_deposit：
- 某些 FA 可能带 dispatchable hook、手续费或特殊存取逻辑
- 平台认可的贡献金额必须等于用户实际收到的最小金额
- 如果不做最小到账断言，ContributionEvent.equity_amount 可能大于真实到账量


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
    // 第一步：校验发放数量大于 0（转账前置条件）
    <b>assert</b>!(equity_amount &gt; 0, <a href="../../aptos-stdlib/../move-stdlib/doc/error.md#0x1_error_invalid_argument">error::invalid_argument</a>(<a href="poc_contribution.md#0x1_poc_contribution_EZERO_AMOUNT">EZERO_AMOUNT</a>));

    // 第二步：从注册表读取股权代币地址，执行真实转账（始终执行，不受后续校验影响）
    // 使用 transfer_assert_minimum_deposit 确保用户实际到账金额不低于声明金额
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

    // 第三步：校验 POC 资格和托管地址，只影响是否发出贡献事件，不影响已完成的转账
    // - 应用必须处于运行状态（ACTIVE）且在 POC 白名单中（WHITELISTED）
    // - 实际签名的托管地址必须与注册表中记录的一致
    <b>if</b> (<a href="poc_registry.md#0x1_poc_registry_is_app_eligible_for_poc">poc_registry::is_app_eligible_for_poc</a>(app_admin)) {
        <b>let</b> registered_custody_address = <a href="poc_registry.md#0x1_poc_registry_get_custody_address">poc_registry::get_custody_address</a>(app_admin);
        <b>let</b> actual_custody_address = <a href="../../aptos-stdlib/../move-stdlib/doc/signer.md#0x1_signer_address_of">signer::address_of</a>(custody_actor);
        <b>if</b> (actual_custody_address == registered_custody_address) {
            <a href="event.md#0x1_event_emit">event::emit</a>(<a href="poc_contribution.md#0x1_poc_contribution_ContributionEvent">ContributionEvent</a> { contributor, equity_amount });
        };
    };
}
</code></pre>



</details>


[move-book]: https://aptos.dev/move/book/SUMMARY
