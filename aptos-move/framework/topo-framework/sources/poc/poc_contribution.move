/// POC Trusted Contribution Emission Contract — the sole trusted path for emitting contribution events.
///
/// ## Overview
///
/// This module is the execution entry point for the Topo chain's POC (Proof of Contribution) system.
/// It integrates equity token transfer + registry validation + contribution event emission into a
/// single atomic function call.
///
/// ## Core Design Principle: Non-Interference by Default, Strict When Requested
///
/// The default `grant_equity_with_contribution` path keeps the legacy non-interference
/// behavior: the equity token transfer executes even if POC validation fails, and
/// validation results only determine whether a `ContributionEvent` is emitted. This means:
/// - A failed validation never blocks the token transfer (the user always receives their tokens)
/// - Only the POC power accounting is affected by validation failures
/// - Applications can safely call this function without worrying about POC validation
///   causing unexpected transaction failures
///
/// Applications that promise POC credit should call
/// `grant_equity_with_contribution_strict` instead. The strict path validates POC
/// eligibility and custody identity before transfer, so validation failure aborts the
/// transaction and no equity tokens move.
///
/// ## Why This Module Exists (Trust Boundary)
///
/// Without this module, any Dapp could emit arbitrary `ContributionEvent`s to inflate
/// their users' POC power. This module enforces that:
/// 1. A real equity token transfer occurred in the same transaction
/// 2. The application is registered in poc_registry and currently ACTIVE
/// 3. The application has been whitelisted by the platform (WHITELISTED status)
/// 4. The custody signer matches the registered custody address (prevents impersonation)
/// 5. All key asset parameters (equity token address, custody address) come from the
///    registry — they are NOT trusted from external input
///
/// ## Call Pattern
///
/// This module's core function is `public fun` (not `entry fun`). Dapp applications
/// must call it from within their own `entry fun`. This design allows off-chain indexers
/// to attribute contribution events to specific applications by inspecting the transaction
/// payload's entry module address.
///
/// ## Typical Call Sequence
///
/// 1. User calls the Dapp application's `entry fun` (business entry point)
/// 2. Application completes its own business validation
/// 3. Application generates `app_signer` (signer for the contract deployment address)
///    and `custody_actor` (signer for the custody address)
/// 4. Application calls either:
///    - `grant_equity_with_contribution` for non-blocking business transfers
///    - `grant_equity_with_contribution_strict` when POC credit is part of the promise
/// 5. This module resolves app identity, equity token, and custody address from the registry
/// 6. Non-strict path transfers first and emits only if validation passes
/// 7. Strict path validates first, aborting before transfer if validation fails
///
/// ## Behavioral Guarantees
///
/// - Transfer fails → transaction aborts (transfer errors still propagate normally)
/// - Transfer succeeds but validation fails → transfer takes effect, no event emitted
/// - Transfer succeeds and validation passes → transfer takes effect, `ContributionEvent` emitted
/// - Strict validation fails → transaction aborts before transfer
module topo_framework::poc_contribution {
    use std::error;
    use std::signer;

    use topo_framework::event;
    use topo_framework::fungible_asset::Metadata;
    use topo_framework::object;
    use topo_framework::object::Object;
    use topo_framework::poc_power_store;
    use topo_framework::poc_registry;
    use topo_framework::primary_fungible_store;

    // ========== Error Codes ==========
    /// Equity amount must be greater than zero
    const EZERO_AMOUNT: u64 = 1;
    /// Strict contribution requires the app to be ACTIVE and WHITELISTED
    const EAPP_NOT_ELIGIBLE_FOR_POC: u64 = 2;
    /// Strict contribution requires the custody signer to match the registered custody address
    const ECUSTODY_ADDRESS_MISMATCH: u64 = 3;

    // ========== Contribution Event ==========

