'use strict';

function defineLazyObjectProperty(object, name, descriptor) {
  if (!descriptor || typeof descriptor.get !== 'function') {
    throw new TypeError('Expected descriptor.get to be a function');
  }
  const enumerable = descriptor.enumerable !== false;
  const writable = descriptor.writable !== false;

  let value;
  let valueSet = false;

  function getValue() {
    if (!valueSet) {
      valueSet = true;
      setValue(descriptor.get());
    }
    return value;
  }

  function setValue(newValue) {
    value = newValue;
    valueSet = true;
    Object.defineProperty(object, name, {
      value: newValue,
      configurable: true,
      enumerable,
      writable,
    });
  }

  Object.defineProperty(object, name, {
    configurable: true,
    enumerable,
    get: getValue,
    set: setValue,
  });
}

function logPolyfillEvent(event) {
  try {
    const log =
      global.__nucleusPolyfillLog && Array.isArray(global.__nucleusPolyfillLog)
        ? global.__nucleusPolyfillLog
        : (global.__nucleusPolyfillLog = []);
    log.push({
      name: event.name,
      stage: event.stage,
      message: event.message,
      typeofValue: event.typeofValue,
      stack: event.stack,
    });
  } catch (_err) {
    // Ignore logging failures.
  }
}

function polyfillObjectProperty(object, name, getValue) {
  if (typeof getValue !== 'function') {
    try {
      logPolyfillEvent({
        name,
        stage: 'invalid-getter',
        message: typeof getValue,
      });
    } catch (_err) {}
    throw new TypeError(
      `[nucleus_polyfill] Expected getter function for ${name}, received ${typeof getValue}`,
    );
  }
  try {
    logPolyfillEvent({
      name,
      stage: 'start',
      typeofValue: typeof object[name],
      message: new Error().stack,
    });
  } catch (_err) {}
  const descriptor = Object.getOwnPropertyDescriptor(object, name);
  if (__DEV__ && descriptor) {
    const backupName = `original${name[0].toUpperCase()}${name.slice(1)}`;
    Object.defineProperty(object, backupName, descriptor);
  }

  const { enumerable, writable, configurable = false } = descriptor || {};
  if (descriptor && !configurable) {
    try {
      logPolyfillEvent({
        name,
        stage: 'skipped',
        message: 'descriptor not configurable',
        typeofValue: typeof object[name],
      });
    } catch (_err) {}
    if (typeof console !== 'undefined' && console && typeof console.error === 'function') {
      console.error('Failed to set polyfill. ' + name + ' is not configurable.');
    }
    return;
  }

  let resolvedValue;
  try {
    resolvedValue = getValue();
    try {
      logPolyfillEvent({
        name,
        stage: 'resolved',
        typeofValue: typeof resolvedValue,
      });
    } catch (_err) {}
  } catch (error) {
    try {
      logPolyfillEvent({
        name,
        stage: 'resolve-error',
        message: error && error.message ? error.message : String(error),
      });
    } catch (_err) {}
    throw error;
  }

  try {
    defineLazyObjectProperty(object, name, {
      get: getValue,
      enumerable: enumerable !== false,
      writable: writable !== false,
    });
    try {
      logPolyfillEvent({
        name,
        stage: 'installed',
        typeofValue: typeof object[name],
      });
    } catch (_err) {}
  } catch (error) {
    try {
      logPolyfillEvent({
        name,
        stage: 'install-error',
        message: error && error.message ? error.message : String(error),
      });
    } catch (_err) {}
    throw error;
  }
}

function polyfillGlobal(name, getValue) {
  polyfillObjectProperty(global, name, getValue);
}

module.exports = {
  polyfillGlobal,
  polyfillObjectProperty,
};
