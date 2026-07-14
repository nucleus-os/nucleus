/**
 * Nucleus-specific ViewConfigIgnore.
 *
 * This file overrides React Native's ViewConfigIgnore.js to ensure that
 * ConditionallyIgnoredEventHandlers returns event handlers for Nucleus.
 *
 * The original implementation only returns event handlers when Platform.OS === 'ios',
 * which excludes Nucleus (Platform.OS === 'nucleus'). This causes event handlers like
 * onPointerEnter, onScroll, onChange, etc. to be missing from validAttributes,
 * breaking event handling for Views, Images, ScrollViews, TextInputs, etc.
 *
 * This override treats Nucleus like iOS for the purposes of event handler registration.
 */
'use strict';

const ignoredViewConfigProps = new WeakSet();

/**
 * Decorates ViewConfig values that are dynamically injected by the library,
 * react-native-gesture-handler. (T45765076)
 */
function DynamicallyInjectedByGestureHandler(object) {
  ignoredViewConfigProps.add(object);
  return object;
}

/**
 * Nucleus override: Always return the event handlers.
 *
 * The original implementation checks Platform.OS === 'ios' and returns undefined
 * for other platforms. For Nucleus, we need these event handlers to be present.
 */
function ConditionallyIgnoredEventHandlers(value) {
  // Nucleus: Always return the value, treating Nucleus like iOS
  return value;
}

function isIgnored(value) {
  if (typeof value === 'object' && value != null) {
    return ignoredViewConfigProps.has(value);
  }
  return false;
}

module.exports = {
  DynamicallyInjectedByGestureHandler,
  ConditionallyIgnoredEventHandlers,
  isIgnored,
};
