// POC 注册合约 —— Dapp 独立应用注册与治理底座
//
// 本模块是 Topo 链 POC（Proof of Contribution）体系的注册中心，
// 负责维护"谁有资格通过框架发出可信贡献事件"。
//
// 核心职责：
// 1. 登记 Dapp 独立应用的基础信息（管理者地址、合约部署地址、股权代币地址、托管地址等）
// 2. 维护应用自身运行状态（运行 / 暂停 / 停运）
// 3. 维护平台 POC 纳入状态（自注册 / 白名单 / 挂起）
// 4. 提供反查接口，供 `poc_contribution` 模块在发放贡献时做身份与资产校验
//
// 设计原则：
// - 平台只管理"是否纳入 POC 可信贡献体系"，不干涉应用自身的业务逻辑
// - 注册表中的关键地址（app_address / equity_token_address / custody_address）必须全局唯一
// - 股权代币地址变更后，POC 纳入状态会自动重置为"自注册"，需要平台重新审核
//
// 术语说明：
// - app_admin：Dapp 独立应用的管理者身份地址（类似企业管理员钱包地址）
// - app_address：Dapp 独立应用的合约部署地址（可变更，但必须绑定到同一管理者）
// - equity_token_address：Dapp 独立应用的股权代币地址（对标以太坊 ERC20 合约地址）
// - custody_address：托管地址，存放待发放股权代币的地址
// - metadata_uri：Dapp 独立应用的官网或权威信息链接
module aptos_framework::poc_registry {
    use std::error;
    use std::option::{Self, Option};
    use std::signer;
    use std::string::String;

    use aptos_std::table::{Self, Table};

    use aptos_framework::event;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object;
    use aptos_framework::system_addresses;

    // ========== 应用自身运行状态（由 Dapp 独立应用自行管控） ==========
    // 运行中：应用正常运营，可以发起可信贡献发放
    const APP_STATE_ACTIVE: u8 = 1;
    // 暂停：应用主动暂停运营（如遇紧急事件），暂停期间不可发起可信贡献发放
    const APP_STATE_PAUSED: u8 = 2;
    // 停运：应用永久停止运营，此状态不可逆，无法恢复为运行状态
    const APP_STATE_STOPPED: u8 = 3;

    // ========== 平台 POC 纳入状态（由链的 DAO 治理组织 / framework 管控） ==========
    // 自注册：应用已完成注册，但尚未被平台纳入 POC 算力体系
    // 此状态下应用的贡献事件不会被链下扫描计入算力
    const POC_LISTING_STATUS_REGISTERED: u8 = 1;
    // 白名单（激活态）：应用已被平台审核通过，纳入 POC 算力体系
    // 此状态下应用发出的贡献事件会被链下扫描并计入算力，算力可参与投票
    const POC_LISTING_STATUS_WHITELISTED: u8 = 2;
    // 挂起：应用被平台暂停纳入 POC（如疑似作弊等），待调查处理
    // 挂起期间贡献事件不计入算力
    const POC_LISTING_STATUS_SUSPENDED: u8 = 3;

