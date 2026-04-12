///
/// TopoGovernance represents the on-chain governance of the Aptos network. Voting power is calculated based on the
/// current epoch's voting power of the proposer or voter's backing stake pool. In addition, for it to count,
/// the stake pool's lockup needs to be at least as long as the proposal's duration.
///
/// It provides the following flow:
/// 1. Proposers can create a proposal by calling TopoGovernance::create_proposal. The proposer's backing stake pool
/// needs to have the minimum proposer stake required. Off-chain components can subscribe to CreateProposalEvent to
/// track proposal creation and proposal ids.
/// 2. Voters can vote on a proposal. Their voting power is derived from the backing stake pool. A stake pool can vote
/// on a proposal multiple times as long as the total voting power of these votes doesn't exceed its total voting power.
module aptos_framework::topo_governance {
    use std::error;
    use std::option;
    use std::signer;
    use std::string::{Self, String, utf8};
    use std::features;

    use aptos_std::math64::min;
    use aptos_std::simple_map::{Self, SimpleMap};
    use aptos_std::smart_table::{Self, SmartTable};
    use aptos_std::table::{Self, Table};

    use aptos_framework::account::{Self, SignerCapability, create_signer_with_capability};
    use aptos_framework::coin;
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::governance_proposal::{Self, GovernanceProposal};
    use aptos_framework::stake;
    use aptos_framework::staking_registry;
    use aptos_framework::staking_config;
    use aptos_framework::system_addresses;
    use aptos_framework::topo_coin::{Self, TopoCoin};
    use aptos_framework::chunky_dkg_config;
    use aptos_framework::consensus_config;
    use aptos_framework::permissioned_signer;
    use aptos_framework::randomness_config;
    use aptos_framework::reconfiguration_with_dkg;
    use aptos_framework::timestamp;
    use aptos_framework::voting;

    #[test_only]
    use std::vector;

    /// The specified stake pool does not have sufficient stake to create a proposal
    const EINSUFFICIENT_PROPOSER_STAKE: u64 = 1;
    /// This account is not the designated voter of the specified stake pool
    const ENOT_DELEGATED_VOTER: u64 = 2;
    /// The specified stake pool does not have long enough remaining lockup to create a proposal or vote
    const EINSUFFICIENT_STAKE_LOCKUP: u64 = 3;
    /// The specified stake pool has already been used to vote on the same proposal
    const EALREADY_VOTED: u64 = 4;
    /// The specified stake pool must be part of the validator set
    const ENO_VOTING_POWER: u64 = 5;
    /// Proposal is not ready to be resolved. Waiting on time or votes
    const EPROPOSAL_NOT_RESOLVABLE_YET: u64 = 6;
    /// The proposal has not been resolved yet
    const EPROPOSAL_NOT_RESOLVED_YET: u64 = 8;
    /// Metadata location cannot be longer than 256 chars
    const EMETADATA_LOCATION_TOO_LONG: u64 = 9;
    /// Metadata hash cannot be longer than 256 chars
    const EMETADATA_HASH_TOO_LONG: u64 = 10;
    /// Account is not authorized to call this function.
    const EUNAUTHORIZED: u64 = 11;
    /// The stake pool is using voting power more than it has.
    const EVOTING_POWER_OVERFLOW: u64 = 12;
    /// Partial voting feature hasn't been properly initialized.
    const EPARTIAL_VOTING_NOT_INITIALIZED: u64 = 13;
    /// The proposal in the argument is not a partial voting proposal.
    const ENOT_PARTIAL_VOTING_PROPOSAL: u64 = 14;
    /// The proposal has expired.
    const EPROPOSAL_EXPIRED: u64 = 15;
    /// Current permissioned signer cannot perform governance operations.
    const ENO_GOVERNANCE_PERMISSION: u64 = 16;

    /// This matches the same enum const in voting. We have to duplicate it as Move doesn't have support for enums yet.
    const PROPOSAL_STATE_SUCCEEDED: u64 = 1;

    const MAX_U64: u64 = 18446744073709551615;

    /// Proposal metadata attribute keys.
    const METADATA_LOCATION_KEY: vector<u8> = b"metadata_location";
    const METADATA_HASH_KEY: vector<u8> = b"metadata_hash";

    /// Store the SignerCapabilities of accounts under the on-chain governance's control.
    struct GovernanceResponsbility has key {
        signer_caps: SimpleMap<address, SignerCapability>,
    }

    /// Configurations of the TopoGovernance, set during Genesis and can be updated by the same process offered
    /// by this TopoGovernance module.
    struct GovernanceConfig has key {
        min_voting_threshold: u128,
        required_proposer_stake: u64,
        voting_duration_secs: u64,
    }

    struct RecordKey has copy, drop, store {
        voter: address,
        proposal_id: u64,
    }

    /// Records to track the proposals each stake pool has been used to vote on.
    struct VotingRecords has key {
        votes: Table<RecordKey, bool>
    }

    /// Records to track the voting power usage of each stake pool on each proposal.
    struct VotingRecordsV2 has key {
        votes: SmartTable<RecordKey, u64>
    }

    /// Used to track which execution script hashes have been approved by governance.
    /// This is required to bypass cases where the execution scripts exceed the size limit imposed by mempool.
    struct ApprovedExecutionHashes has key {
        hashes: SimpleMap<u64, vector<u8>>,
    }

    /// Events generated by interactions with the TopoGovernance module.
    struct GovernanceEvents has key {
        create_proposal_events: EventHandle<CreateProposalEvent>,
        update_config_events: EventHandle<UpdateConfigEvent>,
        vote_events: EventHandle<VoteEvent>,
    }

    /// Event emitted when a proposal is created.
    struct CreateProposalEvent has drop, store {
        proposer: address,
        proposal_id: u64,
        execution_hash: vector<u8>,
        proposal_metadata: SimpleMap<String, vector<u8>>,
    }

    /// Event emitted when there's a vote on a proposa;
    struct VoteEvent has drop, store {
        proposal_id: u64,
        voter: address,
        num_votes: u64,
        should_pass: bool,
    }

    /// Event emitted when the governance configs are updated.
    struct UpdateConfigEvent has drop, store {
        min_voting_threshold: u128,
        required_proposer_stake: u64,
        voting_duration_secs: u64,
    }

    #[event]
    /// Event emitted when a proposal is created.
    struct CreateProposal has drop, store {
        proposer: address,
        proposal_id: u64,
        execution_hash: vector<u8>,
        proposal_metadata: SimpleMap<String, vector<u8>>,
    }

    #[event]
    /// Event emitted when there's a vote on a proposa;
    struct Vote has drop, store {
        proposal_id: u64,
        voter: address,
        num_votes: u64,
        should_pass: bool,
    }

    #[event]
    /// Event emitted when the governance configs are updated.
    struct UpdateConfig has drop, store {
        min_voting_threshold: u128,
        required_proposer_stake: u64,
        voting_duration_secs: u64,
    }

    struct GovernancePermission has copy, drop, store {}

    /// Permissions
    inline fun check_governance_permission(s: &signer) {
        assert!(
            permissioned_signer::check_permission_exists(s, GovernancePermission {}),
            error::permission_denied(ENO_GOVERNANCE_PERMISSION),
        );
    }

    /// Grant permission to perform governance operations on behalf of the master signer.
    public fun grant_permission(master: &signer, permissioned_signer: &signer) {
        permissioned_signer::authorize_unlimited(master, permissioned_signer, GovernancePermission {})
    }

    /// Can be called during genesis or by the governance itself.
    /// Stores the signer capability for a given address.
    public fun store_signer_cap(
        aptos_framework: &signer,
        signer_address: address,
        signer_cap: SignerCapability,
    ) acquires GovernanceResponsbility {
        system_addresses::assert_aptos_framework(aptos_framework);
        system_addresses::assert_framework_reserved(signer_address);

        if (!exists<GovernanceResponsbility>(@aptos_framework)) {
            move_to(
                aptos_framework,
                GovernanceResponsbility { signer_caps: simple_map::create<address, SignerCapability>() }
            );
        };

        let signer_caps = &mut borrow_global_mut<GovernanceResponsbility>(@aptos_framework).signer_caps;
        signer_caps.add(signer_address, signer_cap);
    }

    /// Initializes the state for Aptos Governance. Can only be called during Genesis with a signer
    /// for the aptos_framework (0x1) account.
    /// This function is private because it's called directly from the vm.
    fun initialize(
        aptos_framework: &signer,
        min_voting_threshold: u128,
        required_proposer_stake: u64,
        voting_duration_secs: u64,
    ) {
        system_addresses::assert_aptos_framework(aptos_framework);

        voting::register<GovernanceProposal>(aptos_framework);
        initialize_partial_voting(aptos_framework);
        move_to(aptos_framework, GovernanceConfig {
            voting_duration_secs,
            min_voting_threshold,
            required_proposer_stake,
        });
        move_to(aptos_framework, GovernanceEvents {
            create_proposal_events: account::new_event_handle<CreateProposalEvent>(aptos_framework),
            update_config_events: account::new_event_handle<UpdateConfigEvent>(aptos_framework),
            vote_events: account::new_event_handle<VoteEvent>(aptos_framework),
        });
        move_to(aptos_framework, VotingRecords {
            votes: table::new(),
        });
        move_to(aptos_framework, ApprovedExecutionHashes {
            hashes: simple_map::create<u64, vector<u8>>(),
        })
    }

