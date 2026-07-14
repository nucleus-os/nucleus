'use strict';

// Provide a Nucleus base view config by reusing the iOS defaults.
// This avoids falling back to the generic implementation (which becomes undefined on
// unknown platforms) and ensures pointer/touch event types are present.
//
// Note: Event handler validAttributes are properly included because Nucleus shims
// ViewConfigIgnore.js to make ConditionallyIgnoredEventHandlers return values
// for Nucleus (the original only returns them for Platform.OS === 'ios').

const BaseModule = require('react-native/Libraries/NativeComponent/BaseViewConfig.ios');
const BaseViewConfig = BaseModule && BaseModule.__esModule ? BaseModule.default : BaseModule;

module.exports = BaseViewConfig;
module.exports.default = BaseViewConfig;
