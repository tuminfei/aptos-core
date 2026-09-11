spec topo_framework::chunky_dkg_config_seqnum {
    spec initialize(framework: &signer) {
        aborts_if topo_framework::reconfiguration_state::spec_is_in_progress();
        pragma opaque;
        include config_buffer::InitializeResource<ChunkyDKGConfigSeqNum> {
            config: ChunkyDKGConfigSeqNum { seq_num: 0 }
        };
    }

    spec set_for_next_epoch(framework: &signer, seq_num: u64) {
        aborts_if topo_framework::reconfiguration_state::spec_is_in_progress();
        pragma opaque;
        aborts_if exists<ChunkyDKGConfigSeqNum>(@topo_framework)
            && seq_num <= global<ChunkyDKGConfigSeqNum>(@topo_framework).seq_num;
        include config_buffer::SetForNextEpoch<ChunkyDKGConfigSeqNum> {
            new_config: ChunkyDKGConfigSeqNum { seq_num }
        };
    }

    spec on_new_epoch(framework: &signer) {
        pragma opaque;
        include config_buffer::OnNewEpochApply<ChunkyDKGConfigSeqNum>;
    }
}
