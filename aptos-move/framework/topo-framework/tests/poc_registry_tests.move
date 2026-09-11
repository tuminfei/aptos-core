#[test_only]
module topo_framework::poc_registry_tests {
    use std::signer;
    use std::string;
    use topo_framework::event;
    use topo_framework::fungible_asset;
    use topo_framework::object;
    use topo_framework::poc_registry;

    const APP: address = @0xa11;
    const NEXT_APP: address = @0xa12;
    const CUSTODY: address = @0xc01;
    const NEXT_CUSTODY: address = @0xc02;

    fun create_token(creator: &signer): address {
        let (_, _, _, _, metadata) = fungible_asset::create_fungible_asset(creator);
        object::object_address(&metadata)
    }

    fun prepare(framework: &signer, creator: &signer): address {
        poc_registry::initialize_registry(framework);
        create_token(creator)
    }

    fun register_approved(framework: &signer, admin: &signer): address {
        let token = prepare(framework, admin);
        poc_registry::approve_app_identity(framework, signer::address_of(admin), APP, token, CUSTODY);
        poc_registry::register_app(admin, APP, token, CUSTODY, string::utf8(b"app"));
        token
    }

    fun assert_approval_consumed(framework: &signer, admin: address) {
        let revoked = event::emitted_events<poc_registry::AppIdentityApprovalRevokedEvent>().length();
        poc_registry::revoke_app_identity_approval(framework, admin);
        assert!(event::emitted_events<poc_registry::AppIdentityApprovalRevokedEvent>().length() == revoked, 0);
    }

    #[test(attacker = @0x20)]
    #[expected_failure(abort_code = 0x50003, location = topo_framework::system_addresses)]
    fun only_governance_can_approve(attacker: signer) {
        poc_registry::approve_app_identity(&attacker, @0x20, APP, @0x30, CUSTODY);
    }

    #[test(attacker = @0x20)]
    #[expected_failure(abort_code = 0x50003, location = topo_framework::system_addresses)]
    fun only_governance_can_revoke(attacker: signer) {
        poc_registry::revoke_app_identity_approval(&attacker, @0x10);
    }

    #[test(framework = @topo_framework, victim = @0x10, attacker = @0x20)]
    #[expected_failure(abort_code = 0x50010, location = topo_framework::poc_registry)]
    fun registration_cannot_reserve_unapproved_identities(framework: signer, victim: signer, attacker: signer) {
        let token = prepare(&framework, &victim);
        poc_registry::register_app(&attacker, APP, token, CUSTODY, string::utf8(b"attacker"));
    }

    #[test(framework = @topo_framework, victim = @0x10, attacker = @0x20)]
    #[expected_failure(abort_code = 0x50010, location = topo_framework::poc_registry)]
    fun approval_cannot_be_used_by_another_admin(framework: signer, victim: signer, attacker: signer) {
        let token = prepare(&framework, &victim);
        poc_registry::approve_app_identity(&framework, @0x10, APP, token, CUSTODY);
        poc_registry::register_app(&attacker, APP, token, CUSTODY, string::utf8(b"attacker"));
    }

    #[test(framework = @topo_framework, admin = @0x10)]
    #[expected_failure(abort_code = 0x50010, location = topo_framework::poc_registry)]
    fun registration_cannot_substitute_app_address(framework: signer, admin: signer) {
        let token = prepare(&framework, &admin);
        poc_registry::approve_app_identity(&framework, @0x10, APP, token, CUSTODY);
        poc_registry::register_app(&admin, NEXT_APP, token, CUSTODY, string::utf8(b"app"));
    }

    #[test(framework = @topo_framework, admin = @0x10, victim = @0x20)]
    #[expected_failure(abort_code = 0x50010, location = topo_framework::poc_registry)]
    fun registration_cannot_substitute_equity_token(framework: signer, admin: signer, victim: signer) {
        let token = prepare(&framework, &admin);
        let victim_token = create_token(&victim);
        poc_registry::approve_app_identity(&framework, @0x10, APP, token, CUSTODY);
        poc_registry::register_app(&admin, APP, victim_token, CUSTODY, string::utf8(b"app"));
    }

    #[test(framework = @topo_framework, admin = @0x10)]
    #[expected_failure(abort_code = 0x50010, location = topo_framework::poc_registry)]
    fun registration_cannot_substitute_custody_address(framework: signer, admin: signer) {
        let token = prepare(&framework, &admin);
        poc_registry::approve_app_identity(&framework, @0x10, APP, token, CUSTODY);
        poc_registry::register_app(&admin, APP, token, NEXT_CUSTODY, string::utf8(b"app"));
    }

