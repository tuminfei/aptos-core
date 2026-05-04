import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import fs from 'fs';
import path from 'path';

type RawConfig = Record<string, Record<string, string | number | boolean>>;

function stripInlineComment(line: string) {
  let quote: string | null = null;
  for (let i = 0; i < line.length; i += 1) {
    const ch = line[i];
    if ((ch === '"' || ch === "'") && line[i - 1] !== '\\') {
      quote = quote === ch ? null : quote ?? ch;
    }
    if (ch === '#' && quote === null) {
      return line.slice(0, i);
    }
  }
  return line;
}

function parseScalar(value: string): string | number | boolean {
  const trimmed = value.trim();
  if (!trimmed) {
    return '';
  }
  if ((trimmed.startsWith('"') && trimmed.endsWith('"')) || (trimmed.startsWith("'") && trimmed.endsWith("'"))) {
    return trimmed.slice(1, -1);
  }
  if (/^-?\d+$/.test(trimmed)) {
    return Number(trimmed);
  }
  if (trimmed === 'true' || trimmed === 'false') {
    return trimmed === 'true';
  }
  return trimmed;
}

function readDashboardConfig(): RawConfig {
  const configPath = process.env.CONFIG_PATH || path.resolve(__dirname, '../config.yaml');
  if (!fs.existsSync(configPath)) {
    return {};
  }

  const config: RawConfig = {};
  let section = '';
  for (const rawLine of fs.readFileSync(configPath, 'utf-8').split(/\r?\n/)) {
    const line = stripInlineComment(rawLine).trimEnd();
    if (!line.trim()) {
      continue;
    }

    const sectionMatch = /^([A-Za-z0-9_-]+):\s*$/.exec(line);
    if (sectionMatch && !rawLine.startsWith(' ')) {
      section = sectionMatch[1];
      config[section] = config[section] || {};
      continue;
    }

    const keyMatch = /^\s+([A-Za-z0-9_-]+):\s*(.*?)\s*$/.exec(line);
    if (section && keyMatch) {
      config[section][keyMatch[1]] = parseScalar(keyMatch[2]);
    }
  }
  return config;
}

function stringValue(value: unknown, fallback: string) {
  return value === undefined || value === null || value === '' ? fallback : String(value);
}

function numberValue(value: unknown, fallback: number) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function clientHost(host: string) {
  return host === '' || host === '0.0.0.0' || host === '::' ? '127.0.0.1' : host;
}

function wsUrlFromHttpUrl(url: string) {
  if (url.startsWith('https://')) {
    return `wss://${url.slice('https://'.length)}`;
  }
  if (url.startsWith('http://')) {
    return `ws://${url.slice('http://'.length)}`;
  }
  return url;
}

const dashboardConfig = readDashboardConfig();
const backendHost = stringValue(process.env.BACKEND_HOST ?? dashboardConfig.server?.host, '0.0.0.0');
const backendPort = numberValue(process.env.BACKEND_PORT ?? dashboardConfig.server?.port, 38000);
const frontendHost = stringValue(process.env.FRONTEND_HOST ?? dashboardConfig.frontend?.host, '0.0.0.0');
const frontendPort = numberValue(process.env.FRONTEND_PORT ?? dashboardConfig.frontend?.port, 35173);
const backendUrl = stringValue(
  process.env.FRONTEND_BACKEND_URL ?? dashboardConfig.frontend?.backend_url,
  `http://${clientHost(backendHost)}:${backendPort}`,
);
const wsBackendUrl = stringValue(process.env.FRONTEND_WS_BACKEND_URL, wsUrlFromHttpUrl(backendUrl));

export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: {
      '@': path.resolve(__dirname, 'src'),
    },
  },
  server: {
    host: frontendHost,
    port: frontendPort,
    proxy: {
      '/api/v1': {
        target: backendUrl,
        changeOrigin: true,
      },
      '/ws': {
        target: wsBackendUrl,
        ws: true,
      },
    },
  },
});
