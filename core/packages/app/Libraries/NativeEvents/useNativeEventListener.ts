import { useEffect, useRef } from 'react';

type SignalFunction<T> = (callback: (event: T) => void) => () => void;

interface EventModule<TEvent> {
  addListener(eventName: string): void;
  removeListeners(count: number): void;
  [key: string]: SignalFunction<TEvent> | unknown;
}

/**
 * Generic hook for subscribing to native module events.
 * Works with any TurboModule that follows the addListener/removeListeners pattern.
 */
export function useNativeEventListener<TModule extends EventModule<unknown>, TEvent>(
  module: TModule,
  eventName: keyof TModule,
  signalFn: SignalFunction<TEvent>,
  callback: (event: TEvent) => void
): void {
  const callbackRef = useRef(callback);
  callbackRef.current = callback;

  useEffect(() => {
    module.addListener(eventName as string);
    const unsubscribe = signalFn((event) => {
      callbackRef.current(event);
    });
    return () => {
      unsubscribe();
      module.removeListeners(1);
    };
  }, [module, eventName, signalFn]);
}
