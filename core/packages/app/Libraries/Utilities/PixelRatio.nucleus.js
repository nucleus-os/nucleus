/**
 * Nucleus PixelRatio Implementation
 *
 * Provides pixel ratio utilities for the Nucleus platform
 */

'use strict';

const Dimensions = require('react-native/Libraries/Utilities/Dimensions');

class PixelRatio {
  /**
   * Returns the device pixel density.
   * For Nucleus (desktop), this is typically 1.0, 1.5, 2.0, or higher for Retina displays.
   */
  static get() {
    const dimensions = Dimensions.get('window');
    return dimensions.scale || 1;
  }

  /**
   * Returns the font scale factor.
   * Desktop platforms may have accessibility font scaling.
   */
  static getFontScale() {
    const dimensions = Dimensions.get('window');
    return dimensions.fontScale || 1;
  }

  /**
   * Converts a layout size (dp) to pixel size (px).
   */
  static getPixelSizeForLayoutSize(layoutSize) {
    return Math.round(layoutSize * PixelRatio.get());
  }

  /**
   * Rounds a layout size to the nearest pixel.
   * Use this to avoid sub-pixel rendering artifacts.
   */
  static roundToNearestPixel(layoutSize) {
    const ratio = PixelRatio.get();
    return Math.round(layoutSize * ratio) / ratio;
  }

  /**
   * Returns the pixel density as a string.
   * For debugging purposes.
   */
  static toString() {
    return `PixelRatio(${PixelRatio.get()})`;
  }
}

module.exports = PixelRatio;