    /// Update the governance configurations. This can only be called as part of resolving a proposal in this same
    /// TopoGovernance.
    public fun update_governance_config(
        aptos_framework: &signer,
        min_voting_threshold: u128,
        required_proposer_stake: u64,
        voting_duration_secs: u64,
    ) acquires GovernanceConfig {
        system_addresses::assert_aptos_framework(aptos_framework);

        let governance_config = borrow_global_mut<GovernanceConfig>(@aptos_framework);
        governance_config.voting_duration_secs = voting_duration_secs;
        governance_config.min_voting_threshold = min_voting_threshold;
        governance_config.required_proposer_stake = required_proposer_stake;

        event::emit(
            UpdateConfig {
                min_voting_threshold,
                required_proposer_stake,
                voting_duration_secs
            },
        );
    }

    /// Initializes the state for Aptos Governance partial voting. Can only be called through Aptos governance
    /// proposals with a signer for the aptos_framework (0x1) account.
    public fun initialize_partial_voting(
        aptos_framework: &signer,
    ) {
        system_addresses::assert_aptos_framework(aptos_framework);

        move_to(aptos_framework, VotingRecordsV2 {
            votes: smart_table::new(),
        });
    }

    #[view]
    public fun get_voting_duration_secs(): u64 acquires GovernanceConfig {
        borrow_global<GovernanceConfig>(@aptos_framework).voting_duration_secs
    }

    #[view]
    public fun has_governance_config(): bool {
        exists<GovernanceConfig>(@aptos_framework)
    }

    #[view]
    public fun get_min_voting_threshold(): u128 acquires GovernanceConfig {
        borrow_global<GovernanceConfig>(@aptos_framework).min_voting_threshold
    }

    #[view]
    public fun get_required_proposer_stake(): u64 acquires GovernanceConfig {
        borrow_global<GovernanceConfig>(@aptos_framework).required_proposer_stake
    }

    #[view]
    /// Return true if a stake pool has already voted on a proposal before partial governance voting is enabled.
    public fun has_entirely_voted(voter: address, proposal_id: u64): bool acquires VotingRecords {
        let record_key = RecordKey {
            voter,
            proposal_id,
        };
        // If a stake pool has already voted on a proposal before partial governance voting is enabled,
        // there is a record in VotingRecords.
        let voting_records = borrow_global<VotingRecords>(@aptos_framework);
        voting_records.votes.contains(record_key)
    }

    #[view]
    /// Return remaining voting power of a stake pool on a proposal.
    /// Note: a stake pool's voting power on a proposal could increase over time(e.g. rewards/new stake).
    public fun get_remaining_voting_power(
        voter: address,
        proposal_id: u64
    ): u64 acquires VotingRecords, VotingRecordsV2 {
        assert_voting_initialization();

        let proposal_expiration = voting::get_proposal_expiration_secs<GovernanceProposal>(
            @aptos_framework,
            proposal_id
        );
        if (staking_registry::registry_exists()) {
            // registry 模式下，治理主体已经从“stake_pool 地址”切换成“持有有效 power 的地址自身”。
            // 因此这里直接基于 voter 地址查询有效 power，再减去该地址已经使用过的票数。
            if (is_proposal_expired(proposal_expiration)) {
                return 0
            };
            if (has_entirely_voted(voter, proposal_id)) {
                return 0
            };
            let total_voting_power = staking_registry::get_effective_power(voter);
            if (total_voting_power == 0) {
                return 0
            };
            let record_key = RecordKey {
                voter,
                proposal_id,
            };
            let used_voting_power =
                *VotingRecordsV2[@aptos_framework].votes.borrow_with_default(record_key, &0);
            if (used_voting_power >= total_voting_power) {
                0
            } else {
                total_voting_power - used_voting_power
            }
        } else {
            // The voter's stake needs to be locked up at least as long as the proposal's expiration.
            // Also no one can vote on a expired proposal.
            if (!stake_pool_is_eligible_to_vote(voter, proposal_expiration)
                || is_proposal_expired(proposal_expiration)) {
                return 0
            };

            // If a stake pool has already voted on a proposal before partial governance voting is enabled, the stake pool
            // cannot vote on the proposal even after partial governance voting is enabled.
            if (has_entirely_voted(voter, proposal_id)) {
                return 0
            };
            let record_key = RecordKey {
                voter,
                proposal_id,
            };
            let used_voting_power =
                *VotingRecordsV2[@aptos_framework].votes.borrow_with_default(record_key, &0);
            get_voting_power(voter) - used_voting_power
        }
    }

    public fun assert_proposal_expiration(voter: address, proposal_id: u64) {
        assert_voting_initialization();
        let proposal_expiration = voting::get_proposal_expiration_secs<GovernanceProposal>(
            @aptos_framework,
            proposal_id
        );
        if (staking_registry::registry_exists()) {
            // registry 模式不再依赖传统的 stake lockup 到期时间判定可投票性，
            // 是否还能投票完全由“当前是否仍有有效 power”决定。
            assert!(
                staking_registry::get_effective_power(voter) > 0,
                error::invalid_argument(ENO_VOTING_POWER),
            );
        } else {
            // The voter's stake needs to be locked up at least as long as the proposal's expiration.
            assert!(
                stake_pool_is_eligible_to_vote(voter, proposal_expiration),
                error::invalid_argument(EINSUFFICIENT_STAKE_LOCKUP),
            );
        };
        assert!(
            !is_proposal_expired(proposal_expiration),
            error::invalid_argument(EPROPOSAL_EXPIRED),
        );
    }

    inline fun stake_pool_is_eligible_to_vote(
        stake_pool: address, proposal_expiration: u64
    ): bool {
        if (staking_registry::registry_exists()) {
            staking_registry::get_effective_power(stake_pool) > 0
        } else {
            // The voter's stake needs to be locked up at least as long as the proposal's expiration.
            // Also no one can vote on a expired proposal.
            // Note the boundary condition must be strictly less than to avoid the edge case where the
            // proposal expiration is equal to the lockup until.
            proposal_expiration < stake::get_lockup_secs(stake_pool)
        }
    }

    inline fun is_proposal_expired(proposal_expiration: u64): bool {
        // Expiration time is defined as the time since when the proposal is no longer eligible to be voted on.
        timestamp::now_seconds() >= proposal_expiration
    }

    /// Create a single-step proposal with the caller's voting power.
    /// @param execution_hash Required. This is the hash of the resolution script. When the proposal is resolved,
    /// only the exact script with matching hash can be successfully executed.
    public entry fun create_proposal(
        proposer: &signer,
        execution_hash: vector<u8>,
        metadata_location: vector<u8>,
        metadata_hash: vector<u8>,
    ) acquires GovernanceConfig {
        create_proposal_v2(proposer, execution_hash, metadata_location, metadata_hash, false);
    }

    /// Create a single-step or multi-step proposal with the caller's voting power.
    /// @param execution_hash Required. This is the hash of the resolution script. When the proposal is resolved,
    /// only the exact script with matching hash can be successfully executed.
    public entry fun create_proposal_v2(
        proposer: &signer,
        execution_hash: vector<u8>,
        metadata_location: vector<u8>,
        metadata_hash: vector<u8>,
        is_multi_step_proposal: bool,
    ) acquires GovernanceConfig {
        create_proposal_v2_impl(
            proposer,
            signer::address_of(proposer),
            execution_hash,
            metadata_location,
            metadata_hash,
            is_multi_step_proposal
        );
    }

    /// 创建提案的中间层实现。
    /// 该函数接受旧模式的 `stake_pool` 参数，但在 registry 模式下会将其忽略，
    /// 将投票主体（voting_subject）强制收敛为 proposer 自身地址。
    ///
    /// 这是一个适配层：外部调用方（如 create_proposal_v2）仍然传入 stake_pool，
    /// 但本函数会根据当前模式决定真正的 voting_subject，然后委托给
    /// create_proposal_v2_impl_with_voting_subject 执行核心逻辑。
    ///
    /// @return proposal_id 创建成功后返回提案 ID。
    public fun create_proposal_v2_impl(
        proposer: &signer,
        stake_pool: address,
        execution_hash: vector<u8>,
        metadata_location: vector<u8>,
        metadata_hash: vector<u8>,
        is_multi_step_proposal: bool,
    ): u64 acquires GovernanceConfig {
        let voting_subject =
            if (staking_registry::registry_exists()) {
                // registry 模式下忽略传入的 stake_pool 参数。
                // 原因：registry 模式中不存在 stake_pool → proposer 的间接关系，
                // 提案权严格绑定到 signer 自己的有效 power，
                // 因此 voting_subject 必须是 proposer 自身地址。
                signer::address_of(proposer)
            } else {
                stake_pool
            };
        create_proposal_v2_impl_with_voting_subject(
            proposer,
            voting_subject,
            execution_hash,
            metadata_location,
            metadata_hash,
            is_multi_step_proposal,
        )
    }