    // ========== 错误码 ==========
    // 注册中心尚未初始化（genesis 未执行或被跳过）
    const EREGISTRY_NOT_INITIALIZED: u64 = 1;
    // 该管理者地址已注册过应用，不允许重复注册
    const EAPP_ADMIN_ALREADY_EXISTS: u64 = 2;
    // 该合约部署地址已被其他应用占用
    const EAPP_ADDRESS_ALREADY_EXISTS: u64 = 3;
    // 该股权代币地址已被其他应用绑定
    const EEQUITY_TOKEN_ALREADY_EXISTS: u64 = 4;
    // 该托管地址已被其他应用绑定
    const ECUSTODY_ADDRESS_ALREADY_EXISTS: u64 = 5;
    // 未找到该管理者地址对应的注册信息
    const EAPP_ADMIN_NOT_FOUND: u64 = 6;
    // 未找到该合约部署地址对应的注册信息
    const EAPP_ADDRESS_NOT_FOUND: u64 = 7;
    // 未找到该托管地址对应的注册信息
    const ECUSTODY_ADDRESS_NOT_FOUND: u64 = 8;
    // 未找到该股权代币地址对应的注册信息
    const EEQUITY_TOKEN_NOT_FOUND: u64 = 9;
    // 传入的应用状态值不合法（必须为 ACTIVE / PAUSED / STOPPED 之一）
    const EINVALID_APP_STATE: u64 = 10;
    // 传入的 POC 纳入状态值不合法（必须为 REGISTERED / WHITELISTED / SUSPENDED 之一）
    const EINVALID_POC_LISTING_STATUS: u64 = 11;
    // 应用当前不处于运行状态，无法发起可信贡献发放
    const EAPP_NOT_ACTIVE: u64 = 12;
    // 应用尚未进入 POC 白名单，无法发起可信贡献发放
    const EAPP_NOT_WHITELISTED_FOR_POC: u64 = 13;
    // 应用已永久停运，不允许恢复
    const EAPP_STOPPED: u64 = 14;

    // ========== 核心数据结构 ==========

    // 全局注册中心，存储在 @aptos_framework 地址下，genesis 时初始化。
    // 维护 4 张映射表，支持通过管理者地址、合约部署地址、托管地址、股权代币地址
    // 任意一个维度反查到同一个注册主体。
    struct Registry has key {
        // 主表：管理者地址 -> 应用完整信息
        apps: Table<address, AppInfo>,
        // 反查表：合约部署地址 -> 管理者地址
        app_address_to_admin: Table<address, address>,
        // 反查表：托管地址 -> 管理者地址
        custody_address_to_admin: Table<address, address>,
        // 反查表：股权代币地址 -> 管理者地址
        equity_token_to_admin: Table<address, address>,
    }

    // Dapp 独立应用的注册信息
    struct AppInfo has copy, drop, store {
        // 管理者身份地址（主键），拥有该应用的最高管理权限
        app_admin: address,
        // 合约部署地址，应用在链上的入口模块地址
        // 可由管理者更新（如合约升级重新部署），但必须全局唯一
        app_address: address,
        // 股权代币地址（对标以太坊 ERC20 合约地址）
        // 必须是合法的 Fungible Asset Metadata 对象地址
        // 变更后 POC 纳入状态会自动重置为"自注册"，需平台重新审核
        equity_token_address: address,
        // 托管地址，存放待发放股权代币的钱包地址
        // 可信贡献发放时，必须由该地址签名才能转出代币
        custody_address: address,
        // 应用自身运行状态（APP_STATE_ACTIVE / PAUSED / STOPPED）
        // 由应用管理者自行管控
        app_state: u8,
        // 平台 POC 纳入状态（POC_LISTING_STATUS_REGISTERED / WHITELISTED / SUSPENDED）
        // 由链的 DAO 治理组织（当前为 framework 权限）管控
        poc_listing_status: u8,
        // 应用官网或权威信息链接
        metadata_uri: String,
    }

    // ========== 治理事件 ==========

    // 应用注册成功事件
    #[event]
    struct AppRegisteredEvent has drop, store {
        app_admin: address,
        app_address: address,
        equity_token_address: address,
        custody_address: address,
    }

    // 合约部署地址变更事件（如应用升级重新部署）
    #[event]
    struct AppAddressUpdatedEvent has drop, store {
        app_admin: address,
        old_app_address: address,
        new_app_address: address,
    }

    // 股权代币地址变更事件
    // 注意：变更后 POC 纳入状态会自动重置为"自注册"
    #[event]
    struct AppEquityTokenUpdatedEvent has drop, store {
        app_admin: address,
        old_equity_token_address: address,
        new_equity_token_address: address,
    }