    #[test(framework = @topo_framework, admin = @0x10)]
    #[expected_failure(abort_code = 0x50010, location = topo_framework::poc_registry)]
    fun app_address_update_without_proof_requires_approval(framework: signer, admin: signer) {
        register_approved(&framework, &admin);
        poc_registry::suspend_poc_listing(&framework, @0x10);
        poc_registry::update_app_address(&admin, NEXT_APP);
    }

    #[test(framework = @topo_framework, admin = @0x10, victim = @0x20)]
    #[expected_failure(abort_code = 0x50010, location = topo_framework::poc_registry)]
    fun equity_token_update_without_proof_requires_approval(framework: signer, admin: signer, victim: signer) {
        register_approved(&framework, &admin);
        let victim_token = create_token(&victim);
        poc_registry::update_equity_token_address(&admin, victim_token);
    }

    #[test(framework = @topo_framework, admin = @0x10)]
    #[expected_failure(abort_code = 0x50010, location = topo_framework::poc_registry)]
    fun custody_update_without_proof_requires_approval(framework: signer, admin: signer) {
        register_approved(&framework, &admin);
        poc_registry::update_custody_address(&admin, NEXT_CUSTODY);
    }

    #[test(framework = @topo_framework, admin = @0x10)]
    #[expected_failure(abort_code = 0x50010, location = topo_framework::poc_registry)]
    fun update_requires_approval_of_the_complete_result(framework: signer, admin: signer) {
        let token = register_approved(&framework, &admin);
        // Even the approved new app address cannot be combined with an unapproved custody address.
        poc_registry::approve_app_identity(&framework, @0x10, NEXT_APP, token, NEXT_CUSTODY);
        poc_registry::update_app_address(&admin, NEXT_APP);
    }

    #[test(framework = @topo_framework, admin = @0x10)]
    #[expected_failure(abort_code = 0x50010, location = topo_framework::poc_registry)]
    fun revoked_approval_cannot_register(framework: signer, admin: signer) {
        let token = prepare(&framework, &admin);
        poc_registry::approve_app_identity(&framework, @0x10, APP, token, CUSTODY);
        poc_registry::revoke_app_identity_approval(&framework, @0x10);
        poc_registry::register_app(&admin, APP, token, CUSTODY, string::utf8(b"app"));
    }

    #[test(framework = @topo_framework, admin = @0x10)]
    #[expected_failure(abort_code = 0x50010, location = topo_framework::poc_registry)]
    fun replaced_approval_cannot_register_old_identity(framework: signer, admin: signer) {
        let token = prepare(&framework, &admin);
        poc_registry::approve_app_identity(&framework, @0x10, APP, token, CUSTODY);
        poc_registry::approve_app_identity(&framework, @0x10, NEXT_APP, token, CUSTODY);
        poc_registry::register_app(&admin, APP, token, CUSTODY, string::utf8(b"app"));
    }

    #[test(framework = @topo_framework, admin = @0x10)]
    #[expected_failure(abort_code = 0x50010, location = topo_framework::poc_registry)]
    fun consumed_update_approval_cannot_be_replayed(framework: signer, admin: signer) {
        let token = register_approved(&framework, &admin);
        poc_registry::approve_app_identity(&framework, @0x10, NEXT_APP, token, CUSTODY);
        poc_registry::update_app_address(&admin, NEXT_APP);
        poc_registry::approve_app_identity(&framework, @0x10, APP, token, CUSTODY);
        poc_registry::update_app_address(&admin, APP);
        poc_registry::update_app_address(&admin, NEXT_APP);
    }

    #[test(framework = @topo_framework, admin = @0x10, other = @0x20)]
    #[expected_failure(abort_code = 0x80003, location = topo_framework::poc_registry)]
    fun approval_does_not_bypass_unique_addresses(framework: signer, admin: signer, other: signer) {
        register_approved(&framework, &admin);
        let token = create_token(&other);
        poc_registry::approve_app_identity(&framework, @0x20, APP, token, NEXT_CUSTODY);
        poc_registry::register_app(&other, APP, token, NEXT_CUSTODY, string::utf8(b"other"));
    }

