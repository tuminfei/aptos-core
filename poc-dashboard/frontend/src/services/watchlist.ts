import api from './api';

export async function getWatchlist(kind?: string) {
  const { data } = await api.get('/watchlist', { params: { kind } });
  return data;
}

export async function addToWatchlist(params: { kind: string; address: string; label?: string }) {
  const { data } = await api.post('/watchlist', params);
  return data;
}

export async function updateWatchlistLabel(kind: string, address: string, label: string) {
  const { data } = await api.put(`/watchlist/${kind}/${address}/label`, { label });
  return data;
}

export async function generateAccount(params: { kind: 'user' | 'validator' | 'dapp'; label?: string }) {
  const { data } = await api.post('/watchlist/generate-account', params);
  return data;
}

export async function removeFromWatchlist(kind: string, address: string) {
  const { data } = await api.delete(`/watchlist/${kind}/${address}`);
  return data;
}

export async function getWatchedUsers() {
  const { data } = await api.get('/watchlist/users');
  return data;
}

export async function getWatchedValidators() {
  const { data } = await api.get('/watchlist/validators');
  return data;
}

export async function getAddressBook() {
  const { data } = await api.get('/address-book');
  return data;
}
