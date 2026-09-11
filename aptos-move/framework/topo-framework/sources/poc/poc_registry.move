// POC Registry Contract — Dapp application registration and governance foundation
//
// This module is the registration center for the Topo chain's POC (Proof of Contribution) system.
// It maintains the authoritative record of "which applications are eligible to emit trusted
// contribution events through the framework."
//
// ## Core Responsibilities
// 1. Register Dapp application identity (admin address, contract address, equity token, custody address)
// 2. Maintain application self-managed operational state (ACTIVE / PAUSED / STOPPED)
// 3. Maintain platform POC inclusion status (REGISTERED / WHITELISTED / SUSPENDED)
// 4. Provide reverse-lookup interfaces for `poc_contribution` to validate identity and assets
//    during contribution event emission
//
// ## Design Principles
// - The platform approves application identity bindings and POC inclusion;
//   it does not interfere with the application's own business logic.
// - All key addresses (app_address / equity_token_address / custody_address) must be globally unique
//   across all registered applications.
// - Registration requires a one-use governance approval binding the admin to all three addresses.
//   Updates require control of the new identity or a new governance approval.
// - When the equity token address changes, the POC inclusion status is automatically reset to
//   REGISTERED, requiring platform re-review. This is a security invariant: the core asset
//   identifier changed, so previous audit assumptions may no longer hold.
//
// ## Terminology
// - app_admin: The Dapp application's administrator identity address (analogous to an enterprise admin wallet)
// - app_address: The Dapp application's contract deployment address (the on-chain entry module address)
// - equity_token_address: The Dapp application's equity token address (analogous to an ERC-20 contract address on Ethereum)
// - custody_address: The custodial address holding equity tokens pending distribution
// - metadata_uri: The application's official website or authoritative information link
//
// ## State Machine
//
// App operational state (controlled by app_admin):
//   ACTIVE ←→ PAUSED   (pause_app / resume_app)
//   ACTIVE → STOPPED   (stop_app, irreversible)
//   PAUSED → STOPPED   (stop_app, irreversible)
//
// POC inclusion status (controlled by @topo_framework / DAO governance):
//   REGISTERED → WHITELISTED  (whitelist_app_for_poc)
//   WHITELISTED → SUSPENDED   (suspend_poc_listing)
//   SUSPENDED → WHITELISTED   (whitelist_app_for_poc)
//   Any → REGISTERED          (set_poc_listing_status, or auto-reset on equity token change)
//
// An application can emit trusted ContributionEvents only when BOTH:
//   app_state == ACTIVE  AND  poc_listing_status == WHITELISTED
module topo_framework::poc_registry {
    use std::error;
    use std::signer;
    use std::string::String;

    use topo_std::table::{Self, Table};

    use topo_framework::event;
    use topo_framework::fungible_asset::{Self, Metadata, MintRef};
    use topo_framework::object;
    use topo_framework::system_addresses;

    // ========== App Operational State (controlled by app_admin) ==========
    // ACTIVE: Application is running normally; trusted contribution events can be emitted
    const APP_STATE_ACTIVE: u8 = 1;
    // PAUSED: Application has voluntarily paused operations (e.g., emergency response);
    //         trusted contribution events cannot be emitted while paused
    const APP_STATE_PAUSED: u8 = 2;
    // STOPPED: Application has permanently ceased operations; this state is irreversible
    //          and cannot be restored to ACTIVE or PAUSED
    const APP_STATE_STOPPED: u8 = 3;

    // ========== Platform POC Inclusion Status (controlled by @topo_framework / DAO governance) ==========
    // REGISTERED: Application has completed registration but has not yet been included in the POC power system.
    //             Contribution events from this app are NOT counted toward POC power by off-chain indexers.
    const POC_LISTING_STATUS_REGISTERED: u8 = 1;
    // WHITELISTED (active): Application has passed platform review and is included in the POC power system.
    //                       Contribution events from this app ARE counted toward POC power and can participate in voting.
    const POC_LISTING_STATUS_WHITELISTED: u8 = 2;
    // SUSPENDED: Application's POC inclusion has been suspended by the platform (e.g., suspected fraud, under investigation).
    //            Contribution events are NOT counted toward POC power during suspension.
    const POC_LISTING_STATUS_SUSPENDED: u8 = 3;

    // ========== Constants ==========
    /// Maximum effective weight in basis points (10000 = 100%)
    const MAX_EFFECTIVE_WEIGHT_PBS: u64 = 10000;
    /// Default effective weight in basis points (10000 = 100%)
    const DEFAULT_EFFECTIVE_WEIGHT_PBS: u64 = 10000;

