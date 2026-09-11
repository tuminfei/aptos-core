spec topo_framework::jwks {
    spec remove_oidc_provider_internal(provider_set: &mut SupportedOIDCProviders, name: vector<u8>): Option<vector<u8>> {
        pragma opaque;
        aborts_if false;
    }

    spec on_new_epoch(framework: &signer) {
        pragma opaque;
        include config_buffer::OnNewEpochApply<SupportedOIDCProviders>;
    }

    spec initialize(fx: &signer) {
        pragma opaque;
        aborts_if std::signer::address_of(fx) != @topo_framework;
        aborts_if exists<SupportedOIDCProviders>(@topo_framework);
        aborts_if exists<ObservedJWKs>(@topo_framework);
        aborts_if exists<Patches>(@topo_framework);
        aborts_if exists<PatchedJWKs>(@topo_framework);
        modifies global<SupportedOIDCProviders>(@topo_framework);
        modifies global<ObservedJWKs>(@topo_framework);
        modifies global<Patches>(@topo_framework);
        modifies global<PatchedJWKs>(@topo_framework);
        ensures exists<SupportedOIDCProviders>(@topo_framework);
        ensures exists<ObservedJWKs>(@topo_framework);
        ensures exists<Patches>(@topo_framework);
        ensures exists<PatchedJWKs>(@topo_framework);
    }

    spec initialize_with_defaults(fx: &signer, providers: vector<OIDCProvider>, patches: vector<Patch>) {
        pragma verify = false;
    }

    spec upsert_oidc_provider(fx: &signer, name: vector<u8>, config_url: vector<u8>): Option<vector<u8>> {
        use topo_framework::chain_status;
        pragma opaque;
        pragma aborts_if_is_partial;
        aborts_if std::signer::address_of(fx) != @topo_framework;
        aborts_if !chain_status::is_genesis();
        aborts_if !exists<SupportedOIDCProviders>(@topo_framework);
        modifies global<SupportedOIDCProviders>(@topo_framework);
    }

    spec remove_oidc_provider(fx: &signer, name: vector<u8>): Option<vector<u8>> {
        use topo_framework::chain_status;
        pragma opaque;
        pragma aborts_if_is_partial;
        aborts_if std::signer::address_of(fx) != @topo_framework;
        aborts_if !chain_status::is_genesis();
        aborts_if !exists<SupportedOIDCProviders>(@topo_framework);
        modifies global<SupportedOIDCProviders>(@topo_framework);
    }

    spec upsert_oidc_provider_for_next_epoch(fx: &signer, name: vector<u8>, config_url: vector<u8>): Option<vector<u8>> {
        aborts_if topo_framework::reconfiguration_state::spec_is_in_progress();
        pragma verify_duration_estimate = 120; // TODO: set because of timeout (property proved)
        pragma opaque;
        pragma aborts_if_is_partial;
        aborts_if std::signer::address_of(fx) != @topo_framework;
        modifies global<config_buffer::PendingConfigs>(@topo_framework);
    }

    spec remove_oidc_provider_for_next_epoch(fx: &signer, name: vector<u8>): Option<vector<u8>> {
        aborts_if topo_framework::reconfiguration_state::spec_is_in_progress();
        pragma opaque;
        pragma aborts_if_is_partial;
        aborts_if std::signer::address_of(fx) != @topo_framework;
        modifies global<config_buffer::PendingConfigs>(@topo_framework);
    }

    spec patch_federated_jwks(jwk_owner: &signer, patches: vector<Patch>) {
        pragma verify_duration_estimate = 80;
    }

    spec update_federated_jwk_set(jwk_owner: &signer, iss: vector<u8>, kid_vec: vector<String>, alg_vec: vector<String>, e_vec: vector<String>, n_vec: vector<String>) {
        pragma verify_duration_estimate = 80;
    }

    spec get_patched_jwk(issuer: vector<u8>, jwk_id: vector<u8>): JWK {
        pragma verify_duration_estimate = 80;
    }

    spec upsert_into_observed_jwks(fx: &signer, provider_jwks_vec: vector<ProviderJWKs>)  {
        pragma verify_duration_estimate = 80;
    }

    spec regenerate_patched_jwks() {
        pragma verify_duration_estimate = 80;
    }

    spec try_get_jwk_by_issuer(jwks: &AllProvidersJWKs, issuer: vector<u8>, jwk_id: vector<u8>): Option<JWK> {
        pragma verify_duration_estimate = 80;
    }

    spec remove_jwk(jwks: &mut ProviderJWKs, jwk_id: vector<u8>): Option<JWK> {
        pragma verify_duration_estimate = 80;
    }

    spec apply_patch(jwks: &mut AllProvidersJWKs, patch: Patch) {
        pragma aborts_if_is_partial;
        aborts_if patch.variant.type_name.bytes != b"0x1::jwks::PatchRemoveAll"
            && patch.variant.type_name.bytes != b"0x1::jwks::PatchRemoveIssuer"
            && patch.variant.type_name.bytes != b"0x1::jwks::PatchRemoveJWK"
            && patch.variant.type_name.bytes != b"0x1::jwks::PatchUpsertJWK";
        pragma verify_duration_estimate = 80;
    }

    spec try_get_patched_jwk(issuer: vector<u8>, jwk_id: vector<u8>): Option<JWK> {
        pragma verify_duration_estimate = 80;
    }

    spec set_patches(fx: &signer, patches: vector<Patch>) {
        // 原有补丁应用可能因输入数据而失败；保留其部分失败契约，
        // 此处补证新增冻结检查及可直接确定的权限、资源缺失条件。
        pragma aborts_if_is_partial;
        aborts_if topo_framework::reconfiguration_state::spec_is_in_progress();
        aborts_if std::signer::address_of(fx) != @topo_framework;
        aborts_if !exists<Patches>(@topo_framework);
        aborts_if !exists<ObservedJWKs>(@topo_framework);
        aborts_if !exists<PatchedJWKs>(@topo_framework);
        pragma verify_duration_estimate = 80;
    }

    spec remove_issuer_from_observed_jwks(fx: &signer, issuer: vector<u8>): Option<ProviderJWKs> {
        pragma verify_duration_estimate = 80;
    }


    spec try_get_jwk_by_id(provider_jwks: &ProviderJWKs, jwk_id: vector<u8>): Option<JWK> {
        pragma verify_duration_estimate = 80;
    }

    spec remove_issuer(jwks: &mut AllProvidersJWKs, issuer: vector<u8>): Option<ProviderJWKs> {
        use std::option;
        use std::vector;
        pragma opaque;
        ensures option::is_none(result) <==> (forall jwk: ProviderJWKs where vector::spec_contains(old(jwks).entries, jwk): jwk.issuer != issuer);
        ensures option::is_none(result) ==> old(jwks) == jwks;
        ensures option::is_some(result) ==> vector::spec_contains(old(jwks).entries, option::borrow(result));
    }

}
