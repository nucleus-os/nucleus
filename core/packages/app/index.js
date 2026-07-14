'use strict';

const pkg = require('./package.json');

function getPlatformInfo() {
  return {
    platform: 'nucleus',
    version: pkg.version || '0.0.0',
  };
}

// Re-export Window APIs
const Window = require('./Libraries/Window');
const PerfOverlay = require('./Libraries/DevSupport/PerfOverlay.nucleus.js');
const ContextMenu = require('./Libraries/ContextMenu');
const AppMenuLib = require('./Libraries/AppMenu');
const NativeEvents = require('./Libraries/NativeEvents');

module.exports = {
  getPlatformInfo,
  // Window Management
  WindowManager: Window.WindowManager,
  useWindow: Window.useWindow,
  Window: Window.Window,
  WindowDragRegion: Window.WindowDragRegion,
  Titlebar: Window.Titlebar,
  WindowControls: Window.WindowControls,
  WindowControlButton: Window.WindowControlButton,
  useTitlebarMetrics: Window.useTitlebarMetrics,
  getTitlebarMetrics: Window.getTitlebarMetrics,
  useCurrentWindowId: Window.useCurrentWindowId,
  useWindowContext: Window.useWindowContext,
  Zoom: Window.Zoom,
  ZOOM_CHANGED_EVENT: Window.ZOOM_CHANGED_EVENT,
  // Dev/Perf
  PerfOverlay,
  // Context Menu
  ContextMenuManager: ContextMenu.ContextMenuManager,
  ContextMenu: ContextMenu.ContextMenu,
  ContextMenuConfigurator: ContextMenu.ContextMenuConfigurator,
  addContextMenuListener: ContextMenu.addContextMenuListener,
  setContextMenu: ContextMenu.setContextMenu,
  disableContextMenu: ContextMenu.disableContextMenu,
  setDevToolsItemEnabled: ContextMenu.setDevToolsItemEnabled,
  isDevToolsItemEnabled: ContextMenu.isDevToolsItemEnabled,
  performContextMenuAction: ContextMenu.performContextMenuAction,
  CONTEXT_MENU_REQUESTED_EVENT: ContextMenu.CONTEXT_MENU_REQUESTED_EVENT,
  // Native Events
  useNativeEventListener: NativeEvents.useNativeEventListener,
  useProjection: NativeEvents.useProjection,
  // App Menu
  AppMenuManager: AppMenuLib.AppMenuManager,
  AppMenu: AppMenuLib.AppMenu,
  DockMenu: AppMenuLib.DockMenu,
  useAppMenu: AppMenuLib.useAppMenu,
  setMenus: AppMenuLib.setMenus,
  setDockMenu: AppMenuLib.setDockMenu,
  updateMenuItem: AppMenuLib.updateMenuItem,
  clearMenus: AppMenuLib.clearMenus,
  addAppMenuActionListener: AppMenuLib.addAppMenuActionListener,
  APP_MENU_ACTION_EVENT: AppMenuLib.APP_MENU_ACTION_EVENT,
};