    // ========== Error Codes ==========
    /// Registry resource has not been initialized (genesis not executed or skipped)
    const EREGISTRY_NOT_INITIALIZED: u64 = 1;
    /// An application is already registered under this admin address; duplicate registration not allowed
    const EAPP_ADMIN_ALREADY_EXISTS: u64 = 2;
    /// This contract deployment address is already occupied by another registered application
    const EAPP_ADDRESS_ALREADY_EXISTS: u64 = 3;
    /// This equity token address is already bound to another registered application
    const EEQUITY_TOKEN_ALREADY_EXISTS: u64 = 4;
    /// This custody address is already bound to another registered application
    const ECUSTODY_ADDRESS_ALREADY_EXISTS: u64 = 5;
    /// No registration record found for this admin address
    const EAPP_ADMIN_NOT_FOUND: u64 = 6;
    /// No registration record found for this contract deployment address
    const EAPP_ADDRESS_NOT_FOUND: u64 = 7;
    /// No registration record found for this custody address
    const ECUSTODY_ADDRESS_NOT_FOUND: u64 = 8;
    /// No registration record found for this equity token address
    const EEQUITY_TOKEN_NOT_FOUND: u64 = 9;
    /// Invalid app state value (must be one of APP_STATE_ACTIVE / PAUSED / STOPPED)
    const EINVALID_APP_STATE: u64 = 10;
    /// Invalid POC listing status value (must be one of REGISTERED / WHITELISTED / SUSPENDED)
    const EINVALID_POC_LISTING_STATUS: u64 = 11;
    /// Application is not currently in ACTIVE state; trusted contribution events cannot be emitted
    const EAPP_NOT_ACTIVE: u64 = 12;
    /// Application has not been whitelisted for POC; trusted contribution events cannot be emitted
    const EAPP_NOT_WHITELISTED_FOR_POC: u64 = 13;
    /// Application has been permanently stopped; cannot be resumed
    const EAPP_STOPPED: u64 = 14;
    /// Invalid effective weight value (must be <= MAX_EFFECTIVE_WEIGHT_PBS)
    const EINVALID_EFFECTIVE_WEIGHT: u64 = 15;
    /// Governance has not approved this admin's requested identity binding
    const EIDENTITY_NOT_APPROVED: u64 = 16;

    // ========== Core Data Structures ==========

    /// Global registry, stored under @topo_framework, initialized at genesis.
    ///
    /// Maintains 4 lookup tables to support reverse-lookup from any of:
    /// admin address, contract address, custody address, or equity token address
    /// back to the same registered entity.
    ///
    /// The multi-index design allows `poc_contribution` to efficiently validate
    /// all three address dimensions (app_address, custody_address, equity_token)
    /// in O(1) without scanning the full registry.
    struct Registry has key {
        /// Primary table: admin address → full AppInfo
        apps: Table<address, AppInfo>,
        /// Reverse lookup: contract deployment address → admin address
        app_address_to_admin: Table<address, address>,
        /// Reverse lookup: custody address → admin address
        custody_address_to_admin: Table<address, address>,
        /// Reverse lookup: equity token address → admin address
        equity_token_to_admin: Table<address, address>,
    }

    /// Separate resource so existing Registry values remain compatible after an upgrade.
    /// Created lazily by governance; an approval does not reserve any identity.
    struct IdentityApprovals has key {
        by_admin: Table<address, AppIdentity>,
    }

    struct AppIdentity has drop, store {
        app_address: address,
        equity_token_address: address,
        custody_address: address,
    }

    /// Complete registration record for a Dapp application.
    struct AppInfo has copy, drop, store {
        /// Administrator identity address (primary key); holds highest management authority for this app
        app_admin: address,
        /// Contract deployment address; the on-chain entry module address for this application.
        /// Can be updated by the admin (e.g., after contract upgrade/redeployment), but must remain globally unique.
        app_address: address,
        /// Equity token address (analogous to an ERC-20 contract address on Ethereum).
        /// Must be a valid Fungible Asset Metadata object address.
        /// IMPORTANT: Changing this resets poc_listing_status to REGISTERED, requiring platform re-review.
        equity_token_address: address,
        /// Custody address holding equity tokens pending distribution.
        /// During trusted contribution events, only this address's signer can transfer tokens out.
        custody_address: address,
        /// Application's self-managed operational state (APP_STATE_ACTIVE / PAUSED / STOPPED).
        /// Controlled exclusively by the app_admin.
        app_state: u8,
        /// Platform POC inclusion status (POC_LISTING_STATUS_REGISTERED / WHITELISTED / SUSPENDED).
        /// Controlled by the chain's DAO governance organization (currently @topo_framework).
        poc_listing_status: u8,
        /// Application's official website or authoritative information link
        metadata_uri: String,
        /// Effective weight in per-basis-points (0–10000). 10000 = 100% weight.
        /// Controlled by @topo_framework / DAO governance to adjust the app's actual contribution weight.
        effective_weight_pbs: u64,
    }

    // ========== Governance Events ==========

    #[event]
    struct AppIdentityApprovedEvent has drop, store {
        app_admin: address,
        app_address: address,
        equity_token_address: address,
        custody_address: address,
    }

    #[event]
    struct AppIdentityApprovalRevokedEvent has drop, store {
        app_admin: address,
    }

    #[event]
    /// Emitted when a new application is successfully registered
    struct AppRegisteredEvent has drop, store {
        app_admin: address,
        app_address: address,
        equity_token_address: address,
        custody_address: address,
    }