    #[event]
    /// Trusted contribution event — the protocol boundary of the POC power system.
    ///
    /// This event signifies: this module has completed a registry-validated standard equity
    /// distribution within the current transaction. The recipient is `contributor` and the
    /// platform-recognized target received amount is `equity_amount`.
    ///
    /// Sources of trustworthiness:
    /// - Event is emitted by the `poc_contribution` module (not by the application itself)
    /// - Event is only emitted after a real token transfer has succeeded
    /// - Key asset parameters (equity_token, custody_address) come from the registry, not external input
    /// - Off-chain indexers can cross-validate against the FA transfer event in the same transaction
    ///
    /// Off-chain indexers use this event to:
    /// 1. Identify which application made the contribution (via app_address)
    /// 2. Record the contributor's equity receipt for POC power calculation
    /// 3. Aggregate contribution data across periods for the operator to upload to poc_power_store
    struct ContributionEvent has drop, store {
        /// The address that received the equity tokens (the contributor being rewarded)
        contributor: address,
        /// The Fungible Asset metadata object for the equity token transferred
        equity_token: Object<Metadata>,
        /// The amount of equity tokens transferred (guaranteed to be the minimum received amount)
        equity_amount: u64,
        /// The application's contract deployment address (used for off-chain attribution)
        app_address: address,
        /// The POC power period when this contribution event was emitted
        period: u64,
    }

    // ========== Core Function ==========

    /// Trusted contribution distribution — transfer + validate + conditionally emit event.
    ///
    /// This is the ONLY entry point through which a Dapp application can emit a
    /// platform-recognized contribution event.
    ///
    /// Core principle: non-interference with application business logic.
    /// - Equity token transfer always executes, regardless of POC validation results
    /// - Validation results only determine whether a ContributionEvent is emitted
    /// - If validation fails, the transfer still completes; only the POC record is absent
    ///
    /// Execution flow:
    /// 1. Assert equity_amount > 0 (pre-condition for the transfer; aborts if violated)
    /// 2. Resolve equity_token from registry using app_signer's address (not from caller input)
    /// 3. Execute equity token transfer via transfer_assert_minimum_deposit (always executes)
    /// 4. Check POC eligibility: app must be ACTIVE and WHITELISTED
    /// 5. If eligible: verify custody_actor's address matches the registered custody address
    /// 6. If both checks pass → emit ContributionEvent; otherwise → no event, transfer already done
    ///
    /// Parameters:
    /// - app_signer: Signer for the Dapp application's contract deployment address.
    ///   Typically generated by the application via SignerCapability for a resource account.
    ///   Used to look up the app's registration in poc_registry.
    /// - custody_actor: Signer for the custody address that holds equity tokens pending distribution.
    ///   Typically generated by the application via SignerCapability for a custody resource account.
    ///   Must match the custody_address registered in poc_registry.
    /// - contributor: The recipient address for the equity tokens (the user being rewarded)
    /// - equity_amount: The number of equity token units to transfer
    ///
    /// Why use transfer_assert_minimum_deposit instead of a plain transfer?
    /// - Some Fungible Assets may have dispatchable hooks, transfer fees, or special deposit logic
    ///   that cause the actual received amount to differ from the requested amount.
    /// - The platform's recognized contribution amount must equal the minimum amount the user
    ///   actually receives — not the amount requested.
    /// - Without the minimum deposit assertion, ContributionEvent.equity_amount could exceed
    ///   the true received amount, inflating POC power calculations.
    public fun grant_equity_with_contribution(
        app_signer: &signer,
        custody_actor: &signer,
        contributor: address,
        equity_amount: u64,
    ) {
        // Step 1: Validate equity_amount > 0.
        // This is a hard pre-condition: a zero-amount transfer is meaningless and
        // would produce a misleading ContributionEvent with equity_amount = 0.
        assert!(equity_amount > 0, error::invalid_argument(EZERO_AMOUNT));

        // Step 2: Resolve the equity token from the registry and execute the transfer.
        //
        // Key security property: the equity_token_address is read from poc_registry
        // using the app_signer's address as the lookup key — it is NOT accepted as a
        // parameter from the caller. This prevents a malicious app from passing a
        // different token address to transfer a cheaper token while claiming credit
        // for a more valuable one.
        //
        // transfer_assert_minimum_deposit is used instead of a plain transfer to
        // guarantee that the actual received amount equals equity_amount. If the FA
        // has hooks or fees that reduce the received amount, the transaction aborts
        // rather than emitting a ContributionEvent with an inflated equity_amount.
        let (
            app_admin,
            app_address,
            registered_custody_address,
            actual_custody_address,
            metadata,
        ) = resolve_contribution_context(app_signer, custody_actor);
        primary_fungible_store::transfer_assert_minimum_deposit(
            custody_actor,
            metadata,
            contributor,
            equity_amount,
            equity_amount,
        );

        // Step 3: Conditionally emit ContributionEvent based on POC eligibility checks.
        //
        // This block only affects whether the event is emitted — the transfer above
        // has already completed and cannot be rolled back by anything in this block.
        //
        // Two checks must both pass:
        // a) is_app_eligible_for_poc: app_state == ACTIVE && poc_listing_status == WHITELISTED
        //    If the app is paused, stopped, or not yet whitelisted, no event is emitted.
        // b) custody address match: the actual signer of custody_actor must equal the
        //    custody_address registered in poc_registry. This prevents a whitelisted app
        //    from using an unregistered custody account to emit contribution events.
        if (poc_registry::is_app_eligible_for_poc(app_admin)) {
            if (actual_custody_address == registered_custody_address) {
                emit_contribution_event(contributor, metadata, equity_amount, app_address);
            };
        };
    }

