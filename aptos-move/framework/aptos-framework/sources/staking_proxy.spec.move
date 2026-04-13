spec aptos_framework::staking_proxy {
    /// <high-level-req>
    /// No.: 1
    /// Requirement: When updating the operator through the proxy, all dependent staking wrappers should follow it.
    /// Criticality: Medium
    /// Implementation: The proxy updates staking contracts and direct stake pools owned by the caller.
    /// Enforcement: Audited for operator-only mutation paths and uniqueness checks inside staking contracts.
    ///
    /// No.: 2
    /// Requirement: Proxy staking mutations should only be available to explicitly authorized permissioned signers.
    /// Criticality: High
    /// Implementation: All mutation entrypoints first validate `StakeProxyPermission`.
    /// Enforcement: Spec schemas below gate mutations on the permission check.
    /// </high-level-req>
    spec module {
        pragma verify = true;
        pragma aborts_if_is_partial;
    }

    spec grant_permission {
        pragma aborts_if_is_partial;
        aborts_if !permissioned_signer::spec_is_permissioned_signer(permissioned_signer);
        aborts_if permissioned_signer::spec_is_permissioned_signer(master);
        aborts_if signer::address_of(master) != signer::address_of(permissioned_signer);
    }

    spec set_operator(owner: &signer, old_operator: address, new_operator: address) {
        pragma verify = false;
        pragma aborts_if_is_partial;
        include SetStakePoolOperator;
        include SetStakingContractOperator;
    }

    spec set_staking_contract_operator(owner: &signer, old_operator: address, new_operator: address) {
        pragma aborts_if_is_partial;
        pragma verify = false;
        include SetStakingContractOperator;
    }

    spec schema SetStakingContractOperator {
        use aptos_std::simple_map;
        use aptos_framework::staking_contract::{Store};

        owner: &signer;
        old_operator: address;
        new_operator: address;

        include AbortsIfSignerPermissionStakeProxy {
            s: owner
        };

        let owner_address = signer::address_of(owner);
        let store = global<Store>(owner_address);
        let staking_contract_exists =
            exists<Store>(owner_address)
                && simple_map::spec_contains_key(store.staking_contracts, old_operator);
        aborts_if staking_contract_exists
            && simple_map::spec_contains_key(store.staking_contracts, new_operator);

        let post post_store = global<Store>(owner_address);
        ensures staking_contract_exists ==> !simple_map::spec_contains_key(post_store.staking_contracts, old_operator);
        ensures staking_contract_exists ==> simple_map::spec_contains_key(post_store.staking_contracts, new_operator);
    }

    spec set_stake_pool_operator(owner: &signer, new_operator: address) {
        include SetStakePoolOperator;
        include exists<stake::StakePool>(signer::address_of(owner)) ==> stake::AbortsIfSignerPermissionStake {
            s: owner
        };
    }

    spec schema SetStakePoolOperator {
        owner: &signer;
        new_operator: address;

        include AbortsIfSignerPermissionStakeProxy {
            s: owner
        };

        let owner_address = signer::address_of(owner);
        let ownership_cap = borrow_global<stake::OwnerCapability>(owner_address);
        let pool_address = ownership_cap.pool_address;
        aborts_if stake::stake_pool_exists(owner_address)
            && !(exists<stake::OwnerCapability>(owner_address) && stake::stake_pool_exists(pool_address));
        ensures stake::stake_pool_exists(owner_address)
            ==> global<stake::StakePool>(pool_address).operator_address == new_operator;
    }

    spec schema AbortsIfSignerPermissionStakeProxy {
        use aptos_framework::permissioned_signer;

        s: signer;
        let perm = StakeProxyPermission {};
        aborts_if !permissioned_signer::spec_check_permission_exists(s, perm);
    }
}
