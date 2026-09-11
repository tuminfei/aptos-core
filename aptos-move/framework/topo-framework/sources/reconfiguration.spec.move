spec topo_framework::reconfiguration {
    /// <high-level-req>
    /// No.: 1
    /// Requirement: The Configuration resource is stored under the Aptos framework account with initial values upon
    /// module's initialization.
    /// Criticality: Medium
    /// Implementation: The Configuration resource may only be initialized with specific values and published under the
    /// topo_framework account.
    /// Enforcement: Formally verified via [high-level-req-1](initialize).
    ///
    /// No.: 2
    /// Requirement: The reconfiguration status may be determined at any time without causing an abort, indicating whether
    /// or not the system allows reconfiguration.
    /// Criticality: Low
    /// Implementation: The reconfiguration_enabled function will never abort and always returns a boolean value that
    /// accurately represents whether the system allows reconfiguration.
    /// Enforcement: Formally verified via [high-level-req-2](reconfiguration_enabled).
    ///
    /// No.: 3
    /// Requirement: For each reconfiguration, the epoch value (config_ref.epoch) increases by 1, and one 'NewEpochEvent'
    /// is emitted.
    /// Criticality: Critical
    /// Implementation: After reconfiguration, the reconfigure() function increases the epoch value of the configuration
    /// by one and increments the counter of the NewEpochEvent's EventHandle by one.
    /// Enforcement: Audited that these two values remain in sync.
    ///
    /// No.: 4
    /// Requirement: Reconfiguration is possible only if genesis has started and reconfiguration is enabled. Also, the last
    /// reconfiguration must not be the current time, returning early without further actions otherwise.
    /// Criticality: High
    /// Implementation: The reconfigure() function may only execute to perform successful reconfiguration when genesis
    /// has started and when reconfiguration is enabled. Without satisfying both conditions, the function returns early
    /// without executing any further actions.
    /// Enforcement: Formally verified via [high-level-req-4](reconfigure).
    ///
    /// No.: 5
    /// Requirement: Consecutive reconfigurations without the passage of time are not permitted.
    /// Criticality: High
    /// Implementation: The reconfigure() function enforces the restriction that reconfiguration may only be performed
    /// when the current time is not equal to the last_reconfiguration_time.
    /// Enforcement: Formally verified via [high-level-req-5](reconfigure).
    /// </high-level-req>
    ///

    spec module {
        pragma verify = true;
        pragma aborts_if_is_strict;

        // After genesis, `Configuration` exists.
        invariant [suspendable] chain_status::is_operating() ==>
            exists<Configuration>(@topo_framework);
        invariant [suspendable] chain_status::is_operating() ==>
            (timestamp::spec_now_microseconds() >= last_reconfiguration_time());
    }

    /// Make sure the signer address is @topo_framework.
    spec schema AbortsIfNotTopoFramework {
        topo_framework: &signer;

        let addr = signer::address_of(topo_framework);
        aborts_if !system_addresses::is_topo_framework_address(addr);
    }

    /// Address @topo_framework must exist resource Account and Configuration.
    /// Already exists in framework account.
    /// Guid_creation_num should be 2 according to logic.
    spec initialize(topo_framework: &signer) {
        use std::signer;
        use topo_framework::account::{Account};
        use topo_framework::guid;

        include AbortsIfNotTopoFramework;
        let addr = signer::address_of(topo_framework);
        let post config = global<Configuration>(@topo_framework);
        requires exists<Account>(addr);
        aborts_if !(global<Account>(addr).guid_creation_num == 2);
        aborts_if exists<Configuration>(@topo_framework);
        // property 1: During the module's initialization, it guarantees that the Configuration resource will move under
        // the Aptos framework account with initial values.
        /// [high-level-req-1]
        ensures exists<Configuration>(@topo_framework);
        ensures config.epoch == 0 && config.last_reconfiguration_time == 0;
        ensures config.events
            == event::EventHandle<NewEpochEvent> {
                counter: 0,
                guid: guid::GUID {
                    id: guid::ID { creation_num: 2, addr: @topo_framework }
                }
            };
    }

    spec current_epoch(): u64 {
        aborts_if !exists<Configuration>(@topo_framework);
        ensures result == global<Configuration>(@topo_framework).epoch;
    }

    spec disable_reconfiguration(topo_framework: &signer) {
        include AbortsIfNotTopoFramework;
        aborts_if exists<DisableReconfiguration>(@topo_framework);
        ensures exists<DisableReconfiguration>(@topo_framework);
    }

    /// Make sure the caller is admin and check the resource DisableReconfiguration.
    spec enable_reconfiguration(topo_framework: &signer) {
        use topo_framework::reconfiguration::{DisableReconfiguration};
        include AbortsIfNotTopoFramework;
        aborts_if !exists<DisableReconfiguration>(@topo_framework);
        ensures !exists<DisableReconfiguration>(@topo_framework);
    }

    /// When genesis_event emit the epoch and the `last_reconfiguration_time` .
    /// Should equal to 0
    spec emit_genesis_reconfiguration_event {
        use topo_framework::reconfiguration::{Configuration};

        aborts_if !exists<Configuration>(@topo_framework);
        let config_ref = global<Configuration>(@topo_framework);
        aborts_if !(config_ref.epoch == 0 && config_ref.last_reconfiguration_time == 0);
        ensures global<Configuration>(@topo_framework).epoch == 1;
    }

    spec last_reconfiguration_time {
        aborts_if !exists<Configuration>(@topo_framework);
        ensures result
                == global<Configuration>(@topo_framework).last_reconfiguration_time;
    }

    spec transition_allowed {
        pragma opaque;
        aborts_if false;
        ensures result == spec_transition_allowed();
    }

    spec fun spec_transition_allowed(): bool {
        !chain_status::is_genesis()
            && timestamp::spec_now_microseconds() != 0
            && !exists<DisableReconfiguration>(@topo_framework)
            && timestamp::spec_now_microseconds()
                != global<Configuration>(@topo_framework).last_reconfiguration_time
    }

    spec prepare_transition {
        pragma opaque;
        include stake::ResourceRequirement;
        include stake::GetReconfigStartTimeRequirement;
        include topo_framework::staking_config::StakingRewardsConfigRequirement;
        pragma aborts_if_is_partial;
        modifies global<reconfiguration_state::State>(@topo_framework);
        modifies global<stake::EpochPlan>(@topo_framework);
        modifies global<stake::PrecomputedValidatorSet>(@topo_framework);
        modifies global<std::features::PendingFeatureFreeze>(@std);
        ensures global<Configuration>(@topo_framework) == old(global<Configuration>(@topo_framework));
        ensures !old(stake::is_poc_prepared()) && old(spec_transition_allowed()) ==> result;
        ensures result ==> old(spec_transition_allowed());
        ensures result ==> chain_status::is_operating();
        ensures result && exists<reconfiguration_state::State>(@topo_framework) ==>
            reconfiguration_state::spec_is_in_progress();
        ensures result && exists<reconfiguration_state::State>(@topo_framework) ==>
            reconfiguration_state::spec_active_state_is_valid();
        ensures result && stake::is_poc_prepared() ==>
            exists<stake::EpochPlan>(@topo_framework) && exists<stake::PrecomputedValidatorSet>(@topo_framework);
        ensures result && stake::is_poc_prepared() ==>
            global<stake::EpochPlan>(@topo_framework).data.epoch
                == global<Configuration>(@topo_framework).epoch + 1;
        ensures !result ==> reconfiguration_state::spec_is_in_progress()
            == old(reconfiguration_state::spec_is_in_progress());
    }

    spec complete_epoch {
        pragma opaque;
        requires chain_status::is_operating();
        pragma aborts_if_is_partial;
        modifies global<Configuration>(@topo_framework);
        modifies global<reconfiguration_state::State>(@topo_framework);
        modifies global<stake::EpochPlan>(@topo_framework);
        modifies global<stake::PrecomputedValidatorSet>(@topo_framework);
        modifies global<std::features::PendingFeatureFreeze>(@std);
        modifies global<storage_gas::StorageGas>(@topo_framework);
        aborts_if timestamp::spec_now_microseconds()
            <= global<Configuration>(@topo_framework).last_reconfiguration_time;
        aborts_if global<Configuration>(@topo_framework).epoch == MAX_U64;
        ensures exists<Configuration>(@topo_framework);
        ensures global<Configuration>(@topo_framework).epoch <= MAX_U64;
        ensures global<Configuration>(@topo_framework).epoch
            == old(global<Configuration>(@topo_framework).epoch) + 1;
        ensures global<Configuration>(@topo_framework).last_reconfiguration_time
            == timestamp::spec_now_microseconds();
        ensures !reconfiguration_state::spec_is_in_progress();
    }

    spec complete_prepared_transition {
        requires chain_status::is_operating();
        include stake::ResourceRequirement;
        include topo_framework::staking_config::StakingRewardsConfigRequirement;
        pragma aborts_if_is_partial;
        aborts_if global<Configuration>(@topo_framework).epoch == MAX_U64;
        ensures global<Configuration>(@topo_framework).epoch
            == old(global<Configuration>(@topo_framework).epoch) + 1;
        ensures global<topo_framework::poc_accounting::AccountingState>(@topo_framework).epoch
            == global<Configuration>(@topo_framework).epoch;
        ensures !reconfiguration_state::spec_is_in_progress();
    }

    spec install_genesis_poc_epoch {
        include stake::ResourceRequirement;
        include stake::GetReconfigStartTimeRequirement;
        include topo_framework::staking_config::StakingRewardsConfigRequirement;
        include topo_framework::topo_coin::ExistsTopoCoin;
        pragma aborts_if_is_partial;
        aborts_if chain_status::is_operating();
        aborts_if !exists<Configuration>(@topo_framework);
        aborts_if global<Configuration>(@topo_framework).epoch != 0;
        ensures global<Configuration>(@topo_framework).epoch == 0;
        ensures !reconfiguration_state::spec_is_in_progress();
        ensures !exists<stake::EpochPlan>(@topo_framework);
        ensures !exists<stake::PrecomputedValidatorSet>(@topo_framework);
    }

    spec reconfigure {
        use topo_framework::topo_coin;
        use topo_framework::staking_config;
        use std::features;

        pragma verify = true;

        let success = spec_transition_allowed();
        include features::spec_periodical_reward_rate_decrease_enabled() ==>
            staking_config::StakingRewardsConfigEnabledRequirement;
        include success ==> topo_coin::ExistsTopoCoin;
        // PoC 目标可能不合格而延期，冻结状态损坏时则必须中止。
        // 原生流程的前提不足以证明新增计划的不变量，不能沿用原有的无中止假设。
        pragma aborts_if_is_partial;
        aborts_if success && global<Configuration>(@topo_framework).epoch == MAX_U64;
        // The ensure conditions of the reconfigure function are not fully written, because there is a new cycle in it,
        // but its existing ensure conditions satisfy hp.
        // The property below is not proved within 500s and still cause an timeout
        // property 3: Synchronization of NewEpochEvent counter with configuration epoch.
        ensures success ==>
            global<Configuration>(@topo_framework).epoch
                == old(global<Configuration>(@topo_framework).epoch) + 1;
        ensures success ==>
            global<Configuration>(@topo_framework).last_reconfiguration_time
                == timestamp::spec_now_microseconds();
        // We remove the ensures of event increment due to inconsisency
        // TODO: property 4: Only performs reconfiguration if genesis has started and reconfiguration is enabled.
        // Also, the last reconfiguration must not be the current time, returning early without further actions otherwise.
        // property 5: Consecutive reconfigurations without the passage of time are not permitted.
        /// [high-level-req-4]
        /// [high-level-req-5]
        ensures !success ==>
            global<Configuration>(@topo_framework).epoch
                == old(global<Configuration>(@topo_framework).epoch);
    }

    spec try_reconfigure {
        pragma opaque;
        modifies global<Configuration>(@topo_framework);
        include stake::ResourceRequirement;
        include stake::GetReconfigStartTimeRequirement;
        include topo_framework::staking_config::StakingRewardsConfigRequirement;
        include topo_framework::topo_coin::ExistsTopoCoin;
        pragma aborts_if_is_partial;
        aborts_if !stake::is_poc_prepared() && spec_transition_allowed()
            && global<Configuration>(@topo_framework).epoch == MAX_U64;
        ensures old(stake::is_poc_prepared()) || !old(spec_transition_allowed()) ==> !result;
        ensures !result ==> global<Configuration>(@topo_framework).epoch
            == old(global<Configuration>(@topo_framework).epoch);
        ensures !result ==> global<Configuration>(@topo_framework).last_reconfiguration_time
            == old(global<Configuration>(@topo_framework).last_reconfiguration_time);
        ensures result ==> global<Configuration>(@topo_framework).epoch
            == old(global<Configuration>(@topo_framework).epoch) + 1;
        ensures result ==> old(global<Configuration>(@topo_framework).epoch) < MAX_U64;
        ensures result ==> global<Configuration>(@topo_framework).last_reconfiguration_time
            == timestamp::spec_now_microseconds();
        ensures result ==> !reconfiguration_state::spec_is_in_progress();
    }

    spec reconfiguration_enabled {
        // property 2: The reconfiguration status may be determined at any time without causing an abort, indicating
        // whether or not the system allows reconfiguration.
        /// [high-level-req-2]
        aborts_if false;
        ensures result == !exists<DisableReconfiguration>(@topo_framework);
    }
}
