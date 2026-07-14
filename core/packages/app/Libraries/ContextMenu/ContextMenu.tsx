import React, { useEffect, useRef, useState } from 'react';
import {
  Pressable,
  StyleSheet,
  Text,
  View,
  useColorScheme,
  useWindowDimensions,
} from 'react-native';

import { useCurrentWindowId, WindowManager } from '@nucleus-os/window';
import type {
  ContextMenuAction,
  ContextMenuConfig,
  ContextMenuItem,
  ContextMenuRequest,
  HslaSpec,
} from './ContextMenuManager';
import {
  addContextMenuConfigListener,
  addContextMenuListener,
  addContextMenuWindowOwner,
  disableContextMenu,
  getContextMenuConfig,
  hasContextMenuWindowOwner,
  isDevToolsItemEnabled,
  performContextMenuAction,
  setContextMenu,
} from './ContextMenuManager';

export interface ContextMenuRenderProps {
  request: ContextMenuRequest;
  config: ContextMenuConfig;
  items: Array<ContextMenuItem>;
  close: () => void;
  runAction: (action: ContextMenuAction) => void;
}

export interface ContextMenuProps {
  config: ContextMenuConfig;
  renderMenu?: (props: ContextMenuRenderProps) => React.ReactNode;
}

const DEFAULT_MENU_BASE = {
  paddingX: 6,
  paddingY: 6,
  itemPaddingX: 10,
  itemPaddingY: 7,
  borderRadius: 8,
  minWidth: 180,
};

const DEFAULT_MENU_LIGHT = {
  background: { h: 220, s: 0.18, l: 0.97, a: 0.98 },
  border: { h: 220, s: 0.14, l: 0.84, a: 0.95 },
  text: { h: 220, s: 0.25, l: 0.14, a: 0.92 },
  hoverBackground: { h: 210, s: 0.55, l: 0.92, a: 0.9 },
};

const DEFAULT_MENU_DARK = {
  background: { h: 220, s: 0.2, l: 0.12, a: 0.98 },
  border: { h: 220, s: 0.2, l: 0.28, a: 0.95 },
  text: { h: 0, s: 0, l: 1, a: 0.92 },
  hoverBackground: { h: 210, s: 0.6, l: 0.35, a: 0.75 },
};

function hueToRgb(p: number, q: number, t: number): number {
  let next = t;
  if (next < 0) next += 1;
  if (next > 1) next -= 1;
  if (next < 1 / 6) return p + (q - p) * 6 * next;
  if (next < 1 / 2) return q;
  if (next < 2 / 3) return p + (q - p) * (2 / 3 - next) * 6;
  return p;
}

function hslaToRgba(spec: HslaSpec): string {
  const h = ((spec.h % 360) + 360) % 360;
  const s = Math.max(0, Math.min(1, spec.s));
  const l = Math.max(0, Math.min(1, spec.l));
  const a = Math.max(0, Math.min(1, spec.a));

  if (s === 0) {
    const gray = Math.round(l * 255);
    return `rgba(${gray}, ${gray}, ${gray}, ${a})`;
  }

  const q = l < 0.5 ? l * (1 + s) : l + s - l * s;
  const p = 2 * l - q;
  const r = hueToRgb(p, q, h / 360 + 1 / 3);
  const g = hueToRgb(p, q, h / 360);
  const b = hueToRgb(p, q, h / 360 - 1 / 3);

  return `rgba(${Math.round(r * 255)}, ${Math.round(g * 255)}, ${Math.round(b * 255)}, ${a})`;
}

function applyAlpha(spec: HslaSpec, alpha: number): HslaSpec {
  return { ...spec, a: Math.max(0, Math.min(1, spec.a * alpha)) };
}

function resolveNumber(value: number | undefined, fallback: number): number {
  return value ?? fallback;
}

