spec aptos_framework::staking_registry {
    spec get_effective_power(user: address): u64 {
        ensures result == spec_get_effective_power(user);
    }

    spec fun spec_get_effective_power(user: address): u64;
}
