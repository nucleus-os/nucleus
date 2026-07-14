'use strict';

const path = require('path');
const { resolve: defaultResolve } = require('metro-resolver');
const fs = require('fs');

const DEBUG = Boolean(process.env.NUCLEUS_METRO_DEBUG);

function debugLog(...args) {
  if (DEBUG) {
    console.log('[nucleus-resolver]', ...args);
  }
}

const DEFAULT_FALLBACK_PLATFORMS = ['native', 'ios', undefined];

// Third-party library aliases - auto-detected based on installed packages
const PACKAGE_ALIASES = {
  '@nucleus-os/blur': ['expo-blur'],
  '@nucleus-os/gradient': ['expo-linear-gradient'],
  '@nucleus-os/rnscreens': ['react-native-screens'],
  '@nucleus-os/webview': ['react-native-webview'],
};

function detectInstalledAliases() {
  const aliases = {};
  for (const [shimPackage, aliasedModules] of Object.entries(PACKAGE_ALIASES)) {
    try {
      require.resolve(`${shimPackage}/package.json`);
      // Package is installed, enable aliases
      for (const aliasedModule of aliasedModules) {
        aliases[aliasedModule] = shimPackage;
      }
      debugLog('auto-alias enabled:', aliasedModules.join(', '), '->', shimPackage);
    } catch {
      // Package not installed, skip
    }
  }
  return aliases;
}

function toPosix(p) {
  return p.replace(/\\/g, '/');
}

function stripExtension(moduleName) {
  let result = moduleName;
  let previous;
  do {
    previous = result;
    result = result.replace(/\.(js|jsx|ts|tsx|json)$/i, '');
    result = result.replace(/\.(nucleus|native|ios|android|web)$/i, '');
  } while (result !== previous);
  return result;
}

