/**
 * Low-level ContextMenuManager TurboModule interface.
 *
 * Headless ContextMenuManager TurboModule interface.
 *
 * Emits context menu requests and lets React render the UI.
 */
import { TurboModuleRegistry } from 'react-native';
import type { TurboModule } from 'react-native';

const RCTDeviceEventEmitterRaw = require('react-native/Libraries/EventEmitter/RCTDeviceEventEmitter');
const RCTDeviceEventEmitter =
  RCTDeviceEventEmitterRaw && RCTDeviceEventEmitterRaw.__esModule
    ? RCTDeviceEventEmitterRaw.default
    : RCTDeviceEventEmitterRaw;

export interface ContextMenuConfig {
  items: Array<ContextMenuItem>;
  /**
   * Emit context menu events even if no items are enabled.
   * Useful for fully custom context menu UI.
   */
  enabled?: boolean;
  /**
   * Force a scheme for the default context menu UI, or follow system/Appearance.
   * @default 'system'
   */
  colorScheme?: 'system' | 'light' | 'dark';
  style?: ContextMenuStyle;
}

export type ContextMenuItem =
  | { type: 'separator' }
  | {
      type: 'item';
      id: string;
      title: string;
      enabledWhen?: 'always' | 'hasSelection';
      action: ContextMenuAction;
    };

export type ContextMenuAction =
  | { type: 'copy' }
  | { type: 'openUrlTemplate'; template: string }
  | { type: 'openDevTools' };

export interface ContextMenuRequest {
  windowId: number;
  x: number;
  y: number;
  hasSelection: boolean;
  selectedText: string | null;
}

export interface ContextMenuStyle {
  background?: HslaSpec;
  border?: HslaSpec;
  text?: HslaSpec;
  hoverBackground?: HslaSpec;
  paddingX?: number;
  paddingY?: number;
  itemPaddingX?: number;
  itemPaddingY?: number;
  borderRadius?: number;
  minWidth?: number;
  fontFamily?: string;
  fontSize?: number;
  /**
   * Per-scheme style overrides applied on top of base style.
   */
  light?: ContextMenuStyleOverrides;
  dark?: ContextMenuStyleOverrides;
}

export type ContextMenuStyleOverrides = Omit<ContextMenuStyle, 'light' | 'dark'>;

export interface HslaSpec {
  h: number;
  s: number;
  l: number;
  a: number;
}

export interface ContextMenuManagerSpec extends TurboModule {
  setContextMenuConfig(json: string): void;
  setDevToolsItemEnabled(enabled: boolean): void;
  performAction(actionJson: string, windowId?: number | null, selectedText?: string | null): void;
}

export const ContextMenuManager =
  TurboModuleRegistry.get<ContextMenuManagerSpec>('ContextMenuManager');

if (!ContextMenuManager) {
  console.warn('ContextMenuManager TurboModule not found');
}

let lastContextMenuConfig: ContextMenuConfig = { items: [], enabled: false };
const contextMenuConfigListeners = new Set<(config: ContextMenuConfig) => void>();
const contextMenuWindowOwners = new Set<number>();

export function getContextMenuConfig(): ContextMenuConfig {
  return lastContextMenuConfig;
}

export function addContextMenuConfigListener(listener: (config: ContextMenuConfig) => void): {
  remove: () => void;
} {
  contextMenuConfigListeners.add(listener);
  return {
    remove: () => {
      contextMenuConfigListeners.delete(listener);
    },
  };
}

export function addContextMenuWindowOwner(windowId: number): { remove: () => void } {
  contextMenuWindowOwners.add(windowId);
  return {
    remove: () => {
      contextMenuWindowOwners.delete(windowId);
    },
  };
}

export function hasContextMenuWindowOwner(windowId: number): boolean {
  return contextMenuWindowOwners.has(windowId);
}

function notifyContextMenuConfigListeners(config: ContextMenuConfig) {
  for (const listener of contextMenuConfigListeners) {
    try {
      listener(config);
    } catch (err) {
      console.error('[ContextMenu] Config listener error:', err);
    }
  }
}

export function setContextMenu(config: ContextMenuConfig): void {
  lastContextMenuConfig = config;
  notifyContextMenuConfigListeners(config);
  ContextMenuManager?.setContextMenuConfig(JSON.stringify(config));
}

export function disableContextMenu(): void {
  setContextMenu({ items: [], enabled: false });
}

let devtoolsItemEnabled = true;

export function isDevToolsItemEnabled(): boolean {
  return devtoolsItemEnabled;
}

export function setDevToolsItemEnabled(enabled: boolean): void {
  devtoolsItemEnabled = enabled;
  ContextMenuManager?.setDevToolsItemEnabled(enabled);
}

export const CONTEXT_MENU_REQUESTED_EVENT = 'contextMenuRequested';

export type ContextMenuListener = (event: ContextMenuRequest) => void;

export function addContextMenuListener(
  listener: ContextMenuListener,
): { remove: () => void } | undefined {
  if (!RCTDeviceEventEmitter || !RCTDeviceEventEmitter.addListener) {
    return undefined;
  }
  return RCTDeviceEventEmitter.addListener(CONTEXT_MENU_REQUESTED_EVENT, listener);
}

export function performContextMenuAction(
  action: ContextMenuAction,
  options?: { windowId?: number; selectedText?: string | null },
): void {
  ContextMenuManager?.performAction(
    JSON.stringify(action),
    options?.windowId ?? null,
    options?.selectedText ?? null,
  );
}

export default ContextMenuManager;
