import React, { useState } from 'react';
import { StyleSheet, View } from 'react-native';
import type { ViewProps, PointerEvent } from 'react-native';

import WindowManager from './WindowManager';
import { useTitlebarMetrics } from './useTitlebarMetrics';
import NativeWindowControlRegion from './specs/WindowControlRegionNativeComponent';
import { useCurrentWindowId } from './WindowContext';

export type WindowControlButtonType = 'minimize' | 'maximize' | 'close';

export interface WindowControlButtonProps extends ViewProps {
  type: WindowControlButtonType;
  windowId?: number;
  size?: number;
  iconSize?: number;
  color?: string;
  pressedBackgroundColor?: string;
  disabled?: boolean;
  onPress?: () => void;
}

export function WindowControlButton({
  type,
  windowId,
  size = 28,
  iconSize = 10,
  color = '#8b8f94',
  pressedBackgroundColor = 'rgba(0, 0, 0, 0.12)',
  disabled,
  onPress,
  onPointerDown,
  onPointerUp,
  onPointerCancel,
  style,
  children,
  ...props
}: WindowControlButtonProps) {
  const [pressed, setPressed] = useState(false);
  const contextWindowId = useCurrentWindowId();
  const metrics = useTitlebarMetrics(windowId ?? contextWindowId ?? undefined);

  const handlePointerDown = (event: PointerEvent) => {
    onPointerDown?.(event);
    if (disabled) {
      return;
    }
    setPressed(true);
    onPress?.();
    if (!WindowManager) {
      return;
    }
    const resolvedWindowId =
      typeof windowId === 'number'
        ? windowId
        : contextWindowId ?? WindowManager.getRootWindowId();
    if (resolvedWindowId <= 0) {
      return;
    }
    if (metrics.platform === 'windows') {
      return;
    }
    switch (type) {
      case 'minimize':
        WindowManager.minimizeWindow?.(resolvedWindowId);
        break;
      case 'maximize':
        WindowManager.zoomWindow?.(resolvedWindowId);
        break;
      case 'close':
        WindowManager.closeWindow?.(resolvedWindowId);
        break;
      default:
        break;
    }
  };

  const handlePointerUp = (event: PointerEvent) => {
    onPointerUp?.(event);
    if (pressed) {
      setPressed(false);
    }
  };

  const handlePointerCancel = (event: PointerEvent) => {
    onPointerCancel?.(event);
    if (pressed) {
      setPressed(false);
    }
  };

  return (
    <NativeWindowControlRegion
      {...props}
      controlArea={type}
      onPointerDown={handlePointerDown}
      onPointerUp={handlePointerUp}
      onPointerCancel={handlePointerCancel}
      style={[
        styles.button,
        { width: size, height: size, borderRadius: Math.round(size / 3) },
        pressed ? { backgroundColor: pressedBackgroundColor } : null,
        disabled ? styles.buttonDisabled : null,
        style,
      ]}
    >
      {children ?? (
        <WindowControlIcon type={type} size={iconSize} color={color} />
      )}
    </NativeWindowControlRegion>
  );
}

export interface WindowControlsProps extends ViewProps {
  windowId?: number;
  order?: WindowControlButtonType[];
  buttonSize?: number;
  iconSize?: number;
  color?: string;
  spacing?: number;
  showOnMac?: boolean;
}

export function WindowControls({
  windowId,
  order,
  buttonSize,
  iconSize,
  color,
  spacing = 6,
  showOnMac = false,
  style,
  children,
  ...props
}: WindowControlsProps) {
  const metrics = useTitlebarMetrics(windowId);
  if (!showOnMac && metrics.platform === 'macos') {
    return null;
  }

  const controls =
    children ??
    (order ?? ['minimize', 'maximize', 'close']).map((type, index) => (
      <WindowControlButton
        key={type}
        type={type}
        windowId={windowId}
        size={buttonSize}
        iconSize={iconSize}
        color={color}
        style={index > 0 ? { marginLeft: spacing } : null}
      />
    ));

  return (
    <View {...props} style={[styles.controls, style]}>
      {controls}
    </View>
  );
}

function WindowControlIcon({
  type,
  size,
  color,
}: {
  type: WindowControlButtonType;
  size: number;
  color: string;
}) {
  switch (type) {
    case 'minimize':
      return <View style={[styles.iconLine, { width: size, backgroundColor: color }]} />;
    case 'maximize':
      return (
        <View
          style={[
            styles.iconSquare,
            { width: size, height: size - 1, borderColor: color },
          ]}
        />
      );
    case 'close':
      return (
        <View style={[styles.iconBox, { width: size, height: size }]}>
          <View
            style={[
              styles.iconCross,
              { width: size, backgroundColor: color, transform: [{ rotate: '45deg' }] },
            ]}
          />
          <View
            style={[
              styles.iconCross,
              { width: size, backgroundColor: color, transform: [{ rotate: '-45deg' }] },
            ]}
          />
        </View>
      );
    default:
      return null;
  }
}

const styles = StyleSheet.create({
  controls: {
    flexDirection: 'row',
    alignItems: 'center',
  },
  button: {
    alignItems: 'center',
    justifyContent: 'center',
  },
  buttonDisabled: {
    opacity: 0.5,
  },
  iconLine: {
    height: 1,
    borderRadius: 1,
  },
  iconSquare: {
    borderWidth: 1,
  },
  iconBox: {
    alignItems: 'center',
    justifyContent: 'center',
  },
  iconCross: {
    position: 'absolute',
    height: 1,
    borderRadius: 1,
  },
});
