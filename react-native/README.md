# Nucleus React Native

`react-native/` owns the complete React Native platform: the first-party Bun workspace and its JavaScript packages, Hermes, Fabric, JSI integration, TurboModules, and the bridge from RN commits into the Nucleus render/UI core.

The Bun workspace lives at this directory root. Its packages are `@nucleus-os/app`,
`@nucleus-os/window`, and `@nucleus-os/metro-resolver`; its dependency graph is
locked by `bun.lock`. The exact published React Native package under
`node_modules/react-native` supplies the JavaScript runtime, generated TypeScript
declarations, codegen scripts, ReactCommon, and generated FBReactNativeSpec
sources. The matching canonical React Native gitlink supplies only
`ReactCxxPlatform`, which the npm package omits. The separate Hermes checkout
remains the source of the engine Nucleus compiles.

It consumes the render SDK owned by `core/` and owns `rn` within each
per-target native SDK root, such as
`~/.cache/nucleus/nucleus-native-sdk/linux-arm64/rn`. Generated and native
build intermediates and compiler caches live in component-and-target-specific
Collider workspaces; only finished libraries and generated public headers enter
the staged native SDK. The React Native gitlink is an unmodified source-only
input, not a JavaScript dependency workspace.

Provision and verify from the repository root:

```sh
collider bootstrap rn
collider build rn
collider test rn
```

The first-party runtime is part of the root manifest, not a standalone package. `NucleusReactRuntime` is the supported external Swift product; bridge modules remain implementation details unless a documented external consumer requires them.
