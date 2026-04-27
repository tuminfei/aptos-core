import api from './api';

export async function getValidators(status = 'all') {
  const { data } = await api.get('/validators', { params: { status } });
  return data;
}

export async function getValidator(address: string) {
  const { data } = await api.get(`/validators/${address}`);
  return data;
}

export async function stagePower(params: { user_address: string; power: number }) {
  const { data } = await api.post('/validators/stage-power', params);
  return data;
}

export async function registerValidator(params: { validator_address: string; commission_bps: number }) {
  const { data } = await api.post('/validators/register', params);
  return data;
}

export async function joinValidatorSet(params: { operator_address: string; pool_address: string }) {
  const { data } = await api.post('/validators/join', params);
  return data;
}

export async function leaveValidatorSet(params: { operator_address: string; pool_address: string }) {
  const { data } = await api.post('/validators/leave', params);
  return data;
}

export async function prepareJoin(params: {
  validator_address?: string;
  label?: string;
  power: number;
  set_power_period: number;
  force_epochs_before_delegate: number;
  force_epochs_after_join?: number;
  mint_amount: number;
  deposit_amount: number;
  commission_bps: number;
}) {
  const { data } = await api.post('/validators/prepare-join', params);
  return data;
}
