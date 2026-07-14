# RN TurboModule Inventory

The RN runtime-host interop work's Phase 6a wires the minimum TurboModule
set the topbar bundle
needs and explicitly defers the rest ("Treat the Phase 6 set as the
foundation, not the finish line"). This doc enumerates the full set RN
exposes, classifies each module by who owns it and what it costs us, and
names the phase or external plan that will actually land it.

Scope: TurboModules surfaced through `TurboModuleRegistry.get` /
`getEnforcing` plus the JSI globals that `InitializeCore` installs.
Fabric component descriptors are tracked separately under Phase 5 of the
host interop work.

Spec sources surveyed: the new-arch web-API specs under
`packages/react-native/src/private/{webapis,devsupport,featureflags,viewtransition}/specs/`
and the legacy-format specs under
`packages/react-native/src/private/specs_DEPRECATED/modules/`. The
`_DEPRECATED` suffix names the codegen format being phased out, not the
modules — `Libraries/AppState/NativeAppState.js`,
`Libraries/Blob/NativeBlobModule.js`, `Libraries/Network/Networking.js`,
etc. still re-export from that folder and the TurboModule names there
are what `TurboModuleRegistry.getEnforcing` queries at runtime.

## Status legend

- **Wired** — registered by `registerCoreTurboModules()` (populating
  `turboModuleRegistry_`) in Phase 6a.
- **Portable-reuse** — RN ships a portable C++ impl in
  `ReactCxxPlatform/react/coremodules/` or `ReactCommon/react/nativemodule/`;
  we just register it. Cost is the provider entry plus any required
  platform getter (e.g. display metrics).
- **Stub-OK** — JS probes for the module but the shell does not use the
  surface; ship an empty/identity TurboModule so `getEnforcing` does not
  throw. Promote when a consumer surfaces.
- **N/A platform** — iOS or Android specific; never registered on Linux/macOS
  compositor targets. JS guards on platform before calling.
- **Implement** — no portable impl exists; we write the TurboModule
  ourselves against substrate / Swift services. Names the owning plan.
- **Community** — moved out of core RN; only register if a third-party
  package or shell widget pulls it in.
- **JSI global** — not a TurboModule. Installed as a JS global by host
  code (`TimerManager`, `setUpPerformance`, etc.).

## Core boot path (`InitializeCore` → `setUpDefaultReactNativeEnvironment`)

These run on every bundle load. Anything not wired or stubbed here will
throw before `AppRegistry.runApplication` returns.

| Surface | Status | Source / target | Notes |
| --- | --- | --- | --- |
| Timing (`setTimeout`/`setInterval`/`requestAnimationFrame`) | JSI global | `ReactCommon/react/runtime/TimerManager.h` | Phase 6a installs via `NucleusPlatformTimerRegistry`. No TurboModule. `NativeTiming` in `specs_DEPRECATED/` is the legacy bridge spec and is not used by the new arch path. |
| `Performance` (`performance.now()`, marks, measures) | JSI global (stub) → Implement later | `installMinimalPerformanceGlobal()`; target `NativePerformance` (portable) | Not yet wired. Host installs a minimal `performance.now()` JSI-global stub (steady-clock ms) so `TimerManager`'s `requestAnimationFrame` shim does not JSError; marks/measures are absent. The portable `NativePerformance` TurboModule is not registered yet. |
| `Microtasks` (`queueMicrotask`) | Wired | `NativeMicrotasks` (portable) | Already linked transitively. |
| `DOM` (web APIs on shadow tree) | Wired | `NativeDOM` (portable) | Already linked transitively. |
| `ReactNativeFeatureFlags` | Wired | `NativeReactNativeFeatureFlags` (portable) | Already linked transitively. |
| `ExceptionsManager` | Portable-reuse | `ReactCxxPlatform/.../logging/NativeExceptionsManager` | In Phase 6a list. |
| `ErrorHandling` / Promise polyfill | JSI global | `setUpErrorHandling`, `polyfillPromise` | Pure JS once `ExceptionsManager` is present. |
| `SegmentFetcher` | Stub-OK | `NativeSegmentFetcher` | Used for RAM bundles / dynamic chunks; ship a no-op until we adopt segments. |
| `LogBox` (`__DEV__`) | Stub-OK now, Implement later | `NativeLogBox`, `NativeRedBox`, `NativeDevLoadingView`, `NativeDevSettings` | Needed once we run dev bundles with hot reload. Tracked under a dev-tooling follow-up, not the runtime-host plan. |
| `ReactDevTools` (`__DEV__`) | Stub-OK now | `NativeReactDevToolsRuntimeSettingsModule` | Same dev-tooling follow-up. |
| `IntersectionObserver` (feature-flag gated) | Portable-reuse — not yet wired | `NativeIntersectionObserver` (portable) | Not registered by `registerCoreTurboModules()` yet; register and verify the feature-flag gate per plan §Phase 6a. |
| `MutationObserver` (feature-flag gated) | Portable-reuse — not yet wired | `NativeMutationObserver` (portable) | Same; not registered yet. |
| `IdleCallbacks` (feature-flag gated) | Portable-reuse — not yet wired | `NativeIdleCallbacks` (portable) | Same; not registered yet. |
| `XHR` setup | Depends on Networking | `setUpXHR` registers fetch/XHR globals against `Networking` + `Blob` | Without `Networking`, `fetch` throws. See "Networking" row below. |
| `Alert` setup | Stub-OK | `setUpAlert` → `NativeAlertManager` | Shell does not use `Alert.alert` today; stub. |
| `Navigator` setup | JSI global | `setUpNavigator` | Pure JS, sets `navigator.product`. |
| `BatchedBridge` setup | JSI global | `setUpBatchedBridge` | Pure JS shim; no TurboModule call. |

## App lifecycle and display

| Surface | Status | Source / target | Notes |
| --- | --- | --- | --- |
| `AppRegistry` | JS-only | `Libraries/ReactNative/AppRegistry` | Plan §Phase 6a calls `AppRegistryBinding::startSurface` from native. |
| `AppState` | Portable-reuse | `ReactCxxPlatform/.../AppStateModule` | In Phase 6a list. Compositor reports `active`; emit change events on session lock/idle when those signals exist. |
| `Dimensions` / `PixelRatio` | Portable-reuse | `ReactCxxPlatform/.../DeviceInfoModule` | In Phase 6a list. Backed by the direct overlay host's primary-output-size path. |
| `PlatformConstants` | Portable-reuse | `ReactCxxPlatform/.../PlatformConstantsModule` | In Phase 6a list. Override `getAndroidID` for non-Android. |
| `SourceCode` | Portable-reuse | `ReactCxxPlatform/.../devsupport/SourceCodeModule` | In Phase 6a list. |
| `Appearance` (dark mode) | Implement | `NativeAppearance` | Owner: the shell client (reads compositor color-scheme preference). One getter + one event emitter. Phase: "Shell preferences" follow-up; stub until then. |
| `I18nManager` (RTL) | Stub-OK | `NativeI18nManager` | Return LTR-only constants. Promote when an RTL locale enters scope. |
| `DeviceEventManager` (hardware back) | N/A platform | `NativeDeviceEventManager` | Android-only. |

## Animation and gesture

| Surface | Status | Source / target | Notes |
| --- | --- | --- | --- |
| `NativeAnimatedModule` (`Animated.*` native driver) | Portable-reuse — not yet wired | `ReactCommon/react/renderer/animated/AnimatedModule` | Not registered by `registerCoreTurboModules()` yet. Planned Phase 6a Path 1; Phase 6b swaps to Path 2 per `rn-animation-backend-plan.md`. |
| `NativeAnimatedTurboModule` | Portable-reuse — not yet wired | Same module under TM spec | Same registration; not registered yet. |
| `FrameRateLogger` | Stub-OK | `NativeFrameRateLogger` | Perf telemetry; wire to Tracy when we want frame-rate dropped-frame counters in JS. |

## Networking

All deferred to [`rn-networking-and-websocket-plan.md`](rn-networking-and-websocket-plan.md).
Until that plan lands, ship `Stub-OK` TurboModules that reject promises
with `ENOTIMPL` so consumers fail loud rather than hang.

| Surface | Status | Source / target | Notes |
| --- | --- | --- | --- |
| `Networking` (fetch/XHR) | Implement | `NetworkingModule` (portable factory exists, needs `HttpClientFactory`) | Owner: networking plan. Factory backed by Swift `URLSession` or libcurl. |
| `WebSocket` | Implement | `WebSocketModule` (portable factory exists, needs `WebSocketClientFactory`) | Same plan. |
| `Blob` | Implement | `BlobModule` | Required by `fetch` response bodies and `WebSocket` binary frames. Same plan. |
| `FileReader` | Implement | `NativeFileReaderModule` | Pairs with `Blob`. Same plan. |

## Media and images

| Surface | Status | Source / target | Notes |
| --- | --- | --- | --- |
| `ImageLoader` | Implement | `ImageLoaderModule` (portable factory exists, needs `IImageLoader`) | Phase 5 of the host plan registers the *descriptor* but explicitly defers materialization. Owner: a dedicated image-pipeline plan that picks the decoder (Skia codecs vs. platform) and the cache. |
| `ImageStore` / `ImageEditor` | Community / deferred | `NativeImageStoreIOS`, `NativeImageEditor` | Wire only if a shell widget needs base64 capture or crop. |
| `Vibration` | Stub-OK | `NativeVibration` | No haptics path on the compositor yet. |
| `SoundManager` (key-click etc.) | Stub-OK | `NativeSoundManager` | iOS-flavoured; treat as no-op. |

## Input and accessibility

| Surface | Status | Source / target | Notes |
| --- | --- | --- | --- |
| `AccessibilityInfo` / `AccessibilityManager` | Implement | `NativeAccessibilityInfo`, `NativeAccessibilityManager` | Owner: future a11y plan aligned with `docs/compositor-accessibility-direction.md`. Stub returning "all assistive tech off" until then. |
| `KeyboardObserver` | Implement | `NativeKeyboardObserver` | Owner: input plan once IME/keyboard surfaces have something to publish. Stub until then. |
| `Clipboard` | Implement | `NativeClipboard` | Owner: the shell client over Wayland `wl_data_device` / primary selection. Small (~one read + one write). Land alongside first widget that needs copy/paste. |
| `Linking` (`Linking.openURL`) | Implement | `NativeLinkingManager` / `NativeIntentAndroid` | Owner: compositor session services (`xdg-open` equivalent). Stub until first consumer. |
| `Share` | Stub-OK | `NativeShareModule` | Share sheet is shell-policy; design before implementing. |
| `Permissions` | N/A platform | `NativePermissionsAndroid` | Android only. |

## Dialogs and chrome

| Surface | Status | Source / target | Notes |
| --- | --- | --- | --- |
| `AlertManager` / `DialogManager` | Stub-OK | `NativeAlertManager`, `NativeDialogManagerAndroid` | Promote to Implement when shell ships an actual alert surface. |
| `ActionSheetManager` | Stub-OK | `NativeActionSheetManager` | Same. |
| `ModalManager` | Stub-OK | `NativeModalManager` | RN `<Modal>` will need this once a widget uses it; descriptor lands in Phase 5, manager wires later. |
| `StatusBarManager` | N/A platform | `NativeStatusBarManagerIOS`/`Android` | Compositor owns the status bar surface; RN never drives it. |
| `SettingsManager` | N/A platform | `NativeSettingsManager` | iOS `NSUserDefaults` shim. Use compositor config instead. |
| `ToastAndroid` / `PushNotificationManagerIOS` | N/A platform | — | Platform specific. |

## Storage and background

| Surface | Status | Source / target | Notes |
| --- | --- | --- | --- |
| `AsyncStorage` | Community | `@react-native-async-storage/async-storage` | Out of core. Register only if a bundle imports it. |
| `HeadlessJsTaskSupport` | N/A | `NativeHeadlessJsTaskSupport` | Android background-task shape; no analogue on the compositor. |
| `JSCHeapCapture` | N/A | `NativeJSCHeapCapture` | JSC only; we use Hermes. |

## Test/sample/internal

Always-skip. Provider should not register these; they are used by RN's
internal test harnesses (`fantom`).

- `NativeSampleTurboModule`
- `NativeFantom`, `NativeFantomTestSpecificMethods`, `NativeCPUTime`

## Standalone-app delta

This inventory tracks the compositor's RN host. Standalone desktop apps
(macOS Metal, Windows D3D12 via Skia Graphite, etc.) inherit the same
TurboModule provider but swap platform implementations behind the same
factory interfaces:

- `IImageLoader` — platform decoder (Skia codecs everywhere; platform
  decoder for HEIC/AVIF on macOS via ImageIO).
- `HttpClientFactory` — `URLSession` on Apple, WinHTTP/libcurl elsewhere.
- `WebSocketClientFactory` — `NSURLSessionWebSocketTask` on Apple,
  libwebsockets elsewhere.
- `PlatformConstants.getAndroidID`, `Dimensions` source, `Appearance`
  source — read from the host platform's window/display services rather
  than `valence_overlay_*`.

No additional TurboModules are required for standalone targets; the
deltas are factory injections.

## Action items not covered by any existing plan

The following rows need an owning plan before they leave `Stub-OK`:

1. **Appearance / dark mode signal** — produced by the shell client
   reading compositor color-scheme preference. Pairs with the shell
   customization story.
2. **Clipboard over Wayland selections** — small but needs a Swift
   service entry and a paste-target negotiation policy. Probably folded
   into the first widget that wants copy/paste.
3. **Linking / `xdg-open`** — depends on what URL handlers Nucleus
   exposes; design alongside the app-launch story.
4. **Accessibility surface** — large; needs alignment with
   `docs/compositor-accessibility-direction.md` and the platform a11y
   bus (AT-SPI on Linux, NSAccessibility on macOS).
5. **Dev-tooling bundle** (LogBox, RedBox, DevSettings, DevLoadingView,
   ReactDevToolsRuntimeSettings, DevMenu) — only needed once we ship a
   dev-mode bundle with Metro fast refresh. Track as one cohesive
   follow-up rather than per-module.

Each becomes a real plan when the corresponding feature surfaces a
consumer. Until then, the provider ships a stub that throws
`ENOTIMPL`-shaped errors so the first consumer fails loudly and brings
the implementation into scope.
