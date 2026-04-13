module aptos_framework::staking_proxy {
    use std::error;
    use std::signer;
    use aptos_framework::permissioned_signer;
    use aptos_framework::stake;
    use aptos_framework::staking_contract;

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

    public entry fun set_operator(owner: &signer, old_operator: address, new_operator: address) {
        set_staking_contract_operator(owner, old_operator, new_operator);
        set_stake_pool_operator(owner, new_operator);
    }

    public entry fun set_staking_contract_operator(owner: &signer, old_operator: address, new_operator: address) {
        check_stake_proxy_permission(owner);
        let owner_address = signer::address_of(owner);
        if (staking_contract::staking_contract_exists(owner_address, old_operator)) {
            let current_commission_percentage = staking_contract::commission_percentage(owner_address, old_operator);
            staking_contract::switch_operator(owner, old_operator, new_operator, current_commission_percentage);
        };
    }

    public entry fun set_stake_pool_operator(owner: &signer, new_operator: address) {
        check_stake_proxy_permission(owner);
        let owner_address = signer::address_of(owner);
        if (stake::stake_pool_exists(owner_address)) {
            stake::set_operator(owner, new_operator);
        };
    }
}