    #[event]
    /// Emitted when the contract deployment address is updated (e.g., after contract upgrade)
    struct AppAddressUpdatedEvent has drop, store {
        app_admin: address,
        old_app_address: address,
        new_app_address: address,
    }

    #[event]
    /// Emitted when the equity token address is updated.
    /// Note: this also triggers an automatic reset of poc_listing_status to REGISTERED.
    struct AppEquityTokenUpdatedEvent has drop, store {
        app_admin: address,
        old_equity_token_address: address,
        new_equity_token_address: address,
    }

    #[event]
    /// Emitted when the custody address is updated
    struct AppCustodyUpdatedEvent has drop, store {
        app_admin: address,
        old_custody_address: address,
        new_custody_address: address,
    }

    #[event]
    /// Emitted when the application's self-managed operational state changes
    struct AppStateChangedEvent has drop, store {
        app_admin: address,
        old_app_state: u8,
        new_app_state: u8,
    }

    #[event]
    /// Emitted when the platform POC inclusion status changes
    struct AppPocListingStatusChangedEvent has drop, store {
        app_admin: address,
        old_poc_listing_status: u8,
        new_poc_listing_status: u8,
    }

    #[event]
    /// Emitted when the effective weight is updated by the platform
    struct AppEffectiveWeightUpdatedEvent has drop, store {
        app_admin: address,
        old_effective_weight_pbs: u64,
        new_effective_weight_pbs: u64,
    }

    // ========== Initialization ==========

    /// Called by the genesis module to initialize the registry at chain genesis.
    /// Only callable by friend modules (genesis).
    friend fun initialize(topo_framework: &signer) {
        initialize_registry(topo_framework);
    }

    /// 仅 @topo_framework 可初始化应用注册表；资源已存在时直接返回。
    public entry fun initialize_registry(topo_framework: &signer) {
        system_addresses::assert_topo_framework(topo_framework);
        if (!exists<Registry>(@topo_framework)) {
            move_to(topo_framework, Registry {
                apps: table::new(),
                app_address_to_admin: table::new(),
                custody_address_to_admin: table::new(),
                equity_token_to_admin: table::new(),
            });
        };
    }

    // ========== Identity Authorization ==========

    /// 仅治理可批准管理员下一次注册或更新后的完整身份组合，覆盖该管理员尚未使用的批准。
    /// 批准不占用唯一索引，也不授予 PoC 白名单资格；成功注册或更新后自动消耗。
    /// 更新优先使用控制权证明入口；无法提供证明时，批准该次更新后的完整组合。
    public entry fun approve_app_identity(
        topo_framework: &signer,
        app_admin: address,
        app_address: address,
        equity_token_address: address,
        custody_address: address,
    ) {
        system_addresses::assert_topo_framework(topo_framework);
        if (!exists<IdentityApprovals>(@topo_framework)) {
            move_to(topo_framework, IdentityApprovals { by_admin: table::new() });
        };
        borrow_global_mut<IdentityApprovals>(@topo_framework).by_admin.upsert(app_admin, AppIdentity {
            app_address,
            equity_token_address,
            custody_address,
        });
        event::emit(AppIdentityApprovedEvent { app_admin, app_address, equity_token_address, custody_address });
    }

    /// 仅治理可撤销尚未使用的身份批准；不影响已登记的应用。
    public entry fun revoke_app_identity_approval(topo_framework: &signer, app_admin: address) {
        system_addresses::assert_topo_framework(topo_framework);
        clear_identity_approval(app_admin);
    }

    // ========== Registration Entry ==========

    /// 管理员须先获得治理对完整身份组合的批准，再签名注册；成功后为 ACTIVE / REGISTERED。
    /// 每个管理员只能注册一个应用；合约、股权代币和托管地址各自在对应索引中全局唯一。
    /// 股权代币地址必须通过 `object::address_to_object<Metadata>` 验证，确认为有效 FA 元数据对象。
    /// 验证失败或重复注册均会中止并回滚，原有记录保持不变。
    ///
    /// 参数：
    /// - app_admin：管理员签名，调用者成为应用管理员。
    /// - app_address：应用合约部署地址，即链上入口模块所在地址。
    /// - equity_token_address：股权代币的 FA Metadata 对象地址。
    /// - custody_address：持有待分配股权代币的托管地址。
    /// - metadata_uri：应用官网或权威信息链接。
    public entry fun register_app(
        app_admin: &signer,
        app_address: address,
        equity_token_address: address,
        custody_address: address,
        metadata_uri: String,
    ) {
        let app_admin_address = signer::address_of(app_admin);
        assert!(
            exists<Registry>(@topo_framework),
            error::not_found(EREGISTRY_NOT_INITIALIZED),
        );
        consume_identity_approval(app_admin_address, app_address, equity_token_address, custody_address);
        let registry = borrow_global_mut<Registry>(@topo_framework);

        assert!(
            !registry.apps.contains(app_admin_address),
            error::already_exists(EAPP_ADMIN_ALREADY_EXISTS),
        );
        assert!(
            !registry.app_address_to_admin.contains(app_address),
            error::already_exists(EAPP_ADDRESS_ALREADY_EXISTS),
        );
        assert!(
            !registry.custody_address_to_admin.contains(custody_address),
            error::already_exists(ECUSTODY_ADDRESS_ALREADY_EXISTS),
        );
        assert!(
            !registry.equity_token_to_admin.contains(equity_token_address),
            error::already_exists(EEQUITY_TOKEN_ALREADY_EXISTS),
        );

        object::address_to_object<Metadata>(equity_token_address);

        let info = AppInfo {
            app_admin: app_admin_address,
            app_address,
            equity_token_address,
            custody_address,
            app_state: APP_STATE_ACTIVE,
            poc_listing_status: POC_LISTING_STATUS_REGISTERED,
            metadata_uri,
            effective_weight_pbs: DEFAULT_EFFECTIVE_WEIGHT_PBS,
        };

        registry.apps.add(app_admin_address, info);
        registry.app_address_to_admin.add(app_address, app_admin_address);
        registry.custody_address_to_admin.add(custody_address, app_admin_address);
        registry.equity_token_to_admin.add(equity_token_address, app_admin_address);

        event::emit(AppRegisteredEvent {
            app_admin: app_admin_address,
            app_address,
            equity_token_address,
            custody_address,
        });
    }