    // 托管地址变更事件
    #[event]
    struct AppCustodyUpdatedEvent has drop, store {
        app_admin: address,
        old_custody_address: address,
        new_custody_address: address,
    }

    // 应用自身运行状态变更事件
    #[event]
    struct AppStateChangedEvent has drop, store {
        app_admin: address,
        old_app_state: u8,
        new_app_state: u8,
    }

    // 平台 POC 纳入状态变更事件
    #[event]
    struct AppPocListingStatusChangedEvent has drop, store {
        app_admin: address,
        old_poc_listing_status: u8,
        new_poc_listing_status: u8,
    }

    // ========== 初始化 ==========

    // 由 genesis 模块调用，在链创世时初始化注册中心。
    // 仅限 friend 模块（genesis）调用。
    public(friend) fun initialize(aptos_framework: &signer) {
        initialize_registry(aptos_framework);
    }

    // 初始化注册中心资源。
    // 仅限 aptos_framework 地址调用，且幂等——如果已存在则跳过。
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

    // ========== 注册入口 ==========

    // Dapp 独立应用注册入口。
    //
    // 任何地址都可以调用此函数注册为 Dapp 独立应用管理者。
    // 注册成功后，应用默认处于"运行"状态，POC 纳入状态为"自注册"（尚未进入白名单）。
    //
    // 唯一性约束：
    // - 一个管理者地址只能注册一个应用
    // - app_address / equity_token_address / custody_address 必须全局唯一，不能与已注册应用冲突
    //
    // 参数：
    // - app_admin: 管理者签名（调用者即为管理者）
    // - app_address: 合约部署地址
    // - equity_token_address: 股权代币地址，必须是合法的 FA Metadata 对象
    // - custody_address: 托管地址，存放待发放的股权代币
    // - metadata_uri: 应用官网或权威信息链接
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

    // ========== 信息变更入口 ==========

    // 更新合约部署地址。
    // 适用场景：应用合约升级或重新部署后，需要将新的部署地址绑定到同一管理者。
    // 新地址必须全局唯一，不能与其他已注册应用冲突。
    // 如果新旧地址相同则直接返回（幂等）。
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

    // 更新股权代币地址。
    // 新地址必须是合法的 FA Metadata 对象，且全局唯一。
    // 重要：变更股权代币地址后，POC 纳入状态会自动重置为"自注册"（REGISTERED），
    // 需要平台重新审核后才能恢复白名单资格。
    // 这是因为核心资产标识变了，之前的审计假设可能不再成立。
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

    // 更新托管地址。
    // 新地址必须全局唯一，不能与其他已注册应用冲突。
    // 托管地址是可信贡献发放时签名转出代币的地址，变更后应用仍可正常使用。
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

    // ========== 应用自身状态管理（由应用管理者自行调用） ==========

    // 暂停应用。应用管理者主动暂停运营（如遇紧急事件）。
    // 暂停期间无法通过可信贡献路径发放股权代币。
    // 可通过 resume_app 恢复（前提是未进入"停运"状态）。
    public entry fun pause_app(app_admin: &signer) acquires Registry {
        update_app_state(signer::address_of(app_admin), APP_STATE_PAUSED);
    }

    // 恢复应用运行。将应用从"暂停"状态恢复为"运行"状态。
    // 注意：如果应用已进入"停运"状态（STOPPED），则不可恢复，调用会报错。
    public entry fun resume_app(app_admin: &signer) acquires Registry {
        let app_admin_address = signer::address_of(app_admin);
        assert!(
            get_app_state(app_admin_address) != APP_STATE_STOPPED,
            error::permission_denied(EAPP_STOPPED),
        );
        update_app_state(app_admin_address, APP_STATE_ACTIVE);
    }

    // 永久停运应用。此操作不可逆，停运后无法恢复为运行或暂停状态。
    public entry fun stop_app(app_admin: &signer) acquires Registry {
        update_app_state(signer::address_of(app_admin), APP_STATE_STOPPED);
    }

