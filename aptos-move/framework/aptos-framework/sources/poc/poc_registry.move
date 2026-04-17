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
// - The platform only manages "whether an app is included in the POC trusted contribution system";
//   it does not interfere with the application's own business logic.
// - All key addresses (app_address / equity_token_address / custody_address) must be globally unique
//   across all registered applications.
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
// POC inclusion status (controlled by @aptos_framework / DAO governance):
//   REGISTERED → WHITELISTED  (whitelist_app_for_poc)
//   WHITELISTED → SUSPENDED   (suspend_poc_listing)
//   SUSPENDED → WHITELISTED   (whitelist_app_for_poc)
//   Any → REGISTERED          (set_poc_listing_status, or auto-reset on equity token change)
//
// An application can emit trusted ContributionEvents only when BOTH:
//   app_state == ACTIVE  AND  poc_listing_status == WHITELISTED
module aptos_framework::poc_registry {
    use std::error;
    use std::signer;
    use std::string::String;

    use aptos_std::table::{Self, Table};

    use aptos_framework::event;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object;
    use aptos_framework::system_addresses;

    // ========== App Operational State (controlled by app_admin) ==========
    // ACTIVE: Application is running normally; trusted contribution events can be emitted
    const APP_STATE_ACTIVE: u8 = 1;
    // PAUSED: Application has voluntarily paused operations (e.g., emergency response);
    //         trusted contribution events cannot be emitted while paused
    const APP_STATE_PAUSED: u8 = 2;
    // STOPPED: Application has permanently ceased operations; this state is irreversible
    //          and cannot be restored to ACTIVE or PAUSED
    const APP_STATE_STOPPED: u8 = 3;

    // ========== Platform POC Inclusion Status (controlled by @aptos_framework / DAO governance) ==========
    // REGISTERED: Application has completed registration but has not yet been included in the POC power system.
    //             Contribution events from this app are NOT counted toward POC power by off-chain indexers.
    const POC_LISTING_STATUS_REGISTERED: u8 = 1;
    // WHITELISTED (active): Application has passed platform review and is included in the POC power system.
    //                       Contribution events from this app ARE counted toward POC power and can participate in voting.
    const POC_LISTING_STATUS_WHITELISTED: u8 = 2;
    // SUSPENDED: Application's POC inclusion has been suspended by the platform (e.g., suspected fraud, under investigation).
    //            Contribution events are NOT counted toward POC power during suspension.
    const POC_LISTING_STATUS_SUSPENDED: u8 = 3;

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

    // ========== Core Data Structures ==========

