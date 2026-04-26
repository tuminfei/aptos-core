import api from './api';

export async function forceEndEpoch() {
  const { data } = await api.post('/governance/force-end-epoch');
  return data;
}

export async function getGovernanceConfig() {
  const { data } = await api.get('/governance/config');
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
