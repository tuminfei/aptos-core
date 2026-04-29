import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import { getAddressBook } from '../services/watchlist';
import { useWebSocketEvents } from '../hooks/useWebSocket';

type AddressBookEntry = {
  address: string;
  kind?: string;
  name?: string;
  label?: string;
  display_name?: string;
};

type AddressBookContextValue = {
  entries: Record<string, AddressBookEntry>;
  refresh: () => Promise<void>;
  nameOf: (address?: string, fallback?: string) => string;
};

const AddressBookContext = createContext<AddressBookContextValue>({
  entries: {},
  refresh: async () => {},
  nameOf: (_address, fallback = '') => fallback,
});

export function AddressBookProvider({ children }: { children: ReactNode }) {
  const [entries, setEntries] = useState<Record<string, AddressBookEntry>>({});

  const refresh = useCallback(async () => {
    try {
      const data = await getAddressBook();
      setEntries(data.entries || {});
    } catch {
      // Address names are a convenience layer. Keep the page usable if this lookup fails.
    }
  }, []);

  useEffect(() => {
    refresh();
  }, [refresh]);

  useWebSocketEvents(['address_book_changed', 'validator_set_changed'], refresh);

  const value = useMemo<AddressBookContextValue>(() => ({
    entries,
    refresh,
    nameOf: (address?: string, fallback = '') => {
      if (!address) return fallback;
      const entry = entries[address.toLowerCase()];
      return entry?.display_name || entry?.name || entry?.label || fallback;
    },
  }), [entries, refresh]);

  return (
    <AddressBookContext.Provider value={value}>
      {children}
    </AddressBookContext.Provider>
  );
}

export function useAddressBook() {
  return useContext(AddressBookContext);
}