    // ========== Update Entry Points ==========

    /// 应用管理员可在升级或重新部署后更新合约地址，新地址不能被其他应用用作合约地址。
    /// 治理须预先批准更新后的完整身份组合。
    /// 更新不改变 PoC 准入状态（poc_listing_status）；地址未变时直接返回且不发事件。
    public entry fun update_app_address(
        app_admin: &signer,
        new_app_address: address,
    ) {
        update_app_address_internal(app_admin, new_app_address, false);
    }

    /// 管理员和新合约地址共同签名即可更新，无需治理批准。
    public entry fun update_app_address_with_signer(app_admin: &signer, new_app: &signer) {
        update_app_address_internal(app_admin, signer::address_of(new_app), true);
    }

    fun update_app_address_internal(
        app_admin: &signer,
        new_app_address: address,
        has_identity_control: bool,
    ) {
        let app_admin_address = signer::address_of(app_admin);
        let current_info = get_app_info(app_admin_address);
        if (current_info.app_address == new_app_address) {
            return
        };
        authorize_identity_update(app_admin_address, new_app_address,
            current_info.equity_token_address, current_info.custody_address, has_identity_control);

        assert!(
            exists<Registry>(@topo_framework),
            error::not_found(EREGISTRY_NOT_INITIALIZED),
        );
        let registry = borrow_global_mut<Registry>(@topo_framework);
        assert!(
            !registry.app_address_to_admin.contains(new_app_address),
            error::already_exists(EAPP_ADDRESS_ALREADY_EXISTS),
        );

        let old_app_address = current_info.app_address;
        registry.app_address_to_admin.remove(old_app_address);
        registry.app_address_to_admin.add(new_app_address, app_admin_address);

        let info = borrow_app_info_mut(registry, app_admin_address);
        info.app_address = new_app_address;

        event::emit(AppAddressUpdatedEvent {
            app_admin: app_admin_address,
            old_app_address,
            new_app_address,
        });
    }

    /// 应用管理员更新股权代币；新地址须为有效 FA Metadata 对象，且不能与其他应用的股权代币地址重复。
    /// 治理须预先批准更新后的完整身份组合。
    /// 更换资产后需重新审核，因此 PoC 准入状态重置为 REGISTERED，审核通过后可恢复 WHITELISTED。
    /// 地址未变时直接返回，保留原状态且不发事件。
    public entry fun update_equity_token_address(
        app_admin: &signer,
        new_equity_token_address: address,
    ) {
        update_equity_token_address_internal(app_admin, new_equity_token_address, false);
    }

    /// 管理员通过应用合约提供新代币的铸币能力即可更新，无需治理预先批准。
    /// 代币地址直接由 MintRef 确定；持币或持有 Metadata 对象引用不构成发行权限。
    /// 更新后仍重置 PoC 白名单资格，须经治理重新审核。
    public fun update_equity_token_address_with_mint_ref(app_admin: &signer, mint_ref: &MintRef) {
        let metadata = fungible_asset::mint_ref_metadata(mint_ref);
        update_equity_token_address_internal(app_admin, object::object_address(&metadata), true);
    }

    fun update_equity_token_address_internal(
        app_admin: &signer,
        new_equity_token_address: address,
        has_identity_control: bool,
    ) {
        let app_admin_address = signer::address_of(app_admin);
        let current_info = get_app_info(app_admin_address);
        if (current_info.equity_token_address == new_equity_token_address) {
            return
        };
        authorize_identity_update(app_admin_address, current_info.app_address,
            new_equity_token_address, current_info.custody_address, has_identity_control);

        assert!(
            exists<Registry>(@topo_framework),
            error::not_found(EREGISTRY_NOT_INITIALIZED),
        );
        let registry = borrow_global_mut<Registry>(@topo_framework);
        assert!(
            !registry.equity_token_to_admin.contains(new_equity_token_address),
            error::already_exists(EEQUITY_TOKEN_ALREADY_EXISTS),
        );
        object::address_to_object<Metadata>(new_equity_token_address);

        let old_equity_token_address = current_info.equity_token_address;
        registry.equity_token_to_admin.remove(old_equity_token_address);
        registry.equity_token_to_admin.add(new_equity_token_address, app_admin_address);

        let info = borrow_app_info_mut(registry, app_admin_address);
        info.equity_token_address = new_equity_token_address;

        event::emit(AppEquityTokenUpdatedEvent {
            app_admin: app_admin_address,
            old_equity_token_address,
            new_equity_token_address,
        });

        reset_poc_listing_status_if_needed(info, app_admin_address);
    }

