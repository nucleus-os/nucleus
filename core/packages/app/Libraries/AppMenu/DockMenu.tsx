/**
 * Declarative React component for the dock menu (right-click on dock icon).
 *
 * Uses the same Item/Separator/Submenu components as AppMenu.
 *
 * Usage:
 * ```tsx
 * <DockMenu>
 *   <DockMenu.Item label="New Window" onAction={() => createWindow()} />
 *   <DockMenu.Separator />
 *   <DockMenu.Item label="Show All Windows" onAction={() => showAll()} />
 * </DockMenu>
 * ```
 */
import * as React from 'react';
import { useEffect, useRef } from 'react';
import {
  setDockMenu,
  addAppMenuActionListener,
  type AppMenuItem,
  type OsRole,
  type SystemMenuType,
} from './AppMenuManager';

// =============================================================================
// Types
// =============================================================================

type ActionCallback = () => void;
type ActionMap = Map<string, ActionCallback>;

// =============================================================================
// Child Component Props (same as AppMenu)
// =============================================================================

export interface ItemProps {
  id?: string;
  label: string;
  shortcut?: string;
  checked?: boolean;
  disabled?: boolean;
  role?: OsRole;
  onAction?: () => void;
}

export interface SubmenuProps {
  label: string;
  children?: React.ReactNode;
}

export interface SystemMenuProps {
  menuType: SystemMenuType;
}

// =============================================================================
// Child Components
// =============================================================================

function Item(_props: ItemProps): React.ReactElement | null {
  return null;
}
Item.__dockMenuType = 'item';

function Separator(): React.ReactElement | null {
  return null;
}
Separator.__dockMenuType = 'separator';

function Submenu(_props: SubmenuProps): React.ReactElement | null {
  return null;
}
Submenu.__dockMenuType = 'submenu';

function SystemMenu(_props: SystemMenuProps): React.ReactElement | null {
  return null;
}
SystemMenu.__dockMenuType = 'systemMenu';

// =============================================================================
// Child Processing
// =============================================================================

let idCounter = 0;

function generateId(): string {
  return `__dock_${++idCounter}`;
}

function processChildren(
  children: React.ReactNode,
  actionMap: ActionMap
): AppMenuItem[] {
  const items: AppMenuItem[] = [];

  React.Children.forEach(children, (child) => {
    if (!React.isValidElement(child)) return;

    const type = (child.type as { __dockMenuType?: string }).__dockMenuType;
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

// =============================================================================
// Main DockMenu Component
// =============================================================================

export interface DockMenuProps {
  /** Menu items as children. */
  children?: React.ReactNode;
}

function DockMenuRoot({ children }: DockMenuProps): React.ReactElement | null {
  const actionMapRef = useRef<ActionMap>(new Map());
  const listenerRef = useRef<{ remove: () => void } | undefined>(undefined);

  useEffect(() => {
    // Clear and rebuild action map
    actionMapRef.current.clear();
    const items = processChildren(children, actionMapRef.current);

    // Send to native
    setDockMenu(items);

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
      // Note: We don't clear dock menu on unmount
    };
  }, [children]);

  // Clean up listener on unmount
  useEffect(() => {
    return () => {
      listenerRef.current?.remove();
      listenerRef.current = undefined;
    };
  }, []);

  return null;
}

// =============================================================================
// Export
// =============================================================================

type DockMenuComponent = typeof DockMenuRoot & {
  Item: typeof Item;
  Separator: typeof Separator;
  Submenu: typeof Submenu;
  SystemMenu: typeof SystemMenu;
};

export const DockMenu = DockMenuRoot as DockMenuComponent;
DockMenu.Item = Item;
DockMenu.Separator = Separator;
DockMenu.Submenu = Submenu;
DockMenu.SystemMenu = SystemMenu;
