import type { TitlebarMetrics } from './WindowManager';
import WindowManager from './WindowManager';

const fallbackMetrics: TitlebarMetrics = {
  height: 34,
  leftInset: 0,
  platform: 'unknown',
};

let cachedMetrics: TitlebarMetrics | null = null;

export function getTitlebarMetrics(windowId?: number): TitlebarMetrics {
  if (cachedMetrics) {
    return cachedMetrics;
  }
  if (!WindowManager || !WindowManager.getTitlebarMetrics) {
    cachedMetrics = fallbackMetrics;
    return cachedMetrics;
  }
  let resolved: TitlebarMetrics | null = null;
  try {
    resolved = WindowManager.getTitlebarMetrics(windowId);
  } catch (error) {
    resolved = null;
  }
  if (
    !resolved ||
    typeof resolved.height !== 'number' ||
    typeof resolved.leftInset !== 'number'
  ) {
    cachedMetrics = fallbackMetrics;
    return cachedMetrics;
  }
  cachedMetrics = resolved;
  return cachedMetrics;
}

export function useTitlebarMetrics(windowId?: number): TitlebarMetrics {
  return getTitlebarMetrics(windowId);
}
