/**
 * Imperative hook for app menu management.
 *
 * Provides functions to update menus programmatically.
 * For most cases, prefer the declarative <AppMenu> component.
 *
 * Usage:
 * ```tsx
 * function MyComponent() {
 *   const { setMenus, updateItem, setDockMenu } = useAppMenu();
 *
 *   const updateCheckmark = () => {
 *     updateItem('view-sidebar', { checked: true });
 *   };
 *
 *   // ...
 * }
 * ```
 */
import { useEffect, useEffectEvent } from 'react';
import {
  setMenus as nativeSetMenus,
  setDockMenu as nativeSetDockMenu,
  updateMenuItem,
  addAppMenuActionListener,
  type AppMenuConfig,
  type AppMenuItem,
  type AppMenuItemUpdate,
  type AppMenuActionEvent,
} from './AppMenuManager';

export interface UseAppMenuOptions {
  /**
   * Callback when a custom menu action is triggered.
   * Called for items without an OS role.
   */
  onAction?: (actionId: string) => void;
}

export interface UseAppMenuResult {
  /**
   * Set the full menu bar configuration.
   */
  setMenus: (menus: AppMenuConfig[]) => void;

  /**
   * Set the dock menu configuration.
   */
  setDockMenu: (items: AppMenuItem[]) => void;

  /**
   * Update a single menu item by ID.
   * Useful for toggling checkmarks or changing labels without rebuilding all menus.
   */
  updateItem: (itemId: string, props: AppMenuItemUpdate) => void;
}

/**
 * Hook for imperative app menu management.
 */
export function useAppMenu(options: UseAppMenuOptions = {}): UseAppMenuResult {
  const hasActionHandler = options.onAction != null;
  const handleAction = useEffectEvent((actionId: string) => {
    options.onAction?.(actionId);
  });

  // Set up action listener
  useEffect(() => {
    if (!hasActionHandler) return;

    const subscription = addAppMenuActionListener((event: AppMenuActionEvent) => {
      handleAction(event.actionId);
    });

    return () => {
      subscription?.remove();
    };
  }, [hasActionHandler]);

  return {
    setMenus: nativeSetMenus,
    setDockMenu: nativeSetDockMenu,
    updateItem: updateMenuItem,
  };
}