    /// 应用管理员更新托管地址，新地址不能被其他应用用作托管地址。
    /// 治理须预先批准更新后的完整身份组合。
    /// 发放可信贡献时，由该地址签名授权代币转出；更新不改变 PoC 准入状态（poc_listing_status）。
    /// 地址未变时直接返回，重复调用不发事件。
    public entry fun update_custody_address(
        app_admin: &signer,
        new_custody_address: address,
    ) {
        update_custody_address_internal(app_admin, new_custody_address, false);
    }

    /// 管理员和新托管地址共同签名即可更新，无需治理批准。
    public entry fun update_custody_address_with_signer(app_admin: &signer, new_custody: &signer) {
        update_custody_address_internal(app_admin, signer::address_of(new_custody), true);
    }

    fun update_custody_address_internal(
        app_admin: &signer,
        new_custody_address: address,
        has_identity_control: bool,
    ) {
        let app_admin_address = signer::address_of(app_admin);
        let current_info = get_app_info(app_admin_address);
        if (current_info.custody_address == new_custody_address) {
            return
        };
        authorize_identity_update(app_admin_address, current_info.app_address,
            current_info.equity_token_address, new_custody_address, has_identity_control);

        assert!(
            exists<Registry>(@topo_framework),
            error::not_found(EREGISTRY_NOT_INITIALIZED),
        );
        let registry = borrow_global_mut<Registry>(@topo_framework);
        assert!(
            !registry.custody_address_to_admin.contains(new_custody_address),
            error::already_exists(ECUSTODY_ADDRESS_ALREADY_EXISTS),
        );

        let old_custody_address = current_info.custody_address;
        registry.custody_address_to_admin.remove(old_custody_address);
        registry.custody_address_to_admin.add(new_custody_address, app_admin_address);

        let info = borrow_app_info_mut(registry, app_admin_address);
        info.custody_address = new_custody_address;

        event::emit(AppCustodyUpdatedEvent {
            app_admin: app_admin_address,
            old_custody_address,
            new_custody_address,
        });
    }

    // ========== App Self-Managed State (called by app_admin) ==========

    /// 应用管理员将运行状态设为 PAUSED，暂停通过 poc_contribution 发出可信贡献事件。
    /// 可调用 resume_app 恢复为 ACTIVE；已经暂停时重复调用不发事件。
    public entry fun pause_app(app_admin: &signer) {
        update_app_state(signer::address_of(app_admin), APP_STATE_PAUSED);
    }

    /// 应用管理员将 PAUSED 恢复为 ACTIVE；当前为 STOPPED 时直接恢复会中止。
    /// 已经处于 ACTIVE 时重复调用不发事件。
    public entry fun resume_app(app_admin: &signer) {
        let app_admin_address = signer::address_of(app_admin);
        assert!(
            get_app_state(app_admin_address) != APP_STATE_STOPPED,
            error::permission_denied(EAPP_STOPPED),
        );
        update_app_state(app_admin_address, APP_STATE_ACTIVE);
    }

    /// 应用管理员将运行状态设为 STOPPED，此时不能发出可信贡献事件。
    /// resume_app 拒绝直接恢复此状态；重复停止不发事件。
    public entry fun stop_app(app_admin: &signer) {
        update_app_state(signer::address_of(app_admin), APP_STATE_STOPPED);
    }

    // ========== Platform POC Inclusion Status Management (controlled by @topo_framework / DAO governance) ==========

    /// 仅 @topo_framework 可设置应用的 PoC 贡献准入状态。
    /// new_poc_listing_status 取 REGISTERED（1）、WHITELISTED（2）或 SUSPENDED（3）。
    /// 白名单和暂停入口共用此设置逻辑；状态未变时直接返回且不发事件。
    public entry fun set_poc_listing_status(
        topo_framework: &signer,
        app_admin: address,
        new_poc_listing_status: u8,
    ) {
        system_addresses::assert_topo_framework(topo_framework);
        assert_valid_poc_listing_status(new_poc_listing_status);
        update_poc_listing_status(app_admin, new_poc_listing_status);
    }

    /// 仅 @topo_framework 可将应用的贡献准入状态设为 SUSPENDED，暂停其发出可信贡献事件的资格。
    /// 重新审核后可用 whitelist_app_for_poc 恢复准入；重复暂停不发事件。
    public entry fun suspend_poc_listing(
        topo_framework: &signer,
        app_admin: address,
    ) {
        set_poc_listing_status(topo_framework, app_admin, POC_LISTING_STATUS_SUSPENDED);
    }