function canonicalModuleName(moduleName, originModulePath, reactNativeRoot) {
  const normalizedName = toPosix(moduleName);

  if (normalizedName.startsWith('react-native/')) {
    return stripExtension(normalizedName);
  }

  if (!normalizedName.startsWith('.')) {
    // Allow shimming non-RN packages (e.g. `expo-blur`) for the `nucleus` platform.
    // These imports are not relative, so canonicalize by stripping extensions.
    return stripExtension(normalizedName);
  }

  if (!originModulePath) {
    return null;
  }

  const relativeFromRN = path.relative(reactNativeRoot, originModulePath);
  if (!relativeFromRN.startsWith('..')) {
    const originDir = path.posix.dirname(toPosix(relativeFromRN));
    const combined = path.posix.normalize(path.posix.join(originDir, normalizedName));
    const sanitized = combined.replace(/^\.\//, '');
    return stripExtension(`react-native/${sanitized}`);
  }

  const normalizedOrigin = toPosix(originModulePath);
  const markerMatch = normalizedOrigin.match(/(.*\/react-native)(?:\/|$)/);
  if (markerMatch) {
    const rnRoot = markerMatch[1];
    const originWithin = normalizedOrigin.slice(rnRoot.length + 1);
    const originDirWithin = path.posix.dirname(originWithin);
    const combined = path.posix.normalize(path.posix.join(originDirWithin, normalizedName));
    const sanitized = combined.replace(/^\.\//, '');
    return stripExtension(`react-native/${sanitized}`);
  }

  return null;
}

function pathsEqual(a, b) {
  return path.normalize(a) === path.normalize(b);
}

function isResolutionError(error) {
  return Boolean(
    error &&
      typeof error.message === 'string' &&
      error.message.includes('Unable to resolve module'),
  );
}

function ensurePlatforms(existing) {
  const required = ['nucleus', 'ios', 'native', 'android'];
  const next = Array.isArray(existing) ? [...existing] : [];
  for (const platform of required) {
    if (!next.includes(platform)) {
      next.push(platform);
    }
  }
  return next;
}

function createDefaultShimMap({ reactNativeRoot, nucleusRoot }) {
  return {
    'react-native': path.join(reactNativeRoot, 'index.js'),
    'react-native/Libraries/Utilities/Platform': {
      path: path.join(nucleusRoot, 'Libraries', 'Utilities', 'Platform.nucleus.js'),
    },
    'react-native/Libraries/Utilities/codegenNativeComponent': {
      path: path.join(nucleusRoot, 'Libraries', 'Utilities', 'codegenNativeComponent.nucleus.js'),
    },
    'react-native/src/private/devsupport/rndevtools/ReactDevToolsSettingsManager': {
      path: path.join(
        nucleusRoot,
        'src',
        'private',
        'devsupport',
        'rndevtools',
        'ReactDevToolsSettingsManager.nucleus.js',
      ),
    },
    'react-native/src/private/devsupport/rndevtools/setUpFuseboxReactDevToolsDispatcher': {
      path: path.join(
        nucleusRoot,
        'src',
        'private',
        'devsupport',
        'rndevtools',
        'setUpFuseboxReactDevToolsDispatcher.nucleus.js',
      ),
    },
    'react-native/Libraries/NativeComponent/PlatformBaseViewConfig': {
      path: path.join(
        nucleusRoot,
        'Libraries',
        'NativeComponent',
        'PlatformBaseViewConfig.nucleus.js',
      ),
    },
    'react-native/Libraries/NativeComponent/ViewConfigIgnore': {
      path: path.join(
        nucleusRoot,
        'Libraries',
        'NativeComponent',
        'ViewConfigIgnore.nucleus.js',
      ),
    },
    'react-native/Libraries/ReactNative/ReactFabricPublicInstance/ReactNativeAttributePayload': {
      path: path.join(
        nucleusRoot,
        'Libraries',
        'ReactNative',
        'ReactFabricPublicInstance',
        'ReactNativeAttributePayload.nucleus.js',
      ),
    },
    'react-native/Libraries/Image/Image': {
      path: path.join(reactNativeRoot, 'Libraries', 'Image', 'Image.ios.js'),
    },
    'react-native/Libraries/Image/NativeImageLoaderIOS': {
      path: path.join(nucleusRoot, 'Libraries', 'Image', 'NativeImageLoaderNucleus.nucleus.js'),
    },
    'react-native/Libraries/Image/NativeImageLoaderAndroid': {
      path: path.join(nucleusRoot, 'Libraries', 'Image', 'NativeImageLoaderNucleus.nucleus.js'),
    },
    'react-native/Libraries/Utilities/BackHandler': {
      path: path.join(reactNativeRoot, 'Libraries', 'Utilities', 'BackHandler.ios.js'),
    },
    'react-native/Libraries/Network/RCTNetworking': {
      path: path.join(reactNativeRoot, 'Libraries', 'Network', 'RCTNetworking.android.js'),
    },
    'react-native/Libraries/StyleSheet/PlatformColorValueTypes': {
      path: path.join(reactNativeRoot, 'Libraries', 'StyleSheet', 'PlatformColorValueTypes.ios.js'),
    },
    'react-native/Libraries/StyleSheet/processColor': {
      path: path.join(nucleusRoot, 'Libraries', 'StyleSheet', 'processColor.nucleus.js'),
    },
    'react-native/Libraries/Alert/RCTAlertManager': {
      path: path.join(reactNativeRoot, 'Libraries', 'Alert', 'RCTAlertManager.ios.js'),
    },
    'react-native/Libraries/Components/AccessibilityInfo/legacySendAccessibilityEvent': {
      path: path.join(
        reactNativeRoot,
        'Libraries',
        'Components',
        'AccessibilityInfo',
        'legacySendAccessibilityEvent.ios.js',
      ),
    },
    'react-native/Libraries/Core/setUpReactDevTools': {
      path: path.join(reactNativeRoot, 'Libraries', 'Core', 'setUpReactDevTools.js'),
    },
    'react-native/Libraries/ReactNative/AppContainer-dev': {
      path: path.join(
        nucleusRoot,
        'Libraries',
        'ReactNative',
        'AppContainer-dev.nucleus.js',
      ),
    },
    'react-native/Libraries/Components/TextInput/TextInput': {
      path: path.join(
        nucleusRoot,
        'Libraries',
        'Components',
        'TextInput',
        'TextInput.nucleus.js',
      ),
    },
    'react-native/Libraries/Components/TextInput/TextInputState': {
      path: path.join(
        nucleusRoot,
        'Libraries',
        'Components',
        'TextInput',
        'TextInputState.nucleus.js',
      ),
    },
    'react-native/Libraries/Modal/Modal': {
      path: path.join(
        nucleusRoot,
        'Libraries',
        'Modal',
        'Modal.nucleus.js',
      ),
    },
    'react-native/Libraries/Components/Switch/Switch': {
      path: path.join(
        nucleusRoot,
        'Libraries',
        'Components',
        'Switch',
        'Switch.nucleus.tsx',
      ),
    },
  };
}

function resolveWithShim({ shimMap, moduleName, platform, context, reactNativeRoot }) {
  if (platform !== 'nucleus') {
    return null;
  }

  // Explicit platform-qualified RN imports are intentional escapes. Nucleus
  // platform files use these to borrow a concrete upstream implementation
  // without resolving back through the generic Nucleus shim.
  if (/\.(ios|android|native)(?:\.(js|jsx|ts|tsx))?$/i.test(moduleName)) {
    return null;
  }

  const canonicalName = canonicalModuleName(moduleName, context.originModulePath, reactNativeRoot);

  if (!canonicalName) {
    return null;
  }

  const entry = shimMap[canonicalName];
  if (!entry) {
    debugLog('no shim for', canonicalName);
    return null;
  }

  const targetPath = typeof entry === 'string' ? entry : entry.path;
  if (!targetPath) {
    return null;
  }

  if (context.originModulePath && pathsEqual(context.originModulePath, targetPath)) {
    return null;
  }

  debugLog('shim hit', canonicalName, '->', targetPath);
  return { type: 'sourceFile', filePath: targetPath };
}

function resolvePackageRoot(pkgName, providedPath) {
  if (providedPath) {
    return providedPath;
  }
  try {
    const pkgPath = require.resolve(`${pkgName}/package.json`);
    return fs.realpathSync(path.dirname(pkgPath));
  } catch (error) {
    throw new Error(
      `[nucleus-resolver] Could not resolve '${pkgName}'. ` +
        `Install it in your project or pass an explicit path via options.`,
    );
  }
}

function withNucleusResolver(baseConfig = {}, options = {}) {
  const reactNativeRoot = resolvePackageRoot(
    'react-native',
    options.reactNativeRoot ? fs.realpathSync(options.reactNativeRoot) : undefined,
  );
  const nucleusRoot = resolvePackageRoot(
    '@nucleus-os/app',
    options.nucleusRoot ? fs.realpathSync(options.nucleusRoot) : undefined,
  );

  const defaultShims = createDefaultShimMap({ reactNativeRoot, nucleusRoot });
  const userShims = options.shims || {};
  const shimMap = { ...defaultShims, ...userShims };

  // Auto-detect installed shim packages and merge with user-provided aliases
  const detectedAliases = detectInstalledAliases();
  const userAliases = options.aliases || {};
  const packageAliases = { ...detectedAliases, ...userAliases };

  const fallbackPlatforms = options.fallbackPlatforms || DEFAULT_FALLBACK_PLATFORMS;

  const baseResolver = baseConfig.resolver || {};

  // Fall through to Metro's default resolution. We must clear
  // context.resolveRequest before calling defaultResolve, otherwise
  // Metro sees our resolver on the context, calls it, we call
  // defaultResolve again → infinite recursion.
  const resolveWithBase = (context, moduleName, platform) => {
    return defaultResolve({...context, resolveRequest: undefined}, moduleName, platform);
  };

  const resolver = {
    ...baseResolver,
    platforms: ensurePlatforms(baseResolver.platforms),
    resolveRequest(context, moduleName, platform) {
      // Check for third-party package aliases (e.g., expo-blur -> @nucleus-os/blur)
      const aliasTarget = packageAliases[moduleName];
      if (aliasTarget && !context.originModulePath?.includes(aliasTarget)) {
        debugLog('alias redirect:', moduleName, '->', aliasTarget);
        return resolveWithBase(context, aliasTarget, platform);
      }

      const shim = resolveWithShim({
        shimMap,
        moduleName,
        platform,
        context,
        reactNativeRoot,
      });
      if (shim) {
        return shim;
      }

      try {
        const res = resolveWithBase(context, moduleName, platform);
        // If Metro resolved a React Native file from a different copy under the pnpm store,
        // rewrite it to the selected reactNativeRoot so we only ever bundle a single copy.
        if (
          res &&
          res.type === 'sourceFile' &&
          typeof res.filePath === 'string' &&
          res.filePath.includes(`${path.sep}node_modules${path.sep}.pnpm${path.sep}react-native@`) &&
          !toPosix(res.filePath).startsWith(toPosix(reactNativeRoot))
        ) {
          const idx = res.filePath.lastIndexOf(`${path.sep}node_modules${path.sep}react-native${path.sep}`);
          if (idx !== -1) {
            const subPath = res.filePath.slice(
              idx + `${path.sep}node_modules${path.sep}react-native${path.sep}`.length,
            );
            const candidate = path.join(reactNativeRoot, subPath);
            if (fs.existsSync(candidate)) {
              debugLog('rewrite RN path', res.filePath, '->', candidate);
              return { type: 'sourceFile', filePath: candidate };
            }
          }
        }
        return res;
      } catch (error) {
        if (platform !== 'nucleus' || !isResolutionError(error)) {
          throw error;
        }

        for (const fallbackPlatform of fallbackPlatforms) {
          try {
            debugLog(
              'fallback',
              moduleName,
              '->',
              fallbackPlatform === undefined ? '<default>' : fallbackPlatform,
            );
            return resolveWithBase(
              context,
              moduleName,
              fallbackPlatform === undefined ? undefined : fallbackPlatform,
            );
          } catch (fallbackError) {
            if (!isResolutionError(fallbackError)) {
              throw fallbackError;
            }
          }
        }

        debugLog('resolution failed', moduleName);
        throw error;
      }
    },
  };

  return {
    ...baseConfig,
    resolver,
  };
}

module.exports = {
  withNucleusResolver,
  createDefaultShimMap,
};
