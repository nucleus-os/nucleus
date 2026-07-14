/**
 * Window Management API for NUCLEUS
 *
 * Provides multi-window support with both low-level TurboModule access
 * and high-level React components/hooks.
 *
 * @example Low-level API
 * ```tsx
 * import { WindowManager } from '@nucleus-os/window';
 *
 * const windowId = await WindowManager.createWindow(800, 600, 1.0, 1.0);
 * const surfaceId = await WindowManager.createSurface(windowId, 'MyApp', {});
 * ```
 *
 * @example React Hook API
 * ```tsx
 * import { useWindow } from '@nucleus-os/window';
 *
 * function MyComponent() {
 *   const { windowId, isCreating } = useWindow({ width: 800, height: 600 });
 *   return <Text>Window: {windowId}</Text>;
 * }
 * ```
 *
 * @example React Component API
 * ```tsx
 * import { Window } from '@nucleus-os/window';
 *
 * function SettingsWindow({ theme }: { theme: string }) {
 *   return <View><Text>Theme: {theme}</Text></View>;
 * }
 *
 * function App() {
 *   return (
 *     <Window
 *       width={600}
 *       height={400}
 *       component={SettingsWindow}
 *       componentProps={{ theme: 'dark' }}
 *     />
 *   );
 * }
 * ```
 */

export { default as WindowManager } from './WindowManager';
export type {
  WindowManagerSpec,
  WindowCreateOptions,
  WindowDecorations,
  WindowTitlebarOptions,
  TitlebarMetrics,
  TitlebarPlatform,
} from './WindowManager';

export { default as Zoom } from './Zoom';
export { ZOOM_CHANGED_EVENT } from './Zoom';
export type { ZoomChangedEvent, ZoomSpec } from './Zoom';

export { useWindow } from './useWindow';
export type { UseWindowOptions, UseWindowResult } from './useWindow';

export { Window } from './Window';
export type { WindowProps, SerializableProps } from './Window';

export { WindowDragRegion } from './WindowDragRegion';
export type { WindowDragRegionProps } from './WindowDragRegion';

export { Titlebar } from './Titlebar';
export type { TitlebarProps } from './Titlebar';

export { WindowControls, WindowControlButton } from './WindowControls';
export type {
  WindowControlsProps,
  WindowControlButtonProps,
  WindowControlButtonType,
} from './WindowControls';

export { getTitlebarMetrics, useTitlebarMetrics } from './useTitlebarMetrics';

export { useCurrentWindowId, useWindowContext, WindowProvider } from './WindowContext';
export type { WindowContextValue } from './WindowContext';

// Re-export native component spec for advanced use cases
export { default as NativeWindowControlRegion } from './specs/WindowControlRegionNativeComponent';
export type {
  WindowControlRegionProps as NativeWindowControlRegionProps,
  WindowControlArea,
} from './specs/WindowControlRegionNativeComponent';