    // 已废弃（#[deprecated]）：保留旧的基于 stake_pool 的创建提案接口。
    //
    // 兼容策略：
    // 该接口是旧版 aptos_governance 中 `create_proposal` 的带 stake_pool 参数版本。
    // 在 registry 模式上线后，外部调用方（如 SDK、钱包、DApp）可能尚未迁移到新接口，
    // 仍然会传入 stake_pool 地址。为了平滑过渡，保留此接口但标记为 deprecated。
    //
    // 在 registry 模式下，无论外部传入什么 stake_pool 地址，
    // 内部都会将提案主体（voting_subject）强制收敛为 proposer 自身地址，
    // 确保提案权始终绑定到签名者本人的有效 power。
    //
    // 调用方应尽快迁移到 `create_proposal` 或 `create_proposal_v2`，
    // 这些新接口不再需要传入 stake_pool 参数。
    #[deprecated]
    public entry fun create_proposal_with_stake_pool(
        proposer: &signer,
        stake_pool: address,
        execution_hash: vector<u8>,
        metadata_location: vector<u8>,
        metadata_hash: vector<u8>,
    ) acquires GovernanceConfig {
        create_proposal_v2_with_stake_pool(
            proposer,
            stake_pool,
            execution_hash,
            metadata_location,
            metadata_hash,
            false,
        );
    }

    // 已废弃（#[deprecated]）：保留旧的基于 stake_pool 的创建提案 v2 接口。
    //
    // 兼容策略：
    // 与 create_proposal_with_stake_pool 相同，该接口保留是为了向后兼容。
    // 在 registry 模式下，传入的 stake_pool 参数会被忽略，
    // voting_subject 被强制设为 proposer 自身地址。
    //
    // 旧模式下，stake_pool 参数仍然生效，作为提案的投票主体。
    // 调用方应尽快迁移到不带 stake_pool 参数的新版接口。
    #[deprecated]
    public entry fun create_proposal_v2_with_stake_pool(
        proposer: &signer,
        stake_pool: address,
        execution_hash: vector<u8>,
        metadata_location: vector<u8>,
        metadata_hash: vector<u8>,
        is_multi_step_proposal: bool,
    ) acquires GovernanceConfig {
        let voting_subject =
            if (staking_registry::registry_exists()) {
                // 兼容旧接口：即使外部继续传 stake_pool，
                // registry 模式也会把主体强制收敛为 proposer 地址自身。
                // 这保证了无论调用哪个接口，registry 模式下的行为都是一致的。
                signer::address_of(proposer)
            } else {
                stake_pool
            };
        create_proposal_v2_impl_with_voting_subject(
            proposer,
            voting_subject,
            execution_hash,
            metadata_location,
            metadata_hash,
            is_multi_step_proposal,
        );
    }

    /// 创建提案的核心实现（最底层）。
    ///
    /// ## voting_subject 的语义
    /// `voting_subject` 是一个统一抽象，用于屏蔽两种模式的差异：
    /// - 在 registry 模式下，voting_subject == proposer 自身地址。
    ///   提案人直接以自己的身份参与治理，投票权来源于注册表中的有效 power。
    /// - 在旧模式下，voting_subject == stake_pool 地址。
    ///   提案人通过其关联的 stake_pool 参与治理，投票权来源于 stake_pool 的质押余额。
    ///
    /// 上游调用方（create_proposal_v2_impl、create_proposal_v2_with_stake_pool 等）
    /// 负责根据当前模式将 voting_subject 设置为正确的值，本函数不再关心模式切换逻辑。
    ///
    /// ## 该函数的完整职责
    /// 1. 权限检查：验证 proposer 是否有治理权限（GovernancePermission）
    /// 2. 授权检查（仅旧模式）：验证 proposer 是否是 voting_subject（stake_pool）的 delegated_voter
    /// 3. 质押门槛检查：验证提案人的投票权 >= required_proposer_stake
    /// 4. Lockup 检查（仅旧模式）：验证 stake_pool 的 lockup 覆盖投票期
    /// 5. 元数据校验：创建并验证提案元数据
    /// 6. 早决议阈值计算：registry 模式基于注册表总质押，旧模式基于全链总发行量
    /// 7. 创建提案：调用 voting 模块创建提案
    /// 8. 事件发射：发出 CreateProposal 事件
    fun create_proposal_v2_impl_with_voting_subject(
        proposer: &signer,
        voting_subject: address,
        execution_hash: vector<u8>,
        metadata_location: vector<u8>,
        metadata_hash: vector<u8>,
        is_multi_step_proposal: bool,
    ): u64 acquires GovernanceConfig {
        check_governance_permission(proposer);
        let proposer_address = signer::address_of(proposer);

        // ========== 步骤 1：授权检查（delegated_voter） ==========
        // 提案人的质押必须达到最低保证金要求。
        let governance_config = borrow_global<GovernanceConfig>(@aptos_framework);
        let registry_enabled = staking_registry::registry_exists();
        if (!registry_enabled) {
            // 旧模式下，需要验证 proposer 是 voting_subject（stake_pool）的 delegated_voter。
            // 这是因为旧模式中 stake_pool 的所有者可以将投票权委托给另一个地址，
            // 只有被委托的地址才能代表该 stake_pool 创建提案。
            //
            // registry 模式下跳过此检查的原因：
            // registry 模式中不存在 delegated_voter 的概念。
            // 投票权直接归属于持有有效 power 的地址本身，
            // proposer 就是治理主体，不需要任何委托关系。
            assert!(
                stake::get_delegated_voter(voting_subject) == proposer_address,
                error::invalid_argument(ENOT_DELEGATED_VOTER)
            );
        };

        // ========== 步骤 2：质押门槛检查 ==========
        let stake_balance =
            if (registry_enabled) {
                // registry 模式：从注册表获取 proposer 地址的有效 power。
                // 注意这里用的是 proposer_address 而非 voting_subject，
                // 因为在 registry 模式下两者相同（上游已保证）。
                staking_registry::get_effective_power(proposer_address)
            } else {
                // 旧模式：从 stake_pool 获取聚合后的投票权
                // （active + pending_active + pending_inactive）。
                get_voting_power(voting_subject)
            };
        assert!(
            stake_balance >= governance_config.required_proposer_stake,
            error::invalid_argument(EINSUFFICIENT_PROPOSER_STAKE),
        );

        // ========== 步骤 3：Lockup 检查（仅旧模式） ==========
        // 提案人的质押锁定期必须至少覆盖提案的投票期。
        let current_time = timestamp::now_seconds();
        let proposal_expiration = current_time + governance_config.voting_duration_secs;
        if (!registry_enabled) {
            // 旧模式下，要求 stake_pool 的 lockup 到期时间 > proposal_expiration。
            // 这确保提案人在整个投票期间都保持质押承诺。
            //
            // registry 模式下跳过此检查的原因：
            // 注册表本身管理了 power 的有效期。如果提案人的 power 在投票期间过期，
            // 其投票权会自然降为 0，不需要额外的 lockup 时间约束。
            // 而且 registry 模式的设计理念是”当前有效 power 即为投票权”，
            // 不再要求质押锁定期与提案投票期对齐。
            assert!(
                stake_pool_is_eligible_to_vote(voting_subject, proposal_expiration),
                error::invalid_argument(EINSUFFICIENT_STAKE_LOCKUP),
            );
        };

        // ========== 步骤 4：创建并验证提案元数据 ==========
        let proposal_metadata = create_proposal_metadata(metadata_location, metadata_hash);

        // ========== 步骤 5：计算早决议阈值（early resolution vote threshold） ==========
        // 早决议机制：如果投票数超过阈值，提案可以在投票期结束前提前通过或否决。
        // 这避免了明显已有结果的提案还需要等待整个投票期结束。
        let early_resolution_vote_threshold =
            if (registry_enabled) {
                // registry 模式下，早决议阈值 = 注册表总有效质押量 / 2 + 1。
                //
                // 与旧模式的关键区别：
                // - 旧模式基于全链 TopoCoin 总发行量（coin::supply<TopoCoin>()）计算阈值。
                //   这包括了所有流通中的代币，无论是否参与质押。
                // - registry 模式基于注册表中的总有效质押量（get_total_staked_power()）计算。
                //   这只包括已经注册到治理体系中的质押量。
                //
                // 这一变化的意义：
                // 1. 更精确：只有实际参与治理的质押才被纳入阈值计算，
                //    避免了大量未质押代币”稀释”投票权重的问题。
                // 2. 更合理：阈值反映的是”治理参与者中的多数”，而非”全网持币者中的多数”。
                // 3. 更高效：当注册表质押量远小于总发行量时，提案更容易达到早决议阈值。
                //
                // +1 是为了避免整除时的舍入误差，确保阈值严格超过 50%。
                option::some((staking_registry::get_total_staked_power() as u128) / 2 + 1)
            } else {
                let total_voting_token_supply = coin::supply<TopoCoin>();
                let threshold = option::none<u128>();
                if (total_voting_token_supply.is_some()) {
                    let total_supply = *total_voting_token_supply.borrow();
                    // 50% + 1 to avoid rounding errors.
                    threshold = option::some(total_supply / 2 + 1);
                };
                threshold
            };

        // ========== 步骤 6：调用 voting 模块创建提案 ==========
        let proposal_id = voting::create_proposal_v2(
            proposer_address,
            @aptos_framework,
            governance_proposal::create_proposal(),
            execution_hash,
            governance_config.min_voting_threshold,
            proposal_expiration,
            early_resolution_vote_threshold,
            proposal_metadata,
            is_multi_step_proposal,
        );

        event::emit(
            CreateProposal {
                proposal_id,
                proposer: proposer_address,
                execution_hash,
                proposal_metadata,
            },
        );
        proposal_id
    }

