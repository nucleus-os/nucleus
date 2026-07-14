'use strict';

import type {ColorValue, NativeColorValue} from 'react-native/Libraries/StyleSheet/StyleSheet';

const normalizeColor = require('react-native/Libraries/StyleSheet/normalizeColor').default;

export type ProcessedColorValue = number | NativeColorValue;

/* eslint no-bitwise: 0 */
function processColor(color?: ?(number | ColorValue)): ?ProcessedColorValue {
  if (color === undefined || color === null) {
    return color;
  }

  let normalizedColor = normalizeColor(color);
  if (normalizedColor === null || normalizedColor === undefined) {
    return undefined;
  }

  if (typeof normalizedColor === 'object') {
    const processColorObject =
      require('react-native/Libraries/StyleSheet/PlatformColorValueTypes').processColorObject;

    const processedColorObj = processColorObject(normalizedColor);

    if (processedColorObj != null) {
      return processedColorObj;
    }
  }

  if (typeof normalizedColor !== 'number') {
    return null;
  }

  // Converts 0xrrggbbaa into signed 0xaarrggbb, matching the integer shape
  // consumed by ReactCommon's cxx PlatformColorParser.
  return (((normalizedColor << 24) | (normalizedColor >>> 8)) >>> 0) | 0x0;
}

export default processColor;
