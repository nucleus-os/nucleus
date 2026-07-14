'use strict';

// Minimal shim for React DevTools settings manager when RN package does not
// publish the private src module. We keep settings in a global so DevTools can
// persist across reloads within the same Metro session.

function getGlobalHookSettings() {
  try {
    return global.__RN_DEVTOOLS_HOOK_SETTINGS__ ?? null;
  } catch (_) {
    return null;
  }
}

function setGlobalHookSettings(serialized) {
  try {
    global.__RN_DEVTOOLS_HOOK_SETTINGS__ = serialized;
  } catch (_) {}
}

module.exports = {
  getGlobalHookSettings,
  setGlobalHookSettings,
};
