#[test_only]
module poc_demo::poc_demo_test {
    use std::signer;
    use std::string;

    use topo_framework::account;
    use topo_framework::aptos_coin::{Self, AptosCoin};
    use topo_framework::coin;
    use topo_framework::event;
    use topo_framework::poc_contribution;
    use topo_framework::poc_registry;
    use topo_framework::timestamp;

    use poc_demo::poc_demo;

    fun setup_apt(
        framework: &signer,
        admin: &signer,
        buyer: &signer,
        buyer_apt: u64,
    ): (coin::BurnCapability<AptosCoin>, coin::MintCapability<AptosCoin>) {
        timestamp::set_time_has_started_for_testing(framework);
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(framework);

        let admin_addr = signer::address_of(admin);
        account::create_account_for_test(admin_addr);
        coin::register<AptosCoin>(admin);

        let buyer_addr = signer::address_of(buyer);
        account::create_account_for_test(buyer_addr);
        coin::register<AptosCoin>(buyer);
        coin::deposit(buyer_addr, coin::mint(buyer_apt, &mint_cap));

        (burn_cap, mint_cap)
    }

    #[test(framework = @0x1, app_admin = @0xcafe, buyer = @0xbeef)]
    fun test_full_registration_trade_and_equity_flow(
        framework: &signer,
        app_admin: &signer,
        buyer: &signer,
    ) {
        let (burn_cap, mint_cap) = setup_apt(framework, app_admin, buyer, 1_000);
        poc_registry::initialize_registry(framework);

        let app_admin_addr = signer::address_of(app_admin);
        let buyer_addr = signer::address_of(buyer);
        poc_demo::register_demo_app(
            app_admin,
            string::utf8(b"https://poc-demo.example"),
            100,
            10,
        );

        assert!(poc_demo::exists_app(app_admin_addr), 0);
        assert!(
            poc_registry::get_app_admin_by_app_address(poc_demo::app_address(app_admin_addr))
                == app_admin_addr,
            1,
        );
        assert!(
            poc_registry::get_app_admin_by_equity_token(poc_demo::equity_metadata(app_admin_addr))
                == app_admin_addr,
            2,
        );
        assert!(!poc_registry::is_app_eligible_for_poc(app_admin_addr), 3);
        assert!(poc_demo::custody_inventory(app_admin_addr) == 100, 4);
        assert!(coin::balance<AptosCoin>(buyer_addr) == 1_000, 5);

        poc_demo::buy_equity(buyer, app_admin_addr, 10);
        assert!(coin::balance<AptosCoin>(buyer_addr) == 900, 6);
        assert!(coin::balance<AptosCoin>(app_admin_addr) == 100, 7);
        assert!(poc_demo::user_equity_balance(app_admin_addr, buyer_addr) == 10, 8);
        assert!(poc_demo::custody_inventory(app_admin_addr) == 90, 9);
        assert!(poc_demo::trade_count(app_admin_addr) == 1, 10);
        assert!(poc_demo::trade_equity_amount(app_admin_addr, 0) == 10, 11);
        assert!(event::emitted_events<poc_contribution::ContributionEvent>().length() == 0, 12);

        poc_registry::whitelist_app_for_poc(framework, app_admin_addr);
        assert!(poc_registry::is_app_eligible_for_poc(app_admin_addr), 13);

        poc_demo::buy_equity(buyer, app_admin_addr, 5);
        assert!(coin::balance<AptosCoin>(buyer_addr) == 850, 14);
        assert!(coin::balance<AptosCoin>(app_admin_addr) == 150, 15);
        assert!(poc_demo::user_equity_balance(app_admin_addr, buyer_addr) == 15, 16);
        assert!(poc_demo::custody_inventory(app_admin_addr) == 85, 17);
        assert!(poc_demo::trade_count(app_admin_addr) == 2, 18);
        assert!(poc_demo::total_equity_sold(app_admin_addr) == 15, 19);
        assert!(poc_demo::trade_payment_amount(app_admin_addr, 1) == 50, 20);
        assert!(
            event::emitted_events<poc_contribution::ContributionEvent>().length() == 1,
            21,
        );

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test(framework = @0x1, app_admin = @0xcafe, buyer = @0xbeef)]
    fun test_admin_can_top_up_custody_inventory(
        framework: &signer,
        app_admin: &signer,
        buyer: &signer,
    ) {
        let (burn_cap, mint_cap) = setup_apt(framework, app_admin, buyer, 100);
        poc_registry::initialize_registry(framework);

        let app_admin_addr = signer::address_of(app_admin);
        poc_demo::register_demo_app(
            app_admin,
            string::utf8(b"https://poc-demo.example"),
            40,
            5,
        );
        assert!(poc_demo::custody_inventory(app_admin_addr) == 40, 0);

        poc_demo::mint_equity_to_custody(app_admin, 25);
        assert!(poc_demo::custody_inventory(app_admin_addr) == 65, 1);
        assert!(poc_demo::price_per_equity(app_admin_addr) == 5, 2);
        assert!(poc_demo::expected_payment(app_admin_addr, 3) == 15, 3);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }
}
