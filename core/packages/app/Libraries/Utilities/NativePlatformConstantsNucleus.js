/**
 * Nucleus Platform Constants
 *
 * Provides platform-specific constants for the Nucleus platform
 */

'use strict';

let cachedConstants = null;

function getConstants() {
  if (cachedConstants) {
    return cachedConstants;
  }

  // Get React Native version
  let reactNativeVersion = {
    major: 0,
    minor: 86,
    patch: 0,
    prerelease: 'rc.0',
  };
  try {
    const versionModule = require('react-native/Libraries/Core/ReactNativeVersion');
    if (versionModule && versionModule.version) {
      reactNativeVersion = versionModule.version;
    }
  } catch (e) {
    // Use fallback version
  }

  // Get Nucleus version from package.json
  let nucleusVersion = '0.1.0';
  try {
    const packageJson = require('../../package.json');
    if (packageJson && packageJson.version) {
      nucleusVersion = packageJson.version;
    }
  } catch (e) {
    // Use fallback version
  }

  cachedConstants = {
    // Force version as a string for compatibility
    forceTouchAvailable: false,
    osVersion: nucleusVersion,
    systemName: 'Nucleus',

    // React Native version
    reactNativeVersion: reactNativeVersion,

    // Device info
    isTesting: false,
    isDisableAnimations: false,

    // Nucleus-specific
    platform: 'nucleus',
    Version: nucleusVersion,

    // Desktop-specific (not a tablet)
    interfaceIdiom: 'desktop',

    // Screen info - will be updated by Dimensions
    // These are just defaults that will be overwritten
    screen: {
      width: 1280,
      height: 720,
      scale: 1,
      fontScale: 1,
    },
  };

  return cachedConstants;
}

module.exports = {
  getConstants,
};
