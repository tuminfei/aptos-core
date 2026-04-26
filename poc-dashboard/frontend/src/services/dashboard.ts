import api from './api';

export async function getOverview() {
  const { data } = await api.get('/dashboard/overview');
  return data;
}
