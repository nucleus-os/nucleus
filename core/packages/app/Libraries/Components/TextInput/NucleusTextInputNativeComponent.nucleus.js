/**
 * Nucleus TextInput native component.
 *
 * This is a lightweight bridge that lets RN's JS TextInput implementation
 * render a host component and invoke the standard commands:
 * - focus
 * - blur
 * - setTextAndSelection
 *
 * Phase 1: the native host may be a fallback/unimplemented view; this file
 * just ensures module resolution and command wiring are in place.
 */
'use strict';

const NativeComponentRegistry = require('react-native/Libraries/NativeComponent/NativeComponentRegistry');

const codegenNativeCommandsModule = require('react-native/Libraries/Utilities/codegenNativeCommands');
const codegenNativeCommands =
  codegenNativeCommandsModule.default ?? codegenNativeCommandsModule;
const TextInputViewConfigModule = require('react-native/Libraries/Components/TextInput/RCTTextInputViewConfig');
const TextInputViewConfig = TextInputViewConfigModule.default ?? TextInputViewConfigModule;

// Keep parity with react-native/Libraries/Components/TextInput/TextInputNativeCommands.js
const supportedCommands = ['focus', 'blur', 'setTextAndSelection'];

// flowlint-next-line unclear-type:off
const Commands = codegenNativeCommands({
  supportedCommands,
});

const __INTERNAL_VIEW_CONFIG = {
  uiViewClassName: 'TextInput',
  ...TextInputViewConfig,
};

const NucleusTextInputNativeComponent = NativeComponentRegistry.get(
  'TextInput',
  () => __INTERNAL_VIEW_CONFIG,
);

// In Nucleus, host components may be represented as strings (e.g. "TextInput").
// Export an object so we can safely attach `default` and `Commands` regardless.
module.exports = {
  __esModule: true,
  default: NucleusTextInputNativeComponent,
  Commands,
};