    /// Strict contribution distribution — validate first, then transfer and emit.
    ///
    /// Use this path when the application promises the recipient that the equity
    /// transfer will also be POC-counted. If the app is not ACTIVE + WHITELISTED or
    /// the custody signer is not the registered custody address, this function aborts
    /// before moving any equity tokens.
    public fun grant_equity_with_contribution_strict(
        app_signer: &signer,
        custody_actor: &signer,
        contributor: address,
        equity_amount: u64,
    ) {
        assert!(equity_amount > 0, error::invalid_argument(EZERO_AMOUNT));

        let (
            app_admin,
            app_address,
            registered_custody_address,
            actual_custody_address,
            metadata,
        ) = resolve_contribution_context(app_signer, custody_actor);
        assert!(
            poc_registry::is_app_eligible_for_poc(app_admin),
            error::permission_denied(EAPP_NOT_ELIGIBLE_FOR_POC),
        );
        assert!(
            actual_custody_address == registered_custody_address,
            error::permission_denied(ECUSTODY_ADDRESS_MISMATCH),
        );

        primary_fungible_store::transfer_assert_minimum_deposit(
            custody_actor,
            metadata,
            contributor,
            equity_amount,
            equity_amount,
        );
        emit_contribution_event(contributor, metadata, equity_amount, app_address);
    }

    fun resolve_contribution_context(
        app_signer: &signer,
        custody_actor: &signer,
    ): (address, address, address, address, Object<Metadata>) {
        let app_address = signer::address_of(app_signer);
        let app_admin = poc_registry::get_app_admin_by_app_address(app_address);
        let equity_token_address = poc_registry::get_equity_token_address(app_admin);
        let metadata = object::address_to_object<Metadata>(equity_token_address);
        let registered_custody_address = poc_registry::get_custody_address(app_admin);
        let actual_custody_address = signer::address_of(custody_actor);
        (
            app_admin,
            app_address,
            registered_custody_address,
            actual_custody_address,
            metadata,
        )
    }

    fun emit_contribution_event(
        contributor: address,
        metadata: Object<Metadata>,
        equity_amount: u64,
        app_address: address,
    ) {
        event::emit(ContributionEvent {
            contributor,
            equity_token: metadata,
            equity_amount,
            app_address,
            period: poc_power_store::get_current_period(),
        });
    }

    #[test_only]
    use std::string;
    #[test_only]
    use topo_framework::fungible_asset::{
        Self,
        Metadata as TestMetadata,
        MintRef,
        TestToken,
    };
    #[test_only]
    use topo_framework::timestamp;

