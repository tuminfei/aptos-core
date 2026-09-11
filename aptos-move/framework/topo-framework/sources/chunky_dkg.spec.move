spec topo_framework::chunky_dkg {

    spec initialize(topo_framework: &signer) {
        use std::signer;
        let topo_framework_addr = signer::address_of(topo_framework);
        aborts_if topo_framework_addr != @topo_framework;
    }

    spec start(
        dealer_epoch: u64,
        chunky_dkg_config: ChunkyDKGConfig,
        dealer_validator_set: vector<ValidatorConsensusInfo>,
        target_validator_set: vector<ValidatorConsensusInfo>,
    ) {
        aborts_if !exists<ChunkyDKGState>(@topo_framework);
        aborts_if !spec_is_session_started(dealer_epoch)
            && !exists<timestamp::CurrentTimeMicroseconds>(@topo_framework);
        ensures spec_is_session_started(dealer_epoch);
        // Invariant "at most one ChunkyDKGStartEvent per epoch": if a session
        // was already started for `dealer_epoch`, state is unchanged.
        ensures old(spec_is_session_started(dealer_epoch))
            ==> global<ChunkyDKGState>(@topo_framework)
                == old(global<ChunkyDKGState>(@topo_framework));
    }

    spec last_completed_session(): Option<ChunkyDKGSessionState> {
        aborts_if false;
        ensures result == if (exists<ChunkyDKGState>(@topo_framework)) {
            global<ChunkyDKGState>(@topo_framework).last_completed
        } else {
            option::spec_none()
        };
    }

    spec is_session_started(epoch: u64): bool {
        aborts_if false;
        ensures result == spec_is_session_started(epoch);
    }

    /// A session has been started for `epoch` iff either the in-progress or
    /// the last-completed session on chain has `dealer_epoch == epoch`.
    spec fun spec_is_session_started(epoch: u64): bool {
        exists<ChunkyDKGState>(@topo_framework) && (
            (option::is_some(global<ChunkyDKGState>(@topo_framework).in_progress)
             && option::borrow(global<ChunkyDKGState>(@topo_framework).in_progress)
                    .metadata.dealer_epoch == epoch)
            || (option::is_some(global<ChunkyDKGState>(@topo_framework).last_completed)
                && option::borrow(global<ChunkyDKGState>(@topo_framework).last_completed)
                       .metadata.dealer_epoch == epoch)
        )
    }

    spec finish(aggregated_subtranscript: vector<u8>) {
        pragma opaque;
        aborts_if !exists<ChunkyDKGState>(@topo_framework);
        aborts_if option::is_none(global<ChunkyDKGState>(@topo_framework).in_progress);
        modifies global<ChunkyDKGState>(@topo_framework);
        let session = option::borrow(global<ChunkyDKGState>(@topo_framework).in_progress);
        ensures exists<ChunkyDKGState>(@topo_framework);
        ensures option::is_none(global<ChunkyDKGState>(@topo_framework).in_progress);
        ensures global<ChunkyDKGState>(@topo_framework).last_completed == option::spec_some(
            ChunkyDKGSessionState {
                metadata: session.metadata,
                start_time_us: session.start_time_us,
                aggregated_subtranscript,
            });
    }

    spec try_clear_incomplete_session(fx: &signer) {
        use std::signer;
        let addr = signer::address_of(fx);
        aborts_if addr != @topo_framework;
    }

    spec incomplete_session(): Option<ChunkyDKGSessionState> {
        aborts_if false;
        ensures result == if (exists<ChunkyDKGState>(@topo_framework)) {
            global<ChunkyDKGState>(@topo_framework).in_progress
        } else {
            option::spec_none()
        };
    }

    spec session_dealer_epoch(session: &ChunkyDKGSessionState): u64 {
        aborts_if false;
        ensures result == session.metadata.dealer_epoch;
    }

    spec session_target_validators(session: &ChunkyDKGSessionState): vector<ValidatorConsensusInfo> {
        aborts_if false;
        ensures result == session.metadata.target_validator_set;
    }
}
