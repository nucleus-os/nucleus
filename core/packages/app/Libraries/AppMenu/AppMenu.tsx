/**
 * Declarative React components for native app menus.
 *
 * Usage:
 * ```tsx
 * <AppMenu>
 *   <AppMenu.Menu label="File">
 *     <AppMenu.Item label="New" shortcut="⌘N" onAction={() => handleNew()} />
 *     <AppMenu.Separator />
 *     <AppMenu.Submenu label="Recent">
 *       <AppMenu.Item label="file1.txt" onAction={() => open('file1.txt')} />
 *     </AppMenu.Submenu>
 *   </AppMenu.Menu>
 *   <AppMenu.Menu label="Edit">
 *     <AppMenu.Item label="Cut" shortcut="⌘X" role="cut" />
 *     <AppMenu.Item label="Copy" shortcut="⌘C" role="copy" />
 *     <AppMenu.Item label="Paste" shortcut="⌘V" role="paste" />
 *   </AppMenu.Menu>
 * </AppMenu>
 * ```
 */
import * as React from 'react';
import { useEffect, useRef } from 'react';
import {
  setMenus,
  addAppMenuActionListener,
  type AppMenuConfig,
  type AppMenuItem,
  type OsRole,
  type SystemMenuType,
} from './AppMenuManager';

// =============================================================================
// Context for collecting callbacks
// =============================================================================

type ActionCallback = () => void;
type ActionMap = Map<string, ActionCallback>;

const AppMenuContext = React.createContext<{
  registerAction: (id: string, callback: ActionCallback) => void;
} | null>(null);

// =============================================================================
// Child Component Props
// =============================================================================

export interface MenuProps {
  /** The label displayed in the menu bar. */
  label: string;
  /** Menu items as children. */
  children?: React.ReactNode;
}

export interface ItemProps {
  /** Unique identifier. Auto-generated if not provided. */
  id?: string;
  /** The label displayed for this item. */
  label: string;
  /** Keyboard shortcut hint (display only). */
  shortcut?: string;
  /** Whether this item shows a checkmark. */
  checked?: boolean;
  /** Whether this item is disabled. */
  disabled?: boolean;
  /** OS role for native handling. When set, onAction is not called. */
  role?: OsRole;
  /** Callback when this item is clicked (ignored if role is set). */
  onAction?: () => void;
}

export interface SubmenuProps {
  /** The label for the submenu. */
  label: string;
  /** Submenu items as children. */
  children?: React.ReactNode;
}

export interface SystemMenuProps {
  /** The type of system menu. */
  menuType: SystemMenuType;
}

// =============================================================================
// Internal: Marker types for child processing
// =============================================================================

interface MenuMarker {
  __type: 'menu';
  label: string;
  children: React.ReactNode;
}

interface ItemMarker {
  __type: 'item';
  id?: string;
  label: string;
  shortcut?: string;
  checked?: boolean;
  disabled?: boolean;
  role?: OsRole;
  onAction?: () => void;
}

interface SeparatorMarker {
  __type: 'separator';
}

interface SubmenuMarker {
  __type: 'submenu';
  label: string;
  children: React.ReactNode;
}

interface SystemMenuMarker {
  __type: 'systemMenu';
  menuType: SystemMenuType;
}

type ChildMarker = MenuMarker | ItemMarker | SeparatorMarker | SubmenuMarker | SystemMenuMarker;

// =============================================================================
// Child Components (declarative markers)
// =============================================================================

function Menu(_props: MenuProps): React.ReactElement | null {
  return null;
}
Menu.__appMenuType = 'menu';

function Item(_props: ItemProps): React.ReactElement | null {
  return null;
}
Item.__appMenuType = 'item';

function Separator(): React.ReactElement | null {
  return null;
}
Separator.__appMenuType = 'separator';

function Submenu(_props: SubmenuProps): React.ReactElement | null {
  return null;
}
Submenu.__appMenuType = 'submenu';

function SystemMenu(_props: SystemMenuProps): React.ReactElement | null {
  return null;
}
SystemMenu.__appMenuType = 'systemMenu';

