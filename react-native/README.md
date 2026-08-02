# Nucleus React Native

`react-native/` owns the React Native platform targets inside the root SwiftPM package: Hermes, Fabric, JSI integration, TurboModules, and the bridge from RN commits into the Nucleus render/UI core.

It consumes the render SDK owned by `core/` and owns the RN native SDK under `~/.cache/nucleus/nucleus-native-sdk/rn`. Generated and native outputs remain under `react-native/.rn-build` and `react-native/.cxx-build`; the vendored React Native tree stays unmodified.

Provision and verify from the repository root:

```sh
collider bootstrap rn
collider generate rn-spec
collider build rn
collider test rn
```

The first-party runtime is part of the root manifest, not a standalone package. `NucleusReactRuntime` is the supported external Swift product; bridge modules remain implementation details unless a documented external consumer requires them.
