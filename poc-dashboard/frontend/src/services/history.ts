import api from './api';

export async function sampleHistoryNow() {
  const { data } = await api.post('/history/sample');
  return data;
}

export async function getChainHistory(limit = 200, offset = 0) {
  const { data } = await api.get('/history/chain', { params: { limit, offset } });
  return data;
}

export async function getUserSnapshotHistory(address: string, limit = 200, offset = 0) {
  const { data } = await api.get(`/history/users/${address}`, { params: { limit, offset } });
  return data;
}

export async function getValidatorSnapshotHistory(address: string, limit = 200, offset = 0) {
  const { data } = await api.get(`/history/validators/${address}`, { params: { limit, offset } });
  return data;
}
