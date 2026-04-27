import { useEffect, useRef, useState, useCallback } from 'react';

interface WSMessage {
  type: string;
  data: Record<string, unknown>;
}

type Listener = (data: Record<string, unknown>) => void;

let sharedWs: WebSocket | null = null;
let sharedUrl = '';
let retryCount = 0;
let reconnectTimer: number | null = null;
const statusListeners = new Set<(connected: boolean) => void>();
const messageListeners = new Set<(message: WSMessage) => void>();
const typeListeners = new Map<string, Set<Listener>>();

function notifyStatus(connected: boolean) {
  statusListeners.forEach((fn) => fn(connected));
}

function notifyMessage(msg: WSMessage) {
  messageListeners.forEach((fn) => fn(msg));
  typeListeners.get(msg.type)?.forEach((fn) => fn(msg.data));
}

function subscribeType(type: string, callback: Listener) {
  if (!typeListeners.has(type)) {
    typeListeners.set(type, new Set());
  }
  typeListeners.get(type)!.add(callback);
  return () => {
    typeListeners.get(type)?.delete(callback);
  };
}

function connectShared(url: string) {
  if (sharedWs && (sharedWs.readyState === WebSocket.OPEN || sharedWs.readyState === WebSocket.CONNECTING) && sharedUrl === url) {
    return;
  }

  sharedUrl = url;
  sharedWs = new WebSocket(url);

  sharedWs.onopen = () => {
    retryCount = 0;
    notifyStatus(true);
  };

  sharedWs.onmessage = (e) => {
    try {
      notifyMessage(JSON.parse(e.data));
    } catch {}
  };

  sharedWs.onclose = () => {
    notifyStatus(false);
    const delay = Math.min(1000 * 2 ** retryCount, 30000);
    retryCount++;
    if (reconnectTimer !== null) {
      window.clearTimeout(reconnectTimer);
    }
    reconnectTimer = window.setTimeout(() => connectShared(url), delay);
  };

  sharedWs.onerror = () => sharedWs?.close();
}

export function useWebSocket(url?: string) {
  const [connected, setConnected] = useState(false);
  const [lastMessage, setLastMessage] = useState<WSMessage | null>(null);

  useEffect(() => {
    const wsUrl = url || `${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/ws/events`;
    statusListeners.add(setConnected);
    messageListeners.add(setLastMessage);
    connectShared(wsUrl);
    setConnected(sharedWs?.readyState === WebSocket.OPEN);
    return () => {
      statusListeners.delete(setConnected);
      messageListeners.delete(setLastMessage);
    };
  }, [url]);

  const subscribe = useCallback((type: string, callback: (data: Record<string, unknown>) => void) => {
    return subscribeType(type, callback);
  }, []);

  return { connected, lastMessage, subscribe };
}

export function useWebSocketEvent(type: string, callback: Listener) {
  const callbackRef = useRef(callback);
  callbackRef.current = callback;

  useEffect(() => {
    const wsUrl = `${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/ws/events`;
    connectShared(wsUrl);
    const handler: Listener = (data) => callbackRef.current(data);
    return subscribeType(type, handler);
  }, [type]);
}

export function useWebSocketEvents(types: string[], callback: Listener) {
  const callbackRef = useRef(callback);
  callbackRef.current = callback;
  const typesKey = types.join('\u0000');

  useEffect(() => {
    const wsUrl = `${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/ws/events`;
    connectShared(wsUrl);
    const handler: Listener = (data) => callbackRef.current(data);
    const cleanups = types.map((type) => subscribeType(type, handler));
    return () => cleanups.forEach((cleanup) => cleanup());
  }, [typesKey]);
}
