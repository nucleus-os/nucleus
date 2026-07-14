import React, { useContext } from 'react';

export type WindowContextValue = {
  windowId: number | null;
};

const WindowContext = React.createContext<WindowContextValue>({ windowId: null });

export function WindowProvider({
  windowId,
  children,
}: {
  windowId: number | null;
  children: React.ReactNode;
}) {
  return (
    <WindowContext.Provider value={{ windowId }}>{children}</WindowContext.Provider>
  );
}

export function useWindowContext(): WindowContextValue {
  return useContext(WindowContext);
}

export function useCurrentWindowId(): number | null {
  return useContext(WindowContext).windowId;
}
