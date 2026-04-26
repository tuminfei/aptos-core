import axios from 'axios';
import { notification } from 'antd';

const api = axios.create({
  baseURL: '/api/v1',
  timeout: 30000,
});

api.interceptors.response.use(
  (res) => res,
  (err) => {
    const msg = err.response?.data?.message || err.message || '请求失败';
    notification.error({ message: '请求错误', description: msg });
    return Promise.reject(err);
  },
);

export default api;