    /// Vote on proposal with proposal_id and all voting power from the caller.
    public entry fun batch_vote(
        voter: &signer,
        proposal_id: u64,
        should_pass: bool,
    ) acquires ApprovedExecutionHashes, VotingRecords, VotingRecordsV2 {
        vote_internal(voter, proposal_id, MAX_U64, should_pass);
    }

    /// Batch vote on proposal with proposal_id and specified voting power from the caller.
    public entry fun batch_partial_vote(
        voter: &signer,
        proposal_id: u64,
        voting_power: u64,
        should_pass: bool,
    ) acquires ApprovedExecutionHashes, VotingRecords, VotingRecordsV2 {
        vote_internal(voter, proposal_id, voting_power, should_pass);
    }

    #[deprecated]
    public entry fun batch_vote_with_stake_pools(
        voter: &signer,
        stake_pools: vector<address>,
        proposal_id: u64,
        should_pass: bool,
    ) acquires ApprovedExecutionHashes, VotingRecords, VotingRecordsV2 {
        if (staking_registry::registry_exists()) {
            if (!stake_pools.is_empty()) {
                // registry 模式不存在“一人携带多个独立 stake_pool 主体批量投票”的语义。
                // 这里保留旧 API 只是为了兼容调用方，实际只按 signer 自身执行一次投票。
                vote_internal(voter, proposal_id, MAX_U64, should_pass);
            };
        } else {
            stake_pools.for_each(|stake_pool| {
                vote_internal_with_stake_pool(voter, stake_pool, proposal_id, MAX_U64, should_pass);
            });
        };
    }

    #[deprecated]
    public entry fun batch_partial_vote_with_stake_pools(
        voter: &signer,
        stake_pools: vector<address>,
        proposal_id: u64,
        voting_power: u64,
        should_pass: bool,
    ) acquires ApprovedExecutionHashes, VotingRecords, VotingRecordsV2 {
        if (staking_registry::registry_exists()) {
            if (!stake_pools.is_empty()) {
                // 同上，registry 模式下这仍然只是“signer 自己做一次部分投票”。
                vote_internal(voter, proposal_id, voting_power, should_pass);
            };
        } else {
            stake_pools.for_each(|stake_pool| {
                vote_internal_with_stake_pool(voter, stake_pool, proposal_id, voting_power, should_pass);
            });
        };
    }

    /// Vote on proposal with `proposal_id` and all voting power from the caller.
    public entry fun vote(
        voter: &signer,
        proposal_id: u64,
        should_pass: bool,
    ) acquires ApprovedExecutionHashes, VotingRecords, VotingRecordsV2 {
        vote_internal(voter, proposal_id, MAX_U64, should_pass);
    }

    /// Vote on proposal with `proposal_id` and specified voting power from the caller.
    public entry fun partial_vote(
        voter: &signer,
        proposal_id: u64,
        voting_power: u64,
        should_pass: bool,
    ) acquires ApprovedExecutionHashes, VotingRecords, VotingRecordsV2 {
        vote_internal(voter, proposal_id, voting_power, should_pass);
    }

    #[deprecated]
    public entry fun vote_with_stake_pool(
        voter: &signer,
        stake_pool: address,
        proposal_id: u64,
        should_pass: bool,
    ) acquires ApprovedExecutionHashes, VotingRecords, VotingRecordsV2 {
        vote_internal_with_stake_pool(voter, stake_pool, proposal_id, MAX_U64, should_pass);
    }

    #[deprecated]
    public entry fun partial_vote_with_stake_pool(
        voter: &signer,
        stake_pool: address,
        proposal_id: u64,
        voting_power: u64,
        should_pass: bool,
    ) acquires ApprovedExecutionHashes, VotingRecords, VotingRecordsV2 {
        vote_internal_with_stake_pool(voter, stake_pool, proposal_id, voting_power, should_pass);
    }

    /// Vote on proposal with `proposal_id` and specified voting_power from the caller.
    /// If voting_power is more than all the left voting power of the caller, use all the left voting power.
    /// If a voter has already voted on a proposal before partial governance voting is enabled, the voter
    /// cannot vote on the proposal even after partial governance voting is enabled.
    fun vote_internal(
        voter: &signer,
        proposal_id: u64,
        voting_power: u64,
        should_pass: bool,
    ) acquires ApprovedExecutionHashes, VotingRecords, VotingRecordsV2 {
        vote_internal_impl(
            voter,
            signer::address_of(voter),
            proposal_id,
            voting_power,
            should_pass,
        );
    }

    fun vote_internal_with_stake_pool(
        voter: &signer,
        stake_pool: address,
        proposal_id: u64,
        voting_power: u64,
        should_pass: bool,
    ) acquires ApprovedExecutionHashes, VotingRecords, VotingRecordsV2 {
        let voting_subject =
            if (staking_registry::registry_exists()) {
                // 旧接口兼容层：registry 模式下最终主体仍然必须是 voter 自己。
                signer::address_of(voter)
            } else {
                stake_pool
            };
        vote_internal_impl(voter, voting_subject, proposal_id, voting_power, should_pass);
    }

    fun vote_internal_impl(
        voter: &signer,
        voting_subject: address,
        proposal_id: u64,
        voting_power: u64,
        should_pass: bool,
    ) acquires ApprovedExecutionHashes, VotingRecords, VotingRecordsV2 {
        permissioned_signer::assert_master_signer(voter);
        let voter_address = signer::address_of(voter);
        if (!staking_registry::registry_exists()) {
            assert!(
                stake::get_delegated_voter(voting_subject) == voter_address,
                error::invalid_argument(ENOT_DELEGATED_VOTER),
            );
        };
        // `voting_subject` 在 registry 模式下表示 voter 地址，
        // 在旧模式下表示 stake_pool 地址。后续剩余票数计算与投票记录都统一围绕它展开。
        assert_proposal_expiration(voting_subject, proposal_id);

        // If a stake pool has already voted on a proposal before partial governance voting is enabled,
        // `get_remaining_voting_power` returns 0.
        let staking_pool_voting_power = get_remaining_voting_power(voting_subject, proposal_id);
        voting_power = min(voting_power, staking_pool_voting_power);

        // Short-circuit if the voter has no voting power.
        assert!(voting_power > 0, error::invalid_argument(ENO_VOTING_POWER));

        voting::vote<GovernanceProposal>(
            &governance_proposal::create_empty_proposal(),
            @aptos_framework,
            proposal_id,
            voting_power,
            should_pass,
        );

        let record_key = RecordKey {
            voter: voting_subject,
            proposal_id,
        };
        let used_voting_power = VotingRecordsV2[@aptos_framework].votes.borrow_mut_with_default(record_key, 0);
        // This calculation should never overflow because the used voting cannot exceed the total voting power of this stake pool.
        *used_voting_power += voting_power;

        event::emit(
            Vote {
                proposal_id,
                voter: voter_address,
                num_votes: voting_power,
                should_pass,
            },
        );

        let proposal_state = voting::get_proposal_state<GovernanceProposal>(@aptos_framework, proposal_id);
        if (proposal_state == PROPOSAL_STATE_SUCCEEDED) {
            add_approved_script_hash(proposal_id);
        }
    }

    public entry fun add_approved_script_hash_script(proposal_id: u64) acquires ApprovedExecutionHashes {
        add_approved_script_hash(proposal_id)
    }

    /// Add the execution script hash of a successful governance proposal to the approved list.
    /// This is needed to bypass the mempool transaction size limit for approved governance proposal transactions that
    /// are too large (e.g. module upgrades).
    public fun add_approved_script_hash(proposal_id: u64) acquires ApprovedExecutionHashes {
        let approved_hashes = borrow_global_mut<ApprovedExecutionHashes>(@aptos_framework);

        // Ensure the proposal can be resolved.
        let proposal_state = voting::get_proposal_state<GovernanceProposal>(@aptos_framework, proposal_id);
        assert!(proposal_state == PROPOSAL_STATE_SUCCEEDED, error::invalid_argument(EPROPOSAL_NOT_RESOLVABLE_YET));

        let execution_hash = voting::get_execution_hash<GovernanceProposal>(@aptos_framework, proposal_id);

        // If this is a multi-step proposal, the proposal id will already exist in the ApprovedExecutionHashes map.
        // We will update execution hash in ApprovedExecutionHashes to be the next_execution_hash.
        if (approved_hashes.hashes.contains_key(&proposal_id)) {
            let current_execution_hash = approved_hashes.hashes.borrow_mut(&proposal_id);
            *current_execution_hash = execution_hash;
        } else {
            approved_hashes.hashes.add(proposal_id, execution_hash);
        }
    }

