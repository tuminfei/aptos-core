spec topo_framework::reconfiguration_with_dkg {
    spec module {
        pragma verify = true;
    }

    spec schema StartRequirement {
        requires topo_framework::chain_status::is_operating();
        include stake::ResourceRequirement;
        include stake::GetReconfigStartTimeRequirement;
        include topo_framework::staking_config::StakingRewardsConfigRequirement;
    }

    spec try_start_internal {
        pragma opaque;
        include StartRequirement;
        pragma aborts_if_is_partial;
        ensures !old(reconfiguration_state::spec_is_in_progress())
            && reconfiguration_state::spec_is_in_progress() ==>
            exists<stake::PrecomputedValidatorSet>(@topo_framework);
    } proof {
        split stake::is_poc_prepared();
        split reconfiguration_state::spec_is_in_progress();
        split with_chunky;
    }

    spec validate_cached_plan {
        pragma opaque;
        pragma aborts_if_is_partial;
        ensures stake::is_poc_prepared() ==>
            exists<stake::EpochPlan>(@topo_framework)
                && exists<stake::PrecomputedValidatorSet>(@topo_framework);
        ensures stake::is_poc_prepared() ==>
            global<stake::EpochPlan>(@topo_framework).data.epoch
                == global<reconfiguration::Configuration>(@topo_framework).epoch + 1;
        ensures stake::is_poc_prepared() ==> reconfiguration_state::spec_is_in_progress();
    }

    spec require_start {
        include StartRequirement;
        pragma aborts_if_is_partial;
    }

    spec require_start_with_chunky_dkg {
        include StartRequirement;
        pragma aborts_if_is_partial;
    }

    spec try_start() {
        use topo_framework::chain_status;
        use topo_framework::staking_config;
        use topo_framework::reconfiguration;
        use topo_framework::reconfiguration_state;
        requires exists<reconfiguration::Configuration>(@topo_framework);
        requires chain_status::is_operating();
        include stake::ResourceRequirement;
        include stake::GetReconfigStartTimeRequirement;
        include features::spec_periodical_reward_rate_decrease_enabled() ==>
            staking_config::StakingRewardsConfigEnabledRequirement;
        pragma aborts_if_is_partial;
        // I2：开始换届时必须建立目标缓存；重复调用若直接返回，则不受此约束。
        ensures !old(reconfiguration_state::spec_is_in_progress())
            && reconfiguration_state::spec_is_in_progress() ==>
            exists<stake::PrecomputedValidatorSet>(@topo_framework);
    }

    spec try_start_with_chunky_dkg() {
        use topo_framework::chain_status;
        use topo_framework::staking_config;
        use topo_framework::reconfiguration;
        use topo_framework::reconfiguration_state;
        use topo_framework::chunky_dkg;
        use topo_framework::timestamp;
        requires exists<reconfiguration::Configuration>(@topo_framework);
        requires chain_status::is_operating();
        requires exists<chunky_dkg::ChunkyDKGState>(@topo_framework);
        requires exists<timestamp::CurrentTimeMicroseconds>(@topo_framework);
        include stake::ResourceRequirement;
        include stake::GetReconfigStartTimeRequirement;
        include features::spec_periodical_reward_rate_decrease_enabled() ==>
            staking_config::StakingRewardsConfigEnabledRequirement;
        pragma aborts_if_is_partial;
        // I2：与 try_start 共用目标缓存存在性约束。
        ensures !old(reconfiguration_state::spec_is_in_progress())
            && reconfiguration_state::spec_is_in_progress() ==>
            exists<stake::PrecomputedValidatorSet>(@topo_framework);
    }

    spec finish(framework: &signer) {
        include FinishRequirement;
        pragma aborts_if_is_partial;
    }

    spec try_finish {
        pragma opaque;
        include FinishRequirement;
        include stake::ResourceRequirement;
        include stake::GetReconfigStartTimeRequirement;
        pragma aborts_if_is_partial;
        ensures !result ==> global<reconfiguration::Configuration>(@topo_framework)
            == old(global<reconfiguration::Configuration>(@topo_framework));
    } proof {
        split stake::is_poc_prepared();
    }

    spec try_finish_for_block {
        include FinishResourceRequirement;
        include stake::ResourceRequirement;
        include stake::GetReconfigStartTimeRequirement;
        pragma aborts_if_is_partial;
    }

    spec apply_pending_configs {
        pragma opaque;
        requires topo_framework::chain_status::is_operating();
        requires std::signer::address_of(framework) == @topo_framework;
        include PendingConfigsRequirement;
        pragma aborts_if_is_partial;
        ensures global<reconfiguration::Configuration>(@topo_framework)
            == old(global<reconfiguration::Configuration>(@topo_framework));
        ensures reconfiguration_state::spec_is_in_progress()
            == old(reconfiguration_state::spec_is_in_progress());
    } proof {
        split prepared;
    }

    spec schema FinishRequirement {
        use std::signer;
        framework: signer;
        requires signer::address_of(framework) == @topo_framework;
        include FinishResourceRequirement;
    }

    spec schema FinishResourceRequirement {
        use topo_framework::chain_status;
        use topo_framework::coin::CoinInfo;
        use topo_framework::topo_coin::TopoCoin;
        use topo_framework::staking_config;
        requires chain_status::is_operating();
        requires exists<CoinInfo<TopoCoin>>(@topo_framework);
        include stake::ResourceRequirement;
        include stake::GetReconfigStartTimeRequirement;
        include staking_config::StakingRewardsConfigRequirement;
        include PendingConfigsRequirement;
    }

    spec schema PendingConfigsRequirement {
        requires exists<features::Features>(@std);
    }

    spec try_finalize_reconfig(account: &signer) {
        pragma opaque;
        include FinishRequirement { framework: account };
        pragma aborts_if_is_partial;
    }

    spec finish_with_dkg_result(account: &signer, dkg_result: vector<u8>) {
        use topo_framework::dkg;
        include FinishRequirement { framework: account };
        requires dkg::has_incomplete_session();
        pragma aborts_if_is_partial;
    }

    spec finish_with_chunky_dkg_result(account: &signer, chunky_dkg_result: vector<u8>, encryption_key: vector<u8>) {
        include FinishRequirement { framework: account };
        pragma aborts_if_is_partial;
    } proof {
        split stake::is_poc_prepared();
        split chunky_dkg_config::enabled();
    }

    spec try_advance_reconfig() {
        include FinishResourceRequirement;
        pragma aborts_if_is_partial;
    }
}
