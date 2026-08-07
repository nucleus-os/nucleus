'use strict';

const { TurboModuleRegistry } = require('react-native');

let rafId = null;
let memTimer = null;
let running = false;

function getPerfTM() {
  return (
    TurboModuleRegistry.get?.('PerfOverlay') ||
    TurboModuleRegistry.get?.('NativePerfOverlay') ||
    TurboModuleRegistry.get?.('NucleusPerf') || // backwards-compat fallback
    null
  );
}

function getNativePerformance() {
  return (
    TurboModuleRegistry.get?.('NativePerformanceCxx') ||
    TurboModuleRegistry.get?.('NativePerformance') || null
  );
}

function loop() {
  const perf = getPerfTM();
  if (!running || !perf) {
    rafId = null;
    return;
  }
  try { perf.recordJsFrame(); } catch (e) {}
  rafId = requestAnimationFrame(loop);
}

function publishMemory() {
  const perfTM = getPerfTM();
  if (!perfTM) return;
  const nativePerf = getNativePerformance();
  if (nativePerf && typeof nativePerf.getSimpleMemoryInfo === 'function') {
    try {
      const info = nativePerf.getSimpleMemoryInfo();
      if (info && typeof info === 'object') {
        perfTM.publishMemory(info);
      }
    } catch (e) {}
  }
}

function start() {
  if (running) return;
  running = true;
  const perf = getPerfTM();
  try { perf?.set_enabled?.(true); perf?.setEnabled?.(true); } catch (e) {}
  loop();
  memTimer = setInterval(publishMemory, 2000);
}

function stop() {
  running = false;
  const perf = getPerfTM();
  try { perf?.set_enabled?.(false); perf?.setEnabled?.(false); } catch (e) {}
  if (rafId != null) cancelAnimationFrame(rafId);
  rafId = null;
  if (memTimer != null) clearInterval(memTimer);
  memTimer = null;
}

function setEnabled(flag) {
  if (flag) start(); else stop();
}

function isEnabled() {
  const perf = getPerfTM();
  if (!perf) return false;
  try {
    if (typeof perf.getEnabled === 'function') return !!perf.getEnabled();
    if (typeof perf.get_enabled === 'function') return !!perf.get_enabled();
  } catch (e) {}
  return false;
}

module.exports = {
  start,
  stop,
  setEnabled,
  isEnabled,
};

// Auto-start if native overlay is enabled at boot (env NUCLEUS_PERF_OVERLAY=1)
try {
  const perf = getPerfTM();
  const enabled =
    (typeof perf?.get_enabled === 'function' ? perf.get_enabled() : perf?.getEnabled?.()) || false;
  if (enabled) start();
} catch (e) {}
