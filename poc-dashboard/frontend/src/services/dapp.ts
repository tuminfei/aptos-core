import api from './api';

export async function getDApps() {
  const { data } = await api.get('/dapps');
  return data;
}

export async function getDApp(admin: string) {
  const { data } = await api.get(`/dapps/${admin}`);
  return data;
}

export async function whitelistApp(params: { app_admin: string }) {
  const { data } = await api.post('/dapps/whitelist', params);
  return data;
}

export async function suspendApp(params: { app_admin: string }) {
  const { data } = await api.post('/dapps/suspend', params);
  return data;
}

export async function setWeight(params: { app_admin: string; weight_pbs: number }) {
  const { data } = await api.post('/dapps/set-weight', params);
  return data;
}
