spec topo_framework::staking_proxy {
    /// <high-level-req>
    /// No.: 1
    /// Requirement: When updating the operator through the proxy, the direct stake pool owned by the caller should follow it.
    /// Criticality: Medium
    /// Implementation: The proxy updates the direct stake pool owned by the caller.
    /// Enforcement: Spec schemas below constrain the mutation to the direct stake pool path.
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

    spec set_operator(owner: &signer, new_operator: address) {
        pragma aborts_if_is_partial;
        include SetStakePoolOperator;
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
        use topo_framework::permissioned_signer;

        s: signer;
        let perm = StakeProxyPermission {};
        aborts_if !permissioned_signer::spec_check_permission_exists(s, perm);
    }
}