function resolveStyle(config: ContextMenuConfig, scheme: 'light' | 'dark') {
  const style = config.style ?? {};
  const variant = scheme === 'dark' ? (style.dark ?? {}) : (style.light ?? {});
  const defaults = scheme === 'dark' ? DEFAULT_MENU_DARK : DEFAULT_MENU_LIGHT;

  const background = variant.background ?? style.background ?? defaults.background;
  const border = variant.border ?? style.border ?? defaults.border;
  const text = variant.text ?? style.text ?? defaults.text;
  const hoverBackground =
    variant.hoverBackground ?? style.hoverBackground ?? defaults.hoverBackground;

  return {
    background,
    border,
    text,
    hoverBackground,
    paddingX: resolveNumber(variant.paddingX ?? style.paddingX, DEFAULT_MENU_BASE.paddingX),
    paddingY: resolveNumber(variant.paddingY ?? style.paddingY, DEFAULT_MENU_BASE.paddingY),
    itemPaddingX: resolveNumber(
      variant.itemPaddingX ?? style.itemPaddingX,
      DEFAULT_MENU_BASE.itemPaddingX,
    ),
    itemPaddingY: resolveNumber(
      variant.itemPaddingY ?? style.itemPaddingY,
      DEFAULT_MENU_BASE.itemPaddingY,
    ),
    borderRadius: resolveNumber(
      variant.borderRadius ?? style.borderRadius,
      DEFAULT_MENU_BASE.borderRadius,
    ),
    minWidth: resolveNumber(variant.minWidth ?? style.minWidth, DEFAULT_MENU_BASE.minWidth),
    fontFamily: variant.fontFamily ?? style.fontFamily,
    fontSize: resolveNumber(variant.fontSize ?? style.fontSize, 14),
  };
}

function isItemEnabled(item: ContextMenuItem, hasSelection: boolean): boolean {
  if (item.type === 'separator') {
    return false;
  }
  const enabledWhen = item.enabledWhen ?? 'hasSelection';
  return enabledWhen === 'always' || (enabledWhen === 'hasSelection' && hasSelection);
}

function buildMenuItems(items: Array<ContextMenuItem>): Array<ContextMenuItem> {
  if (!__DEV__ || !isDevToolsItemEnabled()) {
    return items.slice();
  }
  const hasDevTools = items.some((item) => item.type === 'item' && item.id === 'openDevTools');
  if (hasDevTools) {
    return items.slice();
  }
  const next = items.slice();
  if (next.length > 0) {
    next.push({ type: 'separator' });
  }
  next.push({
    type: 'item',
    id: 'openDevTools',
    title: 'Open DevTools',
    enabledWhen: 'always',
    action: { type: 'openDevTools' },
  });
  return next;
}

function hasEnabledItems(items: Array<ContextMenuItem>, hasSelection: boolean): boolean {
  return items.some((item) => isItemEnabled(item, hasSelection));
}

function filterVisibleItems(
  items: Array<ContextMenuItem>,
  hasSelection: boolean,
): Array<ContextMenuItem> {
  const filtered: Array<ContextMenuItem> = [];
  for (const item of items) {
    if (item.type === 'separator') {
      filtered.push(item);
      continue;
    }
    if (isItemEnabled(item, hasSelection)) {
      filtered.push(item);
    }
  }

  const cleaned: Array<ContextMenuItem> = [];
  for (let i = 0; i < filtered.length; i++) {
    const item = filtered[i];
    if (!item) continue;
    if (item.type !== 'separator') {
      cleaned.push(item);
      continue;
    }
    if (cleaned.length === 0) {
      continue;
    }
    const next = filtered.slice(i + 1).find((candidate) => candidate.type !== 'separator');
    if (!next) {
      continue;
    }
    if (cleaned[cleaned.length - 1]?.type === 'separator') {
      continue;
    }
    cleaned.push(item);
  }

  return cleaned;
}

function computeMenuPosition({
  anchorX,
  anchorY,
  menuWidth,
  menuHeight,
  containerWidth,
  containerHeight,
  margin,
}: {
  anchorX: number;
  anchorY: number;
  menuWidth: number;
  menuHeight: number;
  containerWidth: number;
  containerHeight: number;
  margin: number;
}): { left: number; top: number } {
  if (
    !Number.isFinite(anchorX) ||
    !Number.isFinite(anchorY) ||
    !Number.isFinite(menuWidth) ||
    !Number.isFinite(menuHeight) ||
    !Number.isFinite(containerWidth) ||
    !Number.isFinite(containerHeight)
  ) {
    return { left: margin, top: margin };
  }

  const safeMenuWidth = Math.max(0, menuWidth);
  const safeMenuHeight = Math.max(0, menuHeight);
  const safeContainerWidth = Math.max(0, containerWidth);
  const safeContainerHeight = Math.max(0, containerHeight);

  let left = anchorX;
  let top = anchorY;

  if (left + safeMenuWidth + margin > safeContainerWidth) {
    left = anchorX - safeMenuWidth;
  }
  if (top + safeMenuHeight + margin > safeContainerHeight) {
    top = anchorY - safeMenuHeight;
  }

  left = Math.max(margin, left);
  top = Math.max(margin, top);

  if (left + safeMenuWidth + margin > safeContainerWidth) {
    left = Math.max(margin, safeContainerWidth - safeMenuWidth - margin);
  }
  if (top + safeMenuHeight + margin > safeContainerHeight) {
    top = Math.max(margin, safeContainerHeight - safeMenuHeight - margin);
  }

  return { left, top };
}

