spec topo_framework::dkg {

    spec module {
        use topo_framework::chain_status;
        invariant [suspendable] chain_status::is_operating() ==> exists<DKGState>(@topo_framework);
    }

    spec initialize(topo_framework: &signer) {
        use std::signer;
        let aptos_framework_addr = signer::address_of(topo_framework);
        aborts_if aptos_framework_addr != @topo_framework;
    }

    spec start(
        dealer_epoch: u64,
        randomness_config: RandomnessConfig,
        dealer_validator_set: vector<ValidatorConsensusInfo>,
        target_validator_set: vector<ValidatorConsensusInfo>,
    ) {
        aborts_if !exists<DKGState>(@topo_framework);
        aborts_if !exists<timestamp::CurrentTimeMicroseconds>(@topo_framework);
    }

    spec finish(transcript: vector<u8>) {
        use std::option;
        requires exists<DKGState>(@topo_framework);
        requires option::is_some(global<DKGState>(@topo_framework).in_progress);
        aborts_if false;
    }

    spec fun has_incomplete_session(): bool {
        if (exists<DKGState>(@topo_framework)) {
            option::is_some(global<DKGState>(@topo_framework).in_progress)
        } else {
            false
        }
    }

    spec try_clear_incomplete_session(fx: &signer) {
        use std::signer;
        let addr = signer::address_of(fx);
        aborts_if addr != @topo_framework;
    }

    spec incomplete_session(): Option<DKGSessionState> {
        aborts_if false;
    }
}
