/**
 * Low-level AppMenuManager TurboModule interface.
 *
 * Provides native app menu bar and dock menu support.
 * Menus are configured from JS, and action callbacks are emitted back to JS.
 * OS actions (cut/copy/paste/undo/redo) are handled natively.
 */
import { TurboModuleRegistry } from 'react-native';
import type { TurboModule } from 'react-native';

const RCTDeviceEventEmitterRaw = require('react-native/Libraries/EventEmitter/RCTDeviceEventEmitter');
const RCTDeviceEventEmitter =
  RCTDeviceEventEmitterRaw && RCTDeviceEventEmitterRaw.__esModule
    ? RCTDeviceEventEmitterRaw.default
    : RCTDeviceEventEmitterRaw;

// =============================================================================
// Types
// =============================================================================

/**
 * A menu in the app menu bar (e.g., "File", "Edit", "View").
 */
export interface AppMenuConfig {
  /** The label displayed in the menu bar. */
  label: string;
  /** The items in this menu. */
  items: AppMenuItem[];
}

/**
 * A menu item - can be an action, separator, submenu, or system menu.
 */
export type AppMenuItem =
  | { type: 'separator' }
  | {
      type: 'item';
      /** Unique identifier for this item (used in action callbacks). */
      id: string;
      /** The label displayed for this item. */
      label: string;
      /** Keyboard shortcut hint to display (e.g., "⌘N"). Display only. */
      shortcut?: string;
      /** Whether this item shows a checkmark. */
      checked?: boolean;
      /** Whether this item is disabled (grayed out). */
      disabled?: boolean;
      /**
       * OS role for native handling.
       * When set, the action is handled natively without a JS callback.
       */
      role?: OsRole;
    }
  | {
      type: 'submenu';
      /** The label for the submenu. */
      label: string;
      /** The items in the submenu. */
      items: AppMenuItem[];
    }
  | {
      type: 'systemMenu';
      /** The type of system menu. */
      menuType: SystemMenuType;
    };

/**
 * OS-handled menu actions.
 * These are handled natively without a JS round-trip.
 */
export type OsRole = 'cut' | 'copy' | 'paste' | 'selectAll' | 'undo' | 'redo';

/**
 * System-provided menus.
 */
export type SystemMenuType = 'services';

/**
 * Partial update for a menu item.
 */
export interface AppMenuItemUpdate {
  label?: string;
  checked?: boolean;
  disabled?: boolean;
}

/**
 * Event payload when a custom menu action is triggered.
 */
export interface AppMenuActionEvent {
  /** The ID of the menu item that was clicked. */
  actionId: string;
}

// =============================================================================
// TurboModule Spec
// =============================================================================

export interface AppMenuManagerSpec extends TurboModule {
  /**
   * Set the full menu bar configuration.
   * @param configJson JSON-serialized array of AppMenuConfig
   */
  setMenus(configJson: string): void;

  /**
   * Set the dock menu configuration (right-click on dock icon).
   * @param configJson JSON-serialized array of AppMenuItem
   */
  setDockMenu(configJson: string): void;

  /**
   * Update a single menu item by ID.
   * @param itemId The ID of the item to update
   * @param propsJson JSON-serialized AppMenuItemUpdate
   */
  updateMenuItem(itemId: string, propsJson: string): void;

  /**
   * Get the current menu configuration as JSON.
   * Note: This is primarily for debugging; apps typically don't need to read menus back.
   */
  getMenus(): string;
}

// =============================================================================
// Module Instance
// =============================================================================

export const AppMenuManager = TurboModuleRegistry.get<AppMenuManagerSpec>('AppMenuManager');

if (!AppMenuManager) {
  console.warn('AppMenuManager TurboModule not found');
}

// =============================================================================
// High-level API
// =============================================================================

/**
 * Set the app menu bar configuration.
 */
export function setMenus(menus: AppMenuConfig[]): void {
  AppMenuManager?.setMenus(JSON.stringify(menus));
}

/**
 * Set the dock menu configuration.
 */
export function setDockMenu(items: AppMenuItem[]): void {
  AppMenuManager?.setDockMenu(JSON.stringify(items));
}

/**
 * Update a single menu item by ID.
 */
export function updateMenuItem(itemId: string, props: AppMenuItemUpdate): void {
  AppMenuManager?.updateMenuItem(itemId, JSON.stringify(props));
}

/**
 * Clear the app menu bar (set to empty).
 */
export function clearMenus(): void {
  setMenus([]);
}

// =============================================================================
// Event Handling
// =============================================================================

export const APP_MENU_ACTION_EVENT = 'appMenuAction';

export type AppMenuActionListener = (event: AppMenuActionEvent) => void;

/**
 * Add a listener for menu action events.
 * Called when a custom menu item (without an OS role) is clicked.
 *
 * @returns A subscription that can be removed by calling `remove()`.
 */
export function addAppMenuActionListener(
  listener: AppMenuActionListener
): { remove: () => void } | undefined {
  if (!RCTDeviceEventEmitter || !RCTDeviceEventEmitter.addListener) {
    return undefined;
  }
  return RCTDeviceEventEmitter.addListener(APP_MENU_ACTION_EVENT, listener);
}

export default AppMenuManager;
