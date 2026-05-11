module topo_framework::staking_proxy {
    use std::error;
    use std::signer;
    use topo_framework::permissioned_signer;
    use topo_framework::stake;

    struct StakeProxyPermission has copy, drop, store {}

    /// Signer does not have permission to perform stake proxy logic.
    const ENO_STAKE_PERMISSION: u64 = 28;
    /// Permissions
    inline fun check_stake_proxy_permission(s: &signer) {
        assert!(
            permissioned_signer::check_permission_exists(s, StakeProxyPermission {}),
            error::permission_denied(ENO_STAKE_PERMISSION),
        );
    }

    /// Grant permission to mutate staking on behalf of the master signer.
    public fun grant_permission(master: &signer, permissioned_signer: &signer) {
        permissioned_signer::authorize_unlimited(master, permissioned_signer, StakeProxyPermission {})
    }

    public entry fun set_operator(owner: &signer, new_operator: address) {
        set_stake_pool_operator(owner, new_operator);
    }

    public entry fun set_stake_pool_operator(owner: &signer, new_operator: address) {
        check_stake_proxy_permission(owner);
        let owner_address = signer::address_of(owner);
        if (stake::stake_pool_exists(owner_address)) {
            stake::set_operator(owner, new_operator);
        };
    }
}
