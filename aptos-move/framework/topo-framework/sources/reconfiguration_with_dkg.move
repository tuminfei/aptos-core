/// Reconfiguration with DKG helper functions.
module topo_framework::reconfiguration_with_dkg {
    use std::features;
    use std::error;
    use topo_framework::chunky_dkg;
    use topo_framework::chunky_dkg_config;
    use topo_framework::chunky_dkg_config_seqnum;
    use topo_framework::consensus_config;
    use topo_framework::create_signer;
    use topo_framework::decryption;
    use topo_framework::dkg;
    use topo_framework::epoch_timeout_config;
    use topo_framework::event;
    use topo_framework::execution_config;
    use topo_framework::gas_schedule;
    use topo_framework::jwk_consensus_config;
    use topo_framework::jwks;
    use topo_framework::keyless_account;
    use topo_framework::randomness_api_v0_config;
    use topo_framework::randomness_config;
    use topo_framework::randomness_config_seqnum;
    use topo_framework::reconfiguration;
    use topo_framework::reconfiguration_state;
    use topo_framework::stake::{Self, validator_consensus_infos_from_validator_set};
    use topo_framework::system_addresses;
    use topo_framework::timestamp;
    friend topo_framework::block;
    friend topo_framework::topo_governance;

    #[event]
    enum ForceEndEpochEvent has drop, store {
        V1 {
            epoch: u64,
            dkg_incomplete: bool,
            chunky_incomplete: bool,
            deadline_us: u64,
            now_us: u64,
        }
    }

    const ETRANSITION_DEFERRED: u64 = 1;
    const ESESSION_MISMATCH: u64 = 2;

    /// 由区块触发普通 DKG；目标预检不通过时保留旧 Epoch，后续区块可继续重试。
    public(friend) fun try_start() {
        try_start_internal(false);
    }

    /// 由区块触发普通和 Chunky DKG，两者使用同一次预检得到的委员会及成员顺序。
    public(friend) fun try_start_with_chunky_dkg() {
        try_start_internal(true);
    }

    /// 治理启动普通 DKG 必须通过预检，否则回滚同一事务中的治理写入。
    public(friend) fun require_start() {
        assert!(try_start_internal(false), error::invalid_state(ETRANSITION_DEFERRED));
    }

    /// 治理同时启动两种 DKG；两者共用预检结果，预检失败则回滚治理事务。
    public(friend) fun require_start_with_chunky_dkg() {
        assert!(try_start_internal(true), error::invalid_state(ETRANSITION_DEFERRED));
    }

    /// 预检通过后缓存计划、冻结配置，再清理旧会话并启动 DKG；目标不合格时返回 false。
    /// 已在换届或受重复调用等限制时可直接返回 true，因此 true 不一定表示新建了会话。
    fun try_start_internal(with_chunky: bool): bool {
        if (!reconfiguration::transition_allowed()) { return true };
        let cur_epoch = reconfiguration::current_epoch();
        if (reconfiguration_state::is_in_progress()) {
            validate_cached_plan();
            // V1 入口沿用原有本地 override 规则清理 Chunky 会话；目标和截止时间仍保持冻结，
            // 恢复时不能重建计划或启动另一份 DKG。
            if (!with_chunky && chunky_dkg::incomplete_session().is_some()) {
                let framework = create_signer::create_signer(@topo_framework);
                chunky_dkg::try_clear_incomplete_session(&framework);
            };
            return true
        };
        if (!reconfiguration::prepare_transition()) { return false };
        // 预检成功后才清理旧会话，确保延期时不改动换届状态。
        if (chunky_dkg::incomplete_session().is_some()) {
            let framework = create_signer::create_signer(@topo_framework);
            chunky_dkg::try_clear_incomplete_session(&framework);
        };
        let dealers = stake::cur_validator_consensus_infos();
        let target = stake::next_validator_consensus_infos_v2();
        let targets = validator_consensus_infos_from_validator_set(&target);
        // 两种会话直接复用同一向量，避免独立选举造成地址顺序或权重不一致。
        dkg::start(cur_epoch, randomness_config::current(), dealers, targets);
        if (with_chunky) {
            chunky_dkg::start(cur_epoch, chunky_dkg_config::current(), dealers, targets);
        };
        true
    }

