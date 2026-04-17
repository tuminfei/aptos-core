/// POC Trusted Contribution Emission Contract — the sole trusted path for emitting contribution events.
///
/// ## Overview
///
/// This module is the execution entry point for the Topo chain's POC (Proof of Contribution) system.
/// It integrates equity token transfer + registry validation + contribution event emission into a
/// single atomic function call.
///
/// ## Core Design Principle: Non-Interference with Application Business Logic
///
/// The equity token transfer ALWAYS executes, regardless of POC validation results.
/// Validation results only determine whether a `ContributionEvent` is emitted.
/// This means:
/// - A failed validation never blocks the token transfer (the user always receives their tokens)
/// - Only the POC power accounting is affected by validation failures
/// - Applications can safely call this function without worrying about POC validation
///   causing unexpected transaction failures
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
/// 4. Application calls `grant_equity_with_contribution(app_signer, custody_actor, contributor, equity_amount)`
/// 5. This module executes the equity token transfer (always, regardless of validation)
/// 6. This module validates app identity, POC eligibility, and custody address from the registry
/// 7. If all validations pass → emit `ContributionEvent`; otherwise → no event, transfer already done
///
/// ## Behavioral Guarantees
///
/// - Transfer fails → transaction aborts (transfer errors still propagate normally)
/// - Transfer succeeds but validation fails → transfer takes effect, no event emitted
/// - Transfer succeeds and validation passes → transfer takes effect, `ContributionEvent` emitted
module aptos_framework::poc_contribution {
    use std::error;
    use std::signer;

    use aptos_framework::event;
    use aptos_framework::fungible_asset::Metadata;
    use aptos_framework::object;
    use aptos_framework::object::Object;
    use aptos_framework::poc_registry;
    use aptos_framework::primary_fungible_store;

    // ========== Error Codes ==========
    /// Equity amount must be greater than zero
    const EZERO_AMOUNT: u64 = 1;

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
            let registered_custody_address = poc_registry::get_custody_address(app_admin);
            let actual_custody_address = signer::address_of(custody_actor);
            if (actual_custody_address == registered_custody_address) {
                event::emit(ContributionEvent {
                    contributor,
                    equity_token: metadata,
                    equity_amount,
                    app_address
                });
            };
        };
    }
}