// =============================================================================
// Child Processing
// =============================================================================

let idCounter = 0;

function generateId(): string {
  return `__auto_${++idCounter}`;
}

function processChildren(
  children: React.ReactNode,
  actionMap: ActionMap
): AppMenuItem[] {
  const items: AppMenuItem[] = [];

  React.Children.forEach(children, (child) => {
    if (!React.isValidElement(child)) return;

    const type = (child.type as { __appMenuType?: string }).__appMenuType;
    const props = child.props;

    switch (type) {
      case 'separator':
        items.push({ type: 'separator' });
        break;

      case 'item': {
        const itemProps = props as ItemProps;
        const id = itemProps.id || generateId();

        if (itemProps.onAction && !itemProps.role) {
          actionMap.set(id, itemProps.onAction);
        }

        items.push({
          type: 'item',
          id,
          label: itemProps.label,
          shortcut: itemProps.shortcut,
          checked: itemProps.checked,
          disabled: itemProps.disabled,
          role: itemProps.role,
        });
        break;
      }

      case 'submenu': {
        const submenuProps = props as SubmenuProps;
        const subItems = processChildren(submenuProps.children, actionMap);
        items.push({
          type: 'submenu',
          label: submenuProps.label,
          items: subItems,
        });
        break;
      }

      case 'systemMenu': {
        const sysMenuProps = props as SystemMenuProps;
        items.push({
          type: 'systemMenu',
          menuType: sysMenuProps.menuType,
        });
        break;
      }
    }
  });

  return items;
}

function processMenus(
  children: React.ReactNode,
  actionMap: ActionMap
): AppMenuConfig[] {
  const menus: AppMenuConfig[] = [];

  React.Children.forEach(children, (child) => {
    if (!React.isValidElement(child)) return;

    const type = (child.type as { __appMenuType?: string }).__appMenuType;

    if (type === 'menu') {
      const menuProps = child.props as MenuProps;
      const items = processChildren(menuProps.children, actionMap);
      menus.push({
        label: menuProps.label,
        items,
      });
    }
  });

  return menus;
}

// =============================================================================
// Main AppMenu Component
// =============================================================================

export interface AppMenuProps {
  /** Menu definitions as children (AppMenu.Menu elements). */
  children?: React.ReactNode;
}

function AppMenuRoot({ children }: AppMenuProps): React.ReactElement | null {
  const actionMapRef = useRef<ActionMap>(new Map());
  const listenerRef = useRef<{ remove: () => void } | undefined>(undefined);

  // Register action callback (called during render via context)
  const registerAction = (id: string, callback: ActionCallback) => {
    actionMapRef.current.set(id, callback);
  };

  // Process children and update menus on every render
  useEffect(() => {
    // Clear and rebuild action map
    actionMapRef.current.clear();
    const menus = processMenus(children, actionMapRef.current);

    // Send to native
    setMenus(menus);

    // Set up listener if not already
    if (!listenerRef.current) {
      listenerRef.current = addAppMenuActionListener((event) => {
        const callback = actionMapRef.current.get(event.actionId);
        if (callback) {
          callback();
        }
      });
    }

    return () => {
      // Note: We don't clear menus on unmount as the app menu should persist
    };
  }, [children]);

  // Clean up listener on unmount
  useEffect(() => {
    return () => {
      listenerRef.current?.remove();
      listenerRef.current = undefined;
    };
  }, []);

  return (
    <AppMenuContext.Provider value={{ registerAction }}>
      {/* Children are processed but not rendered */}
    </AppMenuContext.Provider>
  );
}

// =============================================================================
// Export
// =============================================================================

type AppMenuComponent = typeof AppMenuRoot & {
  Menu: typeof Menu;
  Item: typeof Item;
  Separator: typeof Separator;
  Submenu: typeof Submenu;
  SystemMenu: typeof SystemMenu;
};

export const AppMenu = AppMenuRoot as AppMenuComponent;
AppMenu.Menu = Menu;
AppMenu.Item = Item;
AppMenu.Separator = Separator;
AppMenu.Submenu = Submenu;
AppMenu.SystemMenu = SystemMenu;
