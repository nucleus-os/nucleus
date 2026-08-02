# Nucleus compositor

The compositor directories own the Linux Wayland/DRM render server inside the root SwiftPM package.

`compositor-core/` contains Wayland protocol dispatch, input and window policy, DRM/KMS presentation, and the renderer integration. `compositor/` contains the thin `NucleusCompositor` executable entry point. The compositor links no React Native or shell product code.

The shell is an ordinary out-of-process Wayland client. Desktop-global policy remains in the compositor; bars, lock UI, notifications, application discovery, and service presentation remain in the shell.

Build and test through Collider from the repository root:

```sh
collider doctor runtime
collider bootstrap compositor
collider build compositor
collider test compositor
collider install session
```

Hardware-facing execution uses the complete session from a free virtual terminal or display-manager session:

```sh
collider run
collider run --tracy --seconds 20
collider run --vk-validation
```

Do not start the compositor inside an existing graphical session: it owns the DRM seat.
