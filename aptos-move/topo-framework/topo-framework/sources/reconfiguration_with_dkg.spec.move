spec poto_framework::reconfiguration_with_dkg {
    spec module {
        pragma verify = true;
    }

    spec try_start() {
        use poto_framework::chain_status;
        use poto_framework::staking_config;
        use poto_framework::reconfiguration;
        pragma verify_duration_estimate = 120;
        requires exists<reconfiguration::Configuration>(@poto_framework);
        requires chain_status::is_operating();
        include stake::ResourceRequirement;
        include stake::GetReconfigStartTimeRequirement;
        include features::spec_periodical_reward_rate_decrease_enabled() ==>
            staking_config::StakingRewardsConfigEnabledRequirement;
        aborts_if false;
        pragma verify_duration_estimate = 600; // TODO: set because of timeout (property proved).
    }

    spec try_start_with_chunky_dkg() {
        pragma verify = false;
    }

    spec finish(framework: &signer) {
        pragma verify_duration_estimate = 1500;
        include FinishRequirement;
        aborts_if false;
    }

    spec schema FinishRequirement {
        use poto_framework::chain_status;
        use std::signer;
        use std::features;
        use poto_framework::coin::CoinInfo;
        use poto_framework::poto_coin::TopoCoin;
        use poto_framework::staking_config;
        use poto_framework::config_buffer;
        use poto_framework::version;
        use poto_framework::consensus_config;
        use poto_framework::execution_config;
        use poto_framework::gas_schedule;
        use poto_framework::jwks;
        use poto_framework::randomness_config;
        use poto_framework::jwk_consensus_config;
        framework: signer;
        requires signer::address_of(framework) == @poto_framework;
        requires chain_status::is_operating();
        requires exists<CoinInfo<TopoCoin>>(@poto_framework);
        include staking_config::StakingRewardsConfigRequirement;
        requires exists<features::Features>(@std);
        include config_buffer::OnNewEpochRequirement<version::Version>;
        include config_buffer::OnNewEpochRequirement<gas_schedule::GasScheduleV2>;
        include config_buffer::OnNewEpochRequirement<execution_config::ExecutionConfig>;
        include config_buffer::OnNewEpochRequirement<consensus_config::ConsensusConfig>;
        include config_buffer::OnNewEpochRequirement<jwks::SupportedOIDCProviders>;
        include config_buffer::OnNewEpochRequirement<randomness_config::RandomnessConfig>;
        include config_buffer::OnNewEpochRequirement<randomness_config_seqnum::RandomnessConfigSeqNum>;
        include config_buffer::OnNewEpochRequirement<randomness_api_v0_config::AllowCustomMaxGasFlag>;
        include config_buffer::OnNewEpochRequirement<randomness_api_v0_config::RequiredGasDeposit>;
        include config_buffer::OnNewEpochRequirement<jwk_consensus_config::JWKConsensusConfig>;
        include config_buffer::OnNewEpochRequirement<keyless_account::Configuration>;
        include config_buffer::OnNewEpochRequirement<keyless_account::Groth16VerificationKey>;
    }

    spec maybe_finish_reconfig_with_chunky_dkg(account: &signer) {
        pragma verify = false;
    }

    spec finish_with_dkg_result(account: &signer, dkg_result: vector<u8>) {
        use poto_framework::dkg;
        pragma verify_duration_estimate = 1500;
        include FinishRequirement { framework: account };
        requires dkg::has_incomplete_session();
        aborts_if false;
    }

    spec finish_with_chunky_dkg_result(account: &signer, chunky_dkg_result: vector<u8>, encryption_key: vector<u8>) {
        pragma verify = false;
    }
}
