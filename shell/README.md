# Nucleus shell

`shell/` owns the first-party out-of-process desktop shell inside the root SwiftPM package. It is a native Swift Wayland client built with NucleusUI and contains no React Native, Hermes, Fabric, or JavaScript runtime.

The shell owns bars, lock-screen UI, notifications, application discovery, Linux service projections, and presentation of shell policy. The compositor retains desktop-global input, window, output, and security policy. A private typed session channel publishes policy state without granting the shell a privileged Wayland client identity.

Build, test, and install from the repository root:

```sh
collider bootstrap shell
collider build shell
collider test shell
collider install session
```

At runtime the supervisor launches `NucleusShell` with the session's ordinary `WAYLAND_DISPLAY` and typed capability descriptors. The shell creates one native surface set per output and renders only when state, input, animation, service data, or a presentation deadline demands a frame.
