/**
 * App Menu API for NUCLEUS.
 *
 * Provides native app menu bar and dock menu support with a declarative React API.
 */

// Manager (low-level)
export {
  default as AppMenuManager,
  setMenus,
  setDockMenu,
  updateMenuItem,
  clearMenus,
  addAppMenuActionListener,
  APP_MENU_ACTION_EVENT,
} from './AppMenuManager';

export type {
  AppMenuConfig,
  AppMenuItem,
  AppMenuItemUpdate,
  AppMenuActionEvent,
  AppMenuActionListener,
  AppMenuManagerSpec,
  OsRole,
  SystemMenuType,
} from './AppMenuManager';

// React components
export { AppMenu } from './AppMenu';
export type { AppMenuProps, MenuProps, ItemProps, SubmenuProps, SystemMenuProps } from './AppMenu';

export { DockMenu } from './DockMenu';
export type { DockMenuProps } from './DockMenu';

// Hooks
export { useAppMenu } from './useAppMenu';
export type { UseAppMenuOptions, UseAppMenuResult } from './useAppMenu';
