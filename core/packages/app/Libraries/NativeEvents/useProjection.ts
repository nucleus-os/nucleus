import { useState } from 'react';
import { useNativeEventListener } from './useNativeEventListener';

interface ProjectionModule<TPayload> {
  addListener(eventName: string): void;
  removeListeners(count: number): void;
  [signalName: string]: ((callback: (payload: TPayload) => void) => () => void) | unknown;
}

/**
 * Generic hook for consuming EntityProjection snapshots from native.
 * Automatically parses JSON and maintains snapshot state.
 *
 * @param module - The TurboModule that emits projection events
 * @param signalName - The signal name (e.g., 'threadSnapshot')
 * @param signalFn - The signal function from the module
 */
export function useProjection<TSnapshot, TPayload extends { snapshot: string }>(
  module: ProjectionModule<TPayload>,
  signalName: string,
  signalFn: (callback: (payload: TPayload) => void) => () => void
): TSnapshot | null {
  const [snapshot, setSnapshot] = useState<TSnapshot | null>(null);

  useNativeEventListener(module, signalName, signalFn, (payload) => {
    const parsed = JSON.parse(payload.snapshot) as TSnapshot;
    setSnapshot(parsed);
  });

  return snapshot;
}