    #[test(framework = @topo_framework, admin = @0x10, other = @0x20)]
    fun approved_registration_and_updates_preserve_registry_invariants(framework: signer, admin: signer, other: signer) {
        let token = register_approved(&framework, &admin);
        assert_approval_consumed(&framework, @0x10);
        let next_token = create_token(&other);
        assert!(poc_registry::get_app_admin_by_app_address(APP) == @0x10, 1);
        assert!(poc_registry::get_app_admin_by_equity_token(token) == @0x10, 2);
        assert!(poc_registry::get_app_admin_by_custody_address(CUSTODY) == @0x10, 3);
        assert!(poc_registry::get_app_state(@0x10) == 1 && poc_registry::get_poc_listing_status(@0x10) == 1, 4);
        poc_registry::whitelist_app_for_poc(&framework, @0x10);

        poc_registry::approve_app_identity(&framework, @0x10, NEXT_APP, token, CUSTODY);
        // No-op updates must neither require nor consume the pending approval.
        poc_registry::update_app_address(&admin, APP);
        poc_registry::update_equity_token_address(&admin, token);
        poc_registry::update_custody_address(&admin, CUSTODY);
        poc_registry::update_app_address(&admin, NEXT_APP);
        assert_approval_consumed(&framework, @0x10);
        assert!(poc_registry::get_app_address(@0x10) == NEXT_APP, 5);
        assert!(poc_registry::get_app_admin_by_app_address(NEXT_APP) == @0x10, 6);
        assert!(poc_registry::get_poc_listing_status(@0x10) == 2, 7);

        poc_registry::approve_app_identity(&framework, @0x10, NEXT_APP, token, NEXT_CUSTODY);
        poc_registry::update_custody_address(&admin, NEXT_CUSTODY);
        assert_approval_consumed(&framework, @0x10);
        assert!(poc_registry::get_custody_address(@0x10) == NEXT_CUSTODY, 8);
        assert!(poc_registry::get_app_admin_by_custody_address(NEXT_CUSTODY) == @0x10, 9);
        assert!(poc_registry::get_poc_listing_status(@0x10) == 2, 10);

        poc_registry::approve_app_identity(&framework, @0x10, NEXT_APP, next_token, NEXT_CUSTODY);
        poc_registry::update_equity_token_address(&admin, next_token);
        assert_approval_consumed(&framework, @0x10);
        assert!(poc_registry::get_equity_token_address(@0x10) == next_token, 11);
        assert!(poc_registry::get_app_admin_by_equity_token(next_token) == @0x10, 12);
        assert!(poc_registry::get_poc_listing_status(@0x10) == 1, 13);

        // All three previous identities are released and can be assigned by governance to another admin.
        poc_registry::approve_app_identity(&framework, @0x20, APP, token, CUSTODY);
        poc_registry::register_app(&other, APP, token, CUSTODY, string::utf8(b"other"));
        assert!(poc_registry::get_app_admin_by_app_address(APP) == @0x20, 14);
        assert!(poc_registry::get_app_admin_by_equity_token(token) == @0x20, 15);
        assert!(poc_registry::get_app_admin_by_custody_address(CUSTODY) == @0x20, 16);
    }

    #[test(framework = @topo_framework, admin = @0x10)]
    fun approvals_do_not_reserve_identities_and_can_be_replaced(framework: signer, admin: signer) {
        // Approval storage works with a registry initialized before this resource existed.
        let token = prepare(&framework, &admin);
        poc_registry::revoke_app_identity_approval(&framework, @0x10);
        poc_registry::approve_app_identity(&framework, @0x20, APP, token, CUSTODY);
        assert!(!poc_registry::exists_app(@0x20), 1);
        assert!(poc_registry::get_app_admins_by_app_addresses(vector[APP]) == vector[@0x0], 2);
        poc_registry::approve_app_identity(&framework, @0x10, NEXT_APP, token, NEXT_CUSTODY);
        poc_registry::approve_app_identity(&framework, @0x10, APP, token, CUSTODY);
        poc_registry::register_app(&admin, APP, token, CUSTODY, string::utf8(b"app"));
        poc_registry::revoke_app_identity_approval(&framework, @0x20);
        poc_registry::revoke_app_identity_approval(&framework, @0x20);
        assert!(poc_registry::get_app_admin_by_app_address(APP) == @0x10, 3);
    }

