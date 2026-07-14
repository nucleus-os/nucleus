'use strict';

// Nucleus Platform shim.
// Start from the iOS implementation for sensible defaults, but
// advertise a distinct OS and add a nucleus-aware select().

let BasePlatform;
try {
  // Prefer iOS semantics until nucleus-specific constants are ready.
  // react-native ships this path; Metro will resolve it from node_modules.
  // eslint-disable-next-line import/no-extraneous-dependencies
  // $FlowFixMe
  BasePlatform = require('react-native/Libraries/Utilities/Platform.ios.js');
  BasePlatform = BasePlatform && BasePlatform.__esModule ? BasePlatform.default : BasePlatform;
} catch (e) {
  // Fallback to the generic wrapper if direct import fails.
  // $FlowFixMe
  const Fallback = require('react-native/Libraries/Utilities/Platform');
  BasePlatform = Fallback && Fallback.__esModule ? Fallback.default : Fallback;
}

const baseDescriptors = Object.getOwnPropertyDescriptors(BasePlatform);
const baseConstantsGetter =
  baseDescriptors.constants && typeof baseDescriptors.constants.get === 'function'
    ? baseDescriptors.constants.get.bind(BasePlatform)
    : null;

const Platform = {};
Object.defineProperties(Platform, baseDescriptors);

Object.defineProperty(Platform, 'OS', {
  configurable: true,
  enumerable: true,
  value: 'nucleus',
  writable: false,
});

let nativeConstantsModule;
let RNVersion;
let attemptedNativeConstants = false;
function getNativeConstantsModule() {
  if (!attemptedNativeConstants) {
    attemptedNativeConstants = true;
    try {
      // Try to load Nucleus-specific constants first
      nativeConstantsModule = require('./NativePlatformConstantsNucleus');
      if (
        nativeConstantsModule &&
        nativeConstantsModule.__esModule &&
        nativeConstantsModule.default
      ) {
        nativeConstantsModule = nativeConstantsModule.default;
      }
    } catch (err) {
      // Fall back to iOS constants if Nucleus module not found
      try {
        // eslint-disable-next-line import/no-extraneous-dependencies
        nativeConstantsModule = require('react-native/Libraries/Utilities/NativePlatformConstantsIOS');
        if (
          nativeConstantsModule &&
          nativeConstantsModule.__esModule &&
          nativeConstantsModule.default
        ) {
          nativeConstantsModule = nativeConstantsModule.default;
        }
      } catch (err2) {
        nativeConstantsModule = null;
      }
    }
  }
  return nativeConstantsModule;
}

Object.defineProperty(Platform, 'constants', {
  configurable: true,
  enumerable: true,
  get() {
    const module = getNativeConstantsModule();
    if (module && typeof module.getConstants === 'function') {
      try {
        return module.getConstants();
      } catch (err) {
        // Fall back to the base platform getter if the TurboModule throws.
      }
    }
    try {
      if (!RNVersion) {
        const vmod = require('react-native/Libraries/Core/ReactNativeVersion');
        RNVersion = vmod && vmod.version ? vmod.version : null;
      }
    } catch (_) {}
    const fallback = baseConstantsGetter ? baseConstantsGetter() : BasePlatform.constants;
    // Ensure reactNativeVersion is present to satisfy version checks.
    if (fallback && !fallback.reactNativeVersion && RNVersion) {
      return { ...fallback, reactNativeVersion: RNVersion };
    }
    return (
      fallback || {
        reactNativeVersion: RNVersion || { major: 0, minor: 0, patch: 0, prerelease: null },
      }
    );
  },
});

// Allow Platform.select({ nucleus, ios, native, default })
Platform.select = function select(spec) {
  if (spec == null) {
    return typeof BasePlatform.select === 'function' ? BasePlatform.select(spec) : spec;
  }

  if (Object.prototype.hasOwnProperty.call(spec, 'nucleus')) {
    return spec.nucleus;
  }

  const fallback =
    typeof BasePlatform.select === 'function'
      ? BasePlatform.select(spec)
      : (spec.native ?? spec.default);

  const androidBranch =
    spec && Object.prototype.hasOwnProperty.call(spec, 'android') ? spec.android : undefined;

  if (
    fallback != null &&
    typeof fallback === 'object' &&
    !Array.isArray(fallback) &&
    androidBranch != null &&
    typeof androidBranch === 'object'
  ) {
    // Copy the iOS branch and backfill any APIs that only exist on Android.
    // The bridgeless UIManager expects helpers such as
    // getConstantsForViewManager, which Android defines today.
    const merged = { ...fallback };
    for (const key of Object.keys(androidBranch)) {
      if (!Object.prototype.hasOwnProperty.call(merged, key)) {
        merged[key] = androidBranch[key];
      }
    }
    return merged;
  }

  return fallback;
};

// Match React Native's module shape: default export object.
// Many RN entry points access `require('.../Platform').default`.
module.exports = Platform;
module.exports.default = Platform;