function ContextMenuOverlayImpl({
  config,
  renderMenu,
  manageNativeConfig = true,
}: ContextMenuProps & { manageNativeConfig?: boolean }) {
  const [request, setRequest] = useState<ContextMenuRequest | null>(null);
  const [menuSize, setMenuSize] = useState({ width: 0, height: 0 });
  const [overlaySize, setOverlaySize] = useState({ width: 0, height: 0 });
  const configRef = useRef(config);
  const renderMenuRef = useRef(renderMenu);
  const { width: windowWidth, height: windowHeight } = useWindowDimensions();
  const schemeFromSystem = useColorScheme();
  const hasCustomMenu = !!renderMenu;
  const currentWindowId = useCurrentWindowId();
  const rootWindowId = WindowManager?.getRootWindowId?.() ?? -1;
  const effectiveWindowId =
    currentWindowId ?? (typeof rootWindowId === 'number' && rootWindowId > 0 ? rootWindowId : null);

  const configJson = JSON.stringify(config);

  useEffect(() => {
    configRef.current = config;
  }, [configJson]);

  useEffect(() => {
    renderMenuRef.current = renderMenu;
  }, [renderMenu]);

  useEffect(() => {
    if (!manageNativeConfig || effectiveWindowId == null) {
      return;
    }
    const sub = addContextMenuWindowOwner(effectiveWindowId);
    return () => {
      sub?.remove?.();
    };
  }, [effectiveWindowId, manageNativeConfig]);

  useEffect(() => {
    const nativeConfig =
      hasCustomMenu && config.enabled == null ? { ...config, enabled: true } : config;
    if (!manageNativeConfig) {
      return;
    }
    setContextMenu(nativeConfig);
    return () => {
      disableContextMenu();
    };
  }, [configJson, hasCustomMenu, manageNativeConfig]);

  useEffect(() => {
    const sub = addContextMenuListener((event) => {
      if (!manageNativeConfig && hasContextMenuWindowOwner(event.windowId)) {
        setRequest(null);
        return;
      }

      // Only handle events for this window.
      // If not under a WindowProvider, fall back to the root window ID (when available).
      if (effectiveWindowId != null && event.windowId !== effectiveWindowId) {
        // Close any open menu in this window when a right-click happens elsewhere
        setRequest(null);
        return;
      }

      const latestConfig = configRef.current;
      const latestRenderMenu = renderMenuRef.current;
      const items = filterVisibleItems(buildMenuItems(latestConfig.items), event.hasSelection);
      if (!latestRenderMenu && items.length === 0) {
        setRequest(null);
        return;
      }
      setRequest({
        windowId: event.windowId,
        x: event.x,
        y: event.y,
        hasSelection: event.hasSelection,
        selectedText: event.selectedText ?? null,
      });
    });
    return () => {
      sub?.remove?.();
    };
  }, [effectiveWindowId, manageNativeConfig]);

  if (!request) {
    return null;
  }

  const items = filterVisibleItems(buildMenuItems(config.items), request.hasSelection);
  const closeMenu = () => {
    setRequest(null);
  };

  const runAction = (action: ContextMenuAction) => {
    performContextMenuAction(action, {
      windowId: request.windowId,
      selectedText: request.selectedText,
    });
  };

  if (renderMenu) {
    return (
      <View
        style={styles.root}
        pointerEvents="box-none"
        onLayout={(event) => {
          const nextWidth = Math.ceil(event.nativeEvent.layout.width);
          const nextHeight = Math.ceil(event.nativeEvent.layout.height);
          if (nextWidth !== overlaySize.width || nextHeight !== overlaySize.height) {
            setOverlaySize({ width: nextWidth, height: nextHeight });
          }
        }}
      >
        <Pressable style={styles.backdrop} onPress={closeMenu} />
        {renderMenu({
          request,
          config,
          items,
          close: closeMenu,
          runAction,
        })}
      </View>
    );
  }

  const margin = 8;
  const containerWidth = overlaySize.width > 0 ? overlaySize.width : windowWidth;
  const containerHeight = overlaySize.height > 0 ? overlaySize.height : windowHeight;
  const isMeasured = menuSize.width > 0 && menuSize.height > 0;
  const { left, top } = computeMenuPosition({
    anchorX: request.x,
    anchorY: request.y,
    menuWidth: menuSize.width,
    menuHeight: menuSize.height,
    containerWidth,
    containerHeight,
    margin,
  });

  const onMenuLayout = (event: { nativeEvent: { layout: { width: number; height: number } } }) => {
    const nextWidth = Math.ceil(event.nativeEvent.layout.width);
    const nextHeight = Math.ceil(event.nativeEvent.layout.height);
    if (nextWidth !== menuSize.width || nextHeight !== menuSize.height) {
      setMenuSize({ width: nextWidth, height: nextHeight });
    }
  };

  const scheme =
    config.colorScheme && config.colorScheme !== 'system'
      ? config.colorScheme
      : schemeFromSystem === 'dark'
        ? 'dark'
        : 'light';
  const resolved = resolveStyle(config, scheme);
  const backgroundColor = hslaToRgba(resolved.background);
  const borderColor = hslaToRgba(resolved.border);
  const textColor = hslaToRgba(resolved.text);
  const hoverBackground = hslaToRgba(resolved.hoverBackground);
  const disabledTextColor = hslaToRgba(applyAlpha(resolved.text, 0.45));
  const separatorColor = hslaToRgba(applyAlpha(resolved.border, 0.6));

  return (
    <View
      style={styles.root}
      pointerEvents="box-none"
      onLayout={(event) => {
        const nextWidth = Math.ceil(event.nativeEvent.layout.width);
        const nextHeight = Math.ceil(event.nativeEvent.layout.height);
        if (nextWidth !== overlaySize.width || nextHeight !== overlaySize.height) {
          setOverlaySize({ width: nextWidth, height: nextHeight });
        }
      }}
    >
      <Pressable style={styles.backdrop} onPress={closeMenu} />
      <View
        onLayout={onMenuLayout}
        style={[
          styles.menuContainer,
          {
            left: isMeasured ? left : -10000,
            top: isMeasured ? top : -10000,
            minWidth: resolved.minWidth,
            borderRadius: resolved.borderRadius,
          },
        ]}
      >
        <View
          style={[
            styles.menuPanel,
            {
              backgroundColor,
              borderColor,
              borderRadius: resolved.borderRadius,
              paddingHorizontal: resolved.paddingX,
              paddingVertical: resolved.paddingY,
            },
          ]}
        >
          {items.map((item, index) => {
            if (item.type === 'separator') {
              return (
                <View
                  key={`context-menu-sep-${index}`}
                  style={[styles.separator, { backgroundColor: separatorColor }]}
                />
              );
            }
            const enabled = isItemEnabled(item, request.hasSelection);
            return (
              <Pressable
                key={item.id}
                disabled={!enabled}
                onPress={() => {
                  if (enabled) {
                    runAction(item.action);
                  }
                  closeMenu();
                }}
                style={(state) => {
                  const hovered = (state as { hovered?: boolean }).hovered === true;
                  return [
                    styles.item,
                    {
                      backgroundColor: hovered && enabled ? hoverBackground : 'transparent',
                      paddingHorizontal: resolved.itemPaddingX,
                      paddingVertical: resolved.itemPaddingY,
                      borderRadius: 6,
                    },
                  ];
                }}
              >
                <Text
                  numberOfLines={1}
                  ellipsizeMode="tail"
                  style={{
                    color: enabled ? textColor : disabledTextColor,
                    fontFamily: resolved.fontFamily,
                    fontSize: resolved.fontSize,
                  }}
                >
                  {item.title}
                </Text>
              </Pressable>
            );
          })}
        </View>
      </View>
    </View>
  );
}

export function ContextMenu({ config, renderMenu }: ContextMenuProps) {
  return (
    <ContextMenuOverlayImpl config={config} renderMenu={renderMenu} manageNativeConfig={true} />
  );
}

export function DefaultContextMenuOverlay() {
  const [config, setConfig] = useState<ContextMenuConfig>(() => getContextMenuConfig());

  useEffect(() => {
    const sub = addContextMenuConfigListener((nextConfig) => {
      setConfig(nextConfig);
    });
    return () => {
      sub?.remove?.();
    };
  }, []);

  return <ContextMenuOverlayImpl config={config} manageNativeConfig={false} />;
}

const styles = StyleSheet.create({
  root: {
    ...StyleSheet.absoluteFillObject,
    zIndex: 1000,
  },
  backdrop: {
    ...StyleSheet.absoluteFillObject,
    backgroundColor: 'transparent',
    zIndex: 1,
  },
  menuContainer: {
    position: 'absolute',
    zIndex: 2,
  },
  menuPanel: {
    borderWidth: 1,
  },
  item: {
    justifyContent: 'center',
  },
  separator: {
    height: 1,
    marginVertical: 4,
  },
});
