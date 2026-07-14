/**
 * Nucleus shim for codegenNativeComponent.
 *
 * React Native warns in bridgeless mode when codegen didn't inline view configs.
 * For Nucleus we rely on the native ViewConfig interop layer, so we skip the warning.
 */
'use strict';

const requireNativeComponentModule = require('react-native/Libraries/ReactNative/requireNativeComponent');
const requireNativeComponent =
  typeof requireNativeComponentModule === 'function'
    ? requireNativeComponentModule
    : requireNativeComponentModule?.default || requireNativeComponentModule?.requireNativeComponent;
const UIManager = require('react-native/Libraries/ReactNative/UIManager');

function codegenNativeComponent(componentName, options) {
  let componentNameInUse =
    options && options.paperComponentName != null ? options.paperComponentName : componentName;

  if (options != null && options.paperComponentNameDeprecated != null) {
    if (UIManager.hasViewManagerConfig(componentName)) {
      componentNameInUse = componentName;
    } else if (
      options.paperComponentNameDeprecated != null &&
      UIManager.hasViewManagerConfig(options.paperComponentNameDeprecated)
    ) {
      componentNameInUse = options.paperComponentNameDeprecated;
    } else {
      throw new Error(
        `Failed to find native component for either ${componentName} or ${
          options.paperComponentNameDeprecated ?? '(unknown)'
        }`,
      );
    }
  }

  return requireNativeComponent(componentNameInUse);
}

module.exports = codegenNativeComponent;
module.exports.default = codegenNativeComponent;
