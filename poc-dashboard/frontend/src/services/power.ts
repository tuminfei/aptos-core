import api from './api';

export async function getPowerOverview() {
  const { data } = await api.get('/power/overview');
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

export async function setPeriod(params: { power_period_in_epochs: number }) {
  const { data } = await api.post('/power/set-period', params);
  return data;
}