    /// 仅 @topo_framework 可将应用加入 PoC 贡献白名单（WHITELISTED）。
    /// 应用还须处于 ACTIVE 才能发出可信贡献事件；此入口不改变应用运行状态。
    /// 贡献白名单与验证者池准入分别管理，治理投票仍按原生代币计权；重复调用不发事件。
    public entry fun whitelist_app_for_poc(
        topo_framework: &signer,
        app_admin: address,
    ) {
        set_poc_listing_status(topo_framework, app_admin, POC_LISTING_STATUS_WHITELISTED);
    }

    /// 仅 @topo_framework 可设置应用贡献的有效权重，单位为万分比，范围为 0–10000。
    /// 10000 表示计入 100% 贡献，5000 表示 50%；数值未变时直接返回且不发事件。
    public entry fun set_effective_weight_pbs(
        topo_framework: &signer,
        app_admin: address,
        new_effective_weight_pbs: u64,
    ) {
        system_addresses::assert_topo_framework(topo_framework);
        assert!(
            new_effective_weight_pbs <= MAX_EFFECTIVE_WEIGHT_PBS,
            error::invalid_argument(EINVALID_EFFECTIVE_WEIGHT),
        );
        assert!(
            exists<Registry>(@topo_framework),
            error::not_found(EREGISTRY_NOT_INITIALIZED),
        );
        let registry = borrow_global_mut<Registry>(@topo_framework);
        let info = borrow_app_info_mut(registry, app_admin);
        let old_effective_weight_pbs = info.effective_weight_pbs;
        if (old_effective_weight_pbs == new_effective_weight_pbs) {
            return
        };

        info.effective_weight_pbs = new_effective_weight_pbs;

        event::emit(AppEffectiveWeightUpdatedEvent {
            app_admin,
            old_effective_weight_pbs,
            new_effective_weight_pbs,
        });
    }

    // ========== Query Interface (View / Resolve) ==========

    #[view]
    /// Check whether an application is registered under the given admin address.
    public fun exists_app(app_admin: address): bool {
        if (!exists<Registry>(@topo_framework)) {
            return false
        };
        borrow_global<Registry>(@topo_framework).apps.contains(app_admin)
    }

    #[view]
    /// Batch-check app registration for caller-provided admin addresses.
    public fun exists_apps(app_admins: vector<address>): vector<bool> {
        let exists_flags = vector[];
        let len = app_admins.length();
        if (!exists<Registry>(@topo_framework)) {
            let i = 0;
            while (i < len) {
                exists_flags.push_back(false);
                i += 1;
            };
            return exists_flags
        };
        let registry = borrow_global<Registry>(@topo_framework);
        let i = 0;
        while (i < len) {
            exists_flags.push_back(registry.apps.contains(*app_admins.borrow(i)));
            i += 1;
        };
        exists_flags
    }

    #[view]
    /// Return full app records for explicit admin addresses.
    public fun get_app_infos_by_admins(
        app_admins: vector<address>,
    ): vector<AppInfo> {
        if (!exists<Registry>(@topo_framework)) {
            return vector[]
        };
        let registry = borrow_global<Registry>(@topo_framework);
        let infos = vector[];
        let len = app_admins.length();
        let i = 0;
        while (i < len) {
            let app_admin = *app_admins.borrow(i);
            assert!(
                registry.apps.contains(app_admin),
                error::not_found(EAPP_ADMIN_NOT_FOUND),
            );
            infos.push_back(*registry.apps.borrow(app_admin));
            i += 1;
        };
        infos
    }

    #[view]
    /// Batch reverse-lookup admin addresses by app contract addresses.
    /// Missing app addresses are returned as @0x0 to keep the batch response total.
    public fun get_app_admins_by_app_addresses(
        app_addresses: vector<address>,
    ): vector<address> {
        let app_admins = vector[];
        let len = app_addresses.length();
        if (!exists<Registry>(@topo_framework)) {
            let i = 0;
            while (i < len) {
                app_admins.push_back(@0x0);
                i += 1;
            };
            return app_admins
        };
        let registry = borrow_global<Registry>(@topo_framework);
        let i = 0;
        while (i < len) {
            let app_address = *app_addresses.borrow(i);
            if (registry.app_address_to_admin.contains(app_address)) {
                app_admins.push_back(*registry.app_address_to_admin.borrow(app_address));
            } else {
                app_admins.push_back(@0x0);
            };
            i += 1;
        };
        app_admins
    }

    #[view]
    /// Reverse-lookup: get admin address from contract deployment address.
    ///
    /// Aborts if the registry is not initialized or the address is not registered.
    /// Used by `poc_contribution` in the trusted contribution path to resolve
    /// app_signer → app_admin → equity_token / custody_address.
    public fun get_app_admin_by_app_address(
        app_address: address,
    ): address {
        assert!(
            exists<Registry>(@topo_framework),
            error::not_found(EREGISTRY_NOT_INITIALIZED),
        );
        let registry = borrow_global<Registry>(@topo_framework);
        assert!(
            registry.app_address_to_admin.contains(app_address),
            error::not_found(EAPP_ADDRESS_NOT_FOUND),
        );
        *registry.app_address_to_admin.borrow(app_address)
    }

