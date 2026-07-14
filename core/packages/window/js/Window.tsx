/**
 * Window component - renders a React component in a separate native window
 *
 * Each window is an independent React surface with its own component tree.
 * Use `component` + `componentProps` to specify what renders in the window.
 *
 * @example
 * ```tsx
 * function SettingsWindow({ theme }: { theme: string }) {
 *   return (
 *     <View style={{ flex: 1, backgroundColor: theme === 'dark' ? '#000' : '#fff' }}>
 *       <Text>Settings</Text>
 *     </View>
 *   );
 * }
 *
 * function App() {
 *   const [showSettings, setShowSettings] = useState(false);
 *
 *   return (
 *     <View>
 *       <Button onPress={() => setShowSettings(true)} title="Open Settings" />
 *       {showSettings && (
 *         <Window
 *           width={600}
 *           height={400}
 *           component={SettingsWindow}
 *           componentProps={{ theme: 'dark' }}
 *           onWindowClosed={() => setShowSettings(false)}
 *         />
 *       )}
 *     </View>
 *   );
 * }
 * ```
 */
import React, { useEffect, useState, useRef, ComponentType } from 'react';
import { AppRegistry, DeviceEventEmitter, View, Text, StyleSheet } from 'react-native';
import WindowManager, { WindowDecorations, WindowTitlebarOptions } from './WindowManager';
import { WindowProvider } from './WindowContext';

/**
 * Props that can be passed to window content components.
 * Must be serializable (no functions, React elements, or class instances).
 */
export type SerializableValue =
  | string
  | number
  | boolean
  | null
  | undefined
  | { [key: string]: SerializableValue }
  | SerializableValue[];

export type SerializableProps = Record<string, SerializableValue>;

export interface WindowProps<P extends SerializableProps = SerializableProps> {
  /** Window width in logical pixels */
  width?: number;
  /** Window height in logical pixels */
  height?: number;
  /** Display scale factor */
  scale?: number;
  /** Font scale multiplier */
  fontScale?: number;
  /** Window title (reserved for future use) */
  title?: string;
  /** Optional titlebar options for custom chrome. */
  titlebar?: WindowTitlebarOptions;
  /** Request client- or server-side window decorations. */
  windowDecorations?: WindowDecorations;
  /**
   * Component to render in the window.
   * This component will be instantiated fresh in the new window's React tree.
   */
  component: ComponentType<P>;
  /**
   * Props to pass to the component.
   * Must be serializable (no functions, React elements, symbols, etc.).
   */
  componentProps?: P;
  /**
   * Optional overlay component to render above the window content.
   * Useful for context menus, tooltips, etc.
   */
  overlay?: ComponentType<{}>;
  /** Callback when window and surface are successfully created */
  onWindowCreated?: (windowId: number, surfaceId: number) => void;
  /** Callback when window creation fails */
  onError?: (error: Error) => void;
  /** Callback when window is closed (either programmatically or by user) */
  onWindowClosed?: () => void;
}

// Cache of registered module names to avoid re-registering
const registeredModules = new Map<ComponentType<any>, string>();
let moduleCounter = 0;

/**
 * Get or create a module name for a component.
 * Reuses the same name for the same component reference.
 */
function getModuleName(component: ComponentType<any>): string {
  let moduleName = registeredModules.get(component);
  if (!moduleName) {
    moduleName = `Window_${++moduleCounter}`;
    registeredModules.set(component, moduleName);
  }
  return moduleName;
}

/**
 * Window component that renders a React component in a separate native window.
 *
 * Unlike portals, each window has its own independent React tree. The `component`
 * prop specifies which component to render, and `componentProps` provides the
 * initial props (which must be serializable).
 *
 * For shared state across windows, use a state management library like Zustand,
 * Redux, or React Context with a global provider.
 */