    // ========== 平台 POC 纳入状态管理（由链的 DAO 治理组织 / framework 管控） ==========

    // 设置应用的 POC 纳入状态。
    // 仅限 aptos_framework 地址调用（当前为中心化治理入口，后续可迁移至 DAO）。
    // 可设置为 REGISTERED / WHITELISTED / SUSPENDED 三种状态之一。
    public entry fun set_poc_listing_status(
        aptos_framework: &signer,
        app_admin: address,
        new_poc_listing_status: u8,
    ) acquires Registry {
        system_addresses::assert_aptos_framework(aptos_framework);
        assert_valid_poc_listing_status(new_poc_listing_status);
        update_poc_listing_status(app_admin, new_poc_listing_status);
    }

    // 挂起应用的 POC 纳入资格（如疑似作弊、待调查等）。
    // 挂起期间应用的贡献事件不计入算力。
    // 仅限 aptos_framework 地址调用。
    public entry fun suspend_poc_listing(
        aptos_framework: &signer,
        app_admin: address,
    ) acquires Registry {
        set_poc_listing_status(aptos_framework, app_admin, POC_LISTING_STATUS_SUSPENDED);
    }

    // 将应用加入 POC 白名单（激活态）。
    // 加入白名单后，应用发出的贡献事件会被链下扫描并计入算力，算力可参与投票。
    // 仅限 aptos_framework 地址调用。
    public entry fun whitelist_app_for_poc(
        aptos_framework: &signer,
        app_admin: address,
    ) acquires Registry {
        set_poc_listing_status(aptos_framework, app_admin, POC_LISTING_STATUS_WHITELISTED);
    }

    // ========== 查询接口（View / Resolve） ==========

    // 查询指定管理者地址是否已注册应用。
    #[view]
    public fun exists_app(app_admin: address): bool acquires Registry {
        if (!exists<Registry>(@aptos_framework)) {
            return false
        };
        borrow_global<Registry>(@aptos_framework).apps.contains(app_admin)
    }

    // 通过合约部署地址反查管理者地址（安全版本，未找到时返回 None）。
    public fun resolve_app_admin_by_app_address(
        app_address: address,
    ): Option<address> acquires Registry {
        if (!exists<Registry>(@aptos_framework)) {
            return option::none()
        };

        let registry = borrow_global<Registry>(@aptos_framework);
        if (registry.app_address_to_admin.contains(app_address)) {
            option::some(*registry.app_address_to_admin.borrow(app_address))
        } else {
            option::none()
        }
    }

    // 通过托管地址反查管理者地址（安全版本，未找到时返回 None）。
    public fun resolve_app_admin_by_custody_address(
        custody_address: address,
    ): Option<address> acquires Registry {
        if (!exists<Registry>(@aptos_framework)) {
            return option::none()
        };

        let registry = borrow_global<Registry>(@aptos_framework);
        if (registry.custody_address_to_admin.contains(custody_address)) {
            option::some(*registry.custody_address_to_admin.borrow(custody_address))
        } else {
            option::none()
        }
    }

    // 通过股权代币地址反查管理者地址（安全版本，未找到时返回 None）。
    public fun resolve_app_admin_by_equity_token(
        equity_token_address: address,
    ): Option<address> acquires Registry {
        if (!exists<Registry>(@aptos_framework)) {
            return option::none()
        };

        let registry = borrow_global<Registry>(@aptos_framework);
        if (registry.equity_token_to_admin.contains(equity_token_address)) {
            option::some(*registry.equity_token_to_admin.borrow(equity_token_address))
        } else {
            option::none()
        }
    }

    // 通过合约部署地址反查管理者地址（断言版本，未找到时报错）。
    // 供 poc_contribution 模块在可信贡献发放路径中使用。
    #[view]
    public fun get_app_admin_by_app_address(
        app_address: address,
    ): address acquires Registry {
        let maybe_app_admin = resolve_app_admin_by_app_address(app_address);
        assert!(maybe_app_admin.is_some(), error::not_found(EAPP_ADDRESS_NOT_FOUND));
        maybe_app_admin.extract()
    }

