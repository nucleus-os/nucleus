/**
 * Low-level WindowManager TurboModule interface
 *
 * Provides direct access to native window management functions.
 * For higher-level API, use the Window component or useWindow hook.
 */
import { TurboModuleRegistry } from 'react-native';
import type { TurboModule } from 'react-native';

export type WindowDecorations = 'client' | 'server';

export type WindowTitlebarOptions = {
  appearsTransparent?: boolean;
  trafficLightPosition?: { x: number; y: number };
};

export type TitlebarPlatform = 'macos' | 'windows' | 'linux' | 'unknown';

export type TitlebarMetrics = {
  height: number;
  leftInset: number;
  platform: TitlebarPlatform;
};

export type WindowCreateOptions = {
  /**
   * The window title. If not provided, a default title will be generated
   * based on the window number (e.g., "React Native Nucleus App (Window #2)").
   */
  title?: string;
  titlebar?: WindowTitlebarOptions;
  windowDecorations?: WindowDecorations;
};

type NativeWindowTitlebarOptions = {
  appearsTransparent: boolean | null;
  trafficLightPosition: { x: number; y: number } | null;
};

type NativeWindowCreateOptions = {
  title: string | null;
  titlebar: NativeWindowTitlebarOptions | null;
  windowDecorations: WindowDecorations | null;
};

interface NativeWindowManagerSpec extends TurboModule {
  /**
   * Create a new window with specified dimensions.
   * @returns Promise that resolves to window ID
   */
  createWindow(
    width: number,
    height: number,
    scale: number,
    fontScale: number,
    options: NativeWindowCreateOptions | null
  ): Promise<number>;

  /**
   * Create a React surface on a window.
   * @returns Promise that resolves to surface ID
   */
  createSurface(
    windowId: number,
    moduleName: string,
    initialPropsJson: string
  ): Promise<number>;

  /**
   * Stop a surface and clean up resources.
   */
  stopSurface(surfaceId: number): void;

  /**
   * Move a surface from its current window to another window.
   * The surface's React tree and state are preserved.
   */
  moveSurface(surfaceId: number, toWindowId: number): Promise<void>;

  /**
   * Close a window and clean up all associated resources.
   * This will stop all surfaces bound to the window and close it.
   */
  closeWindow(windowId: number): void;

  /**
   * Start a native window move (Linux/X11/Wayland).
   */
  startWindowMove(windowId: number): void;

  /**
   * Minimize a window.
   */
  minimizeWindow(windowId: number): void;

  /**
   * Toggle window zoom/maximize state.
   */
  zoomWindow(windowId: number): void;

  /**
   * Get platform-specific titlebar metrics.
   */
  getTitlebarMetrics(windowId: number | null): TitlebarMetrics;

  /**
   * Get the root window ID.
   * @returns Root window ID, or -1 if none exists
   */
  getRootWindowId(): number;
}

export interface WindowManagerSpec {
  createWindow(
    width: number,
    height: number,
    scale: number,
    fontScale: number,
    options?: WindowCreateOptions
  ): Promise<number>;
  createSurface(
    windowId: number,
    moduleName: string,
    initialProps: Record<string, any>
  ): Promise<number>;
  stopSurface(surfaceId: number): void;
  moveSurface(surfaceId: number, toWindowId: number): Promise<void>;
  closeWindow(windowId: number): void;
  startWindowMove(windowId: number): void;
  minimizeWindow(windowId: number): void;
  zoomWindow(windowId: number): void;
  getTitlebarMetrics(windowId?: number): TitlebarMetrics;
  getRootWindowId(): number;
}

const NativeWindowManager =
  TurboModuleRegistry.get<NativeWindowManagerSpec>('WindowManager');

function normalizeCreateOptions(
  options?: WindowCreateOptions
): NativeWindowCreateOptions | null {
  if (!options) {
    return null;
  }

  return {
    title: options.title ?? null,
    titlebar: options.titlebar
      ? {
          appearsTransparent: options.titlebar.appearsTransparent ?? null,
          trafficLightPosition: options.titlebar.trafficLightPosition ?? null,
        }
      : null,
    windowDecorations: options.windowDecorations ?? null,
  };
}

export const WindowManager: WindowManagerSpec | null = NativeWindowManager
  ? {
      createWindow(width, height, scale, fontScale, options) {
        return NativeWindowManager.createWindow(
          width,
          height,
          scale,
          fontScale,
          normalizeCreateOptions(options),
        );
      },
      createSurface(windowId, moduleName, initialProps) {
        let json: string;
        try {
          json = JSON.stringify(initialProps ?? {});
        } catch (err) {
          throw new Error(
            `createSurface initialProps must be JSON-serializable: ${String(err)}`,
          );
        }
        return NativeWindowManager.createSurface(windowId, moduleName, json);
      },
      stopSurface(surfaceId) {
        NativeWindowManager.stopSurface(surfaceId);
      },
      moveSurface(surfaceId, toWindowId) {
        return NativeWindowManager.moveSurface(surfaceId, toWindowId);
      },
      closeWindow(windowId) {
        NativeWindowManager.closeWindow(windowId);
      },
      startWindowMove(windowId) {
        NativeWindowManager.startWindowMove(windowId);
      },
      minimizeWindow(windowId) {
        NativeWindowManager.minimizeWindow(windowId);
      },
      zoomWindow(windowId) {
        NativeWindowManager.zoomWindow(windowId);
      },
      getTitlebarMetrics(windowId) {
        return NativeWindowManager.getTitlebarMetrics(windowId ?? null);
      },
      getRootWindowId() {
        return NativeWindowManager.getRootWindowId();
      },
    }
  : null;

if (!WindowManager) {
  console.warn('WindowManager TurboModule not found');
}

export default WindowManager;
