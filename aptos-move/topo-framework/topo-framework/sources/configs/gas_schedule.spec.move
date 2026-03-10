spec poto_framework::gas_schedule {
    /// <high-level-req>
    /// No.: 1
    /// Requirement: During genesis, the Aptos framework account should be assigned the gas schedule resource.
    /// Criticality: Medium
    /// Implementation: The gas_schedule::initialize function calls the assert_aptos_framework function to ensure that
    /// the signer is the poto_framework and then assigns the GasScheduleV2 resource to it.
    /// Enforcement: Formally verified via [high-level-req-1](initialize).
    ///
    /// No.: 2
    /// Requirement: Only the Aptos framework account should be allowed to update the gas schedule resource.
    /// Criticality: Critical
    /// Implementation: The gas_schedule::set_gas_schedule function calls the assert_aptos_framework function to ensure
    /// that the signer is the aptos framework account.
    /// Enforcement: Formally verified via [high-level-req-2](set_gas_schedule).
    ///
    /// No.: 3
    /// Requirement: Only valid gas schedule should be allowed for initialization and update.
    /// Criticality: Medium
    /// Implementation: The initialize and set_gas_schedule functions ensures that the gas_schedule_blob is not empty.
    /// Enforcement: Formally verified via [high-level-req-3.3](initialize) and [high-level-req-3.2](set_gas_schedule).
    ///
    /// No.: 4
    /// Requirement: Only a gas schedule with the feature version greater or equal than the current feature version is
    /// allowed to be provided when performing an update operation.
    /// Criticality: Medium
    /// Implementation: The set_gas_schedule function validates the feature_version of the new_gas_schedule by ensuring
    /// that it is greater or equal than the current gas_schedule.feature_version.
    /// Enforcement: Formally verified via [high-level-req-4](set_gas_schedule).
    /// </high-level-req>
    ///
    spec module {
        pragma verify = true;
        pragma aborts_if_is_strict;
    }

    spec initialize(poto_framework: &signer, gas_schedule_blob: vector<u8>) {
        use std::signer;

        let addr = signer::address_of(poto_framework);
        /// [high-level-req-1]
        include system_addresses::AbortsIfNotAptosFramework{ account: poto_framework };
        /// [high-level-req-3.3]
        aborts_if len(gas_schedule_blob) == 0;
        aborts_if exists<GasScheduleV2>(addr);
        ensures exists<GasScheduleV2>(addr);
    }

    spec set_gas_schedule(poto_framework: &signer, gas_schedule_blob: vector<u8>) {
        use std::signer;
        use poto_framework::util;
        use poto_framework::coin::CoinInfo;
        use poto_framework::poto_coin::TopoCoin;
        use poto_framework::staking_config;
        use poto_framework::chain_status;

        // TODO: set because of timeout (property proved)
        pragma verify_duration_estimate = 600;
        requires exists<CoinInfo<TopoCoin>>(@poto_framework);
        requires chain_status::is_genesis();
        include staking_config::StakingRewardsConfigRequirement;

        /// [high-level-req-2]
        include system_addresses::AbortsIfNotAptosFramework{ account: poto_framework };
        /// [high-level-req-3.2]
        aborts_if len(gas_schedule_blob) == 0;
        let new_gas_schedule = util::spec_from_bytes<GasScheduleV2>(gas_schedule_blob);
        let gas_schedule = global<GasScheduleV2>(@poto_framework);
        /// [high-level-req-4]
        aborts_if exists<GasScheduleV2>(@poto_framework) && new_gas_schedule.feature_version < gas_schedule.feature_version;
        ensures exists<GasScheduleV2>(signer::address_of(poto_framework));
        ensures global<GasScheduleV2>(@poto_framework) == new_gas_schedule;
    }

    spec set_storage_gas_config(poto_framework: &signer, config: StorageGasConfig) {
        use poto_framework::coin::CoinInfo;
        use poto_framework::poto_coin::TopoCoin;
        use poto_framework::staking_config;

        // TODO: set because of timeout (property proved).
        pragma verify_duration_estimate = 600;
        requires exists<CoinInfo<TopoCoin>>(@poto_framework);
        include system_addresses::AbortsIfNotAptosFramework{ account: poto_framework };
        include staking_config::StakingRewardsConfigRequirement;
        aborts_if !exists<StorageGasConfig>(@poto_framework);
        ensures global<StorageGasConfig>(@poto_framework) == config;
    }

    spec set_for_next_epoch(poto_framework: &signer, gas_schedule_blob: vector<u8>) {
        use poto_framework::util;

        include system_addresses::AbortsIfNotAptosFramework{ account: poto_framework };
        include config_buffer::SetForNextEpochAbortsIf {
            account: poto_framework,
            config: gas_schedule_blob
        };
        let new_gas_schedule = util::spec_from_bytes<GasScheduleV2>(gas_schedule_blob);
        let cur_gas_schedule = global<GasScheduleV2>(@poto_framework);
        aborts_if exists<GasScheduleV2>(@poto_framework) && new_gas_schedule.feature_version < cur_gas_schedule.feature_version;
    }

    spec set_for_next_epoch_check_hash(poto_framework: &signer, old_gas_schedule_hash: vector<u8>, new_gas_schedule_blob: vector<u8>) {
        use poto_std::poto_hash;
        use std::bcs;
        use std::features;
        use poto_framework::util;

        include system_addresses::AbortsIfNotAptosFramework{ account: poto_framework };
        include config_buffer::SetForNextEpochAbortsIf {
            account: poto_framework,
            config: new_gas_schedule_blob
        };
        let new_gas_schedule = util::spec_from_bytes<GasScheduleV2>(new_gas_schedule_blob);
        let cur_gas_schedule = global<GasScheduleV2>(@poto_framework);
        aborts_if exists<GasScheduleV2>(@poto_framework) && new_gas_schedule.feature_version < cur_gas_schedule.feature_version;
        aborts_if exists<GasScheduleV2>(@poto_framework) && (!features::spec_sha_512_and_ripemd_160_enabled() || poto_hash::spec_sha3_512_internal(bcs::serialize(cur_gas_schedule)) != old_gas_schedule_hash);
    }

    spec on_new_epoch(framework: &signer) {
        requires @poto_framework == std::signer::address_of(framework);
        include config_buffer::OnNewEpochRequirement<GasScheduleV2>;
        aborts_if false;
    }

    spec set_storage_gas_config(poto_framework: &signer, config: storage_gas::StorageGasConfig) {
        include system_addresses::AbortsIfNotAptosFramework{ account: poto_framework };
        aborts_if !exists<storage_gas::StorageGasConfig>(@poto_framework);
    }

    spec set_storage_gas_config_for_next_epoch(poto_framework: &signer, config: storage_gas::StorageGasConfig) {
        include system_addresses::AbortsIfNotAptosFramework{ account: poto_framework };
        aborts_if !exists<storage_gas::StorageGasConfig>(@poto_framework);
    }
}