    // 通过托管地址反查管理者地址（断言版本，未找到时报错）。
    #[view]
    public fun get_app_admin_by_custody_address(
        custody_address: address,
    ): address acquires Registry {
        let maybe_app_admin = resolve_app_admin_by_custody_address(custody_address);
        assert!(maybe_app_admin.is_some(), error::not_found(ECUSTODY_ADDRESS_NOT_FOUND));
        maybe_app_admin.extract()
    }

    // 通过股权代币地址反查管理者地址（断言版本，未找到时报错）。
    #[view]
    public fun get_app_admin_by_equity_token(
        equity_token_address: address,
    ): address acquires Registry {
        let maybe_app_admin = resolve_app_admin_by_equity_token(equity_token_address);
        assert!(maybe_app_admin.is_some(), error::not_found(EEQUITY_TOKEN_NOT_FOUND));
        maybe_app_admin.extract()
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

    // 通过合约部署地址获取应用官网链接。
    #[view]
    public fun get_metadata_uri_by_app_address(
        app_address: address,
    ): String acquires Registry {
        get_app_info_by_app_address(app_address).metadata_uri
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

    // 断言应用有资格发起可信贡献发放（断言版本，不满足时直接报错）。
    // 由 poc_contribution 模块在可信贡献发放路径中调用，作为最关键的准入门槛。
    // 同时检查：
    // - 应用自身处于运行状态（ACTIVE），否则报 EAPP_NOT_ACTIVE
    // - 平台已将其纳入 POC 白名单（WHITELISTED），否则报 EAPP_NOT_WHITELISTED_FOR_POC
    public fun assert_app_eligible_for_poc(app_admin: address) acquires Registry {
        let info = get_app_info(app_admin);
        assert!(
            info.app_state == APP_STATE_ACTIVE,
            error::permission_denied(EAPP_NOT_ACTIVE),
        );
        assert!(
            info.poc_listing_status == POC_LISTING_STATUS_WHITELISTED,
            error::permission_denied(EAPP_NOT_WHITELISTED_FOR_POC),
        );
    }

    // ========== 内部辅助函数 ==========

    // 从注册表中获取指定管理者的可变引用（内部使用）。
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

    // 更新应用自身运行状态（内部使用）。
    // 状态相同时幂等返回，不发事件。
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

    // 更新平台 POC 纳入状态（内部使用）。
    // 状态相同时幂等返回，不发事件。
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

    // 股权代币地址变更后，自动重置 POC 纳入状态为"自注册"（内部使用）。
    // 如果当前已经是"自注册"状态则跳过。
    // 设计意图：核心资产标识变了，之前的审计假设可能不再成立，需要平台重新审核。
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

    // 校验应用自身运行状态值是否合法（内部使用）。
    fun assert_valid_app_state(app_state: u8) {
        assert!(
            app_state == APP_STATE_ACTIVE ||
                app_state == APP_STATE_PAUSED ||
                app_state == APP_STATE_STOPPED,
            error::invalid_argument(EINVALID_APP_STATE),
        );
    }

    // 校验平台 POC 纳入状态值是否合法（内部使用）。
    fun assert_valid_poc_listing_status(poc_listing_status: u8) {
        assert!(
            poc_listing_status == POC_LISTING_STATUS_REGISTERED ||
                poc_listing_status == POC_LISTING_STATUS_WHITELISTED ||
                poc_listing_status == POC_LISTING_STATUS_SUSPENDED,
            error::invalid_argument(EINVALID_POC_LISTING_STATUS),
        );
    }

    // ========== 测试 ==========

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
        assert!(get_metadata_uri(app_admin_address) == get_metadata_uri_by_app_address(app_admin_address), 8);
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