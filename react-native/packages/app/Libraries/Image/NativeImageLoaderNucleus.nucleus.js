/**
 * Nucleus ImageLoader TurboModule entrypoint.
 *
 * On Nucleus we implement ImageLoader in Rust TurboModules. This file mirrors the
 * upstream NativeImageLoader* modules, with a safe fallback if the native
 * module is not available.
 */

'use strict';

const { TurboModuleRegistry } = require('react-native');

const NativeImageLoader = TurboModuleRegistry.get?.('ImageLoader');

const Fallback = {
  getConstants() {
    return {};
  },
  getSize() {
    return Promise.resolve({ width: 0, height: 0 });
  },
  getSizeWithHeaders() {
    return Promise.resolve({ width: 0, height: 0 });
  },
  prefetchImage() {
    return Promise.resolve(true);
  },
  prefetchImageWithMetadata() {
    return Promise.resolve(true);
  },
  queryCache() {
    return Promise.resolve({});
  },
  abortRequest() {},
};

module.exports = NativeImageLoader || Fallback;