    /// Resolve a successful single-step proposal. This would fail if the proposal is not successful (not enough votes or more no
    /// than yes).
    public fun resolve(
        proposal_id: u64,
        signer_address: address
    ): signer acquires ApprovedExecutionHashes, GovernanceResponsbility {
        voting::resolve<GovernanceProposal>(@aptos_framework, proposal_id);
        remove_approved_hash(proposal_id);
        get_signer(signer_address)
    }

    /// Resolve a successful multi-step proposal. This would fail if the proposal is not successful.
    public fun resolve_multi_step_proposal(
        proposal_id: u64,
        signer_address: address,
        next_execution_hash: vector<u8>
    ): signer acquires GovernanceResponsbility, ApprovedExecutionHashes {
        voting::resolve_proposal_v2<GovernanceProposal>(@aptos_framework, proposal_id, next_execution_hash);
        // If the current step is the last step of this multi-step proposal,
        // we will remove the execution hash from the ApprovedExecutionHashes map.
        if (next_execution_hash.length() == 0) {
            remove_approved_hash(proposal_id);
        } else {
            // If the current step is not the last step of this proposal,
            // we replace the current execution hash with the next execution hash
            // in the ApprovedExecutionHashes map.
            add_approved_script_hash(proposal_id)
        };
        get_signer(signer_address)
    }

    /// Remove an approved proposal's execution script hash.
    public fun remove_approved_hash(proposal_id: u64) acquires ApprovedExecutionHashes {
        assert!(
            voting::is_resolved<GovernanceProposal>(@aptos_framework, proposal_id),
            error::invalid_argument(EPROPOSAL_NOT_RESOLVED_YET),
        );

        let approved_hashes = &mut borrow_global_mut<ApprovedExecutionHashes>(@aptos_framework).hashes;
        if (approved_hashes.contains_key(&proposal_id)) {
            approved_hashes.remove(&proposal_id);
        };
    }

    /// Manually reconfigure. Called at the end of a governance txn that alters on-chain configs.
    ///
    /// WARNING: this function always ensures a reconfiguration starts, but when the reconfiguration finishes depends.
    /// - If feature `RECONFIGURE_WITH_DKG` is disabled, it finishes immediately.
    ///   - At the end of the calling transaction, we will be in a new epoch.
    /// - If feature `RECONFIGURE_WITH_DKG` is enabled, it starts DKG, and the new epoch will start in a block prologue after DKG finishes.
    ///
    /// This behavior affects when an update of an on-chain config (e.g. `ConsensusConfig`, `Features`) takes effect,
    /// since such updates are applied whenever we enter an new epoch.
    public entry fun reconfigure(aptos_framework: &signer) {
        system_addresses::assert_aptos_framework(aptos_framework);
        if (consensus_config::validator_txn_enabled() && randomness_config::enabled()) {
            if (chunky_dkg_config::enabled()) {
                reconfiguration_with_dkg::try_start_with_chunky_dkg();
            } else {
                reconfiguration_with_dkg::try_start();
            }
        } else {
            reconfiguration_with_dkg::finish(aptos_framework);
        }
    }

    /// Change epoch immediately.
    /// If `RECONFIGURE_WITH_DKG` is enabled and we are in the middle of a DKG,
    /// stop waiting for DKG and enter the new epoch without randomness.
    ///
    /// WARNING: currently only used by tests. In most cases you should use `reconfigure()` instead.
    /// TODO: migrate these tests to be aware of async reconfiguration.
    public entry fun force_end_epoch(aptos_framework: &signer) {
        system_addresses::assert_aptos_framework(aptos_framework);
        reconfiguration_with_dkg::finish(aptos_framework);
    }

    /// `force_end_epoch()` equivalent but only called in testnet,
    /// where the core resources account exists and has been granted power to mint Aptos coins.
    public entry fun force_end_epoch_test_only(aptos_framework: &signer) acquires GovernanceResponsbility {
        let core_signer = get_signer_testnet_only(aptos_framework, @0x1);
        system_addresses::assert_aptos_framework(&core_signer);
        reconfiguration_with_dkg::finish(&core_signer);
    }

    /// Update feature flags and also trigger reconfiguration.
    public fun toggle_features(aptos_framework: &signer, enable: vector<u64>, disable: vector<u64>) {
        system_addresses::assert_aptos_framework(aptos_framework);
        features::change_feature_flags_for_next_epoch(aptos_framework, enable, disable);
        reconfigure(aptos_framework);
    }

    /// Only called in testnet where the core resources account exists and has been granted power to mint Aptos coins.
    public fun get_signer_testnet_only(
        core_resources: &signer, signer_address: address): signer acquires GovernanceResponsbility {
        system_addresses::assert_core_resource(core_resources);
        // Core resources account only has mint capability in tests/testnets.
        assert!(topo_coin::has_mint_capability(core_resources), error::unauthenticated(EUNAUTHORIZED));
        get_signer(signer_address)
    }

    #[view]
    /// Return the voting power a stake pool has with respect to governance proposals.
    public fun get_voting_power(pool_address: address): u64 {
        if (staking_registry::registry_exists()) {
            staking_registry::get_effective_power(pool_address)
        } else {
            let allow_validator_set_change =
                staking_config::get_allow_validator_set_change(&staking_config::get());
            if (allow_validator_set_change) {
                let (active, _, pending_active, pending_inactive) = stake::get_stake(pool_address);
                // We calculate the voting power as total non-inactive stakes of the pool. Even if the validator is not in the
                // active validator set, as long as they have a lockup (separately checked in create_proposal and voting), their
                // stake would still count in their voting power for governance proposals.
                active + pending_active + pending_inactive
            } else {
                stake::get_current_epoch_voting_power(pool_address)
            }
        }
    }

    /// Return a signer for making changes to 0x1 as part of on-chain governance proposal process.
    fun get_signer(signer_address: address): signer acquires GovernanceResponsbility {
        let governance_responsibility = borrow_global<GovernanceResponsbility>(@aptos_framework);
        let signer_cap = governance_responsibility.signer_caps.borrow(&signer_address);
        create_signer_with_capability(signer_cap)
    }

    fun create_proposal_metadata(
        metadata_location: vector<u8>,
        metadata_hash: vector<u8>
    ): SimpleMap<String, vector<u8>> {
        assert!(utf8(metadata_location).length() <= 256, error::invalid_argument(EMETADATA_LOCATION_TOO_LONG));
        assert!(utf8(metadata_hash).length() <= 256, error::invalid_argument(EMETADATA_HASH_TOO_LONG));

        let metadata = simple_map::create<String, vector<u8>>();
        metadata.add(utf8(METADATA_LOCATION_KEY), metadata_location);
        metadata.add(utf8(METADATA_HASH_KEY), metadata_hash);
        metadata
    }

    fun assert_voting_initialization() {
        assert!(exists<VotingRecordsV2>(@aptos_framework), error::invalid_state(EPARTIAL_VOTING_NOT_INITIALIZED));
    }

    #[test_only]
    public entry fun create_proposal_for_test(
        proposer: &signer,
        multi_step: bool,
    ) acquires GovernanceConfig {
        let execution_hash = vector[1];
        if (multi_step) {
            create_proposal_v2(
                proposer,
                execution_hash,
                b"",
                b"",
                true,
            );
        } else {
            create_proposal(
                proposer,
                execution_hash,
                b"",
                b"",
            );
        };
    }

    #[test_only]
    public fun resolve_proposal_for_test(
        proposal_id: u64,
        signer_address: address,
        multi_step: bool,
        finish_multi_step_execution: bool
    ): signer acquires ApprovedExecutionHashes, GovernanceResponsbility {
        if (multi_step) {
            let execution_hash = vector::empty<u8>();
            execution_hash.push_back(1);

            if (finish_multi_step_execution) {
                resolve_multi_step_proposal(proposal_id, signer_address, vector::empty<u8>())
            } else {
                resolve_multi_step_proposal(proposal_id, signer_address, execution_hash)
            }
        } else {
            resolve(proposal_id, signer_address)
        }
    }

    #[test_only]
    /// Force reconfigure. To be called at the end of a proposal that alters on-chain configs.
    public fun toggle_features_for_test(enable: vector<u64>, disable: vector<u64>) {
        toggle_features(&account::create_signer_for_test(@0x1), enable, disable);
    }