    /// 治理强制结束必须有合法目标；没有冻结会话时也先同步预检，失败则回滚。
    public(friend) fun finish(framework: &signer) {
        assert!(try_finish(framework), error::invalid_state(ETRANSITION_DEFERRED));
    }

    /// 同步换届复用完整提交流程；目标不合格时本块继续执行，统计仍计入旧 Epoch。
    public(friend) fun try_finish_for_block() {
        let framework = create_signer::create_signer(@topo_framework);
        try_finish(&framework);
    }

    /// 同步和异步换届共用提交流程：校验缓存、结算旧 Epoch 奖励、应用配置、安装原计划。
    fun try_finish(framework: &signer): bool {
        system_addresses::assert_topo_framework(framework);
        if (!reconfiguration::transition_allowed()) { return true };
        let prepared = stake::is_poc_prepared();
        if (prepared) {
            if (!reconfiguration::prepare_transition()) { return false };
            stake::settle_closing_epoch();
        };
        let target_epoch = reconfiguration::current_epoch() + 1;
        // 未准备 PoC 时保留原有配置安装顺序；准备后须先按旧上下文结算奖励，
        // 再应用新奖励率和费用配置，使其从下一 Epoch 开始生效。
        apply_pending_configs(framework, prepared, target_epoch);
        dkg::try_clear_incomplete_session(framework);
        chunky_dkg::try_clear_incomplete_session(framework);
        if (prepared) {
            reconfiguration::complete_prepared_transition();
        } else {
            reconfiguration::reconfigure();
        };
        true
    }

    /// 按原有依赖顺序应用缓冲配置；PoC 准备后凭计划令牌安装功能开关，密钥按目标 Epoch 安装。
    fun apply_pending_configs(framework: &signer, prepared: bool, target_epoch: u64) {
        consensus_config::on_new_epoch(framework);
        execution_config::on_new_epoch(framework);
        gas_schedule::on_new_epoch(framework);
        std::version::on_new_epoch(framework);
        if (prepared) {
            stake::apply_cached_features(framework);
        } else {
            features::on_new_epoch(framework);
        };
        jwk_consensus_config::on_new_epoch(framework);
        jwks::on_new_epoch(framework);
        keyless_account::on_new_epoch(framework);
        randomness_config_seqnum::on_new_epoch(framework);
        randomness_config::on_new_epoch(framework);
        randomness_api_v0_config::on_new_epoch_for_reconfiguration(framework);
        chunky_dkg_config_seqnum::on_new_epoch(framework);
        chunky_dkg_config::on_new_epoch(framework);
        epoch_timeout_config::on_new_epoch(framework);
        decryption::on_new_epoch(framework, target_epoch);
    }

    /// PoC 准备后，所有完成入口都检查计划与 PVS 成对存在且 Epoch 匹配；缓存损坏时拒绝提交。
    fun validate_cached_plan() {
        if (stake::is_poc_prepared()) {
            stake::validate_epoch_plan(reconfiguration::current_epoch() + 1);
        };
    }

