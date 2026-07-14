import React, { useRef } from 'react';
import type { ViewProps, PointerEvent } from 'react-native';

import WindowManager from './WindowManager';
import NativeWindowControlRegion from './specs/WindowControlRegionNativeComponent';
import { useCurrentWindowId } from './WindowContext';
import { useTitlebarMetrics } from './useTitlebarMetrics';

export interface WindowDragRegionProps extends ViewProps {
  windowId?: number;
}

export function WindowDragRegion({
  windowId,
  onPointerDown,
  onPointerMove,
  onPointerUp,
  onPointerCancel,
  ...props
}: WindowDragRegionProps) {
  const shouldStartMoveRef = useRef(false);
  const contextWindowId = useCurrentWindowId();
  const metrics = useTitlebarMetrics(windowId ?? contextWindowId ?? undefined);

  const startWindowMove = () => {
    if (metrics.platform === 'windows') {
      return;
    }
    if (!WindowManager || !WindowManager.startWindowMove) {
      return;
    }
    const resolvedWindowId =
      typeof windowId === 'number'
        ? windowId
        : contextWindowId ?? WindowManager.getRootWindowId();
    if (resolvedWindowId > 0) {
      WindowManager.startWindowMove(resolvedWindowId);
    }
  };

  const handlePointerDown = (event: PointerEvent) => {
    onPointerDown?.(event);
    shouldStartMoveRef.current = true;
  };

  const handlePointerMove = (event: PointerEvent) => {
    onPointerMove?.(event);
    if (!shouldStartMoveRef.current) {
      return;
    }
    shouldStartMoveRef.current = false;
    startWindowMove();
  };

  const handlePointerUp = (event: PointerEvent) => {
    onPointerUp?.(event);
    shouldStartMoveRef.current = false;
  };

  const handlePointerCancel = (event: PointerEvent) => {
    onPointerCancel?.(event);
    shouldStartMoveRef.current = false;
  };

  return (
    <NativeWindowControlRegion
      {...props}
      controlArea="drag"
      onPointerDown={handlePointerDown}
      onPointerMove={handlePointerMove}
      onPointerUp={handlePointerUp}
      onPointerCancel={handlePointerCancel}
    />
  );
}