    // 通过托管地址反查管理者地址（断言版本，未找到时报错）。
    #[view]
    public fun get_app_admin_by_custody_address(
        custody_address: address,
    ): address {
        assert!(
            exists<Registry>(@topo_framework),
            error::not_found(EREGISTRY_NOT_INITIALIZED),
        );
        let registry = borrow_global<Registry>(@topo_framework);
        assert!(
            registry.custody_address_to_admin.contains(custody_address),
            error::not_found(ECUSTODY_ADDRESS_NOT_FOUND),
        );
        *registry.custody_address_to_admin.borrow(custody_address)
    }

    // 通过股权代币地址反查管理者地址（断言版本，未找到时报错）。
    #[view]
    public fun get_app_admin_by_equity_token(
        equity_token_address: address,
    ): address {
        assert!(
            exists<Registry>(@topo_framework),
            error::not_found(EREGISTRY_NOT_INITIALIZED),
        );
        let registry = borrow_global<Registry>(@topo_framework);
        assert!(
            registry.equity_token_to_admin.contains(equity_token_address),
            error::not_found(EEQUITY_TOKEN_NOT_FOUND),
        );
        *registry.equity_token_to_admin.borrow(equity_token_address)
    }

    // 获取指定管理者地址的完整注册信息（断言版本，未找到时报错）。
    #[view]
    public fun get_app_info(app_admin: address): AppInfo {
        assert!(
            exists<Registry>(@topo_framework),
            error::not_found(EREGISTRY_NOT_INITIALIZED),
        );
        let registry = borrow_global<Registry>(@topo_framework);
        assert!(
            registry.apps.contains(app_admin),
            error::not_found(EAPP_ADMIN_NOT_FOUND),
        );
        *registry.apps.borrow(app_admin)
    }

    // 通过合约部署地址获取完整注册信息。
    #[view]
    public fun get_app_info_by_app_address(
        app_address: address,
    ): AppInfo {
        get_app_info(get_app_admin_by_app_address(app_address))
    }

    // 获取合约部署地址。
    #[view]
    public fun get_app_address(app_admin: address): address {
        get_app_info(app_admin).app_address
    }

    // 获取股权代币地址。
    #[view]
    public fun get_equity_token_address(app_admin: address): address {
        get_app_info(app_admin).equity_token_address
    }

    // 获取托管地址。
    #[view]
    public fun get_custody_address(app_admin: address): address {
        get_app_info(app_admin).custody_address
    }

    // 获取应用自身运行状态。
    #[view]
    public fun get_app_state(app_admin: address): u8 {
        get_app_info(app_admin).app_state
    }

    // 获取平台 POC 纳入状态。
    #[view]
    public fun get_poc_listing_status(app_admin: address): u8 {
        get_app_info(app_admin).poc_listing_status
    }

    // 获取应用官网或权威信息链接。
    #[view]
    public fun get_metadata_uri(app_admin: address): String {
        get_app_info(app_admin).metadata_uri
    }

    #[view]
    public fun get_effective_weight_pbs(app_admin: address): u64 {
        get_app_info(app_admin).effective_weight_pbs
    }

    // 查询应用是否处于运行状态（ACTIVE）。
    // 未注册的应用返回 false。
    #[view]
    public fun is_app_active(app_admin: address): bool {
        if (!exists_app(app_admin)) {
            return false
        };
        get_app_state(app_admin) == APP_STATE_ACTIVE
    }

    // 查询应用是否已进入 POC 白名单（WHITELISTED）。
    // 未注册的应用返回 false。
    #[view]
    public fun is_poc_listed(app_admin: address): bool {
        if (!exists_app(app_admin)) {
            return false
        };
        get_poc_listing_status(app_admin) == POC_LISTING_STATUS_WHITELISTED
    }

    // 查询应用是否同时满足可信贡献发放的两个前提条件：
    // 1. 应用自身处于运行状态（ACTIVE）
    // 2. 平台已将其纳入 POC 白名单（WHITELISTED）
    // 未注册的应用返回 false。
    #[view]
    public fun is_app_eligible_for_poc(app_admin: address): bool {
        if (!exists_app(app_admin)) {
            return false
        };
        let info = get_app_info(app_admin);
        info.app_state == APP_STATE_ACTIVE &&
            info.poc_listing_status == POC_LISTING_STATUS_WHITELISTED
    }

    // ========== Internal Helpers ==========

    fun clear_identity_approval(app_admin: address) {
        if (!exists<IdentityApprovals>(@topo_framework)) return;
        let approvals = &mut borrow_global_mut<IdentityApprovals>(@topo_framework).by_admin;
        if (approvals.contains(app_admin)) {
            approvals.remove(app_admin);
            event::emit(AppIdentityApprovalRevokedEvent { app_admin });
        };
    }

