export const VALIDATOR_STATUS: Record<number, string> = {
  1: 'pending_active',
  2: 'active',
  3: 'pending_inactive',
  4: 'inactive',
};

export const VALIDATOR_STATUS_LABEL: Record<string, string> = {
  pending_active: '待加入',
  active: '活跃',
  pending_inactive: '待退出',
  inactive: '未激活',
};

export const VALIDATOR_STATUS_COLOR: Record<string, string> = {
  active: 'green',
  pending_active: 'gold',
  pending_inactive: 'orange',
  inactive: 'default',
};

export const APP_STATE_LABEL: Record<number, string> = {
  1: '运行中',
  2: '已暂停',
  3: '已停止',
};

export const APP_STATE_COLOR: Record<number, string> = {
  1: 'green',
  2: 'orange',
  3: 'red',
};

export const POC_STATUS_LABEL: Record<number, string> = {
  1: '已注册',
  2: '白名单',
  3: '已暂停',
};

export const POC_STATUS_COLOR: Record<number, string> = {
  1: 'default',
  2: 'green',
  3: 'red',
};

export const ACTION_LABELS: Record<string, string> = {
  stage_power: '设置算力',
  stage_batch_power: '批量设置算力',
  set_power_period: '修改算力周期',
  power_writeback_stage_batch: '自动算力上链',
  force_end_epoch: '强制结束Epoch',
  mint_topo: '铸造TOPO',
  register_validator: '注册验证者',
  deposit: '保证金',
  withdraw: '提取保证金',
  delegate: '委托',
  undelegate: '取消委托',
  join_validator_set: '加入验证者集合',
  leave_validator_set: '退出验证者集合',
  whitelist_app: 'DApp白名单',
  suspend_app: '暂停DApp',
  set_app_weight: '设置DApp权重',
  proxy_stake: '代理质押',
  prepare_join: '添加验证者',
};

export const OCTAS_PER_TOPO = 1e8;
export const MIN_VALIDATOR_STAKE_OCTAS = 1_000_000_000;
export const DEFAULT_VALIDATOR_STAKE_OCTAS = MIN_VALIDATOR_STAKE_OCTAS * 10;
export const DEFAULT_USER_STAKE_OCTAS = MIN_VALIDATOR_STAKE_OCTAS * 5;
