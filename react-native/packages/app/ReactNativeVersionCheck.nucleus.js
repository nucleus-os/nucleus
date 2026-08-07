'use strict';

const Platform = require('./Platform.nucleus');

const ReactNativeVersion = require('react-native/Libraries/Core/ReactNativeVersion');

function formatVersion(version) {
  return (
    `${version.major}.${version.minor}.${version.patch}` +
    (version.prerelease != null ? `-${version.prerelease}` : '')
  );
}

function checkVersions() {
  const nativeVersion = Platform.constants.reactNativeVersion;
  if (
    ReactNativeVersion.version.major !== nativeVersion.major ||
    ReactNativeVersion.version.minor !== nativeVersion.minor
  ) {
    console.error(
      `React Native version mismatch.\n\nJavaScript version: ${formatVersion(
        ReactNativeVersion.version,
      )}\n` +
        `Native version: ${formatVersion(nativeVersion)}\n\n` +
        'Make sure that you have rebuilt the native code. If the problem ' +
        'persists try clearing the Watchman and packager caches with ' +
        '`watchman watch-del-all && npx react-native start --reset-cache`.',
    );
  }
}

module.exports = {
  checkVersions,
};
