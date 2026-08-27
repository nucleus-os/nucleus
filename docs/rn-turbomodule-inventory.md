# RN TurboModule inventory

This inventory is generated from `ReactRuntimeHost::registerCoreTurboModules()` and records only modules Nucleus actually registers plus the next required groups. The source registry remains authoritative.

## Registered

| Module | Ownership |
| --- | --- |
| `PlatformConstants` | Nucleus desktop-shaped constants |
| `DeviceInfo` | Nucleus live display metrics |
| `NucleusHostCommand` | embedding-host command seam |
| `AppState` | Nucleus lifecycle state |
| `SourceCode` | Nucleus source URL state without the dev-server stack |
| `NativePerformance` | portable React Native implementation |
| `ExceptionsManager` | portable implementation with Nucleus logging |
| `NativeDOM` | portable React Native implementation |
| `NativeMicrotasks` | portable React Native implementation |
| `NativeReactNativeFeatureFlags` | portable React Native implementation |

Timer and animation-frame globals are installed through the runtime timer registry and are not TurboModules.

## Required next

1. Networking, WebSocket, Blob, and FileReader follow `rn-networking-and-websocket-plan.md` after asynchronous JS dispatch exists.
2. Native animation follows `rn-animation-backend-plan.md` and the per-surface presentation clock.
3. Image loading reuses the current Nucleus image pipeline and cache rather than adding an RN-only decoder.
4. Appearance, clipboard, linking, and accessibility receive owning platform services before registration.
5. DevSupport modules land as one cohesive Metro/LogBox/DevTools capability, never as silent stubs.

## Registration rule

Do not register a fake success implementation merely to satisfy `getEnforcing`. A module is either behaviorally implemented, deliberately absent so the first unsupported consumer fails clearly, or platform-inapplicable behind React Native's platform guard. Each addition includes a headless Hermes lookup and behavior test.
