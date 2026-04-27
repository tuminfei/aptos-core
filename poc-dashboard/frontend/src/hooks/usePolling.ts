import { useState, useEffect, useCallback, useRef } from 'react';

export function usePolling<T>(
  fetchFn: () => Promise<T>,
  intervalMs: number = 10000,
  deps: unknown[] = [],
) {
  const [data, setData] = useState<T | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<Error | null>(null);
  const mountedRef = useRef(true);
  const dataRef = useRef<T | null>(null);

  const refresh = useCallback(async () => {
    try {
      if (dataRef.current === null) {
        setLoading(true);
      }
      const result = await fetchFn();
      if (mountedRef.current) {
        dataRef.current = result;
        setData(result);
        setError(null);
      }
    } catch (e) {
      if (mountedRef.current) setError(e as Error);
    } finally {
      if (mountedRef.current) setLoading(false);
    }
  }, [fetchFn, ...deps]);

  useEffect(() => {
    mountedRef.current = true;
    dataRef.current = null;
    setData(null);
    setError(null);
    setLoading(true);
    refresh();
    if (intervalMs <= 0) {
      return () => {
        mountedRef.current = false;
      };
    }
    const timer = setInterval(refresh, intervalMs);
    return () => {
      mountedRef.current = false;
      clearInterval(timer);
    };
  }, [refresh, intervalMs]);

  return { data, loading, error, refresh };
}