    #[test_only]
    fun setup_test_app(
        framework: &signer,
        app_admin: &signer,
        custody: address,
        mint_to_custody_amount: u64,
        whitelist: bool,
    ): (Object<TestMetadata>, MintRef) {
        timestamp::set_time_has_started_for_testing(framework);
        poc_registry::initialize_registry(framework);

        let (constructor_ref, token_object) = fungible_asset::create_test_token(app_admin);
        let (mint_ref, _transfer_ref, _burn_ref) =
            primary_fungible_store::init_test_metadata_with_primary_store_enabled(&constructor_ref);
        let metadata = token_object.convert<TestToken, TestMetadata>();
        if (mint_to_custody_amount > 0) {
            primary_fungible_store::mint(&mint_ref, custody, mint_to_custody_amount);
        };

        let app_admin_address = signer::address_of(app_admin);
        poc_registry::register_app(
            app_admin,
            app_admin_address,
            object::object_address(&metadata),
            custody,
            string::utf8(b"https://app.example"),
        );
        if (whitelist) {
            poc_registry::whitelist_app_for_poc(framework, app_admin_address);
        };
        (metadata, mint_ref)
    }

    #[test(framework = @topo_framework, app_admin = @0xcafe, contributor = @0xface)]
    fun test_strict_contribution_transfers_and_emits(
        framework: &signer,
        app_admin: &signer,
        contributor: &signer,
    ) {
        let app_admin_address = signer::address_of(app_admin);
        let contributor_address = signer::address_of(contributor);
        let (metadata, _mint_ref) = setup_test_app(
            framework,
            app_admin,
            app_admin_address,
            50,
            true,
        );

        grant_equity_with_contribution_strict(
            app_admin,
            app_admin,
            contributor_address,
            20,
        );

        assert!(primary_fungible_store::balance(app_admin_address, metadata) == 30, 0);
        assert!(primary_fungible_store::balance(contributor_address, metadata) == 20, 1);
        assert!(
            event::emitted_events<ContributionEvent>().contains(&ContributionEvent {
                contributor: contributor_address,
                equity_token: metadata,
                equity_amount: 20,
                app_address: app_admin_address,
                period: 0,
            }),
            2,
        );
    }

    #[test(framework = @topo_framework, app_admin = @0xcafe, contributor = @0xface)]
    #[expected_failure(abort_code = 0x50002, location = Self)]
    fun test_strict_contribution_aborts_when_not_whitelisted(
        framework: &signer,
        app_admin: &signer,
        contributor: &signer,
    ) {
        let app_admin_address = signer::address_of(app_admin);
        let contributor_address = signer::address_of(contributor);
        setup_test_app(framework, app_admin, app_admin_address, 50, false);

        grant_equity_with_contribution_strict(
            app_admin,
            app_admin,
            contributor_address,
            20,
        );
    }

    #[test(
        framework = @topo_framework,
        app_admin = @0xcafe,
        custody = @0xbeef,
        contributor = @0xface
    )]
    #[expected_failure(abort_code = 0x50003, location = Self)]
    fun test_strict_contribution_aborts_on_custody_mismatch(
        framework: &signer,
        app_admin: &signer,
        custody: &signer,
        contributor: &signer,
    ) {
        let custody_address = signer::address_of(custody);
        let contributor_address = signer::address_of(contributor);
        setup_test_app(framework, app_admin, custody_address, 50, true);

        grant_equity_with_contribution_strict(
            app_admin,
            app_admin,
            contributor_address,
            20,
        );
    }

    #[test(framework = @topo_framework, app_admin = @0xcafe, contributor = @0xface)]
    fun test_legacy_contribution_still_transfers_without_event_when_not_whitelisted(
        framework: &signer,
        app_admin: &signer,
        contributor: &signer,
    ) {
        let app_admin_address = signer::address_of(app_admin);
        let contributor_address = signer::address_of(contributor);
        let (metadata, _mint_ref) = setup_test_app(
            framework,
            app_admin,
            app_admin_address,
            50,
            false,
        );

        grant_equity_with_contribution(
            app_admin,
            app_admin,
            contributor_address,
            20,
        );

        assert!(primary_fungible_store::balance(app_admin_address, metadata) == 30, 0);
        assert!(primary_fungible_store::balance(contributor_address, metadata) == 20, 1);
        assert!(event::emitted_events<ContributionEvent>().is_empty(), 2);
    }
}
