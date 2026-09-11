spec topo_framework::reconfiguration_state {

    spec module {
        use topo_framework::chain_status;
        invariant [suspendable] chain_status::is_operating() ==> exists<State>(@topo_framework);
    }

    spec initialize(fx: &signer) {
        use std::signer;
        use topo_std::from_bcs;
        aborts_if signer::address_of(fx) != @topo_framework;
        let post post_state = global<State>(@topo_framework);
        ensures exists<State>(@topo_framework);
        ensures !exists<State>(@topo_framework) ==> from_bcs::deserializable<StateInactive>(post_state.variant.data);
    }

    spec initialize_for_testing(fx: &signer) {
        use std::signer;
        aborts_if signer::address_of(fx) != @topo_framework;
    }

    spec is_in_progress(): bool {
        pragma opaque;
        aborts_if false;
        ensures [abstract] result == spec_is_in_progress();
        ensures [concrete] result == (exists<State>(@topo_framework) &&
            copyable_any::type_name(global<State>(@topo_framework).variant).bytes
                == b"0x1::reconfiguration_state::StateActive");
    }

    spec fun spec_is_in_progress(): bool {
        exists<State>(@topo_framework) && spec_state_is_active(global<State>(@topo_framework))
    }

    spec assert_not_in_progress {
        aborts_if spec_is_in_progress();
    }

    spec fun spec_state_is_active(s: State): bool {
        copyable_any::type_name(s.variant).bytes == b"0x1::reconfiguration_state::StateActive"
    }

    spec fun spec_active_state_is_valid(): bool {
        exists<State>(@topo_framework)
            && topo_std::type_info::type_name<StateActive>() == global<State>(@topo_framework).variant.type_name
            && topo_std::from_bcs::deserializable<StateActive>(global<State>(@topo_framework).variant.data)
    }

    spec State {
        use topo_std::from_bcs;
        use topo_std::type_info;
        invariant copyable_any::type_name(variant).bytes == b"0x1::reconfiguration_state::StateActive" ||
            copyable_any::type_name(variant).bytes == b"0x1::reconfiguration_state::StateInactive";
        invariant copyable_any::type_name(variant).bytes == b"0x1::reconfiguration_state::StateActive"
            ==> from_bcs::deserializable<StateActive>(variant.data);
        invariant copyable_any::type_name(variant).bytes == b"0x1::reconfiguration_state::StateInactive"
            ==> from_bcs::deserializable<StateInactive>(variant.data);
        invariant copyable_any::type_name(variant).bytes == b"0x1::reconfiguration_state::StateActive" ==>
            type_info::type_name<StateActive>() == variant.type_name;
        invariant copyable_any::type_name(variant).bytes == b"0x1::reconfiguration_state::StateInactive" ==>
            type_info::type_name<StateInactive>() == variant.type_name;
    }

    spec on_reconfig_start {
        use topo_std::from_bcs;
        use topo_std::type_info;
        use std::bcs;
        modifies global<State>(@topo_framework);
        aborts_if false;
        requires exists<timestamp::CurrentTimeMicroseconds>(@topo_framework);
        let state = Any {
            type_name: type_info::type_name<StateActive>(),
            data: bcs::serialize(StateActive {
                start_time_secs: timestamp::spec_now_seconds()
            })
        };
        let pre_state = global<State>(@topo_framework);
        let post post_state = global<State>(@topo_framework);
        ensures (exists<State>(@topo_framework) && copyable_any::type_name(pre_state.variant).bytes
            == b"0x1::reconfiguration_state::StateInactive") ==> copyable_any::type_name(post_state.variant).bytes
            == b"0x1::reconfiguration_state::StateActive";
        ensures (exists<State>(@topo_framework) && copyable_any::type_name(pre_state.variant).bytes
            == b"0x1::reconfiguration_state::StateInactive") ==> post_state.variant == state;
        ensures (exists<State>(@topo_framework) && copyable_any::type_name(pre_state.variant).bytes
            == b"0x1::reconfiguration_state::StateInactive") ==> from_bcs::deserializable<StateActive>(post_state.variant.data);
    }

    spec start_time_secs(): u64 {
        include StartTimeSecsAbortsIf;
    }

    spec on_reconfig_finish {
        modifies global<State>(@topo_framework);
        aborts_if exists<State>(@topo_framework) && !spec_is_in_progress();
        ensures !spec_is_in_progress();
    }

    spec fun spec_start_time_secs(): u64 {
        use topo_std::from_bcs;
        let state = global<State>(@topo_framework);
        from_bcs::deserialize<StateActive>(state.variant.data).start_time_secs
    }

    spec schema StartTimeSecsRequirement {
        requires exists<State>(@topo_framework);
        requires copyable_any::type_name(global<State>(@topo_framework).variant).bytes
            == b"0x1::reconfiguration_state::StateActive";
        include UnpackRequiresStateActive {
            x:  global<State>(@topo_framework).variant
        };
    }

    spec schema UnpackRequiresStateActive {
        use topo_std::from_bcs;
        use topo_std::type_info;
        x: Any;
        requires type_info::type_name<StateActive>() == x.type_name && from_bcs::deserializable<StateActive>(x.data);
    }

    spec schema StartTimeSecsAbortsIf {
        aborts_if !exists<State>(@topo_framework);
        include  copyable_any::type_name(global<State>(@topo_framework).variant).bytes
            == b"0x1::reconfiguration_state::StateActive" ==>
        copyable_any::UnpackAbortsIf<StateActive> {
            self: global<State>(@topo_framework).variant
        };
        aborts_if copyable_any::type_name(global<State>(@topo_framework).variant).bytes
            != b"0x1::reconfiguration_state::StateActive";
    }

}
