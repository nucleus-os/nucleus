/**
 * React hook for creating and managing a window
 *
 * @example
 * ```tsx
 * function MyComponent() {
 *   const windowId = useWindow(800, 600);
 *
 *   if (!windowId) {
 *     return <Text>Creating window...</Text>;
 *   }
 *
 *   return <Text>Window created: {windowId}</Text>;
 * }
 * ```
 */
import { useState, useEffect, useRef } from 'react';
import WindowManager, {
  WindowDecorations,
  WindowTitlebarOptions,
} from './WindowManager';

export interface UseWindowOptions {
  width?: number;
  height?: number;
  scale?: number;
  fontScale?: number;
  titlebar?: WindowTitlebarOptions;
  windowDecorations?: WindowDecorations;
  /** If true, don't create window automatically */
  manual?: boolean;
}

export interface UseWindowResult {
  windowId: number | null;
  isCreating: boolean;
  error: Error | null;
  createWindow: () => Promise<void>;
}

/**
 * Hook to create and manage a window
 */
export function useWindow(options: UseWindowOptions = {}): UseWindowResult {
  const {
    width = 800,
    height = 600,
    scale = 1.0,
    fontScale = 1.0,
    titlebar,
    windowDecorations,
    manual = false,
  } = options;

  const [windowId, setWindowId] = useState<number | null>(null);
  const [isCreating, setIsCreating] = useState(false);
  const [error, setError] = useState<Error | null>(null);
  const isMountedRef = useRef(true);

  const createWindow = async () => {
    if (!WindowManager) {
      const err = new Error('WindowManager TurboModule not available');
      setError(err);
      throw err;
    }

    setIsCreating(true);
    setError(null);

    try {
      const winId = await WindowManager.createWindow(
        width,
        height,
        scale,
        fontScale,
        titlebar || windowDecorations
          ? { titlebar, windowDecorations }
          : undefined
      );

      if (isMountedRef.current) {
        setWindowId(winId);
        setIsCreating(false);
      }
    } catch (err) {
      if (isMountedRef.current) {
        const error = err instanceof Error ? err : new Error(String(err));
        setError(error);
        setIsCreating(false);
      }
      throw err;
    }
  };

  useEffect(() => {
    isMountedRef.current = true;

    if (!manual) {
      createWindow();
    }

    return () => {
      isMountedRef.current = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []); // Empty deps - only create once

  return { windowId, isCreating, error, createWindow };
}
