import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import path from 'path';

export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: {
      '@': path.resolve(__dirname, 'src'),
    },
  },
  server: {
    port: 35173,
    proxy: {
      '/api/v1': {
        target: 'http://127.0.0.1:38000',
        changeOrigin: true,
      },
      '/ws': {
        target: 'ws://127.0.0.1:38000',
        ws: true,
      },
    },
  },
});
