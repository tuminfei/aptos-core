module poc_demo::poc_demo {
    use std::error;
    use std::option;
    use std::signer;
    use std::string::{Self, String};

    use aptos_std::smart_table::{Self, SmartTable};

    use aptos_framework::account::{Self, SignerCapability};
    use aptos_framework::aptos_account;
    use aptos_framework::event;
    use aptos_framework::fungible_asset::{Self, Metadata, MintRef};
    use aptos_framework::object;
    use aptos_framework::poc_contribution;
    use aptos_framework::poc_registry;
    use aptos_framework::primary_fungible_store;

    const EAPP_ALREADY_INITIALIZED: u64 = 1;
    const EAPP_NOT_FOUND: u64 = 2;
    const EINVALID_INITIAL_SUPPLY: u64 = 3;
    const EINVALID_PRICE: u64 = 4;
    const EINVALID_QUANTITY: u64 = 5;
    const ETRADE_NOT_FOUND: u64 = 6;
    const ENOT_ADMIN: u64 = 7;

    const APP_SEED: vector<u8> = b"poc-demo-app";
    const CUSTODY_SEED: vector<u8> = b"poc-demo-custody";
    const EQUITY_SEED: vector<u8> = b"poc-demo-equity";

    struct TradeRecord has copy, drop, store {
        trade_id: u64,
        buyer: address,
        payment_amount: u64,
        equity_amount: u64,
    }

    struct DemoApp has key {
        admin: address,
        settlement_address: address,
        app_address: address,
        custody_address: address,
        equity_metadata_address: address,
        mint_ref: MintRef,
        price_per_equity: u64,
        next_trade_id: u64,
        total_equity_sold: u64,
        trades: SmartTable<u64, TradeRecord>,
        app_signer_cap: SignerCapability,
        custody_signer_cap: SignerCapability,
    }

    #[event]
    struct EquityPurchased has drop, store {
        app_admin: address,
        trade_id: u64,
        buyer: address,
        payment_amount: u64,
        equity_amount: u64,
    }

    public entry fun register_demo_app(
        app_admin: &signer,
        metadata_uri: String,
        initial_supply: u64,
        price_per_equity: u64,
    ) {
        let admin = signer::address_of(app_admin);
        assert!(
            !exists<DemoApp>(admin),
            error::already_exists(EAPP_ALREADY_INITIALIZED),
        );
        assert!(
            initial_supply > 0,
            error::invalid_argument(EINVALID_INITIAL_SUPPLY),
        );
        assert!(
            price_per_equity > 0,
            error::invalid_argument(EINVALID_PRICE),
        );

        let (app_signer, app_signer_cap) = account::create_resource_account(app_admin, APP_SEED);
        let (custody_signer, custody_signer_cap) =
            account::create_resource_account(app_admin, CUSTODY_SEED);
        let app_address = signer::address_of(&app_signer);
        let custody_address = signer::address_of(&custody_signer);

        let constructor_ref = &object::create_named_object(app_admin, EQUITY_SEED);
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            constructor_ref,
            option::none(),
            string::utf8(b"POC Demo Equity"),
            string::utf8(b"PDEQ"),
            0,
            string::utf8(b""),
            string::utf8(b""),
        );
        let mint_ref = fungible_asset::generate_mint_ref(constructor_ref);
        let metadata = constructor_ref.object_from_constructor_ref::<Metadata>();
        let equity_metadata_address = metadata.object_address();
        primary_fungible_store::mint(&mint_ref, custody_address, initial_supply);

        poc_registry::register_app(
            app_admin,
            app_address,
            equity_metadata_address,
            custody_address,
            metadata_uri,
        );

        move_to(app_admin, DemoApp {
            admin,
            settlement_address: admin,
            app_address,
            custody_address,
            equity_metadata_address,
            mint_ref,
            price_per_equity,
            next_trade_id: 0,
            total_equity_sold: 0,
            trades: smart_table::new(),
            app_signer_cap,
            custody_signer_cap,
        });
    }

    public entry fun mint_equity_to_custody(
        app_admin: &signer,
        amount: u64,
    ) acquires DemoApp {
        let admin = signer::address_of(app_admin);
        assert_admin(app_admin);
        assert!(amount > 0, error::invalid_argument(EINVALID_QUANTITY));

        let config = borrow_global<DemoApp>(admin);
        primary_fungible_store::mint(&config.mint_ref, config.custody_address, amount);
    }

    public entry fun buy_equity(
        buyer: &signer,
        app_admin: address,
        equity_amount: u64,
    ) acquires DemoApp {
        assert!(equity_amount > 0, error::invalid_argument(EINVALID_QUANTITY));

        let buyer_addr = signer::address_of(buyer);
        let config = borrow_global_mut<DemoApp>(app_admin);
        let payment_amount = equity_amount * config.price_per_equity;
        aptos_account::transfer(buyer, config.settlement_address, payment_amount);

        let trade_id = config.next_trade_id;
        config.next_trade_id = trade_id + 1;
        config.total_equity_sold += equity_amount;

        let record = TradeRecord {
            trade_id,
            buyer: buyer_addr,
            payment_amount,
            equity_amount,
        };
        config.trades.add(trade_id, record);
        event::emit(EquityPurchased {
            app_admin,
            trade_id,
            buyer: buyer_addr,
            payment_amount,
            equity_amount,
        });

        let app_signer = account::create_signer_with_capability(&config.app_signer_cap);
        let custody_signer = account::create_signer_with_capability(&config.custody_signer_cap);
        poc_contribution::grant_equity_with_contribution(
            &app_signer,
            &custody_signer,
            buyer_addr,
            equity_amount,
        );
    }

    #[view]
    public fun exists_app(app_admin: address): bool {
        exists<DemoApp>(app_admin)
    }

    #[view]
    public fun app_address(app_admin: address): address acquires DemoApp {
        borrow_app(app_admin).app_address
    }

    #[view]
    public fun custody_address(app_admin: address): address acquires DemoApp {
        borrow_app(app_admin).custody_address
    }

    #[view]
    public fun equity_metadata(app_admin: address): address acquires DemoApp {
        borrow_app(app_admin).equity_metadata_address
    }

    #[view]
    public fun price_per_equity(app_admin: address): u64 acquires DemoApp {
        borrow_app(app_admin).price_per_equity
    }

    #[view]
    public fun trade_count(app_admin: address): u64 acquires DemoApp {
        borrow_app(app_admin).next_trade_id
    }

    #[view]
    public fun total_equity_sold(app_admin: address): u64 acquires DemoApp {
        borrow_app(app_admin).total_equity_sold
    }

    #[view]
    public fun expected_payment(
        app_admin: address,
        equity_amount: u64,
    ): u64 acquires DemoApp {
        equity_amount * borrow_app(app_admin).price_per_equity
    }

    #[view]
    public fun custody_inventory(app_admin: address): u64 acquires DemoApp {
        let config = borrow_app(app_admin);
        primary_fungible_store::balance(
            config.custody_address,
            object::address_to_object<Metadata>(config.equity_metadata_address),
        )
    }

    #[view]
    public fun user_equity_balance(
        app_admin: address,
        user: address,
    ): u64 acquires DemoApp {
        let metadata = object::address_to_object<Metadata>(equity_metadata(app_admin));
        primary_fungible_store::balance(user, metadata)
    }

    #[view]
    public fun get_trade(
        app_admin: address,
        trade_id: u64,
    ): TradeRecord acquires DemoApp {
        let config = borrow_app(app_admin);
        assert!(
            config.trades.contains(trade_id),
            error::not_found(ETRADE_NOT_FOUND),
        );
        *config.trades.borrow(trade_id)
    }

    #[view]
    public fun trade_payment_amount(
        app_admin: address,
        trade_id: u64,
    ): u64 acquires DemoApp {
        get_trade(app_admin, trade_id).payment_amount
    }

    #[view]
    public fun trade_equity_amount(
        app_admin: address,
        trade_id: u64,
    ): u64 acquires DemoApp {
        get_trade(app_admin, trade_id).equity_amount
    }

    inline fun borrow_app(app_admin: address): &DemoApp {
        assert!(exists<DemoApp>(app_admin), error::not_found(EAPP_NOT_FOUND));
        borrow_global<DemoApp>(app_admin)
    }

    inline fun assert_admin(app_admin: &signer) {
        let admin = signer::address_of(app_admin);
        assert!(borrow_app(admin).admin == admin, error::permission_denied(ENOT_ADMIN));
    }
}