    #[test(framework = @topo_framework, admin = @0x10, new_app = @0xa12, new_custody = @0xc02, issuer = @0x20)]
    fun identity_control_allows_updates_without_governance(
        framework: signer, admin: signer, new_app: signer, new_custody: signer, issuer: signer,
    ) {
        let token = register_approved(&framework, &admin);
        let (mint_ref, _, _, _, metadata) = fungible_asset::create_fungible_asset(&issuer);
        let next_token = object::object_address(&metadata);
        poc_registry::whitelist_app_for_poc(&framework, @0x10);

        poc_registry::update_app_address_with_signer(&admin, &new_app);
        assert!(poc_registry::get_app_address(@0x10) == NEXT_APP, 1);
        assert!(poc_registry::get_app_admins_by_app_addresses(vector[APP, NEXT_APP]) == vector[@0x0, @0x10], 2);
        assert!(poc_registry::is_poc_listed(@0x10), 3);

        poc_registry::update_custody_address_with_signer(&admin, &new_custody);
        assert!(poc_registry::get_custody_address(@0x10) == NEXT_CUSTODY, 4);
        assert!(poc_registry::get_app_admin_by_custody_address(NEXT_CUSTODY) == @0x10, 5);
        assert!(poc_registry::is_poc_listed(@0x10), 6);

        poc_registry::update_equity_token_address_with_mint_ref(&admin, &mint_ref);
        assert!(poc_registry::get_equity_token_address(@0x10) == next_token && next_token != token, 7);
        assert!(poc_registry::get_app_admin_by_equity_token(next_token) == @0x10, 8);
        assert!(poc_registry::get_poc_listing_status(@0x10) == 1, 9);
    }

    #[test(framework = @topo_framework, admin = @0x10, attacker = @0x20, new_app = @0xa12)]
    #[expected_failure(abort_code = 0x60006, location = topo_framework::poc_registry)]
    fun identity_proof_does_not_replace_admin_authorization(
        framework: signer, admin: signer, attacker: signer, new_app: signer,
    ) {
        register_approved(&framework, &admin);
        poc_registry::update_app_address_with_signer(&attacker, &new_app);
    }

    #[test(framework = @topo_framework, admin = @0x10, other = @0x20, app = @0xa11)]
    #[expected_failure(abort_code = 0x80003, location = topo_framework::poc_registry)]
    fun app_signer_does_not_bypass_unique_addresses(framework: signer, admin: signer, other: signer, app: signer) {
        register_approved(&framework, &admin);
        let token = create_token(&other);
        poc_registry::approve_app_identity(&framework, @0x20, NEXT_APP, token, NEXT_CUSTODY);
        poc_registry::register_app(&other, NEXT_APP, token, NEXT_CUSTODY, string::utf8(b"other"));
        poc_registry::update_app_address_with_signer(&other, &app);
    }

    #[test(framework = @topo_framework, admin = @0x10, other = @0x20, custody = @0xc01)]
    #[expected_failure(abort_code = 0x80005, location = topo_framework::poc_registry)]
    fun custody_signer_does_not_bypass_unique_addresses(framework: signer, admin: signer, other: signer, custody: signer) {
        register_approved(&framework, &admin);
        let token = create_token(&other);
        poc_registry::approve_app_identity(&framework, @0x20, NEXT_APP, token, NEXT_CUSTODY);
        poc_registry::register_app(&other, NEXT_APP, token, NEXT_CUSTODY, string::utf8(b"other"));
        poc_registry::update_custody_address_with_signer(&other, &custody);
    }

    #[test(framework = @topo_framework, admin = @0x10, other = @0x20)]
    #[expected_failure(abort_code = 0x80004, location = topo_framework::poc_registry)]
    fun mint_ref_does_not_bypass_unique_tokens(framework: signer, admin: signer, other: signer) {
        poc_registry::initialize_registry(&framework);
        let (mint_ref, _, _, _, metadata) = fungible_asset::create_fungible_asset(&admin);
        let token = object::object_address(&metadata);
        poc_registry::approve_app_identity(&framework, @0x10, APP, token, CUSTODY);
        poc_registry::register_app(&admin, APP, token, CUSTODY, string::utf8(b"app"));
        let other_token = create_token(&other);
        poc_registry::approve_app_identity(&framework, @0x20, NEXT_APP, other_token, NEXT_CUSTODY);
        poc_registry::register_app(&other, NEXT_APP, other_token, NEXT_CUSTODY, string::utf8(b"other"));
        poc_registry::update_equity_token_address_with_mint_ref(&other, &mint_ref);
    }

    #[test(framework = @topo_framework, admin = @0x10, custody = @0xc01, new_custody = @0xc02)]
    #[expected_failure(abort_code = 0x50010, location = topo_framework::poc_registry)]
    fun proof_update_invalidates_pending_governance_approval(
        framework: signer, admin: signer, custody: signer, new_custody: signer,
    ) {
        let token = register_approved(&framework, &admin);
        poc_registry::approve_app_identity(&framework, @0x10, NEXT_APP, token, CUSTODY);
        poc_registry::update_custody_address_with_signer(&admin, &new_custody);
        poc_registry::update_custody_address_with_signer(&admin, &custody);
        // Returning to the old binding must not revive the old governance approval.
        poc_registry::update_app_address(&admin, NEXT_APP);
    }
}
