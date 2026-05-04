import api from './api';

const POWER_ADMIN_TIMEOUT_MS = 300000;

export async function getPowerOverview() {
  const { data } = await api.get('/power/overview');
  return data;
}

export async function getPowerStore() {
  const { data } = await api.get('/power/store');
  return data;
}

export async function queryPowerStoreUsers(params: { addresses: string[]; target_period?: number }) {
  const { data } = await api.post('/power/store/users', params);
  return data;
}

export async function stageSingle(params: { user_address: string; power: number }) {
  const { data } = await api.post('/power/stage-single', params);
  return data;
}

export async function stageBatch(params: { target_period: number; updates: { address: string; power: number }[] }) {
  const { data } = await api.post('/power/stage-batch', params);
  return data;
}

export async function getPowerWritebackTask() {
  const { data } = await api.get('/power/writeback-task');
  return data;
}

export async function configurePowerWritebackTask(params: {
  enabled: boolean;
  interval_secs: number;
  max_users_per_run: number;
  max_gas?: number;
  gas_unit_price?: number;
}) {
  const { data } = await api.post('/power/writeback-task/config', params);
  return data;
}

export async function runPowerWritebackOnce(params: { force?: boolean } = {}) {
  const { data } = await api.post('/power/writeback-task/run-once', params, { timeout: POWER_ADMIN_TIMEOUT_MS });
  return data;
}

export async function setPeriod(params: { power_period_in_epochs: number }) {
  const { data } = await api.post('/power/set-period', params);
  return data;
}

export async function setRetention(params: { retention_bps_per_period: number; max_gas?: number; gas_unit_price?: number }) {
  const { data } = await api.post('/power/set-retention', params, { timeout: POWER_ADMIN_TIMEOUT_MS });
  return data;
}

export async function setOperator(params: { operator: string; max_gas?: number; gas_unit_price?: number }) {
  const { data } = await api.post('/power/set-operator', params, { timeout: POWER_ADMIN_TIMEOUT_MS });
  return data;
}