    #[test_only]
    public entry fun test_voting_generic(
        aptos_framework: signer,
        proposer: signer,
        yes_voter: signer,
        no_voter: signer,
        multi_step: bool,
        use_generic_resolve_function: bool,
    ) acquires ApprovedExecutionHashes, GovernanceConfig, GovernanceResponsbility, VotingRecords, VotingRecordsV2 {
        setup_partial_voting(&aptos_framework, &proposer, &yes_voter, &no_voter);

        let execution_hash = vector[1];

        create_proposal_for_test(&proposer, multi_step);

        vote(&yes_voter, 0, true);
        vote(&no_voter, 0, false);

        test_resolving_proposal_generic(aptos_framework, use_generic_resolve_function, execution_hash);
    }

    #[test_only]
    public entry fun test_resolving_proposal_generic(
        aptos_framework: signer,
        use_generic_resolve_function: bool,
        execution_hash: vector<u8>,
    ) acquires ApprovedExecutionHashes, GovernanceResponsbility {
        // Once expiration time has passed, the proposal should be considered resolve now as there are more yes votes
        // than no.
        timestamp::update_global_time_for_test(100001000000);
        let proposal_state = voting::get_proposal_state<GovernanceProposal>(signer::address_of(&aptos_framework), 0);
        assert!(proposal_state == PROPOSAL_STATE_SUCCEEDED, proposal_state);

        // Add approved script hash.
        add_approved_script_hash(0);
        let approved_hashes = borrow_global<ApprovedExecutionHashes>(@aptos_framework).hashes;
        assert!(*approved_hashes.borrow(&0) == execution_hash, 0);

        // Resolve the proposal.
        let account = resolve_proposal_for_test(0, @aptos_framework, use_generic_resolve_function, true);
        assert!(signer::address_of(&account) == @aptos_framework, 1);
        assert!(voting::is_resolved<GovernanceProposal>(@aptos_framework, 0), 2);
        let approved_hashes = borrow_global<ApprovedExecutionHashes>(@aptos_framework).hashes;
        assert!(!approved_hashes.contains_key(&0), 3);
    }

    #[test(aptos_framework = @aptos_framework, proposer = @0x123, yes_voter = @0x234, no_voter = @345)]
    public entry fun test_voting(
        aptos_framework: signer,
        proposer: signer,
        yes_voter: signer,
        no_voter: signer,
    ) acquires ApprovedExecutionHashes, GovernanceConfig, GovernanceResponsbility, VotingRecords, VotingRecordsV2 {
        test_voting_generic(aptos_framework, proposer, yes_voter, no_voter, false, false);
    }

    #[test(aptos_framework = @aptos_framework, proposer = @0x123, yes_voter = @0x234, no_voter = @345)]
    public entry fun test_voting_multi_step(
        aptos_framework: signer,
        proposer: signer,
        yes_voter: signer,
        no_voter: signer,
    ) acquires ApprovedExecutionHashes, GovernanceConfig, GovernanceResponsbility, VotingRecords, VotingRecordsV2 {
        test_voting_generic(aptos_framework, proposer, yes_voter, no_voter, true, true);
    }

    #[test(aptos_framework = @aptos_framework, proposer = @0x123, yes_voter = @0x234, no_voter = @345)]
    #[expected_failure(abort_code = 0x5000a, location = aptos_framework::voting)]
    public entry fun test_voting_multi_step_cannot_use_single_step_resolve(
        aptos_framework: signer,
        proposer: signer,
        yes_voter: signer,
        no_voter: signer,
    ) acquires ApprovedExecutionHashes, GovernanceConfig, GovernanceResponsbility, VotingRecords, VotingRecordsV2 {
        test_voting_generic(aptos_framework, proposer, yes_voter, no_voter, true, false);
    }

    #[test(aptos_framework = @aptos_framework, proposer = @0x123, yes_voter = @0x234, no_voter = @345)]
    public entry fun test_voting_single_step_can_use_generic_resolve_function(
        aptos_framework: signer,
        proposer: signer,
        yes_voter: signer,
        no_voter: signer,
    ) acquires ApprovedExecutionHashes, GovernanceConfig, GovernanceResponsbility, VotingRecords, VotingRecordsV2 {
        test_voting_generic(aptos_framework, proposer, yes_voter, no_voter, false, true);
    }

    #[test_only]
    public entry fun test_can_remove_approved_hash_if_executed_directly_via_voting_generic(
        aptos_framework: signer,
        proposer: signer,
        yes_voter: signer,
        no_voter: signer,
        multi_step: bool,
    ) acquires ApprovedExecutionHashes, GovernanceConfig, GovernanceResponsbility, VotingRecords, VotingRecordsV2 {
        setup_partial_voting(&aptos_framework, &proposer, &yes_voter, &no_voter);

        create_proposal_for_test(&proposer, multi_step);
        vote(&yes_voter, 0, true);
        vote(&no_voter, 0, false);

        // Add approved script hash.
        timestamp::update_global_time_for_test(100001000000);
        add_approved_script_hash(0);

        // Resolve the proposal.
        if (multi_step) {
            let execution_hash = vector::empty<u8>();
            let next_execution_hash = vector::empty<u8>();
            execution_hash.push_back(1);
            voting::resolve_proposal_v2<GovernanceProposal>(@aptos_framework, 0, next_execution_hash);
            assert!(voting::is_resolved<GovernanceProposal>(@aptos_framework, 0), 0);
            if (next_execution_hash.length() == 0) {
                remove_approved_hash(0);
            } else {
                add_approved_script_hash(0)
            };
        } else {
            voting::resolve<GovernanceProposal>(@aptos_framework, 0);
            assert!(voting::is_resolved<GovernanceProposal>(@aptos_framework, 0), 0);
            remove_approved_hash(0);
        };
        let approved_hashes = borrow_global<ApprovedExecutionHashes>(@aptos_framework).hashes;
        assert!(!approved_hashes.contains_key(&0), 1);
    }

    #[test(aptos_framework = @aptos_framework, proposer = @0x123, yes_voter = @0x234, no_voter = @345)]
    public entry fun test_can_remove_approved_hash_if_executed_directly_via_voting(
        aptos_framework: signer,
        proposer: signer,
        yes_voter: signer,
        no_voter: signer,
    ) acquires ApprovedExecutionHashes, GovernanceConfig, GovernanceResponsbility, VotingRecords, VotingRecordsV2 {
        test_can_remove_approved_hash_if_executed_directly_via_voting_generic(
            aptos_framework,
            proposer,
            yes_voter,
            no_voter,
            false
        );
    }

    #[test(aptos_framework = @aptos_framework, proposer = @0x123, yes_voter = @0x234, no_voter = @345)]
    public entry fun test_can_remove_approved_hash_if_executed_directly_via_voting_multi_step(
        aptos_framework: signer,
        proposer: signer,
        yes_voter: signer,
        no_voter: signer,
    ) acquires ApprovedExecutionHashes, GovernanceConfig, GovernanceResponsbility, VotingRecords, VotingRecordsV2 {
        test_can_remove_approved_hash_if_executed_directly_via_voting_generic(
            aptos_framework,
            proposer,
            yes_voter,
            no_voter,
            true
        );
    }

    #[test(aptos_framework = @aptos_framework, proposer = @0x123, voter_1 = @0x234, voter_2 = @345)]
    #[expected_failure(abort_code = 65541, location = aptos_framework::topo_governance)]
    public entry fun test_cannot_double_vote(
        aptos_framework: signer,
        proposer: signer,
        voter_1: signer,
        voter_2: signer,
    ) acquires ApprovedExecutionHashes, GovernanceConfig, GovernanceResponsbility, VotingRecords, VotingRecordsV2 {
        setup_voting(&aptos_framework, &proposer, &voter_1, &voter_2);

        create_proposal(
            &proposer,
            b"0",
            b"",
            b"",
        );

        // Double voting should throw an error.
        vote(&voter_1, 0, true);
        vote(&voter_1, 0, true);
    }

    #[test(aptos_framework = @aptos_framework, proposer = @0x123, voter_1 = @0x234, voter_2 = @345)]
    #[expected_failure(abort_code = 65551, location = aptos_framework::topo_governance)]
    public entry fun test_cannot_vote_for_expired_proposal(
        aptos_framework: signer,
        proposer: signer,
        voter_1: signer,
        voter_2: signer,
    ) acquires ApprovedExecutionHashes, GovernanceConfig, GovernanceResponsbility, VotingRecords, VotingRecordsV2 {
        setup_partial_voting_with_initialized_stake(&aptos_framework, &proposer, &voter_1, &voter_2);

        create_proposal(
            &proposer,
            b"0",
            b"",
            b"",
        );

        timestamp::fast_forward_seconds(2000);
        stake::end_epoch();

        // Should abort because the proposal has expired.
        vote(&voter_1, 0, true);
    }

