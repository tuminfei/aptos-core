import api from './api';

export async function sampleHistoryNow() {
  const { data } = await api.post('/history/sample');
  return data;
}

export async function getChainHistory(limit = 50, offset = 0) {
  const { data } = await api.get('/history/chain', { params: { limit, offset } });
  return data;
}

export async function getUserSnapshotHistory(address: string, limit = 50, offset = 0) {
  const { data } = await api.get(`/history/users/${address}`, { params: { limit, offset } });
  return data;
}

export async function getUserPowerPeriodHistory(address: string, limit = 50, offset = 0) {
  const { data } = await api.get(`/history/users/${address}/power-periods`, { params: { limit, offset } });
  return data;
}

export async function getValidatorSnapshotHistory(address: string, limit = 50, offset = 0) {
  const { data } = await api.get(`/history/validators/${address}`, { params: { limit, offset } });
  return data;
}

export async function sampleConsensusValidatorPowerNow() {
  const { data } = await api.post('/history/consensus-validator-power/sample');
  return data;
}

export async function getConsensusValidatorPowerHistory(
  limit = 50,
  offset = 0,
  includeValidators = false,
  epochRange?: { start_epoch: number; end_epoch: number },
) {
  const { data } = await api.get('/history/consensus-validator-power', {
    params: { limit, offset, include_validators: includeValidators, ...epochRange },
  });
  return data;
}

export async function getConsensusValidatorPowerEpoch(epoch: number) {
  const { data } = await api.get(`/history/consensus-validator-power/${epoch}`);
  return data;
}