export function Window<P extends SerializableProps = SerializableProps>({
  width = 800,
  height = 600,
  scale = 1.0,
  fontScale = 1.0,
  title,
  titlebar,
  windowDecorations,
  component: Component,
  componentProps = {} as P,
  overlay: Overlay,
  onWindowCreated,
  onError,
  onWindowClosed,
}: WindowProps<P>) {
  const [error, setError] = useState<Error | null>(null);
  const isMountedRef = useRef(true);
  const windowIdRef = useRef<number | null>(null);
  const surfaceIdRef = useRef<number | null>(null);
  const moduleNameRef = useRef<string | null>(null);
  const componentPropsRef = useRef<P>(componentProps);
  const onWindowCreatedRef = useRef(onWindowCreated);
  const onErrorRef = useRef(onError);
  const onWindowClosedRef = useRef(onWindowClosed);
  // Track if window was closed natively to avoid double-calling onWindowClosed
  const closedNativelyRef = useRef(false);

  useEffect(() => {
    componentPropsRef.current = componentProps;
  }, [componentProps]);

  useEffect(() => {
    onWindowCreatedRef.current = onWindowCreated;
  }, [onWindowCreated]);

  useEffect(() => {
    onErrorRef.current = onError;
  }, [onError]);

  useEffect(() => {
    onWindowClosedRef.current = onWindowClosed;
  }, [onWindowClosed]);

  // Subscribe to native window close events (e.g., macOS traffic light close button)
  useEffect(() => {
    const subscription = DeviceEventEmitter.addListener(
      'windowNativeClosed',
      (event: { windowId: number }) => {
        // Only handle events for our window
        if (windowIdRef.current !== null && event.windowId === windowIdRef.current) {
          if (__DEV__) {
            console.info('[Window] Native window closed', { windowId: event.windowId });
          }
          closedNativelyRef.current = true;
          windowIdRef.current = null;
          surfaceIdRef.current = null;
          onWindowClosedRef.current?.();
        }
      },
    );

    return () => {
      subscription.remove();
    };
  }, []);

  useEffect(() => {
    let cancelled = false;
    isMountedRef.current = true;
    closedNativelyRef.current = false;

    // Get or create module name for this component
    const moduleName = getModuleName(Component);
    moduleNameRef.current = moduleName;

    // Register the component with AppRegistry if not already registered
    // The component receives initialProps from the native side
    if (!AppRegistry.getRunnable(moduleName)) {
      AppRegistry.registerComponent(moduleName, () => {
        return function WindowRoot(props: P & { __nucleusWindowId?: number }) {
          const { __nucleusWindowId, ...rest } = props;
          const resolvedWindowId = typeof __nucleusWindowId === 'number' ? __nucleusWindowId : null;
          return (
            <WindowProvider windowId={resolvedWindowId}>
              <>
                <Component {...(rest as P)} />
                {Overlay && <Overlay />}
              </>
            </WindowProvider>
          );
        };
      });
    }

    async function createWindowAndSurface() {
      if (!WindowManager) {
        const err = new Error('WindowManager TurboModule not available');
        setError(err);
        onErrorRef.current?.(err);
        return;
      }

      try {
        // Create the native window
        const windowId = await WindowManager.createWindow(
          width,
          height,
          scale,
          fontScale,
          titlebar || windowDecorations ? { titlebar, windowDecorations } : undefined,
        );
        if (cancelled || !isMountedRef.current) {
          WindowManager.closeWindow(windowId);
          return;
        }
        windowIdRef.current = windowId;
        if (__DEV__) {
          console.info('[Window] createWindow resolved', {
            windowId,
            width,
            height,
            scale,
            fontScale,
          });
        }

        // Create the React surface with initial props
        if (__DEV__) {
          console.info('[Window] createSurface calling', {
            windowId,
            moduleName,
            initialProps: componentPropsRef.current,
          });
        }
        const surfaceId = await WindowManager.createSurface(windowId, moduleName, {
          ...(componentPropsRef.current as Record<string, any>),
          // Used by WindowProvider to scope window control helpers.
          __nucleusWindowId: windowId,
        });
        if (cancelled || !isMountedRef.current) {
          WindowManager.closeWindow(windowId);
          return;
        }
        surfaceIdRef.current = surfaceId;
        if (__DEV__) {
          console.info('[Window] createSurface resolved', {
            windowId,
            surfaceId,
            moduleName,
          });
        }

        if (isMountedRef.current) {
          setError(null);
          onWindowCreatedRef.current?.(windowId, surfaceId);
        }
      } catch (err) {
        console.error('[Window] Failed to create window:', err);
        const error = err instanceof Error ? err : new Error(String(err));
        if (isMountedRef.current) {
          setError(error);
          onErrorRef.current?.(error);
        }
      }
    }

    createWindowAndSurface();

    return () => {
      cancelled = true;
      isMountedRef.current = false;
      // Close the window on unmount (unless already closed natively)
      if (windowIdRef.current !== null && WindowManager) {
        WindowManager.closeWindow(windowIdRef.current);
        windowIdRef.current = null;
        surfaceIdRef.current = null;
        // Only call onWindowClosed if window wasn't already closed natively
        if (!closedNativelyRef.current) {
          onWindowClosedRef.current?.();
        }
      }
    };
  }, [Component, Overlay, fontScale, height, scale, titlebar, windowDecorations, width]); // Recreate when creation inputs change

  // Render error state in main window if creation failed
  if (error) {
    return (
      <View style={styles.errorContainer}>
        <Text style={styles.errorText}>Window Error: {error.message}</Text>
      </View>
    );
  }

  // Window renders nothing in the main tree - content is in the separate window
  return null;
}

const styles = StyleSheet.create({
  errorContainer: {
    padding: 16,
    backgroundColor: '#ffebee',
    borderRadius: 8,
    margin: 8,
  },
  errorText: {
    color: '#c62828',
    fontSize: 14,
  },
});
