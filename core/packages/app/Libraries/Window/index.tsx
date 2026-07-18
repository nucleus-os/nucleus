/**
 * Window Management API for NUCLEUS
 *
 * Re-exports from @nucleus-os/window with NUCLEUS-specific overlays.
 */

// Re-export everything from the window extension
export {
  WindowManager,
  Zoom,
  ZOOM_CHANGED_EVENT,
  useWindow,
  Titlebar,
  getTitlebarMetrics,
  useTitlebarMetrics,
  useCurrentWindowId,
  useWindowContext,
  WindowProvider,
} from '@nucleus-os/window';

export type {
  WindowManagerSpec,
  WindowCreateOptions,
  WindowDecorations,
  WindowTitlebarOptions,
  TitlebarMetrics,
  TitlebarPlatform,
  ZoomChangedEvent,
  ZoomSpec,
  UseWindowOptions,
  UseWindowResult,
  TitlebarProps,
  WindowContextValue,
  SerializableProps,
} from '@nucleus-os/window';

// Re-export Window component with ContextMenu overlay pre-configured
import React from 'react';
import { Window as BaseWindow, WindowProps as BaseWindowProps, SerializableProps } from '@nucleus-os/window';
import { DefaultContextMenuOverlay } from '../ContextMenu/ContextMenu';

/**
 * Window component with NUCLEUS ContextMenu overlay pre-configured.
 *
 * This is a wrapper around the base Window component that automatically
 * includes the DefaultContextMenuOverlay for context menu support.
 */
export function Window<P extends SerializableProps = SerializableProps>(
  props: BaseWindowProps<P>
) {
  return <BaseWindow {...props} overlay={DefaultContextMenuOverlay} />;
}

export type { BaseWindowProps as WindowProps };
