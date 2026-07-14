# @nucleus-os/metro-resolver

Helper for wiring Nucleus into Metro. It adds a resolver that:

- understands the `nucleus` platform extension but falls back to `native` and `ios`
- redirects a set of React Native modules to Nucleus-specific shims
- still allows additional shims to be layered on by the host application

## Usage

```js
// metro.config.js
const path = require('path');
const { getDefaultConfig, mergeConfig } = require('@react-native/metro-config');
const { withNucleusResolver } = require('@nucleus-os/metro-resolver');

const base = getDefaultConfig(__dirname);

module.exports = withNucleusResolver(
  mergeConfig(base, {
    projectRoot: __dirname,
    watchFolders: [path.resolve(__dirname, '..', '..', 'packages')],
  }),
  {
    // Optional overrides if your packages live in custom locations:
    // reactNativeRoot: path.resolve(__dirname, 'node_modules/react-native'),
    // nucleusRoot: path.resolve(__dirname, 'node_modules/@nucleus-os/app'),
  },
);
```

You can supply extra shims if your app needs them:

```js
module.exports = withNucleusResolver(config, {
  shims: {
    'react-native/Libraries/Whatever': '/absolute/path/to/custom.js',
  },
});
```

The package assumes `react-native` and `@nucleus-os/app` are already installed in your repository.