    #[test(aptos_framework = @aptos_framework, proposer = @0x123, voter_1 = @0x234, voter_2 = @0x345)]
    #[expected_failure(abort_code = 65539, location = aptos_framework::topo_governance)]
    public entry fun test_cannot_vote_due_to_insufficient_stake_lockup(
        aptos_framework: signer,
        proposer: signer,
        voter_1: signer,
        voter_2: signer,
    ) acquires ApprovedExecutionHashes, GovernanceConfig, GovernanceResponsbility, VotingRecords, VotingRecordsV2 {
        setup_partial_voting_with_initialized_stake(&aptos_framework, &proposer, &voter_1, &voter_2);

        create_proposal(
            &proposer,
            b"0",
            b"",
            b"",
        );

        // Should abort due to insufficient stake lockup.
        vote(&voter_1, 0, true);
    }

    #[test(aptos_framework = @aptos_framework, proposer = @0x123, voter_1 = @0x234, voter_2 = @345)]
    #[expected_failure(abort_code = 65541, location = aptos_framework::topo_governance)]
    public entry fun test_cannot_double_vote_with_different_voter_addresses(
        aptos_framework: signer,
        proposer: signer,
        voter_1: signer,
        voter_2: signer,
    ) acquires ApprovedExecutionHashes, GovernanceConfig, GovernanceResponsbility, VotingRecords, VotingRecordsV2 {
        setup_voting(&aptos_framework, &proposer, &voter_1, &voter_2);

        create_proposal(
            &proposer,
            b"0",
            b"",
            b"",
        );

        // Double voting should throw an error for 2 different voters if they still use the same stake pool.
        vote(&voter_1, 0, true);
        stake::set_delegated_voter(&voter_1, signer::address_of(&voter_2));
        vote_with_stake_pool(&voter_2, signer::address_of(&voter_1), 0, true);
    }

    #[test(aptos_framework = @aptos_framework, proposer = @0x123, voter_1 = @0x234, voter_2 = @345)]
    public entry fun test_stake_pool_can_vote_on_partial_voting_proposal_many_times(
        aptos_framework: signer,
        proposer: signer,
        voter_1: signer,
        voter_2: signer,
    ) acquires ApprovedExecutionHashes, GovernanceConfig, GovernanceResponsbility, VotingRecords, VotingRecordsV2 {
        setup_partial_voting(&aptos_framework, &proposer, &voter_1, &voter_2);
        let execution_hash = vector[1];
        let proposer_addr = signer::address_of(&proposer);
        let voter_1_addr = signer::address_of(&voter_1);
        let voter_2_addr = signer::address_of(&voter_2);

        create_proposal_for_test(&proposer, true);

        partial_vote(&voter_1, 0, 5, true);
        partial_vote(&voter_1, 0, 3, true);
        partial_vote(&voter_1, 0, 2, true);

        assert!(get_remaining_voting_power(proposer_addr, 0) == 100, 0);
        assert!(get_remaining_voting_power(voter_1_addr, 0) == 10, 1);
        assert!(get_remaining_voting_power(voter_2_addr, 0) == 10, 2);

        test_resolving_proposal_generic(aptos_framework, true, execution_hash);
    }

    #[test(aptos_framework = @aptos_framework, proposer = @0x123, voter_1 = @0x234, voter_2 = @345)]
    #[expected_failure(abort_code = 0x3, location = Self)]
    public entry fun test_stake_pool_can_vote_with_partial_voting_power(
        aptos_framework: signer,
        proposer: signer,
        voter_1: signer,
        voter_2: signer,
    ) acquires ApprovedExecutionHashes, GovernanceConfig, GovernanceResponsbility, VotingRecords, VotingRecordsV2 {
        setup_partial_voting(&aptos_framework, &proposer, &voter_1, &voter_2);
        let execution_hash = vector[1];
        let proposer_addr = signer::address_of(&proposer);
        let voter_1_addr = signer::address_of(&voter_1);
        let voter_2_addr = signer::address_of(&voter_2);

        create_proposal_for_test(&proposer, true);

        partial_vote(&voter_1, 0, 9, true);

        assert!(get_remaining_voting_power(proposer_addr, 0) == 100, 0);
        assert!(get_remaining_voting_power(voter_1_addr, 0) == 11, 1);
        assert!(get_remaining_voting_power(voter_2_addr, 0) == 10, 2);

        // No enough Yes. The proposal cannot be resolved.
        test_resolving_proposal_generic(aptos_framework, true, execution_hash);
    }

    #[test(aptos_framework = @aptos_framework, proposer = @0x123, voter_1 = @0x234, voter_2 = @345)]
    public entry fun test_batch_vote(
        aptos_framework: signer,
        proposer: signer,
        voter_1: signer,
        voter_2: signer,
    ) acquires ApprovedExecutionHashes, GovernanceConfig, GovernanceResponsbility, VotingRecords, VotingRecordsV2 {
        features::change_feature_flags_for_testing(&aptos_framework, vector[features::get_coin_to_fungible_asset_migration_feature()], vector[]);
        setup_partial_voting(&aptos_framework, &proposer, &voter_1, &voter_2);
        let execution_hash = vector[1];
        let voter_1_addr = signer::address_of(&voter_1);
        let voter_2_addr = signer::address_of(&voter_2);
        stake::set_delegated_voter(&voter_2, voter_1_addr);
        create_proposal_for_test(&proposer, true);
        batch_vote_with_stake_pools(&voter_1, vector[voter_1_addr, voter_2_addr], 0, true);
        test_resolving_proposal_generic(aptos_framework, true, execution_hash);
    }

    #[test(aptos_framework = @aptos_framework, proposer = @0x123, voter_1 = @0x234, voter_2 = @345)]
    public entry fun test_batch_partial_vote(
        aptos_framework: signer,
        proposer: signer,
        voter_1: signer,
        voter_2: signer,
    ) acquires ApprovedExecutionHashes, GovernanceConfig, GovernanceResponsbility, VotingRecords, VotingRecordsV2 {
        features::change_feature_flags_for_testing(&aptos_framework, vector[features::get_coin_to_fungible_asset_migration_feature()], vector[]);
        setup_partial_voting(&aptos_framework, &proposer, &voter_1, &voter_2);
        let execution_hash = vector[1];
        let voter_1_addr = signer::address_of(&voter_1);
        let voter_2_addr = signer::address_of(&voter_2);
        stake::set_delegated_voter(&voter_2, voter_1_addr);
        create_proposal_for_test(&proposer, true);
        batch_partial_vote_with_stake_pools(
            &voter_1,
            vector[voter_1_addr, voter_2_addr],
            0,
            9,
            true,
        );
        test_resolving_proposal_generic(aptos_framework, true, execution_hash);
    }

    #[test(aptos_framework = @aptos_framework, proposer = @0x123, voter_1 = @0x234, voter_2 = @345)]
    public entry fun test_stake_pool_can_vote_only_with_its_own_voting_power(
        aptos_framework: signer,
        proposer: signer,
        voter_1: signer,
        voter_2: signer,
    ) acquires ApprovedExecutionHashes, GovernanceConfig, GovernanceResponsbility, VotingRecords, VotingRecordsV2 {
        setup_partial_voting(&aptos_framework, &proposer, &voter_1, &voter_2);
        let execution_hash = vector[1];
        let proposer_addr = signer::address_of(&proposer);
        let voter_1_addr = signer::address_of(&voter_1);
        let voter_2_addr = signer::address_of(&voter_2);

        create_proposal_for_test(&proposer, true);

        partial_vote(&voter_1, 0, 9, true);
        // The total voting power of voter_1 is 20. It can only vote with 20 voting power even we pass 30 as the argument.
        partial_vote(&voter_1, 0, 30, true);

        assert!(get_remaining_voting_power(proposer_addr, 0) == 100, 0);
        assert!(get_remaining_voting_power(voter_1_addr, 0) == 0, 1);
        assert!(get_remaining_voting_power(voter_2_addr, 0) == 10, 2);

        test_resolving_proposal_generic(aptos_framework, true, execution_hash);
    }

    #[test(aptos_framework = @aptos_framework, proposer = @0x123, voter_1 = @0x234, voter_2 = @345)]
    public entry fun test_no_remaining_voting_power_about_proposal_expiration_time(
        aptos_framework: signer,
        proposer: signer,
        voter_1: signer,
        voter_2: signer,
    ) acquires GovernanceConfig, GovernanceResponsbility, VotingRecords, VotingRecordsV2 {
        setup_partial_voting_with_initialized_stake(&aptos_framework, &proposer, &voter_1, &voter_2);
        let proposer_addr = signer::address_of(&proposer);
        let voter_1_addr = signer::address_of(&voter_1);
        let voter_2_addr = signer::address_of(&voter_2);

        create_proposal_for_test(&proposer, true);
        assert!(get_remaining_voting_power(proposer_addr, 0) == 100, 0);
        assert!(get_remaining_voting_power(voter_1_addr, 0) == 0, 1);
        assert!(get_remaining_voting_power(voter_2_addr, 0) == 0, 2);

        // 500 seconds later, lockup period of voter_1 and voter_2 is reset.
        timestamp::fast_forward_seconds(440);
        stake::end_epoch();
        assert!(get_remaining_voting_power(proposer_addr, 0) == 100, 0);
        assert!(get_remaining_voting_power(voter_1_addr, 0) == 20, 1);
        assert!(get_remaining_voting_power(voter_2_addr, 0) == 10, 2);

        // 501 seconds later, the proposal expires.
        timestamp::fast_forward_seconds(441);
        stake::end_epoch();
        assert!(get_remaining_voting_power(proposer_addr, 0) == 0, 0);
        assert!(get_remaining_voting_power(voter_1_addr, 0) == 0, 1);
        assert!(get_remaining_voting_power(voter_2_addr, 0) == 0, 2);
    }

