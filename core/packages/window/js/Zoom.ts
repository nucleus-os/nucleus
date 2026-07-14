/**
 * Browser-like zoom control (per-surface).
 *
 * Zoom is implemented natively as a LU→PU unit conversion:
 * - LU: layout units (React Native / Yoga)
 * - PU: Nucleus paint/hit-test units
 */
import { TurboModuleRegistry } from 'react-native';
import type { TurboModule } from 'react-native';

export interface ZoomSpec extends TurboModule {
  getZoom(surfaceId?: number): number;
  setZoom(zoom: number, surfaceId?: number): number;
  resetZoom(surfaceId?: number): number;
  zoomIn(surfaceId?: number): number;
  zoomOut(surfaceId?: number): number;

  getNativeOverlayEnabled(): boolean;
  setNativeOverlayEnabled(enabled: boolean): void;

  getShortcutsEnabled(): boolean;
  setShortcutsEnabled(enabled: boolean): void;
}

export type ZoomChangedEvent = {
  surfaceId: number;
  oldZoom: number;
  newZoom: number;
};

export const ZOOM_CHANGED_EVENT = 'zoomChanged';

export const Zoom = TurboModuleRegistry.get<ZoomSpec>('Zoom');

if (!Zoom) {
  console.warn('Zoom TurboModule not found');
}

export default Zoom;
