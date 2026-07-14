// Metro config for the shell's RN app. Mirrors the RN platform's app template: the "nucleus"
// platform, the Nucleus metro resolver (so @nucleus-os/* and the render-native modules resolve
// against the monorepo core), and the Babel config the platform ships.
const path = require("path");

const nucleusCore = path.resolve(__dirname, "../../../core");
const reactNativePlatform = path.resolve(__dirname, "../../../react-native");
const reactNativeRoot = path.resolve(reactNativePlatform, "third-party/react-native/packages/react-native");
const { withNucleusResolver } = require(path.join(
  nucleusCore,
  "packages/metro-resolver",
));

const config = {
  projectRoot: path.resolve(__dirname, ".."),
  watchFolders: [nucleusCore, reactNativePlatform, reactNativeRoot],
  resolver: {
    // The platform's metro resolver maps @nucleus-os/* + the "nucleus" platform shims.
    resolverMainFields: ["nucleus", "react-native", "browser", "main"],
    platforms: ["nucleus"],
    nodeModulesPaths: [
      path.resolve(__dirname, "../node_modules"),
      path.resolve(reactNativePlatform, "third-party/react-native/node_modules"),
    ],
    extraNodeModules: {
      "@nucleus-os/app": path.resolve(nucleusCore, "packages/app"),
      "@nucleus-os/window": path.resolve(nucleusCore, "packages/window"),
      "@nucleus-os/metro-resolver": path.resolve(nucleusCore, "packages/metro-resolver"),
      react: path.resolve(__dirname, "../node_modules/react"),
      "react-native": reactNativeRoot,
    },
  },
};

module.exports = withNucleusResolver(config, {
  reactNativeRoot,
  nucleusRoot: path.resolve(nucleusCore, "packages/app"),
});
