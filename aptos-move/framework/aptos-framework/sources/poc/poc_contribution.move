/// POC 可信贡献发放合约 —— 贡献事件的唯一可信发出路径
///
/// 本模块是 Topo 链 POC（Proof of Contribution）体系的执行入口，
/// 负责把"股权代币转账 + 注册表校验 + 贡献事件发出"整合到一个函数中。
///
/// 核心设计原则：
/// - 不干涉应用主业务：股权代币转账始终执行，不受 POC 校验结果影响。
///   校验结果只决定是否发出 ContributionEvent，不会阻断转账。
/// - 贡献事件（ContributionEvent）不能由 Dapp 独立应用随意发出，
///   必须经过本模块提供的核心函数，在完成身份校验和真实转账后才能发出。
/// - 关键资产参数（股权代币地址、托管地址等）全部从 poc_registry 注册表读取，
///   不信任外部传入，防止伪造。
///
/// 调用方式：
/// - 本模块的核心函数是 `public fun`（而非 `entry fun`），
///   Dapp 独立应用需要在自己的 entry fun 中调用本函数。
///   这样链下索引器可以通过交易 payload 的入口模块地址做应用归因。
///
/// 典型调用时序：
/// 1. 用户调用 Dapp 独立应用的 entry fun（业务入口）
/// 2. 应用完成自身业务校验
/// 3. 应用生成 app_signer（合约部署地址的签名者）和 custody_actor（托管地址的签名者）
/// 4. 应用调用 grant_equity_with_contribution(app_signer, custody_actor, contributor, equity_amount)
/// 5. 本模块先执行股权代币转账（始终执行，不受校验影响）
/// 6. 本模块从注册表校验应用身份、POC 资格、托管地址
/// 7. 校验全部通过后才发出 ContributionEvent；校验不通过则不发事件，但转账已完成
///
/// 行为保证：
/// - 转账失败 -> 交易失败（转账本身的错误仍会 abort）
/// - 转账成功但校验不通过 -> 转账生效，不发事件
/// - 转账成功且校验通过 -> 转账生效，发出 ContributionEvent
module aptos_framework::poc_contribution {
    use std::error;
    use std::signer;

    use aptos_framework::event;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object;
    use aptos_framework::poc_registry;
    use aptos_framework::primary_fungible_store;

    // ========== 错误码 ==========
    /// 发放数量不能为 0
    const EZERO_AMOUNT: u64 = 1;

    // ========== 贡献事件 ==========

    #[event]
    /// 可信贡献事件 —— POC 算力体系的协议边界。
    ///
    /// 该事件表示：本模块已在当前交易内完成一笔通过注册表校验的标准股权发放，
    /// 收款人为 contributor，平台认可的目标到账金额为 equity_amount。
    ///
    /// 可信性来源：
    /// - 事件由 poc_contribution 模块发出（非应用自行 emit）
    /// - 事件只在真实转账成功后发出
    /// - 关键资产参数由注册表给出，非外部传入
    /// - 链下还能看到同交易的 FA 转账事实做交叉验证
    struct ContributionEvent has drop, store {
        /// 贡献者（接收股权代币的用户地址）
        contributor: address,
        /// 本次发放的股权代币数量（平台认可的目标到账金额）
        equity_amount: u64,
    }

    // ========== 核心函数 ==========

    /// 可信贡献发放 —— 转账 + 校验 + 条件发事件。
    ///
    /// 这是 Dapp 独立应用发出平台认可的贡献事件的唯一入口。
    ///
    /// 核心原则：不干涉应用主业务。
    /// - 股权代币转账始终执行，不受 POC 校验结果影响
    /// - 校验结果只决定是否发出 ContributionEvent
    /// - 校验不通过时转账照常完成，只是不产生可信贡献记录
    ///
    /// 执行流程：
    /// 1. 校验发放数量大于 0（这是转账本身的前置条件，不通过会 abort）
    /// 2. 执行股权代币转账（始终执行）
    /// 3. 校验应用身份：app_signer 地址是否在注册表中
    /// 4. 校验 POC 资格：应用是否处于运行状态且在白名单中
    /// 5. 校验托管地址：custody_actor 签名地址是否与注册表一致
    /// 6. 以上校验全部通过 -> 发出 ContributionEvent；任一不通过 -> 不发事件
    ///
    /// 参数：
    /// - app_signer: Dapp 独立应用的合约部署地址签名者
    ///   （通常由应用通过 SignerCapability 生成资源账户的 signer）
    /// - custody_actor: 托管地址的签名者，拥有转出股权代币的权限
    ///   （通常由应用通过 SignerCapability 生成托管资源账户的 signer）
    /// - contributor: 贡献者地址（接收股权代币的用户）
    /// - equity_amount: 本次发放的股权代币数量
    ///
    /// 为什么使用 transfer_assert_minimum_deposit：
    /// - 某些 FA 可能带 dispatchable hook、手续费或特殊存取逻辑
    /// - 平台认可的贡献金额必须等于用户实际收到的最小金额
    /// - 如果不做最小到账断言，ContributionEvent.equity_amount 可能大于真实到账量
    public fun grant_equity_with_contribution(
        app_signer: &signer,
        custody_actor: &signer,
        contributor: address,
        equity_amount: u64,
    ) {
        // 第一步：校验发放数量大于 0（转账前置条件）
        assert!(equity_amount > 0, error::invalid_argument(EZERO_AMOUNT));

        // 第二步：从注册表读取股权代币地址，执行真实转账（始终执行，不受后续校验影响）
        // 使用 transfer_assert_minimum_deposit 确保用户实际到账金额不低于声明金额
        let app_address = signer::address_of(app_signer);
        let app_admin = poc_registry::get_app_admin_by_app_address(app_address);
        let equity_token_address = poc_registry::get_equity_token_address(app_admin);
        let metadata = object::address_to_object<Metadata>(equity_token_address);
        primary_fungible_store::transfer_assert_minimum_deposit(
            custody_actor,
            metadata,
            contributor,
            equity_amount,
            equity_amount,
        );

        // 第三步：校验 POC 资格和托管地址，只影响是否发出贡献事件，不影响已完成的转账
        // - 应用必须处于运行状态（ACTIVE）且在 POC 白名单中（WHITELISTED）
        // - 实际签名的托管地址必须与注册表中记录的一致
        if (poc_registry::is_app_eligible_for_poc(app_admin)) {
            let registered_custody_address = poc_registry::get_custody_address(app_admin);
            let actual_custody_address = signer::address_of(custody_actor);
            if (actual_custody_address == registered_custody_address) {
                event::emit(ContributionEvent { contributor, equity_amount });
            };
        };
    }
}