    /// 普通 DKG 完成，且 Chunky 已完成或影子模式宽限期已到时，可结束换届；全局超时也可结束等待。
    /// 结果回调和区块检查统一由此处判断是否提交，提交时使用原冻结计划。
    fun try_finalize_reconfig(account: &signer) {
        if (!reconfiguration_state::is_in_progress()) { return };
        validate_cached_plan();

        // 超时从本次冻结的起始时间计算；到期后无论会话是否完成，都只提交原冻结计划。
        // 先用 u256 换算微秒并相加，避免宽限期过大导致区块入口算术溢出。
        let force_end_grace = epoch_timeout_config::force_end_grace_period_secs();
        if (force_end_grace.is_some()) {
            let now_us = timestamp::now_microseconds();
            let deadline = (reconfiguration_state::start_time_secs() as u256) * 1_000_000
                + (*force_end_grace.borrow() as u256) * 1_000_000;
            if ((now_us as u256) >= deadline) {
                // 此时 deadline 不超过当前 u64 时间，可安全转换为事件字段的 u64 类型。
                let deadline_us = deadline as u64;
                let dkg_incomplete = dkg::incomplete_session().is_some();
                let chunky_incomplete = chunky_dkg::incomplete_session().is_some();
                event::emit(ForceEndEpochEvent::V1 {
                    epoch: reconfiguration::current_epoch(),
                    dkg_incomplete,
                    chunky_incomplete,
                    deadline_us,
                    now_us,
                });
                finish(account);
                return
            };
        };

        // 未触发全局超时时，普通 DKG 必须已经完成。
        if (dkg::incomplete_session().is_some()) { return };

        // Chunky 尚未完成时，须已配置影子模式宽限期且等待时间达到该期限，才能继续提交。
        let chunky_session = chunky_dkg::incomplete_session();
        if (chunky_session.is_some()) {
            let grace_period = chunky_dkg_config::grace_period_secs();
            if (grace_period.is_none()) { return };
            let start_time_us = chunky_dkg::session_start_time(chunky_session.borrow());
            let deadline = (start_time_us as u256) + (*grace_period.borrow() as u256) * 1_000_000;
            if ((timestamp::now_microseconds() as u256) < deadline) {
                return
            };
        };

        finish(account);
    }

    /// 校验会话 Epoch 和完整目标后接收普通 DKG 结果，再统一判断是否提交换届。
    /// 无会话或结果所属目标不匹配时中止，不能把迟到结果用于新计划。
    fun finish_with_dkg_result(account: &signer, dkg_result: vector<u8>) {
        validate_cached_plan();
        if (stake::is_poc_prepared()) {
            let session = dkg::incomplete_session();
            assert!(session.is_some(), error::invalid_state(ESESSION_MISMATCH));
            assert!(dkg::session_dealer_epoch(session.borrow()) == reconfiguration::current_epoch(),
                error::invalid_state(ESESSION_MISMATCH));
            assert!(dkg::session_target_validators(session.borrow()) ==
                validator_consensus_infos_from_validator_set(&stake::cached_validator_set()),
                error::invalid_state(ESESSION_MISMATCH));
        };
        dkg::finish(dkg_result);
        try_finalize_reconfig(account);
    }

    /// Chunky 未启用时直接返回；启用时先核验会话身份，再缓冲对应目标 Epoch 的加密密钥。
    /// 通过 DKG 结果专用入口写入密钥，全程保持配置冻结。
    fun finish_with_chunky_dkg_result(
        account: &signer, chunky_dkg_result: vector<u8>, encryption_key: vector<u8>
    ) {
        if (!chunky_dkg_config::enabled()) {
            return;
        };

        validate_cached_plan();
        if (stake::is_poc_prepared()) {
            let session = chunky_dkg::incomplete_session();
            assert!(session.is_some(), error::invalid_state(ESESSION_MISMATCH));
            assert!(chunky_dkg::session_dealer_epoch(session.borrow()) == reconfiguration::current_epoch(),
                error::invalid_state(ESESSION_MISMATCH));
            assert!(chunky_dkg::session_target_validators(session.borrow()) ==
                validator_consensus_infos_from_validator_set(&stake::cached_validator_set()),
                error::invalid_state(ESESSION_MISMATCH));
        };
        chunky_dkg::finish(chunky_dkg_result);
        let next_epoch = reconfiguration::current_epoch() + 1;
        decryption::set_for_next_epoch(next_epoch, encryption_key);
        try_finalize_reconfig(account);
    }

    /// 达到换届间隔后，由各区块入口持续检查完成或超时条件。
    /// 影子模式超时及本地 Chunky 恢复都使用同一结束条件，不重启 DKG 或改变冻结目标。
    public(friend) fun try_advance_reconfig() {
        let framework = create_signer::create_signer(@topo_framework);
        try_finalize_reconfig(&framework);
    }
}
