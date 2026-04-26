import api from './api';

export async function getUser(address: string) {
  const { data } = await api.get(`/users/${address}`);
  return data;
}

export async function getPowerHistory(address: string, periods = 10) {
  const { data } = await api.get(`/users/${address}/power-history`, { params: { periods } });
  return data;
}
