spec poto_framework::dkg {

    spec module {
        use poto_framework::chain_status;
        invariant [suspendable] chain_status::is_operating() ==> exists<DKGState>(@poto_framework);
    }

    spec initialize(poto_framework: &signer) {
        use std::signer;
        let poto_framework_addr = signer::address_of(poto_framework);
        aborts_if poto_framework_addr != @poto_framework;
    }

    spec start(
        dealer_epoch: u64,
        randomness_config: RandomnessConfig,
        dealer_validator_set: vector<ValidatorConsensusInfo>,
        target_validator_set: vector<ValidatorConsensusInfo>,
    ) {
        aborts_if !exists<DKGState>(@poto_framework);
        aborts_if !exists<timestamp::CurrentTimeMicroseconds>(@poto_framework);
    }

    spec finish(transcript: vector<u8>) {
        use std::option;
        requires exists<DKGState>(@poto_framework);
        requires option::is_some(global<DKGState>(@poto_framework).in_progress);
        aborts_if false;
    }

    spec fun has_incomplete_session(): bool {
        if (exists<DKGState>(@poto_framework)) {
            option::is_some(global<DKGState>(@poto_framework).in_progress)
        } else {
            false
        }
    }

    spec try_clear_incomplete_session(fx: &signer) {
        use std::signer;
        let addr = signer::address_of(fx);
        aborts_if addr != @poto_framework;
    }

    spec incomplete_session(): Option<DKGSessionState> {
        aborts_if false;
    }
}