    #[test_only]
    public fun setup_voting(
        aptos_framework: &signer,
        proposer: &signer,
        yes_voter: &signer,
        no_voter: &signer,
    ) acquires GovernanceResponsbility {
        use std::vector;
        use aptos_framework::account;
        use aptos_framework::coin;
        use aptos_framework::topo_coin::{Self, TopoCoin};

        timestamp::set_time_has_started_for_testing(aptos_framework);
        account::create_account_for_test(signer::address_of(aptos_framework));
        account::create_account_for_test(signer::address_of(proposer));
        account::create_account_for_test(signer::address_of(yes_voter));
        account::create_account_for_test(signer::address_of(no_voter));

        // Initialize the governance.
        staking_config::initialize_for_test(aptos_framework, 0, 1000, 2000, true, 0, 1, 100);
        initialize(aptos_framework, 10, 100, 1000);
        store_signer_cap(
            aptos_framework,
            @aptos_framework,
            account::create_test_signer_cap(@aptos_framework),
        );

        // Initialize the stake pools for proposer and voters.
        let active_validators = vector::empty<address>();
        active_validators.push_back(signer::address_of(proposer));
        active_validators.push_back(signer::address_of(yes_voter));
        active_validators.push_back(signer::address_of(no_voter));
        let (_sk_1, pk_1, _pop_1) = stake::generate_identity();
        let (_sk_2, pk_2, _pop_2) = stake::generate_identity();
        let (_sk_3, pk_3, _pop_3) = stake::generate_identity();
        let pks = vector[pk_1, pk_2, pk_3];
        stake::create_validator_set(aptos_framework, active_validators, pks);

        let (burn_cap, mint_cap) = topo_coin::initialize_for_test(aptos_framework);
        // Spread stake among active and pending_inactive because both need to be accounted for when computing voting
        // power.
        coin::register<TopoCoin>(proposer);
        coin::deposit(signer::address_of(proposer), coin::mint(100, &mint_cap));
        coin::register<TopoCoin>(yes_voter);
        coin::deposit(signer::address_of(yes_voter), coin::mint(20, &mint_cap));
        coin::register<TopoCoin>(no_voter);
        coin::deposit(signer::address_of(no_voter), coin::mint(10, &mint_cap));
        stake::create_stake_pool(proposer, coin::mint(50, &mint_cap), coin::mint(50, &mint_cap), 10000);
        stake::create_stake_pool(yes_voter, coin::mint(10, &mint_cap), coin::mint(10, &mint_cap), 10000);
        stake::create_stake_pool(no_voter, coin::mint(5, &mint_cap), coin::mint(5, &mint_cap), 10000);
        coin::destroy_mint_cap<TopoCoin>(mint_cap);
        coin::destroy_burn_cap<TopoCoin>(burn_cap);
    }

    #[test_only]
    public fun setup_voting_with_initialized_stake(
        aptos_framework: &signer,
        proposer: &signer,
        yes_voter: &signer,
        no_voter: &signer,
    ) acquires GovernanceResponsbility {
        use aptos_framework::account;
        use aptos_framework::coin;
        use aptos_framework::topo_coin::TopoCoin;

        timestamp::set_time_has_started_for_testing(aptos_framework);
        account::create_account_for_test(signer::address_of(aptos_framework));
        account::create_account_for_test(signer::address_of(proposer));
        account::create_account_for_test(signer::address_of(yes_voter));
        account::create_account_for_test(signer::address_of(no_voter));

        // Initialize the governance.
        stake::initialize_for_test_custom(aptos_framework, 0, 1000, 2000, true, 0, 1, 1000);
        initialize(aptos_framework, 10, 100, 1000);
        store_signer_cap(
            aptos_framework,
            @aptos_framework,
            account::create_test_signer_cap(@aptos_framework),
        );

        // Initialize the stake pools for proposer and voters.
        // Spread stake among active and pending_inactive because both need to be accounted for when computing voting
        // power.
        coin::register<TopoCoin>(proposer);
        coin::deposit(signer::address_of(proposer), stake::mint_coins(100));
        coin::register<TopoCoin>(yes_voter);
        coin::deposit(signer::address_of(yes_voter), stake::mint_coins(20));
        coin::register<TopoCoin>(no_voter);
        coin::deposit(signer::address_of(no_voter), stake::mint_coins(10));

        let (_sk_1, pk_1, pop_1) = stake::generate_identity();
        let (_sk_2, pk_2, pop_2) = stake::generate_identity();
        let (_sk_3, pk_3, pop_3) = stake::generate_identity();
        stake::initialize_test_validator(&pk_2, &pop_2, yes_voter, 20, true, false);
        stake::initialize_test_validator(&pk_3, &pop_3, no_voter, 10, true, false);
        stake::end_epoch();
        timestamp::fast_forward_seconds(1440);
        stake::initialize_test_validator(&pk_1, &pop_1, proposer, 100, true, false);
        stake::end_epoch();
    }

    #[test_only]
    public fun setup_partial_voting_with_initialized_stake(
        aptos_framework: &signer,
        proposer: &signer,
        yes_voter: &signer,
        no_voter: &signer,
    ) acquires GovernanceResponsbility {
        setup_voting_with_initialized_stake(aptos_framework, proposer, yes_voter, no_voter);
    }

    #[test_only]
    public fun setup_partial_voting(
        aptos_framework: &signer,
        proposer: &signer,
        voter_1: &signer,
        voter_2: &signer,
    ) acquires GovernanceResponsbility {
        setup_voting(aptos_framework, proposer, voter_1, voter_2);
    }

    #[test(aptos_framework = @aptos_framework)]
    public entry fun test_update_governance_config(
        aptos_framework: signer,
    ) acquires GovernanceConfig {
        account::create_account_for_test(signer::address_of(&aptos_framework));
        initialize(&aptos_framework, 1, 2, 3);
        update_governance_config(&aptos_framework, 10, 20, 30);

        let config = borrow_global<GovernanceConfig>(@aptos_framework);
        assert!(config.min_voting_threshold == 10, 0);
        assert!(config.required_proposer_stake == 20, 1);
        assert!(config.voting_duration_secs == 30, 3);
    }

    #[test(account = @0x123)]
    #[expected_failure(abort_code = 0x50003, location = aptos_framework::system_addresses)]
    public entry fun test_update_governance_config_unauthorized_should_fail(
        account: signer) acquires GovernanceConfig {
        initialize(&account, 1, 2, 3);
        update_governance_config(&account, 10, 20, 30);
    }

    #[test(aptos_framework = @aptos_framework, proposer = @0x123, yes_voter = @0x234, no_voter = @345)]
    public entry fun test_replace_execution_hash(
        aptos_framework: signer,
        proposer: signer,
        yes_voter: signer,
        no_voter: signer,
    ) acquires GovernanceResponsbility, GovernanceConfig, ApprovedExecutionHashes, VotingRecords, VotingRecordsV2 {
        setup_partial_voting(&aptos_framework, &proposer, &yes_voter, &no_voter);

        create_proposal_for_test(&proposer, true);
        vote(&yes_voter, 0, true);
        vote(&no_voter, 0, false);

        // Add approved script hash.
        timestamp::update_global_time_for_test(100001000000);
        add_approved_script_hash(0);

        // Resolve the proposal.
        let execution_hash = vector::empty<u8>();
        let next_execution_hash = vector::empty<u8>();
        execution_hash.push_back(1);
        next_execution_hash.push_back(10);

        voting::resolve_proposal_v2<GovernanceProposal>(@aptos_framework, 0, next_execution_hash);

        if (next_execution_hash.length() == 0) {
            remove_approved_hash(0);
        } else {
            add_approved_script_hash(0)
        };

        let approved_hashes = borrow_global<ApprovedExecutionHashes>(@aptos_framework).hashes;
        assert!(*approved_hashes.borrow(&0) == vector[10u8, ], 1);
    }

    #[test_only]
    public fun initialize_for_test(
        aptos_framework: &signer,
        min_voting_threshold: u128,
        required_proposer_stake: u64,
        voting_duration_secs: u64,
    ) {
        initialize(aptos_framework, min_voting_threshold, required_proposer_stake, voting_duration_secs);
    }

    #[verify_only]
    public fun initialize_for_verification(
        aptos_framework: &signer,
        min_voting_threshold: u128,
        required_proposer_stake: u64,
        voting_duration_secs: u64,
    ) {
        initialize(aptos_framework, min_voting_threshold, required_proposer_stake, voting_duration_secs);
    }
}
