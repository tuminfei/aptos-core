import api from './api';

const POC_ADMIN_TIMEOUT_MS = 300000;

export async function getDApps() {
  const { data } = await api.get('/dapps');
  return data;
}

export async function getDApp(admin: string) {
  const { data } = await api.get(`/dapps/${admin}`);
  return data;
}

export async function whitelistApp(params: { app_admin: string }) {
  const { data } = await api.post('/dapps/whitelist', params, { timeout: POC_ADMIN_TIMEOUT_MS });
  return data;
}

export async function registerApp(params: {
  app_admin: string;
  app_address: string;
  equity_token_address: string;
  custody_address: string;
  metadata_uri: string;
  max_gas?: number;
  gas_unit_price?: number;
}) {
  const { data } = await api.post('/dapps/register', params);
  return data;
}

export async function pauseApp(params: { app_admin: string; max_gas?: number; gas_unit_price?: number }) {
  const { data } = await api.post('/dapps/pause', params);
  return data;
}

export async function resumeApp(params: { app_admin: string; max_gas?: number; gas_unit_price?: number }) {
  const { data } = await api.post('/dapps/resume', params);
  return data;
}

export async function stopApp(params: { app_admin: string; max_gas?: number; gas_unit_price?: number }) {
  const { data } = await api.post('/dapps/stop', params);
  return data;
}

export async function updateAppAddress(params: { app_admin: string; new_address: string; max_gas?: number; gas_unit_price?: number }) {
  const { data } = await api.post('/dapps/update-app-address', params);
  return data;
}

export async function updateCustodyAddress(params: { app_admin: string; new_address: string; max_gas?: number; gas_unit_price?: number }) {
  const { data } = await api.post('/dapps/update-custody-address', params);
  return data;
}

export async function updateEquityTokenAddress(params: { app_admin: string; new_address: string; max_gas?: number; gas_unit_price?: number }) {
  const { data } = await api.post('/dapps/update-equity-token-address', params);
  return data;
}

export async function suspendApp(params: { app_admin: string }) {
  const { data } = await api.post('/dapps/suspend', params, { timeout: POC_ADMIN_TIMEOUT_MS });
  return data;
}

export async function setPocStatus(params: { app_admin: string; status: number; max_gas?: number; gas_unit_price?: number }) {
  const { data } = await api.post('/dapps/set-poc-status', params, { timeout: POC_ADMIN_TIMEOUT_MS });
  return data;
}

export async function setWeight(params: { app_admin: string; weight_pbs: number; max_gas?: number; gas_unit_price?: number }) {
  const { data } = await api.post('/dapps/set-weight', params, { timeout: POC_ADMIN_TIMEOUT_MS });
  return data;
}

export async function createDemoDApp(params: {
  label: string;
  metadata_uri: string;
  initial_supply: number;
  price_per_equity: number;
  auto_whitelist: boolean;
  gas_mint_octas: number;
  max_gas?: number;
  gas_unit_price?: number;
}) {
  const { data } = await api.post('/dapps/demo/create', params, { timeout: 300000 });
  return data;
}

export async function mintDemoEquity(params: {
  app_admin: string;
  amount: number;
  module_address?: string;
  max_gas?: number;
  gas_unit_price?: number;
}) {
  const { data } = await api.post('/dapps/demo/mint-equity', params);
  return data;
}

export async function buyDemoEquity(params: {
  app_admin: string;
  equity_amount: number;
  buyer_address?: string;
  buyer_label?: string;
  module_address?: string;
  auto_create_buyer?: boolean;
  mint_octas?: number;
  max_gas?: number;
  gas_unit_price?: number;
}) {
  const { data } = await api.post('/dapps/demo/buy-equity', params);
  return data;
}

export async function startDemoAutoTrade(params: {
  app_admin: string;
  module_address?: string;
  interval_secs: number;
  tx_per_tick: number;
  amount_min: number;
  amount_max: number;
  max_runs: number;
  buyer_addresses: string[];
  auto_create_buyers: number;
  mint_octas: number;
  max_gas?: number;
  gas_unit_price?: number;
}) {
  const { data } = await api.post('/dapps/demo/auto-trade/start', params);
  return data;
}

export async function stopDemoAutoTrade(params: { app_admin: string }) {
  const { data } = await api.post('/dapps/demo/auto-trade/stop', params);
  return data;
}

export async function getDemoAutoTradeStatus(app_admin?: string) {
  const { data } = await api.get('/dapps/demo/auto-trade/status', { params: { app_admin } });
  return data;
}

export async function getContributionEvents(params: {
  contributor?: string;
  app_admin?: string;
  limit?: number;
  offset?: number;
}) {
  const { data } = await api.get('/contributions', { params });
  return data;
}
