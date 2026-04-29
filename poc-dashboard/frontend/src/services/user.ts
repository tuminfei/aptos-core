import api from './api';

export async function getUser(address: string) {
  const { data } = await api.get(`/users/${address}`);
  return data;
}

export async function getUserContributionEvents(address: string, limit = 50, offset = 0) {
  const { data, status } = await api.get('/contributions', {
    params: { contributor: address, limit, offset },
    validateStatus: (status) => (status >= 200 && status < 300) || status === 404,
  });
  if (status === 404) {
    return { total: 0, limit, offset, total_equity_amount: 0, events: [] };
  }
  return data;
}
