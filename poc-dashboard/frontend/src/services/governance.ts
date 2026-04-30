import api from './api';

const GOVERNANCE_ADMIN_TIMEOUT_MS = 300000;

export async function forceEndEpoch() {
  const { data } = await api.post('/governance/force-end-epoch');
  return data;
}

export async function getGovernanceConfig() {
  const { data } = await api.get('/governance/config');
  return data;
}

export async function updateGovernanceConfig(params: {
  min_voting_threshold: number;
  required_proposer_stake: number;
  voting_duration_secs: number;
  max_gas?: number;
  gas_unit_price?: number;
}) {
  const { data } = await api.post('/governance/update-config', params, { timeout: GOVERNANCE_ADMIN_TIMEOUT_MS });
  return data;
}

export async function setOctasPerPower(params: { octas_per_power: number; max_gas?: number; gas_unit_price?: number }) {
  const { data } = await api.post('/governance/set-octas-per-power', params, { timeout: GOVERNANCE_ADMIN_TIMEOUT_MS });
  return data;
}

export async function setMinActivePower(params: { min_active_power: number; max_gas?: number; gas_unit_price?: number }) {
  const { data } = await api.post('/governance/set-min-active-power', params, { timeout: GOVERNANCE_ADMIN_TIMEOUT_MS });
  return data;
}

export async function setForceExitPowerBps(params: { force_exit_power_bps: number; max_gas?: number; gas_unit_price?: number }) {
  const { data } = await api.post('/governance/set-force-exit-power-bps', params, { timeout: GOVERNANCE_ADMIN_TIMEOUT_MS });
  return data;
}

export async function setCooldownSecs(params: { cooldown_secs: number; max_gas?: number; gas_unit_price?: number }) {
  const { data } = await api.post('/governance/set-cooldown-secs', params, { timeout: GOVERNANCE_ADMIN_TIMEOUT_MS });
  return data;
}

export async function setEpochInterval(params: { epoch_interval_secs: number; max_gas?: number; gas_unit_price?: number }) {
  const { data } = await api.post('/governance/set-epoch-interval', params, { timeout: GOVERNANCE_ADMIN_TIMEOUT_MS });
  return data;
}

export async function mintTopo(params: { recipient: string; amount: number }) {
  const { data } = await api.post('/topo/mint', params);
  return data;
}

export async function getBalance(address: string) {
  const { data } = await api.get(`/topo/balance/${address}`);
  return data;
}

export async function getChainInfo() {
  const { data } = await api.get('/system/chain-info');
  return data;
}

export async function getFrameworkStatus() {
  const { data } = await api.get('/governance/framework-status');
  return data;
}

export async function upgradeFramework(params?: { max_gas?: number; gas_unit_price?: number }) {
  const { data } = await api.post('/governance/upgrade-framework', params || {}, { timeout: GOVERNANCE_ADMIN_TIMEOUT_MS });
  return data;
}

export async function cleanupStaging(params?: { max_gas?: number; gas_unit_price?: number }) {
  const { data } = await api.post('/governance/cleanup-staging', params || {}, { timeout: GOVERNANCE_ADMIN_TIMEOUT_MS });
  return data;
}
