import api from './api';

export async function deposit(params: { user_address: string; amount: number }) {
  const { data } = await api.post('/staking/deposit', params);
  return data;
}

export async function delegate(params: { user_address: string; validator_address: string }) {
  const { data } = await api.post('/staking/delegate', params);
  return data;
}

export async function undelegate(params: { user_address: string }) {
  const { data } = await api.post('/staking/undelegate', params);
  return data;
}

export async function withdraw(params: { user_address: string }) {
  const { data } = await api.post('/staking/withdraw', params);
  return data;
}

export async function proxyStake(params: {
  target_user: string;
  mint_amount: number;
  set_power: number;
  deposit_amount: number;
  delegate_to: string;
  force_epoch: boolean;
}) {
  const { data } = await api.post('/staking/proxy', params);
  return data;
}
