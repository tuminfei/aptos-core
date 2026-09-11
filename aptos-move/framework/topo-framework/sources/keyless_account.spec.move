spec topo_framework::keyless_account {
    spec module {
        // TODO: verification is  disabled until this module is specified.
        pragma verify=false;
    }

    spec on_new_epoch(fx: &signer) {
        pragma verify = true;
        pragma opaque;
        include config_buffer::OnNewEpochApplyPair<Groth16VerificationKey, Configuration> {
            framework: fx
        };
    }
}
