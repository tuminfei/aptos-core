import { useCallback, useRef } from 'react';
import { useWebSocketEvents } from './useWebSocket';

type EventFilter = (data: Record<string, unknown>) => boolean;

export function useEventRefresh(
  eventTypes: string[],
  refresh: () => void | Promise<void>,
  filter?: EventFilter,
) {
  const refreshRef = useRef(refresh);
  const filterRef = useRef(filter);
  const runningRef = useRef(false);
  const pendingRef = useRef(false);
  refreshRef.current = refresh;
  filterRef.current = filter;

  const onEvent = useCallback(async (data: Record<string, unknown>) => {
    if (filterRef.current && !filterRef.current(data)) {
      return;
    }
    if (runningRef.current) {
      pendingRef.current = true;
      return;
    }
    runningRef.current = true;
    try {
      do {
        pendingRef.current = false;
        await refreshRef.current();
      } while (pendingRef.current);
    } finally {
      runningRef.current = false;
    }
  }, []);

  useWebSocketEvents(eventTypes, onEvent);
}