    fun authorize_identity_update(
        app_admin: address,
        app_address: address,
        equity_token_address: address,
        custody_address: address,
        has_identity_control: bool,
    ) {
        if (has_identity_control) {
            // Any actual identity change invalidates pending approvals for the previous binding.
            clear_identity_approval(app_admin);
        } else {
            consume_identity_approval(app_admin, app_address, equity_token_address, custody_address);
        };
    }

    /// Consume only an exact approval; later failures roll this back with the transaction.
    fun consume_identity_approval(
        app_admin: address,
        app_address: address,
        equity_token_address: address,
        custody_address: address,
    ) {
        assert!(exists<IdentityApprovals>(@topo_framework), error::permission_denied(EIDENTITY_NOT_APPROVED));
        let approvals = &mut borrow_global_mut<IdentityApprovals>(@topo_framework).by_admin;
        assert!(approvals.contains(app_admin), error::permission_denied(EIDENTITY_NOT_APPROVED));
        let approved = approvals.remove(app_admin);
        assert!(approved.app_address == app_address
            && approved.equity_token_address == equity_token_address
            && approved.custody_address == custody_address,
            error::permission_denied(EIDENTITY_NOT_APPROVED));
    }

    /// Borrow a mutable reference to an AppInfo entry by admin address (internal use only).
    /// Aborts if the admin address is not found in the registry.
    fun borrow_app_info_mut(
        registry: &mut Registry,
        app_admin: address,
    ): &mut AppInfo {
        assert!(
            registry.apps.contains(app_admin),
            error::not_found(EAPP_ADMIN_NOT_FOUND),
        );
        registry.apps.borrow_mut(app_admin)
    }

    /// Update the application's self-managed operational state (internal use only).
    /// Idempotent: if the new state equals the current state, returns without emitting an event.
    fun update_app_state(
        app_admin: address,
        new_app_state: u8,
    ) {
        assert_valid_app_state(new_app_state);
        assert!(
            exists<Registry>(@topo_framework),
            error::not_found(EREGISTRY_NOT_INITIALIZED),
        );
        let registry = borrow_global_mut<Registry>(@topo_framework);
        let info = borrow_app_info_mut(registry, app_admin);
        let old_app_state = info.app_state;
        if (old_app_state == new_app_state) {
            return
        };

        info.app_state = new_app_state;

        event::emit(AppStateChangedEvent {
            app_admin,
            old_app_state,
            new_app_state,
        });
    }

    /// Update the platform POC inclusion status (internal use only).
    /// Idempotent: if the new status equals the current status, returns without emitting an event.
    fun update_poc_listing_status(
        app_admin: address,
        new_poc_listing_status: u8,
    ) {
        assert!(
            exists<Registry>(@topo_framework),
            error::not_found(EREGISTRY_NOT_INITIALIZED),
        );
        let registry = borrow_global_mut<Registry>(@topo_framework);
        let info = borrow_app_info_mut(registry, app_admin);
        let old_poc_listing_status = info.poc_listing_status;
        if (old_poc_listing_status == new_poc_listing_status) {
            return
        };

        info.poc_listing_status = new_poc_listing_status;

        event::emit(AppPocListingStatusChangedEvent {
            app_admin,
            old_poc_listing_status,
            new_poc_listing_status,
        });
    }

    /// Auto-reset POC inclusion status to REGISTERED after an equity token address change (internal use only).
    ///
    /// Skips if the current status is already REGISTERED.
    ///
    /// Design intent: the equity token is the core asset identifier for the application.
    /// When it changes, previous platform audit assumptions may no longer hold
    /// (different supply cap, different transfer hooks, different burn mechanics, etc.).
    /// Requiring re-review prevents an app from swapping to a malicious token while
    /// retaining its trusted whitelist status.
    fun reset_poc_listing_status_if_needed(
        info: &mut AppInfo,
        app_admin: address,
    ) {
        let old_poc_listing_status = info.poc_listing_status;
        if (old_poc_listing_status == POC_LISTING_STATUS_REGISTERED) {
            return
        };

        info.poc_listing_status = POC_LISTING_STATUS_REGISTERED;
        event::emit(AppPocListingStatusChangedEvent {
            app_admin,
            old_poc_listing_status,
            new_poc_listing_status: POC_LISTING_STATUS_REGISTERED,
        });
    }

    /// Validate that an app_state value is one of the three legal constants (internal use only).
    fun assert_valid_app_state(app_state: u8) {
        assert!(
            app_state == APP_STATE_ACTIVE ||
                app_state == APP_STATE_PAUSED ||
                app_state == APP_STATE_STOPPED,
            error::invalid_argument(EINVALID_APP_STATE),
        );
    }

    /// Validate that a poc_listing_status value is one of the three legal constants (internal use only).
    fun assert_valid_poc_listing_status(poc_listing_status: u8) {
        assert!(
            poc_listing_status == POC_LISTING_STATUS_REGISTERED ||
                poc_listing_status == POC_LISTING_STATUS_WHITELISTED ||
                poc_listing_status == POC_LISTING_STATUS_SUSPENDED,
            error::invalid_argument(EINVALID_POC_LISTING_STATUS),
        );
    }
}
