/**
 * Type definitions for @nucleus-os/app
 */

import type { ViewProps } from 'react-native';
import type { ColorValue } from 'react-native/Libraries/StyleSheet/StyleSheet';

export interface PlatformInfo {
  platform: 'nucleus';
  version: string;
}

export function getPlatformInfo(): PlatformInfo;

// Window Management API
export {
  WindowManager,
  WindowManagerSpec,
  TitlebarMetrics,
  TitlebarPlatform,
  Zoom,
  ZoomSpec,
  ZOOM_CHANGED_EVENT,
  ZoomChangedEvent,
  useWindow,
  UseWindowOptions,
  UseWindowResult,
  Window,
  WindowProps,
  Titlebar,
  TitlebarProps,
  useTitlebarMetrics,
  getTitlebarMetrics,
  useCurrentWindowId,
  useWindowContext,
  WindowContextValue,
} from './Libraries/Window';

// Context Menu API
export {
  ContextMenuManager,
  ContextMenuManagerSpec,
  ContextMenu,
  ContextMenuProps,
  ContextMenuRenderProps,
  ContextMenuConfigurator,
  ContextMenuRequest,
  ContextMenuListener,
  CONTEXT_MENU_REQUESTED_EVENT,
  addContextMenuListener,
  disableContextMenu,
  setContextMenu,
  performContextMenuAction,
  setDevToolsItemEnabled,
  isDevToolsItemEnabled,
  ContextMenuAction,
  ContextMenuConfig,
  ContextMenuItem,
  ContextMenuStyle,
  ContextMenuStyleOverrides,
  HslaSpec,
} from './Libraries/ContextMenu';

// App Menu API
export {
  AppMenuManager,
  AppMenuManagerSpec,
  AppMenu,
  AppMenuProps,
  MenuProps,
  ItemProps,
  SubmenuProps,
  SystemMenuProps,
  DockMenu,
  DockMenuProps,
  useAppMenu,
  UseAppMenuOptions,
  UseAppMenuResult,
  setMenus,
  setDockMenu,
  updateMenuItem,
  clearMenus,
  addAppMenuActionListener,
  APP_MENU_ACTION_EVENT,
  AppMenuConfig,
  AppMenuItem,
  AppMenuItemUpdate,
  AppMenuActionEvent,
  AppMenuActionListener,
  OsRole,
  SystemMenuType,
} from './Libraries/AppMenu';

// Note: Blur and Gradient are now in separate packages.
// Import from '@nucleus-os/blur' and '@nucleus-os/gradient' instead.

export function useNativeEventListener<
  TModule extends {
    addListener(eventName: string): void;
    removeListeners(count: number): void;
    [key: string]: unknown;
  },
  TEvent,
>(
  module: TModule,
  eventName: keyof TModule,
  signalFn: (callback: (event: TEvent) => void) => () => void,
  callback: (event: TEvent) => void
): void;

export function useProjection<TSnapshot, TPayload extends { snapshot: string }>(
  module: {
    addListener(eventName: string): void;
    removeListeners(count: number): void;
    [signalName: string]: ((callback: (payload: TPayload) => void) => () => void) | unknown;
  },
  signalName: string,
  signalFn: (callback: (payload: TPayload) => void) => () => void
): TSnapshot | null;
