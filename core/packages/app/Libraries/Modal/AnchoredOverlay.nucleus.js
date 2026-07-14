/**
 * Anchored overlay helpers for window-space positioning.
 *
 * @flow
 * @format
 */

'use strict';

import { Dimensions } from 'react-native';

const UIManager = require('react-native/Libraries/ReactNative/UIManager');

export function getSurfaceOrigin(surfaceId: number): ?{x: number, y: number} {
  if (!UIManager.getSurfaceOrigin) {
    return null;
  }
  return UIManager.getSurfaceOrigin(surfaceId);
}

export function getSurfaceBounds(surfaceId: number): ?{
  x: number,
  y: number,
  width: number,
  height: number,
  windowWidth?: number,
  windowHeight?: number,
} {
  if (!UIManager.getSurfaceBounds) {
    return null;
  }
  return UIManager.getSurfaceBounds(surfaceId);
}

export function measureInSurface(
  surfaceId: number,
  tag: number,
  callback: (x: number, y: number, width: number, height: number) => void
) {
  if (UIManager.measureInSurface) {
    UIManager.measureInSurface(surfaceId, tag, callback);
    return;
  }

  const origin = getSurfaceOrigin(surfaceId);
  UIManager.measureInWindow(tag, (x: number, y: number, width: number, height: number) => {
    if (!origin) {
      callback(x, y, width, height);
      return;
    }
    callback(x - origin.x, y - origin.y, width, height);
  });
}

export function computeAnchoredOverlayLayout({
  anchorRect,
  placement = 'auto',
  offset = 0,
  maxHeight = 0,
  minWidth = 0,
  clampToWindow = true,
  windowBounds,
}: {
  anchorRect: {x: number, y: number, width: number, height: number},
  placement?: 'auto' | 'up' | 'down',
  offset?: number,
  maxHeight?: number,
  minWidth?: number,
  clampToWindow?: boolean,
  windowBounds?: {width: number, height: number},
}): {
  placement: 'up' | 'down',
  left: number,
  top?: number,
  bottom?: number,
  minWidth: number,
  maxHeight: number,
} {
  const windowSize = windowBounds || Dimensions.get('window');
  const gap = offset;
  const desiredMaxHeight = maxHeight > 0 ? maxHeight : windowSize.height;

  const spaceBelow = Math.max(
    0,
    windowSize.height - (anchorRect.y + anchorRect.height) - gap
  );
  const spaceAbove = Math.max(0, anchorRect.y - gap);

  const openUpwards =
    placement === 'up'
      ? true
      : placement === 'down'
        ? false
        : spaceBelow < desiredMaxHeight && spaceAbove > spaceBelow;

  const availableSpace = openUpwards ? spaceAbove : spaceBelow;
  let resolvedMaxHeight = Math.max(0, Math.min(desiredMaxHeight, availableSpace));
  if (resolvedMaxHeight > 0 && resolvedMaxHeight < 120 && availableSpace > resolvedMaxHeight) {
    resolvedMaxHeight = availableSpace;
  }
  const resolvedMinWidth = Math.max(minWidth, anchorRect.width);

  let left = anchorRect.x;
  if (clampToWindow) {
    const maxLeft = Math.max(0, windowSize.width - resolvedMinWidth);
    left = Math.min(Math.max(0, left), maxLeft);
  }

  if (openUpwards) {
    return {
      placement: 'up',
      left,
      bottom: windowSize.height - anchorRect.y + gap,
      minWidth: resolvedMinWidth,
      maxHeight: resolvedMaxHeight,
    };
  }

  return {
    placement: 'down',
    left,
    top: anchorRect.y + anchorRect.height + gap,
    minWidth: resolvedMinWidth,
    maxHeight: resolvedMaxHeight,
  };
}

export function computeAnchoredOverlayFromTag({
  tag,
  placement = 'auto',
  offset = 0,
  maxHeight = 0,
  minWidth = 0,
  clampToWindow = true,
  windowBounds,
}: {
  tag: number,
  placement?: 'auto' | 'up' | 'down',
  offset?: number,
  maxHeight?: number,
  minWidth?: number,
  clampToWindow?: boolean,
  windowBounds?: {width: number, height: number},
}, callback: (
  layout: {
    placement: 'up' | 'down',
    left: number,
    top?: number,
    bottom?: number,
    minWidth: number,
    maxHeight: number,
  }
) => void) {
  UIManager.measureInWindow(
    tag,
    (x: number, y: number, width: number, height: number) => {
      const layout = computeAnchoredOverlayLayout({
        anchorRect: {x, y, width, height},
        placement,
        offset,
        maxHeight,
        minWidth,
        clampToWindow,
        windowBounds,
      });
      callback(layout);
    }
  );
}
