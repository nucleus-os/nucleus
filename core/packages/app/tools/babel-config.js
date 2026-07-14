/* eslint-disable import/no-commonjs */
'use strict';

const DEFAULT_PRESET = 'module:@react-native/babel-preset';

function makeNucleusBabelConfig(options = {}) {
  const {
    reactCompiler = true,
    reanimated = true,
    extraPlugins = [],
  } = options;

  const plugins = [];

  if (reactCompiler) {
    // React Compiler should run before other plugins.
    // Configure sources to exclude node_modules from compilation.
    plugins.push([
      'babel-plugin-react-compiler',
      {
        sources: filename => {
          // Only compile app code, not node_modules
          return !filename.includes('node_modules');
        },
      },
    ]);
  }

  if (Array.isArray(extraPlugins) && extraPlugins.length > 0) {
    plugins.push(...extraPlugins);
  }

  if (reanimated) {
    // Worklets plugin transforms 'worklet' directives — must run last.
    plugins.push('react-native-worklets/plugin');
  }

  const config = {
    presets: [DEFAULT_PRESET],
  };

  if (plugins.length > 0) {
    config.plugins = plugins;
  }

  return config;
}

module.exports = {
  makeNucleusBabelConfig,
};
