/* eslint-disable import/no-commonjs */
'use strict';

const fs = require('fs');
const path = require('path');

function resolveFrom(moduleId, appRoot) {
  return require.resolve(moduleId, {paths: [appRoot]});
}

function requireFrom(moduleId, appRoot) {
  return require(resolveFrom(moduleId, appRoot));
}

function resolveOptionalFrom(moduleId, appRoot) {
  try {
    return resolveFrom(moduleId, appRoot);
  } catch {
    return null;
  }
}

function resolvePackageDir(moduleId, appRoot) {
  const entryPath = fs.realpathSync(resolveFrom(moduleId, appRoot));
  let dir = path.dirname(entryPath);
  while (dir !== path.dirname(dir)) {
    if (fs.existsSync(path.join(dir, 'package.json'))) {
      return dir;
    }
    dir = path.dirname(dir);
  }
  return path.dirname(entryPath);
}

function escapeForRegex(str) {
  return String(str).replace(/[-/\\^$*+?.()|[\]{}]/g, r => `\\${r}`);
}

/**
 * Create Metro config for Nucleus apps.
 *
 * Assumes pnpm hoisted layout (node-linker=hoisted in .npmrc) — all deps
 * are flat in the monorepo root node_modules/, no symlinks to resolve.
 *
 * Usage:
 *   const {makeMetroConfig} = require('@nucleus-os/app/tools/metro-config');
 *   module.exports = makeMetroConfig(__dirname);
 */
function makeMetroConfig(appRoot) {
  const reactNativeRoot = resolvePackageDir('react-native', appRoot);
  const nucleusRoot = resolvePackageDir('@nucleus-os/app', appRoot);

  const {getDefaultConfig, mergeConfig} = requireFrom('@react-native/metro-config', appRoot);
  const {withNucleusResolver} = requireFrom('@nucleus-os/metro-resolver', nucleusRoot);

  const monorepoRoot = nucleusRoot ? path.resolve(nucleusRoot, '../..') : path.resolve(appRoot, '../..');

  // Nitrogen generates JSON configs outside the app's project root.
  const watchFolders = [];
  const nitrogenGeneratedDir = path.resolve(monorepoRoot, 'nitrogen/generated');
  if (fs.existsSync(nitrogenGeneratedDir)) {
    watchFolders.push(nitrogenGeneratedDir);
  }

  // Exclude non-JS directories from Metro's file watcher.
  const blockListPatterns = [];
  for (const dir of ['target', 'third-party', 'cmake', 'cpp', 'crates', 'nitrogen/generated/c++']) {
    const fullPath = path.resolve(monorepoRoot, dir);
    if (fs.existsSync(fullPath)) {
      blockListPatterns.push(`^${escapeForRegex(fullPath)}/.*$`);
    }
  }

  const baseConfig = getDefaultConfig(appRoot);
  const defaultSourceExts = baseConfig.resolver?.sourceExts || [];

  const config = mergeConfig(baseConfig, {
    projectRoot: monorepoRoot,
    watchFolders,
    resolver: {
      nodeModulesPaths: [
        path.resolve(appRoot, 'node_modules'),
      ],
      platforms: ['nucleus', 'ios', 'native', 'android'],
      sourceExts: Array.from(new Set([...defaultSourceExts, 'ts', 'tsx', 'nucleus.ts', 'nucleus.tsx'])),
      ...(blockListPatterns.length > 0
        ? {blockList: new RegExp(blockListPatterns.join('|'))}
        : {}),
    },
    serializer: {
      getModulesRunBeforeMainModule: () => [
        resolveFrom('react-native/Libraries/Core/InitializeCore', appRoot),
      ],
    },
  });

  // Safe-area-context shim — Nucleus provides its own implementation
  const shims = {
    'react-native-safe-area-context': {
      path: path.join(nucleusRoot, 'src', 'shims', 'react-native-safe-area-context.nucleus.tsx'),
    },
  };

  let result = withNucleusResolver(config, {
    reactNativeRoot,
    nucleusRoot,
    shims,
  });

  // Auto-configure reanimated if installed
  const reanimatedMetroPath = resolveOptionalFrom('react-native-reanimated/metro-config', appRoot);
  if (reanimatedMetroPath) {
    const {wrapWithReanimatedMetroConfig} = require(reanimatedMetroPath);
    result = wrapWithReanimatedMetroConfig(result);
  }

  return result;
}

module.exports = {makeMetroConfig};