    /// Global registry, stored under @aptos_framework, initialized at genesis.
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
        /// Controlled by the chain's DAO governance organization (currently @aptos_framework).
        poc_listing_status: u8,
        /// Application's official website or authoritative information link
        metadata_uri: String,
    }

    // ========== Governance Events ==========

    /// Emitted when a new application is successfully registered
    #[event]
    struct AppRegisteredEvent has drop, store {
        app_admin: address,
        app_address: address,
        equity_token_address: address,
        custody_address: address,
    }

    /// Emitted when the contract deployment address is updated (e.g., after contract upgrade)
    #[event]
    struct AppAddressUpdatedEvent has drop, store {
        app_admin: address,
        old_app_address: address,
        new_app_address: address,
    }

    /// Emitted when the equity token address is updated.
    /// Note: this also triggers an automatic reset of poc_listing_status to REGISTERED.
    #[event]
    struct AppEquityTokenUpdatedEvent has drop, store {
        app_admin: address,
        old_equity_token_address: address,
        new_equity_token_address: address,
    }

    /// Emitted when the custody address is updated
    #[event]
    struct AppCustodyUpdatedEvent has drop, store {
        app_admin: address,
        old_custody_address: address,
        new_custody_address: address,
    }

    /// Emitted when the application's self-managed operational state changes
    #[event]
    struct AppStateChangedEvent has drop, store {
        app_admin: address,
        old_app_state: u8,
        new_app_state: u8,
    }

    /// Emitted when the platform POC inclusion status changes
    #[event]
    struct AppPocListingStatusChangedEvent has drop, store {
        app_admin: address,
        old_poc_listing_status: u8,
        new_poc_listing_status: u8,
    }

    // ========== Initialization ==========

    /// Called by the genesis module to initialize the registry at chain genesis.
    /// Only callable by friend modules (genesis).
    public(friend) fun initialize(aptos_framework: &signer) {
        initialize_registry(aptos_framework);
    }

    /// Initialize the Registry resource.
    /// Only callable by @aptos_framework. Idempotent — skips if already initialized.
    public entry fun initialize_registry(aptos_framework: &signer) {
        system_addresses::assert_aptos_framework(aptos_framework);
        if (!exists<Registry>(@aptos_framework)) {
            move_to(aptos_framework, Registry {
                apps: table::new(),
                app_address_to_admin: table::new(),
                custody_address_to_admin: table::new(),
                equity_token_to_admin: table::new(),
            });
        };
    }

    // ========== Registration Entry ==========

    /// Dapp application registration entry point.
    ///
    /// Any address may call this function to register as a Dapp application administrator.
    /// After successful registration, the application defaults to ACTIVE state with
    /// POC listing status REGISTERED (not yet whitelisted by the platform).
    ///
    /// Uniqueness constraints (all enforced atomically):
    /// - One admin address can only register one application
    /// - app_address / equity_token_address / custody_address must each be globally unique
    ///   across all registered applications
    ///
    /// The equity_token_address is validated as a real Fungible Asset Metadata object
    /// via `object::address_to_object<Metadata>` — this aborts if the address is not
    /// a valid FA metadata object, preventing registration with fake token addresses.
    ///
    /// Parameters:
    /// - app_admin: Administrator signer (the caller becomes the admin)
    /// - app_address: Contract deployment address (the on-chain entry module address)
    /// - equity_token_address: Equity token address; must be a valid FA Metadata object
    /// - custody_address: Custody address holding equity tokens pending distribution
    /// - metadata_uri: Application's official website or authoritative information link
    public entry fun register_app(
        app_admin: &signer,
        app_address: address,
        equity_token_address: address,
        custody_address: address,
        metadata_uri: String,
    ) acquires Registry {
        let app_admin_address = signer::address_of(app_admin);
        assert!(
            exists<Registry>(@aptos_framework),
            error::not_found(EREGISTRY_NOT_INITIALIZED),
        );
        let registry = borrow_global_mut<Registry>(@aptos_framework);

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

    /// Update the contract deployment address.
    ///
    /// Use case: after a contract upgrade or redeployment, bind the new deployment address
    /// to the same admin. The new address must be globally unique.
    /// Idempotent: if the new address equals the current address, returns immediately.
    ///
    /// This does NOT reset poc_listing_status — only equity token changes trigger a reset.
    public entry fun update_app_address(
        app_admin: &signer,
        new_app_address: address,
    ) acquires Registry {
        let app_admin_address = signer::address_of(app_admin);
        let current_info = get_app_info(app_admin_address);
        if (current_info.app_address == new_app_address) {
            return
        };

        assert!(
            exists<Registry>(@aptos_framework),
            error::not_found(EREGISTRY_NOT_INITIALIZED),
        );
        let registry = borrow_global_mut<Registry>(@aptos_framework);
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

    /// Update the equity token address.
    ///
    /// The new address must be a valid FA Metadata object and globally unique.
    ///
    /// IMPORTANT SECURITY INVARIANT: Changing the equity token address automatically resets
    /// poc_listing_status to REGISTERED, requiring platform re-review before the app can
    /// regain WHITELISTED status. This is intentional:
    /// - The equity token is the core asset identifier for the application.
    /// - Previous platform audits were conducted against the old token; a new token means
    ///   the audit assumptions may no longer hold (different supply, different transfer hooks, etc.).
    /// - Requiring re-review prevents an app from swapping to a malicious token while retaining
    ///   its trusted whitelist status.
    ///
    /// Idempotent: if the new address equals the current address, returns immediately.
    public entry fun update_equity_token_address(
        app_admin: &signer,
        new_equity_token_address: address,
    ) acquires Registry {
        let app_admin_address = signer::address_of(app_admin);
        let current_info = get_app_info(app_admin_address);
        if (current_info.equity_token_address == new_equity_token_address) {
            return
        };

        assert!(
            exists<Registry>(@aptos_framework),
            error::not_found(EREGISTRY_NOT_INITIALIZED),
        );
        let registry = borrow_global_mut<Registry>(@aptos_framework);
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

    /// Update the custody address.
    ///
    /// The new address must be globally unique across all registered applications.
    /// The custody address is the signer that authorizes token transfers during trusted
    /// contribution events. Changing it does NOT reset poc_listing_status.
    ///
    /// Idempotent: if the new address equals the current address, returns immediately.
    public entry fun update_custody_address(
        app_admin: &signer,
        new_custody_address: address,
    ) acquires Registry {
        let app_admin_address = signer::address_of(app_admin);
        let current_info = get_app_info(app_admin_address);
        if (current_info.custody_address == new_custody_address) {
            return
        };

        assert!(
            exists<Registry>(@aptos_framework),
            error::not_found(EREGISTRY_NOT_INITIALIZED),
        );
        let registry = borrow_global_mut<Registry>(@aptos_framework);
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

    /// Pause the application. The admin voluntarily suspends operations (e.g., emergency response).
    ///
    /// While paused, trusted contribution events cannot be emitted via `poc_contribution`.
    /// The application can be resumed via `resume_app` as long as it has not been permanently stopped.
    public entry fun pause_app(app_admin: &signer) acquires Registry {
        update_app_state(signer::address_of(app_admin), APP_STATE_PAUSED);
    }

    /// Resume the application from PAUSED state back to ACTIVE.
    ///
    /// Aborts if the application is in STOPPED state — permanent stops cannot be reversed.
    /// This guard prevents accidental resurrection of a stopped application.
    public entry fun resume_app(app_admin: &signer) acquires Registry {
        let app_admin_address = signer::address_of(app_admin);
        assert!(
            get_app_state(app_admin_address) != APP_STATE_STOPPED,
            error::permission_denied(EAPP_STOPPED),
        );
        update_app_state(app_admin_address, APP_STATE_ACTIVE);
    }

    /// Permanently stop the application. This operation is irreversible.
    ///
    /// Once stopped, the application cannot be restored to ACTIVE or PAUSED state.
    /// Use this only when the application is being permanently decommissioned.
    public entry fun stop_app(app_admin: &signer) acquires Registry {
        update_app_state(signer::address_of(app_admin), APP_STATE_STOPPED);
    }

    // ========== Platform POC Inclusion Status Management (controlled by @aptos_framework / DAO governance) ==========

    /// Set the POC inclusion status for an application.
    ///
    /// Only callable by @aptos_framework (currently centralized governance; can be migrated to DAO later).
    /// Valid values: REGISTERED / WHITELISTED / SUSPENDED.
    ///
    /// This is the master setter; `whitelist_app_for_poc` and `suspend_poc_listing` are
    /// convenience wrappers around this function.
    public entry fun set_poc_listing_status(
        aptos_framework: &signer,
        app_admin: address,
        new_poc_listing_status: u8,
    ) acquires Registry {
        system_addresses::assert_aptos_framework(aptos_framework);
        assert_valid_poc_listing_status(new_poc_listing_status);
        update_poc_listing_status(app_admin, new_poc_listing_status);
    }

    /// Suspend an application's POC inclusion (e.g., suspected fraud, under investigation).
    ///
    /// While suspended, the application's contribution events are NOT counted toward POC power.
    /// The suspension can be lifted by calling `whitelist_app_for_poc` after investigation.
    /// Only callable by @aptos_framework.
    public entry fun suspend_poc_listing(
        aptos_framework: &signer,
        app_admin: address,
    ) acquires Registry {
        set_poc_listing_status(aptos_framework, app_admin, POC_LISTING_STATUS_SUSPENDED);
    }

    /// Add an application to the POC whitelist (WHITELISTED / active state).
    ///
    /// After whitelisting, contribution events emitted by this application are scanned
    /// by off-chain indexers and counted toward POC power, which can participate in governance voting.
    /// Only callable by @aptos_framework.
    public entry fun whitelist_app_for_poc(
        aptos_framework: &signer,
        app_admin: address,
    ) acquires Registry {
        set_poc_listing_status(aptos_framework, app_admin, POC_LISTING_STATUS_WHITELISTED);
    }

    // ========== Query Interface (View / Resolve) ==========

    /// Check whether an application is registered under the given admin address.
    #[view]
    public fun exists_app(app_admin: address): bool acquires Registry {
        if (!exists<Registry>(@aptos_framework)) {
            return false
        };
        borrow_global<Registry>(@aptos_framework).apps.contains(app_admin)
    }

    /// Reverse-lookup: get admin address from contract deployment address.
    ///
    /// Aborts if the registry is not initialized or the address is not registered.
    /// Used by `poc_contribution` in the trusted contribution path to resolve
    /// app_signer → app_admin → equity_token / custody_address.
    #[view]
    public fun get_app_admin_by_app_address(
        app_address: address,
    ): address acquires Registry {
        assert!(
            exists<Registry>(@aptos_framework),
            error::not_found(EREGISTRY_NOT_INITIALIZED),
        );
        let registry = borrow_global<Registry>(@aptos_framework);
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
    ): address acquires Registry {
        assert!(
            exists<Registry>(@aptos_framework),
            error::not_found(EREGISTRY_NOT_INITIALIZED),
        );
        let registry = borrow_global<Registry>(@aptos_framework);
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
    ): address acquires Registry {
        assert!(
            exists<Registry>(@aptos_framework),
            error::not_found(EREGISTRY_NOT_INITIALIZED),
        );
        let registry = borrow_global<Registry>(@aptos_framework);
        assert!(
            registry.equity_token_to_admin.contains(equity_token_address),
            error::not_found(EEQUITY_TOKEN_NOT_FOUND),
        );
        *registry.equity_token_to_admin.borrow(equity_token_address)
    }

    // 获取指定管理者地址的完整注册信息（断言版本，未找到时报错）。
    #[view]
    public fun get_app_info(app_admin: address): AppInfo acquires Registry {
        assert!(
            exists<Registry>(@aptos_framework),
            error::not_found(EREGISTRY_NOT_INITIALIZED),
        );
        let registry = borrow_global<Registry>(@aptos_framework);
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
    ): AppInfo acquires Registry {
        get_app_info(get_app_admin_by_app_address(app_address))
    }

    // 获取合约部署地址。
    #[view]
    public fun get_app_address(app_admin: address): address acquires Registry {
        get_app_info(app_admin).app_address
    }

    // 获取股权代币地址。
    #[view]
    public fun get_equity_token_address(app_admin: address): address acquires Registry {
        get_app_info(app_admin).equity_token_address
    }

    // 获取托管地址。
    #[view]
    public fun get_custody_address(app_admin: address): address acquires Registry {
        get_app_info(app_admin).custody_address
    }

    // 获取应用自身运行状态。
    #[view]
    public fun get_app_state(app_admin: address): u8 acquires Registry {
        get_app_info(app_admin).app_state
    }

    // 获取平台 POC 纳入状态。
    #[view]
    public fun get_poc_listing_status(app_admin: address): u8 acquires Registry {
        get_app_info(app_admin).poc_listing_status
    }

    // 获取应用官网或权威信息链接。
    #[view]
    public fun get_metadata_uri(app_admin: address): String acquires Registry {
        get_app_info(app_admin).metadata_uri
    }

    // 查询应用是否处于运行状态（ACTIVE）。
    // 未注册的应用返回 false。
    #[view]
    public fun is_app_active(app_admin: address): bool acquires Registry {
        if (!exists_app(app_admin)) {
            return false
        };
        get_app_state(app_admin) == APP_STATE_ACTIVE
    }

    // 查询应用是否已进入 POC 白名单（WHITELISTED）。
    // 未注册的应用返回 false。
    #[view]
    public fun is_poc_listed(app_admin: address): bool acquires Registry {
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
    public fun is_app_eligible_for_poc(app_admin: address): bool acquires Registry {
        if (!exists_app(app_admin)) {
            return false
        };
        let info = get_app_info(app_admin);
        info.app_state == APP_STATE_ACTIVE &&
            info.poc_listing_status == POC_LISTING_STATUS_WHITELISTED
    }

    // ========== Internal Helpers ==========

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
    ) acquires Registry {
        assert_valid_app_state(new_app_state);
        assert!(
            exists<Registry>(@aptos_framework),
            error::not_found(EREGISTRY_NOT_INITIALIZED),
        );
        let registry = borrow_global_mut<Registry>(@aptos_framework);
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
    ) acquires Registry {
        assert!(
            exists<Registry>(@aptos_framework),
            error::not_found(EREGISTRY_NOT_INITIALIZED),
        );
        let registry = borrow_global_mut<Registry>(@aptos_framework);
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

    // ========== Tests ==========

    #[test_only]
    use std::string;
    #[test_only]
    use aptos_framework::fungible_asset;
    #[test_only]
    use aptos_framework::primary_fungible_store;
    #[test_only]
    use aptos_framework::timestamp;

    // 测试：注册应用后，可通过 3 种地址维度正常反查到同一注册主体。
    // 验证注册后的默认状态：app_state = ACTIVE, poc_listing_status = REGISTERED。
    #[test(framework = @0x1, app_admin = @0xcafe)]
    fun test_register_and_resolve_app(
        framework: &signer,
        app_admin: &signer,
    ) acquires Registry {
        timestamp::set_time_has_started_for_testing(framework);
        initialize_registry(framework);

        let (constructor_ref, metadata) = fungible_asset::create_test_token(app_admin);
        let (_mint_ref, _transfer_ref, _burn_ref) =
            primary_fungible_store::init_test_metadata_with_primary_store_enabled(&constructor_ref);

        let app_admin_address = signer::address_of(app_admin);
        let metadata_address = metadata.object_address();
        let metadata_uri = string::utf8(b"https://app.example");
        register_app(
            app_admin,
            app_admin_address,
            metadata_address,
            app_admin_address,
            metadata_uri,
        );

        assert!(exists_app(app_admin_address), 0);
        assert!(get_app_admin_by_app_address(app_admin_address) == app_admin_address, 1);
        assert!(get_app_admin_by_custody_address(app_admin_address) == app_admin_address, 2);
        assert!(get_app_admin_by_equity_token(metadata_address) == app_admin_address, 3);
        assert!(get_app_address(app_admin_address) == app_admin_address, 4);
        assert!(get_custody_address(app_admin_address) == app_admin_address, 5);
        assert!(get_equity_token_address(app_admin_address) == metadata_address, 6);
        assert!(get_poc_listing_status(app_admin_address) == POC_LISTING_STATUS_REGISTERED, 7);
        assert!(get_metadata_uri(app_admin_address) == string::utf8(b"https://app.example"), 8);
        assert!(is_app_active(app_admin_address), 9);
        assert!(!is_poc_listed(app_admin_address), 10);
    }

    // 测试：更新股权代币地址后，POC 纳入状态会自动重置为"自注册"（REGISTERED）。
    // 验证核心资产标识变更后的安全重置机制。
    #[test(framework = @0x1, app_admin = @0xcafe, asset_admin = @0xface)]
    fun test_equity_token_update_resets_poc_listing_status(
        framework: &signer,
        app_admin: &signer,
        asset_admin: &signer,
    ) acquires Registry {
        timestamp::set_time_has_started_for_testing(framework);
        initialize_registry(framework);

        let (constructor_ref_1, metadata_1) = fungible_asset::create_test_token(app_admin);
        let (_mint_ref_1, _transfer_ref_1, _burn_ref_1) =
            primary_fungible_store::init_test_metadata_with_primary_store_enabled(&constructor_ref_1);

        let (constructor_ref_2, metadata_2) = fungible_asset::create_test_token(asset_admin);
        let (_mint_ref_2, _transfer_ref_2, _burn_ref_2) =
            primary_fungible_store::init_test_metadata_with_primary_store_enabled(&constructor_ref_2);

        let app_admin_address = signer::address_of(app_admin);
        register_app(
            app_admin,
            app_admin_address,
            object::object_address(&metadata_1),
            app_admin_address,
            string::utf8(b"https://app.example"),
        );

        whitelist_app_for_poc(framework, app_admin_address);
        assert!(get_poc_listing_status(app_admin_address) == POC_LISTING_STATUS_WHITELISTED, 0);

        update_equity_token_address(app_admin, object::object_address(&metadata_2));
        assert!(get_poc_listing_status(app_admin_address) == POC_LISTING_STATUS_REGISTERED, 1);
    }

    // 测试：POC 资格判断辅助函数。
    // 验证：未进白名单时不具备资格 -> 进入白名单后具备资格 -> 应用暂停后资格失效。
    #[test(framework = @0x1, app_admin = @0xcafe)]
    fun test_app_eligibility_helpers(
        framework: &signer,
        app_admin: &signer,
    ) acquires Registry {
        timestamp::set_time_has_started_for_testing(framework);
        initialize_registry(framework);

        let (constructor_ref, metadata) = fungible_asset::create_test_token(app_admin);
        let (_mint_ref, _transfer_ref, _burn_ref) =
            primary_fungible_store::init_test_metadata_with_primary_store_enabled(&constructor_ref);

        let app_admin_address = signer::address_of(app_admin);
        register_app(
            app_admin,
            app_admin_address,
            object::object_address(&metadata),
            app_admin_address,
            string::utf8(b"https://app.example"),
        );

        assert!(!is_app_eligible_for_poc(app_admin_address), 0);
        whitelist_app_for_poc(framework, app_admin_address);
        assert!(is_app_eligible_for_poc(app_admin_address), 1);

        pause_app(app_admin);
        assert!(!is_app_eligible_for_poc(app_admin_address), 2);
    }
}
