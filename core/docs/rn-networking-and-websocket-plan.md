# RN Networking, WebSocket, and Blob Native Modules

## Outcome

(To be filled in once Phase 8 lands.)

## Position

This plan adds HTTP/HTTPS (including HTTP/2), WebSocket, and Blob native
modules to the active Swift-based React Native runtime host. The runtime
host today
(`swift/Sources/NucleusReactRuntime/cxx/ReactRuntimeHost.cpp`,
`swift/Sources/NucleusReactRuntimeCxx/`) ships in bridgeless mode with
hand-written JSI TurboModules: only `PlatformConstants`, `SourceCode`,
`DeviceInfo`, `NativeDOM`, `NativeMicrotasks`, and
`NativeReactNativeFeatureFlags` are installed. The hardcoded factory at
`ReactRuntimeHost.cpp:1565` knows nothing else. There is no networking,
no WebSocket, no Blob, no device-event emitter wired across threads, and
the runtime's `ImmediateCallInvoker` is synchronous-only — so background
threads cannot post work to the JS thread, which is the structural
prerequisite for any I/O module.

The legacy Rust implementation under
`crates/nucleus_network/` and `crates/nucleus_rn/` is reference-only per
`CLAUDE.md`. It used a custom Nitrogen spec (`Networking.nitro.ts`) on
top of `reqwest` + `tokio-tungstenite` + `tokio` and a JS-side polyfill
of fetch/XHR/WebSocket against that spec. It worked but forced a custom
JS surface, blocked on `std::fs::read` in the FormData path, persisted
cookies non-atomically, and could not stream blob responses. This plan
treats `crates/` as the shape blueprint for redirect logic, multipart
generation, cookie persistence, and frame budgeting — not the API
contract.

The active substrate is Swift end to end — producer-side dynamics and
policy state, the io_uring loop (swift-system), and the render server
(Swift + C++ interop). Networking is
client-side I/O that does not touch substrate records; it lives entirely
inside the Swift-owned RN host. The right networking backbone for that
posture is `swift-nio` (already checked out at
`/home/maddy/Developer/swift-nio`), together with `swift-nio-ssl` for
TLS and `swift-nio-http2` for HTTP/2 — neither of which is checked out
yet. We do not adopt `async-http-client`: the Rust impl had to drive
redirects by hand on top of `reqwest`'s high-level client (setting
`Policy::none()`), and a direct NIO build keeps redirect, cookie,
multipart, and incremental-update control in one place. The added cost
of writing it ourselves is small compared to the dependency tree
`async-http-client` brings (NIOHTTP1 + NIOSSL + NIOHTTP2 + NIOFoundationCompat +
swift-log + swift-collections + Atomics, plus pool/redirect heuristics
that do not match the legacy semantics anyway).

The JS-side contract is the upstream React Native TurboModule shape:
`NativeNetworkingIOS`, `NativeWebSocketModule`, `NativeBlobModule`.
Their generated C++ interfaces ship in the FBReactNativeSpec codegen
output (`third-party/react-native/packages/react-native/React/FBReactNativeSpec/`,
regenerated per `CLAUDE.md`'s prerequisite step). We subclass those
generated `TurboModule` interfaces directly instead of declaring a
custom Nitrogen surface, so stock React Native JS — `fetch`,
`XMLHttpRequest`, `WebSocket`, `FormData`, `Blob`, `URL` — works
unmodified against `NativeWebSocketModule` / `RCTNetworking` /
`BlobManager` lookups without RN patches. This matches the
`CLAUDE.md` rule that public RN compatibility is required and the
vendored RN tree must not be patched.

C++/Swift integration follows the pattern set by the runtime host
interop work: each module is a
thin C++ `facebook::react::TurboModule` subclass under
`swift/Sources/NucleusReactRuntime/cxx/` paired with a Swift engine
under a new `swift/Sources/NucleusNetworking/` module. The Swift engine
consumes swift-nio directly, and the C++ TurboModule holds a
`std::shared_ptr` to a Swift-implemented engine wrapper exposed via
Swift's C++ interop. JSI hops back to the JS thread go through a new
`RuntimeJSCallInvoker` that posts to the runtime's JS-thread queue via
`facebook::react::RuntimeScheduler::scheduleTask`. Hermes runs on the
main thread; the EventLoopGroup spawns its own worker threads; the
NIOThreadPool handles blocking file reads for multipart uploads.

HTTP/2 is integrated at the transport substrate (Phase 2), not bolted
onto HTTP/1.1 in the request module. The shared `NIOSSLContext`
advertises ALPN `["h2", "http/1.1"]`; the channel installs either
NIOHTTP2 or NIOHTTP1 handlers based on negotiated protocol; the
`HTTPClientEngine` request API is HTTP-version-agnostic.

## State Invariant

Across every phase boundary the following must hold:

1. **Single shared `EventLoopGroup`.** The runtime host owns exactly
   one `NIOPosix.MultiThreadedEventLoopGroup` whose lifetime brackets
   all networking modules. Modules acquire it at construction; teardown
   stops accepting new work, drains in-flight, then shuts the group
   down with the documented `shutdownGracefully` timeout.
2. **One cancellation handle per JS-visible operation.** Each
   `sendRequest`, `connect`, and outbound blob transfer carries a
   stable integer ID from JS that maps to exactly one
   `Task<Void, Never>` plus its associated `NIOAsyncChannel`. Abort
   cancels the task; the channel closes within a bounded number of
   EventLoop ticks (target: next tick on the owning loop).
3. **JSI on the JS thread only.** No `jsi::Runtime` access occurs on
   EventLoop threads or `NIOThreadPool` threads. Every native →
   JavaScript event hop goes through `RuntimeJSCallInvoker::invokeAsync`,
   which posts to `RuntimeScheduler::scheduleTask`. `invokeSync`
   asserts the current thread is the JS thread.
4. **Cookie jar is single-writer.** A Swift `actor CookieJar` mediates
   all reads and writes. Persistence writes go to
   `${XDG_DATA_HOME:-~/.local/share}/nucleus/cookies.json` via
   temp+`rename(2)` so concurrent compositor invocations or crashes
   never observe a torn file.
5. **Blob bytes are reference-counted.** A Swift `actor BlobStore`
   holds blob payloads as `NIOCore.ByteBuffer`. The JS-visible blob ID
   takes an explicit retain on construction and an explicit release on
   `BlobModule.release`. In-flight network operations that reference a
   blob ID hold their own retain for the duration of the transfer; the
   payload survives even if JS releases its ID first.
6. **TurboModule lifetimes nest under the host.** All Networking,
   WebSocket, and Blob TurboModules are destroyed before the runtime
   host's `EventLoopGroup` shuts down. The host's destructor sequences
   module teardown → invoker drain → loop shutdown.
7. **No request or socket survives runtime destruction.** Module
   teardown aborts every in-flight operation. Pending `Task` instances
   are awaited (with a 5-second cap) before the loop group closes.
8. **HTTP version is transparent above the engine.** The
   `HTTPClientEngine` API is identical for HTTP/1.1 and HTTP/2 calls.
   The negotiated wire format is observable only through the response
   metadata (`HTTPVersion` field) and never affects JS-visible
   semantics, redirect handling, cookie attachment, or multipart
   encoding.

## End State

When all phases land, the architecture looks like:

- **`swift/Sources/NucleusNetworking/`** is a new Swift module compiled
  with `-cxx-interoperability-mode=default`. It owns:
  - `Transport.swift` — shared `EventLoopGroup`, `NIOSSLContext`,
    connection pool, ALPN-driven HTTP version routing.
  - `HTTPClientEngine.swift` — request execution actor: redirects,
    multipart, streaming, cookies, blob bodies.
  - `WebSocketEngine.swift` — WebSocket connection actor: handshake
    via `NIOWebSocketClientUpgrader`, frame aggregation, ping/pong.
  - `CookieJar.swift` — persistent cookie store actor.
  - `BlobStore.swift` — `ByteBuffer`-keyed blob registry actor.
- **`swift/Sources/NucleusReactRuntime/cxx/`** gains three TurboModule
  implementations and the cross-thread invoker:
  - `RuntimeJSCallInvoker.{hpp,cpp}` — replaces `ImmediateCallInvoker`.
  - `DeviceEventEmitter.{hpp,cpp}` — JSI binding to
    `RCTDeviceEventEmitter` global; thread-safe `emit(name, payload)`.
  - `NetworkingModule.{hpp,cpp}` — subclass of the FBReactNativeSpec
    `NativeNetworkingIOSCxxSpec` interface.
  - `WebSocketModule.{hpp,cpp}` — subclass of
    `NativeWebSocketModuleCxxSpec`.
  - `BlobModule.{hpp,cpp}` — subclass of `NativeBlobModuleCxxSpec`.
  - `TurboModuleRegistry.{hpp,cpp}` — table-driven module factory
    replacing the hardcoded if-ladder in `ReactRuntimeHost.cpp:1565`.
- **Submodules** added under `third-party/`:
  - `third-party/swift-nio` (matching the
    `/home/maddy/Developer/swift-nio` working copy)
  - `third-party/swift-nio-ssl`
  - `third-party/swift-nio-http2`
  Each is forked to Codeberg under `maddythewisp` per the submodule
  policy in `CLAUDE.md`. BoringSSL builds from swift-nio-ssl's
  vendored copy via the standard NIO build path; Skia's BoringSSL stays
  untouched.
- **`Package.swift`** has new target/product entries for each NIO module
  product (NIOCore, NIOPosix, NIOEmbedded, NIOHTTP1, NIOWebSocket,
  NIOTLS, NIOConcurrencyHelpers, NIOFoundationCompat, NIOFileSystem,
  NIOSSL, NIOHTTP2) plus the new `NucleusNetworking` module. CNIOLinux,
  CNIOAtomics, CNIOLLHTTP, CNIOSHA1, and CNIOPosix are built as SwiftPM C
  targets from NIO's C sources (the same precedent used for
  Skia / folly / fmt).
- **The runtime host's TurboModule factory** is a registry. New entries
  register at host construction:
  ```
  registry.add("Networking", makeNetworkingModule);
  registry.add("WebSocketModule", makeWebSocketModule);
  registry.add("BlobModule", makeBlobModule);
  ```
  The previously hardcoded 6 modules move into entries in the same
  registry. New modules added later append to this list.
- **JS-side**: `import 'react-native'` boots `InitializeCore`, which
  wires global `fetch`, `XMLHttpRequest`, `WebSocket`, `FormData`,
  `Blob`, and `URL`. These reach the new TurboModules under their
  upstream names (`Networking`, `WebSocketModule`, `BlobModule`). No
  patches to the vendored RN tree. No custom JS polyfills.
- **HTTP/2** is the default for HTTPS connections when the server
  negotiates `h2` via ALPN. HTTP/1.1 remains for `http://` (no h2c
  prior-knowledge support) and for servers that do not negotiate `h2`.
  Headers, redirects, cookies, multipart, and incremental updates work
  identically across both wire formats.
- **The DevTools network reporter** mirrors the Rust impl's connection
  timing, response body preview (capped at 1 MiB), and redirect chain.
  Hooks live in `HTTPClientEngine`; Inspector wiring lands as Phase 7.

## Reference Bucket

Three reference bodies feed this plan; each is consulted at a specific
phase rather than copied:

- **`/home/maddy/Developer/swift-nio`** — current working copy of
  swift-nio, Swift 6.1 minimum, full `NIOAsyncChannel` /
  `AsyncSequence` bridging. Phases 2–5 consume its modules directly.
- **`crates/nucleus_network/` and `crates/nucleus_rn/`** (legacy
  Rust) — used as the shape blueprint for redirect rules
  (`networking.rs` lines exercising 301/302 POST→GET drop, 303 GET,
  307/308 preserve), multipart boundary generation, cookie jar JSON
  layout, blob-store retain semantics, and WebSocket close-frame
  handling. Per `CLAUDE.md` the directory is not modified; phases cite
  it as "see legacy" and adapt.
- **`third-party/react-native/.../specs_DEPRECATED/modules/NativeNetworkingIOS.js`,
  `NativeWebSocketModule.js`, `NativeBlobModule.js`** — declare the
  exact JS contract. The codegen output at
  `third-party/react-native/packages/react-native/React/FBReactNativeSpec/`
  is the authoritative C++ interface we subclass.

## Phase 1 — Async JS Dispatch Foundation

### Goal

Replace `ImmediateCallInvoker` with a real cross-thread `CallInvoker`
that posts work to the JS thread via `RuntimeScheduler::scheduleTask`.
Add a `DeviceEventEmitter` C++ facade that any thread can call to
deliver an event to JS. Convert the hardcoded TurboModule factory at
`ReactRuntimeHost.cpp:1565` into a table-driven registry. None of this
is networking-specific; it is the foundation every async module
depends on.

### Work

#### `RuntimeJSCallInvoker`

- New: `swift/Sources/NucleusReactRuntime/cxx/include/NucleusReactRuntime/RuntimeJSCallInvoker.hpp`
  declaring `nucleus::react::RuntimeJSCallInvoker : public facebook::react::CallInvoker`.
  - Constructor takes `std::weak_ptr<facebook::react::RuntimeScheduler>`
    and a `std::thread::id` (the JS thread).
  - `invokeAsync(CallFunc&&)` captures the lambda, locks the weak
    scheduler, and calls `scheduler->scheduleTask(SchedulerPriority::ImmediatePriority,
    [func = std::move(func)](jsi::Runtime& rt) mutable { func(rt); })`.
    The lambda runs on the JS thread.
  - `invokeSync(CallFunc&&)` asserts
    `std::this_thread::get_id() == jsThreadId_` and invokes the lambda
    against the current runtime. Crashes on misuse rather than risking
    JSI cross-thread access.
- New: `swift/Sources/NucleusReactRuntime/cxx/RuntimeJSCallInvoker.cpp`
  with the implementation. The current `ImmediateCallInvoker` at
  `ReactRuntimeHost.cpp:294` is deleted; all references switch to the
  new invoker, constructed once in `ReactRuntimeHostImpl::initialize`.

#### `DeviceEventEmitter`

- New: `swift/Sources/NucleusReactRuntime/cxx/include/NucleusReactRuntime/DeviceEventEmitter.hpp`
  declaring `nucleus::react::DeviceEventEmitter`.
  - Constructor takes `std::shared_ptr<RuntimeJSCallInvoker>` and a
    weak runtime reference.
  - `emit(std::string name, folly::dynamic payload)` schedules a JS
    thread task that:
    1. Resolves `globalThis.__nativeBridgeIPC` or the
       `RCTDeviceEventEmitter.emit` JS function via JSI property
       lookup (cached after first resolve).
    2. Converts the `folly::dynamic` payload to `jsi::Value`.
    3. Calls `emitFn.call(runtime, jsi::String::createFromUtf8(name),
       payloadValue)`.
  - Caches the resolved emit function in a `jsi::Function` member to
    avoid repeated lookups; invalidates the cache on runtime
    destruction.
- The `RCTDeviceEventEmitter` JS global is set up by RN's
  `InitializeCore`; no JS-side changes needed. The emitter exposes
  `emit(eventName, payload)` for native callers.

#### Table-driven TurboModule registry

- New: `swift/Sources/NucleusReactRuntime/cxx/include/NucleusReactRuntime/TurboModuleRegistry.hpp`
  declaring `nucleus::react::TurboModuleRegistry`.
  - `using ModuleFactory = std::function<std::shared_ptr<facebook::react::TurboModule>(std::shared_ptr<facebook::react::CallInvoker>)>;`
  - `void add(std::string name, ModuleFactory factory);`
  - `std::shared_ptr<facebook::react::TurboModule> lookup(const std::string& name, std::shared_ptr<facebook::react::CallInvoker> invoker) const;`
- The lambda installed via `TurboModuleBinding::install()` at
  `ReactRuntimeHost.cpp:1565` becomes a one-liner:
  `[registry](const std::string& name) -> std::shared_ptr<TurboModule> { return registry->lookup(name, invoker); }`.
- The current 6 hardcoded modules
  (`PlatformConstants`, `SourceCode`, `DeviceInfo`, `NativeDOM`,
  `NativeMicrotasks`, `NativeReactNativeFeatureFlags`) become entries
  registered at host construction time, alongside Phase 4 / 5 / 3
  modules in later phases.

#### EventBeat re-verification

- The `ImmediateEventBeat` at `ReactRuntimeHost.cpp:346` calls
  `induce()` synchronously from `request()`. Under the new invoker,
  confirm `request()` is still invoked on the JS thread by the
  scheduler and that synchronous induction continues to work
  unchanged. Add a runtime assertion: `request()` checks
  `std::this_thread::get_id() == jsThreadId_`.

#### Tests

- New: `swift/Tests/NucleusReactRuntimeCxxTests/RuntimeJSCallInvokerTests.swift`
  exercising:
  - Background `std::thread` calling `invokeAsync` lands on the JS
    thread (assert via a JSI-readable counter incremented inside the
    lambda).
  - `invokeSync` from a non-JS thread aborts (Swift `XCTAssertCrash`
    or equivalent).
- New: `swift/Tests/NucleusReactRuntimeCxxTests/DeviceEventEmitterTests.swift`
  exercising a background-thread `emit("test", {"key": 42})` reaching
  a JS-side listener installed via `RCTDeviceEventEmitter.addListener`.

### Files touched

- New: `swift/Sources/NucleusReactRuntime/cxx/include/NucleusReactRuntime/RuntimeJSCallInvoker.hpp`
- New: `swift/Sources/NucleusReactRuntime/cxx/RuntimeJSCallInvoker.cpp`
- New: `swift/Sources/NucleusReactRuntime/cxx/include/NucleusReactRuntime/DeviceEventEmitter.hpp`
- New: `swift/Sources/NucleusReactRuntime/cxx/DeviceEventEmitter.cpp`
- New: `swift/Sources/NucleusReactRuntime/cxx/include/NucleusReactRuntime/TurboModuleRegistry.hpp`
- New: `swift/Sources/NucleusReactRuntime/cxx/TurboModuleRegistry.cpp`
- Modified: `swift/Sources/NucleusReactRuntime/cxx/ReactRuntimeHost.cpp`
  (delete `ImmediateCallInvoker`; rewire to `RuntimeJSCallInvoker`;
  convert hardcoded module factory to registry use; add EventBeat
  thread assertion)
- Modified: `swift/Sources/NucleusReactRuntime/cxx/include/NucleusReactRuntime/ReactRuntimeHost.hpp`
- New tests: `swift/Tests/NucleusReactRuntimeCxxTests/RuntimeJSCallInvokerTests.swift`,
  `swift/Tests/NucleusReactRuntimeCxxTests/DeviceEventEmitterTests.swift`
- Modified: `Package.swift` (test target registration)

### Verification

- `swift build` green.
- `swift test -Xswiftc -cxx-interoperability-mode=default --filter NucleusReactRuntimeCxxTests` green
  with the two new tests.
- Topbar bundle continues to render under
  `capture-compositor --launch --rn-shell-bundle` — no behavioral
  regression for existing surfaces. Mount events, timers, EventBeat
  all continue to fire correctly.
- `rg -n "ImmediateCallInvoker"` returns no matches in the active
  tree.

### Exit criteria

Any thread can call `DeviceEventEmitter::emit` and the payload reaches
a JS listener. The TurboModule registry is the single insertion point
for future modules. No call site assumes synchronous JSI dispatch from
arbitrary threads anymore.

## Phase 2 — swift-nio Vendoring and Transport Substrate

### Goal

Vendor swift-nio + swift-nio-ssl + swift-nio-http2 under
`third-party/`, wire them into the Zig build, and stand up a new
`NucleusNetworking` Swift module providing the shared transport
substrate: one `EventLoopGroup`, one ALPN-aware `NIOSSLContext`, a
connection pool keyed on `(scheme, host, port)`, and a low-level
request execution primitive that abstracts over HTTP/1.1 and HTTP/2.
No JS exposure yet; this phase is build wiring and a transport-layer
proof.

### Work

#### Submodule vendoring

- Add submodules under `third-party/`:
  - `third-party/swift-nio` → fork of
    `https://github.com/apple/swift-nio` on
    `codeberg.org:maddythewisp/swift-nio`, branch `main`, pinned to
    the current 2.x release tag on disk at
    `/home/maddy/Developer/swift-nio`.
  - `third-party/swift-nio-ssl` → fork of `apple/swift-nio-ssl`,
    branch `main`.
  - `third-party/swift-nio-http2` → fork of `apple/swift-nio-http2`,
    branch `main`.
- Update `CLAUDE.md`'s Submodules table to list the three new entries
  with their Codeberg remotes.
- Each submodule retains its vendored C sources unchanged
  (CNIOLinux, CNIOAtomics, CNIOLLHTTP, CNIOSHA1, CNIOPosix from
  swift-nio; BoringSSL from swift-nio-ssl). No patches.

#### Build integration

- Extend `Package.swift`:
  - One SwiftPM target per NIO product needed by our code:
    `NIOConcurrencyHelpers`, `NIOCore`, `NIOPosix`, `NIOEmbedded`,
    `NIOFoundationCompat`, `NIOTLS`, `NIOHTTP1`, `NIOWebSocket`,
    `_NIOFileSystem` (renamed to `NIOFileSystem` upstream), `NIOSSL`,
    `NIOHTTP2`. Each compiles from its `Sources/<Name>/` directory
    with the include paths the upstream `Package.swift` declares.
  - C dependency static libraries: `CNIOLinux`, `CNIOAtomics`,
    `CNIOLLHTTP`, `CNIOSHA1`, `CNIOPosix`, `CNIODarwin` (Linux build
    skips Darwin), built as SwiftPM C targets with the
    source lists pulled from each `Package.swift`. Linux-only modules
    add `-DCNIO_LINUX` and the standard NIO `-D` flags
    (`_GNU_SOURCE`, `__APPLE_USE_RFC_3542`).
  - BoringSSL from `third-party/swift-nio-ssl/Sources/CNIOBoringSSL/`
    is built as a SwiftPM C target matching the upstream
    `Package.swift` source list. Skia's BoringSSL fork stays
    untouched and unlinked into this graph; the two coexist as
    independent statics in the final binary because their symbols
    differ only by namespace.
  - New SwiftPM target `NucleusNetworking` depending on the NIO modules
    above. Compiles with `-cxx-interoperability-mode=default`,
    `-Xcc -std=c++20`, and the same include paths as
    `NucleusReactRuntimeCxx` plus the new NIO header paths.
- Verify cold build time is acceptable. CLAUDE.md's "single
  opinionated build, all integrations compile" rule applies; if
  BoringSSL adds more than 90 seconds to a cold build, split it into
  a parallel static library step rather than serializing on Skia.

#### Shared transport in Swift

- New: `swift/Sources/NucleusNetworking/Transport.swift`. A Swift
  `actor Transport` (one instance per runtime host) owns:
  - `let eventLoopGroup: MultiThreadedEventLoopGroup` —
    `numberOfThreads: System.coreCount`, bounded by 8.
  - `let sslContext: NIOSSLContext` — built once from a
    `TLSConfiguration` with:
    - `applicationProtocols = ["h2", "http/1.1"]`
    - `certificateVerification = .fullVerification`
    - System trust roots loaded via `NIOSSLContext`'s default Linux
      trust path (`/etc/ssl/certs/ca-certificates.crt` is the
      typical NixOS location; fall back to NIO's built-in search).
    - `cipherSuites` left at NIO defaults.
  - `let threadPool: NIOThreadPool` — for blocking multipart file
    reads; size 4.
  - `let connectionPool: ConnectionPool` — per-`(scheme, host, port)`
    bucket of idle channels with a 30 s idle timeout and per-bucket
    cap of 6 (matches Chrome/Firefox defaults).
  - `func acquireChannel(scheme: Scheme, host: String, port: Int) async throws -> PooledChannel`
    establishes or reuses a TCP connection; for TLS, performs the
    handshake and returns a `PooledChannel` tagged with the
    negotiated `HTTPVersion` (`http1_1` or `http2`) read from the
    `NIOSSLClientHandler`'s ALPN result.
  - `func release(_ channel: PooledChannel, reusable: Bool)` returns
    the channel to its pool bucket or closes it.

#### Channel pipeline assembly

- For `http://` connections: TCP only; pipeline installs
  `HTTPRequestEncoder`, `ByteToMessageHandler(HTTPResponseDecoder())`,
  and a `NIOAsyncChannel<HTTPClientResponsePart, HTTPClientRequestPart>`
  at the head.
- For `https://` connections: same plus a `NIOSSLClientHandler` at
  the bottom of the pipeline. After handshake, if ALPN selected
  `h2`, the pipeline reconfigures via
  `NIOHTTP2.NIOHTTP2Handler` + `HTTP2StreamMultiplexer` and the
  channel surfaces a stream-aware async API. If ALPN selected
  `http/1.1` or nothing, the HTTP/1.1 pipeline above is installed.
- A single helper `Transport.configurePipeline(_:tls:)` encapsulates
  both branches so the per-version logic stays out of the request
  engine.

#### HTTP version abstraction

- New: `swift/Sources/NucleusNetworking/HTTPClientCore.swift`. Defines:
  - `enum HTTPVersion { case http1_1, http2 }`
  - `struct HTTPRequestSpec { method, url, headers, body: HTTPBody }`
  - `struct HTTPResponseHead { status, headers, version }`
  - `enum HTTPResponseEvent { head(HTTPResponseHead), bodyChunk(ByteBuffer), end(trailers: HTTPHeaders?) }`
  - `protocol HTTPRequestExecutor { func execute(_ request: HTTPRequestSpec, on channel: PooledChannel) -> AsyncThrowingStream<HTTPResponseEvent, Error> }`
  - Two concrete executors: `HTTP1RequestExecutor` (using
    `NIOAsyncChannel` directly) and `HTTP2RequestExecutor` (using
    `HTTP2StreamMultiplexer.openStream` per request).
  - The executor chosen at `Transport.acquireChannel` time based on
    the channel's negotiated version.

#### Transport-layer tests

- New: `swift/Tests/NucleusNetworkingTests/TransportTests.swift`:
  - Acquire an HTTPS channel to `https://httpbin.org/get` (or a
    locally-hosted equivalent), verify ALPN negotiated `h2` against
    a known h2-supporting host.
  - Acquire an HTTP channel to a local NIO HTTP/1.1 server spun up
    in the test, verify request/response round-trip.
  - Acquire two channels to the same `(scheme, host, port)`, release
    one, verify the next acquire reuses it.
  - Idle-timeout test: release a channel, wait 31 s in a
    `MockTimerWheel`, verify pool drops it.

### Files touched

- New submodules: `third-party/swift-nio`,
  `third-party/swift-nio-ssl`, `third-party/swift-nio-http2`
- Modified: `.gitmodules`
- Modified: `CLAUDE.md` (Submodules table)
- Modified: `Package.swift` (NIO module targets +
  C static-library targets + `NucleusNetworking` module)
- Modified: `Package.swift`'s shared include-path helper if include path
  composition needs one
- New: `swift/Sources/NucleusNetworking/Transport.swift`
- New: `swift/Sources/NucleusNetworking/HTTPClientCore.swift`
- New: `swift/Sources/NucleusNetworking/ConnectionPool.swift`
- New: `swift/Tests/NucleusNetworkingTests/TransportTests.swift`
- Modified: `Package.swift` (new test target registration)

### Verification

- `swift build` green; cold-build time within budget.
- `swift test -Xswiftc -cxx-interoperability-mode=default --filter NucleusNetworkingTests` green.
- `nm` on the final binary shows both BoringSSL symbol sets
  (NIOSSL's `CNIOBoringSSL_*` and Skia's BoringSSL) without
  collision.
- Capture a `tools/profile/capture-compositor` run to confirm the
  enlarged binary still loads in the compositor's existing memory
  budget.

### Exit criteria

`Transport.acquireChannel` returns a working channel for both
`http://` and `https://` URLs with correct ALPN-driven HTTP version
selection. The request executor abstraction transparently routes
through HTTP/1.1 or HTTP/2 based on negotiation. No JS exposure;
this is a pure Swift API consumed only by Phase 4's HTTP module and
Phase 5's WebSocket module.

## Phase 3 — Cookie Jar and Blob Module

### Goal

Land the two ancillary services that HTTP and WebSocket both depend
on: a persistent cookie jar and a blob store. The Blob TurboModule
also gets its JS exposure here, because BlobModule is independent of
the request engine and exercises the full module-binding pipeline
(TurboModule registry, RuntimeJSCallInvoker, DeviceEventEmitter)
against a small, low-risk surface before Phase 4 leans on it.

### Work

#### Cookie jar

- New: `swift/Sources/NucleusNetworking/CookieJar.swift`. A Swift
  `actor CookieJar` providing:
  - `func cookies(for url: URL) async -> [HTTPCookie]` — returns
    cookies whose `domain`, `path`, `secure`, and expiry constraints
    match the URL.
  - `func setCookies(_ cookies: [HTTPCookie], for url: URL) async`
    — parses incoming `Set-Cookie` headers, applies RFC 6265 §5.3
    update rules.
  - `func clearAll() async` — purges in-memory and on-disk state.
  - `func persistIfNeeded() async` — debounced 1 s write to
    `${XDG_DATA_HOME:-~/.local/share}/nucleus/cookies.json` via
    temp+rename. Triggered after every mutating call.
  - `struct HTTPCookie: Codable` with the RFC 6265 fields plus the
    legacy compatibility fields (sameSite, hostOnly).
- File format: JSON array of cookie objects, matching the Rust
  impl's schema in `crates/nucleus_network/src/cookie_jar.rs` for
  forward-migration compatibility (read both formats if needed; new
  writes use the Swift schema).
- Atomicity: the `persistIfNeeded` write goes to
  `cookies.json.tmp.<pid>.<random>` then `rename(2)` over the real
  path. The Rust impl's known non-atomic flush is the explicit thing
  this fixes.

#### Blob store

- New: `swift/Sources/NucleusNetworking/BlobStore.swift`. A Swift
  `actor BlobStore` providing:
  - `func create(_ buffer: ByteBuffer, type: String?) async -> String`
    — generates a UUIDv4 ID, stores `(buffer, retainCount: 1, type)`,
    returns the ID.
  - `func retain(_ id: String) async`
  - `func release(_ id: String) async` — releases one reference;
    drops the buffer when retain count reaches 0.
  - `func buffer(for id: String) async -> ByteBuffer?`
  - `func size(for id: String) async -> Int?`
  - `func slice(_ id: String, offset: Int, length: Int) async -> String?`
    — creates a new blob ID referencing a slice of the parent
    buffer; uses `ByteBuffer.slice(at:length:)` for zero-copy.
  - `func combine(_ parts: [BlobPart]) async -> String?`
    — concatenates multiple parts (each a blob ID, string, or
    Data) into a new blob.

#### Blob TurboModule

- New: `swift/Sources/NucleusReactRuntime/cxx/include/NucleusReactRuntime/BlobModule.hpp`
  declaring `nucleus::react::BlobModule : public facebook::react::NativeBlobModuleCxxSpec<BlobModule>`.
  The base class comes from FBReactNativeSpec
  (`third-party/react-native/packages/react-native/React/FBReactNativeSpec/`).
  Methods implemented:
  - `jsi::Object getConstants(jsi::Runtime& rt)` — returns
    `{ BLOB_URI_SCHEME: "blob", BLOB_URI_HOST: nullptr }`.
  - `void addNetworkingHandler()` — no-op on Linux (iOS uses this
    to install a request body handler in RCTNetworking; we wire
    blob bodies via the Phase 4 request engine directly).
  - `void addWebSocketHandler(double socketId)` /
    `removeWebSocketHandler(double socketId)` — record the WS
    socket as a blob consumer (defers to BlobStore's retain
    tracking via WebSocketModule in Phase 5).
  - `void sendOverSocket(jsi::Object blob, double socketId)` —
    looks up the blob, hands it to WebSocketModule for
    binary-frame transmission.
  - `void createFromParts(jsi::Array parts, jsi::String withId)`
    — reads each part (blob ID with offset/length, or string),
    constructs the combined buffer through BlobStore, stores
    under `withId`.
  - `void release(jsi::String blobId)` — calls
    `BlobStore.release`.
- The C++ module holds a `std::shared_ptr<SwiftBlobStoreHandle>`
  obtained via Swift C++ interop. The Swift side wraps `BlobStore`
  in a non-actor handle that exposes synchronous methods bridging
  to the actor via `Task.detached + AsyncSemaphore` for the rare
  cases where C++ needs a synchronous answer; most methods are
  fire-and-forget from C++.

#### Module registration

- Register `BlobModule` in the TurboModule registry from Phase 1:
  ```
  registry.add("BlobModule", [transport, blobStore](auto invoker) {
    return std::make_shared<nucleus::react::BlobModule>(invoker, blobStore);
  });
  ```
- The `Transport` actor instance and `BlobStore` actor instance are
  created at host construction and held by the host as
  `std::shared_ptr` (via Swift C++ interop handles).

#### Tests

- New: `swift/Tests/NucleusNetworkingTests/CookieJarTests.swift`:
  - RFC 6265 §5.3 update precedence (path specificity, same domain
    overwriting).
  - Persist + reload round-trip via a `tempDir` override.
  - Concurrent writes from multiple `Task`s do not corrupt the file
    (write race test with `rename` atomicity assertion).
  - Forward-read of a Rust-impl-shaped JSON file.
- New: `swift/Tests/NucleusNetworkingTests/BlobStoreTests.swift`:
  - Create / retain / release count tracking.
  - Slice yields zero-copy `ByteBuffer.slice`.
  - Combine N parts produces the correct concatenation.
- New: `swift/Tests/NucleusReactRuntimeCxxTests/BlobModuleTests.swift`:
  - End-to-end: JS `new Blob(["hello", " ", "world"])` results in
    a BlobStore entry of size 11 with the correct bytes.
  - `URL.createObjectURL(blob)` yields `blob:hostname/<uuid>`.

### Files touched

- New: `swift/Sources/NucleusNetworking/CookieJar.swift`
- New: `swift/Sources/NucleusNetworking/BlobStore.swift`
- New: `swift/Sources/NucleusReactRuntime/cxx/include/NucleusReactRuntime/BlobModule.hpp`
- New: `swift/Sources/NucleusReactRuntime/cxx/BlobModule.cpp`
- Modified: `swift/Sources/NucleusReactRuntime/cxx/ReactRuntimeHost.cpp`
  (instantiate Transport + BlobStore at host construction; register
  BlobModule)
- New tests: `swift/Tests/NucleusNetworkingTests/CookieJarTests.swift`,
  `swift/Tests/NucleusNetworkingTests/BlobStoreTests.swift`,
  `swift/Tests/NucleusReactRuntimeCxxTests/BlobModuleTests.swift`

### Verification

- `swift build` green.
- `swift test -Xswiftc -cxx-interoperability-mode=default
  --filter NucleusNetworkingTests --filter NucleusReactRuntimeCxxTests` green.
- Test bundle: `const blob = new Blob(["hello"]);
  console.log(blob.size);` prints `5` and the BlobStore reports one
  active entry. `await blob.text()` returns `"hello"`.
- Cookie jar file appears at the expected XDG path after the test
  bundle calls `document.cookie = "foo=bar"` (via a synthetic JS
  cookie shim test, no real network needed).

### Exit criteria

The Blob TurboModule satisfies upstream RN's `NativeBlobModule`
contract; `new Blob(...)`, `URL.createObjectURL`, and
`URL.revokeObjectURL` work in JS. The cookie jar exposes the API
HTTP requests will consume in Phase 4 and persists atomically.

## Phase 4 — RCTNetworking (HTTP, HTTPS, HTTP/2)

### Goal

Land the HTTP request module. Wires the JS `fetch` / `XMLHttpRequest`
surface to the swift-nio transport substrate from Phase 2, with
manual redirect handling, multipart upload via `NIOFileSystem`,
streamed responses, cookie integration, and blob bodies. HTTP/2 is
transparent at this layer — the engine sees a uniform
`HTTPRequestExecutor` regardless of negotiated wire format.

### Work

#### HTTPClientEngine

- New: `swift/Sources/NucleusNetworking/HTTPClientEngine.swift`. A
  Swift `actor HTTPClientEngine` providing:
  - `let transport: Transport`
  - `let cookieJar: CookieJar`
  - `let blobStore: BlobStore`
  - `var inflight: [Int: InflightRequest] = [:]` keyed by JS-side
    request ID.
  - `func send(_ request: NetworkRequest, requestId: Int, sink: EventSink) async`
  - `func abort(requestId: Int)`
  - `struct NetworkRequest { method, url, headers, body, responseType,
    useIncrementalUpdates, timeout, withCredentials }`
  - `enum NetworkResponseEvent { didSendNetworkData(progress, total),
    didReceiveNetworkResponse(status, headers), didReceiveNetworkData(chunk),
    didReceiveNetworkDataIncremental(chunk), didCompleteNetworkResponse(error?) }`
  - `protocol EventSink { func emit(_ event: NetworkResponseEvent, for requestId: Int) }`

#### Request body shapes

- `enum NetworkRequestBody`:
  - `case none`
  - `case string(String, contentType: String?)` — UTF-8 encoded.
  - `case base64(String, contentType: String?)` — decoded once at
    submit time.
  - `case blob(blobId: String, contentType: String?)` — retains via
    `BlobStore`; bytes streamed directly from the
    `ByteBuffer` without intermediate copies.
  - `case formData([FormDataPart], boundary: String)` where each
    part is either:
    - `.string(name, value, contentType)`
    - `.blob(name, blobId, fileName, contentType)`
    - `.file(name, filePath, fileName, contentType)` — read via
      `NIOFileSystem.FileSystem.shared.openFile(forReadingAt:)` and
      streamed in 64 KiB chunks. Replaces the legacy impl's
      blocking `std::fs::read` on a tokio worker.

#### Redirect handler

- Mirrors `crates/nucleus_network/src/networking.rs` redirect logic:
  - Max 20 hops.
  - 301 / 302: convert POST→GET, drop body; preserve all other
    methods unchanged with body.
  - 303: convert any method to GET, drop body.
  - 307 / 308: preserve method and body.
  - Relative `Location` headers resolved via Swift `URL(relative:to:)`.
  - Each hop re-runs cookie attachment (`cookieJar.cookies(for: url)`)
    and cookie storage from `Set-Cookie` headers.
- DevTools (Phase 7) records the chain; in Phase 4 the redirect
  walker only emits the final response's events.

#### Incremental updates

- If `useIncrementalUpdates` is true:
  - `responseType: "text"`: each `bodyChunk` decodes as UTF-8 (or
    the response's Content-Type charset) and fires
    `didReceiveNetworkDataIncremental` with the cumulative string
    (matches RN's behavior).
  - `responseType: "base64"`: each chunk encodes as base64; fires
    incrementally.
  - `responseType: "blob"`: no incremental updates (Rust impl
    limitation preserved; blob requires the full buffer to compute
    size and create the BlobStore entry).
- If `useIncrementalUpdates` is false: chunks accumulate into a
  single `ByteBuffer`; one `didReceiveNetworkData` event fires with
  the final payload encoded per `responseType`.

#### Streaming and progress

- `didSendNetworkData(progress, total)` emits before each request
  body chunk write. For blob bodies, `total` is known up front. For
  formData with file parts, `total` sums each part's size from
  `FileInfo` (queried at submit time via `NIOFileSystem.info`).
- `didReceiveNetworkResponse(status, headers)` emits once on
  receiving the response head.
- `didCompleteNetworkResponse(error?)` is the terminal event; the
  request ID's `InflightRequest` entry is removed after it fires.

#### Cancellation

- `abort(requestId: Int)`:
  1. Looks up `InflightRequest`.
  2. Cancels its `Task` via `task.cancel()`.
  3. Closes the channel without returning it to the pool (cooperative
     cancellation alone isn't enough — the server may still be
     streaming).
  4. Emits `didCompleteNetworkResponse(error: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))`.

#### TurboModule

- New: `swift/Sources/NucleusReactRuntime/cxx/include/NucleusReactRuntime/NetworkingModule.hpp`
  declaring `nucleus::react::NetworkingModule : public facebook::react::NativeNetworkingIOSCxxSpec<NetworkingModule>`.
  Methods (matching `NativeNetworkingIOS.js`):
  - `void sendRequest(jsi::Runtime& rt, jsi::Object query, jsi::Function callback)`
    — parses `query` ({method, url, data, headers, responseType,
    incrementalUpdates, timeout, withCredentials}), submits to
    `HTTPClientEngine.send`, invokes `callback(requestId)`.
  - `void abortRequest(jsi::Runtime& rt, double requestId)`
  - `void clearCookies(jsi::Runtime& rt, jsi::Function callback)`
    — invokes `cookieJar.clearAll()`, calls back with success.
  - `void addListener(jsi::Runtime&, jsi::String eventName)` /
    `void removeListeners(jsi::Runtime&, double count)` — required
    by the new RN EventEmitter spec for subscription ref counting.
- Events fire through `DeviceEventEmitter.emit` on the JS thread:
  `didSendNetworkData`, `didReceiveNetworkResponse`,
  `didReceiveNetworkDataIncremental` / `didReceiveNetworkData`,
  `didCompleteNetworkResponse`. Payload shapes match
  `RCTNetworking.ios.js`'s subscriber expectations.

#### Module wiring

- The `NetworkingModule` C++ class holds:
  - `std::shared_ptr<SwiftHTTPClientEngineHandle>` (Swift handle
    exposed via interop)
  - `std::shared_ptr<DeviceEventEmitter>`
- On `sendRequest`, it allocates a fresh request ID
  (`std::atomic<uint64_t>`), constructs a `NetworkRequest` from the
  JS query, and posts to the engine via the Swift handle. The
  engine's `EventSink` is a C++ object that calls
  `DeviceEventEmitter.emit` on each event.

#### Registration

- The TurboModule registry adds:
  ```
  registry.add("Networking", [engine, emitter](auto invoker) {
    return std::make_shared<nucleus::react::NetworkingModule>(invoker, engine, emitter);
  });
  ```

#### Tests

- New: `swift/Tests/NucleusNetworkingTests/HTTPClientEngineTests.swift`:
  - Simple GET / 200 / text round-trip against a local NIO
    HTTP/1.1 server.
  - HTTPS GET against a local NIOSSL server with ALPN `h2`;
    confirm response arrives via HTTP/2 executor.
  - Redirect chain: 302 → 200; POST body dropped, method rewritten
    to GET. Includes a multi-hop case to verify hop-counter
    enforcement at 21.
  - Multipart upload with one string part and one file part; verify
    boundary, Content-Disposition headers, and file bytes against
    a known fixture.
  - Incremental update: 256 KiB streamed response with
    `useIncrementalUpdates=true` fires N chunks summing to the
    full payload.
  - Cancellation: abort mid-stream; verify
    `didCompleteNetworkResponse(error: cancelled)` fires within 2
    EventLoop ticks.
  - Cookie integration: server sets `Set-Cookie: a=1`; next request
    to same origin includes `Cookie: a=1`.

### Files touched

- New: `swift/Sources/NucleusNetworking/HTTPClientEngine.swift`
- New: `swift/Sources/NucleusNetworking/RedirectPolicy.swift`
- New: `swift/Sources/NucleusNetworking/MultipartWriter.swift`
- New: `swift/Sources/NucleusReactRuntime/cxx/include/NucleusReactRuntime/NetworkingModule.hpp`
- New: `swift/Sources/NucleusReactRuntime/cxx/NetworkingModule.cpp`
- Modified: `swift/Sources/NucleusReactRuntime/cxx/ReactRuntimeHost.cpp`
  (instantiate `HTTPClientEngine` at host construction; register
  module)
- New tests: `swift/Tests/NucleusNetworkingTests/HTTPClientEngineTests.swift`,
  `swift/Tests/NucleusReactRuntimeCxxTests/NetworkingModuleTests.swift`

### Verification

- `swift build` green.
- `swift test -Xswiftc -cxx-interoperability-mode=default
  --filter NucleusNetworkingTests --filter NucleusReactRuntimeCxxTests` green.
- Test bundle exercising `fetch("https://example.com/")` returns a
  200 response with body. Verify both `http/1.1` and `h2` paths
  against test servers with controlled ALPN.
- Test bundle exercising `XMLHttpRequest` with progress events,
  abort mid-stream, and `responseType="arraybuffer"`.
- Test bundle exercising FormData upload with a synthetic file
  (`new Blob([new Uint8Array(1024)])`) — multipart body matches
  fixture.

### Exit criteria

`fetch`, `XMLHttpRequest`, and `FormData` work transparently against
HTTP/1.1, HTTPS/1.1, and HTTPS/2 servers. Redirects, cookies, progress,
incremental updates, and cancellation match RN's iOS reference
behavior. The DevTools-observable wire format (HTTP version, header
order) is determined by ALPN, not by the JS contract.

## Phase 5 — WebSocketModule

### Goal

Land the WebSocket module. Reuses the Phase 2 transport substrate for
TCP / TLS / connection establishment, then drives `NIOWebSocket`'s
frame parser + `NIOWebSocketClientUpgrader` for the upgrade handshake.
Frame aggregation, ping/pong, binary blob frames, and close-frame
handling all run inside a Swift actor; the C++ TurboModule exposes
the JS-facing `connect` / `send` / `sendBinary` / `ping` / `close`
methods.

### Work

#### WebSocketEngine

- New: `swift/Sources/NucleusNetworking/WebSocketEngine.swift`. A
  Swift `actor WebSocketEngine`:
  - `let transport: Transport`
  - `let blobStore: BlobStore`
  - `var sockets: [Int: WebSocketSession] = [:]` keyed by JS-side
    socket ID.
  - `func connect(socketId: Int, url: URL, protocols: [String], headers: [String: String], sink: WebSocketSink) async`
  - `func send(socketId: Int, payload: WebSocketOutbound)`
  - `func close(socketId: Int, code: UInt16, reason: String)`
  - `enum WebSocketOutbound { case text(String), binary(ByteBuffer),
    binaryBlob(blobId: String), ping(ByteBuffer) }`
  - `protocol WebSocketSink { func emit(_ event: WebSocketEvent, for socketId: Int) }`
  - `enum WebSocketEvent { open, message(WebSocketInbound),
    closing(code: UInt16, reason: String), closed(code: UInt16, reason: String, wasClean: Bool), failed(error: Error) }`
  - `enum WebSocketInbound { case text(String), binary(blobId: String) }`

#### Upgrade pipeline

- For `ws://` URLs: `Transport.acquireChannel(scheme: .ws, ...)`
  yields a TCP-only channel with an HTTP/1.1 pipeline (no h2
  upgrade for WebSocket; the negotiation goes through HTTP/1.1
  `Upgrade: websocket`).
- For `wss://`: TLS channel with HTTP/1.1 ALPN. ALPN cannot be `h2`
  for WebSocket establishment — the engine forces ALPN to
  `["http/1.1"]` for WS connections via a per-request override on
  the SSL handler.
- Pipeline assembly:
  1. `HTTPRequestEncoder` + `HTTPResponseDecoder` install on the
     channel.
  2. `NIOWebSocketClientUpgrader` configured with:
     - `requestKey: <16 random bytes base64>`
     - `expectedProtocols: protocols`
     - `upgradePipelineHandler:` closure that, on successful
       upgrade, replaces the HTTP handlers with
       `WebSocketFrameEncoder` + `WebSocketFrameDecoder` +
       `WebSocketMessageAggregator` (handles fragmentation) +
       `NIOAsyncChannel<WebSocketFrame, WebSocketFrame>`.
  3. The engine sends a GET with `Upgrade: websocket` headers.
- On successful upgrade: emit `open` event.
- On failure: emit `failed` with the HTTP status and any response
  body for diagnostics.

#### Frame handling

- Inbound text frames: aggregator yields a complete UTF-8 string;
  emit `message(.text(...))`.
- Inbound binary frames: aggregator yields a `ByteBuffer`; the
  engine calls `BlobStore.create(buffer, type: "application/octet-stream")`
  and emits `message(.binary(blobId:))`. The blob retain is held
  by the JS side until `URL.revokeObjectURL` or explicit release.
- Inbound ping frames: respond with a pong containing the same
  payload. No JS event.
- Inbound pong frames: dropped (the engine doesn't track outbound
  ping timing in this phase; ping-timeout heuristics are a follow-up).
- Inbound close frame: emit `closing(code, reason)`, write the
  reciprocal close frame, then emit `closed(code, reason, wasClean: true)`.
- 16 MiB frame size budget: matches the Rust impl. Exceeding closes
  the connection with `1009` (message too big) and emits `failed`.

#### Outbound frames

- `send(text:)`: encodes to a `WebSocketFrame` with opcode `text`,
  masked (client always masks), `fin: true`.
- `send(binary:)`: opcode `binary`, masked, fin true. Buffer comes
  from a `ByteBuffer`.
- `send(binaryBlob:)`: looks up the blob in `BlobStore`, retains for
  the duration of the write, sends frame, releases.
- Backpressure: writes go through `NIOAsyncChannelOutboundWriter`
  which respects channel writability. The Swift caller awaits the
  write before returning.

#### TurboModule

- New: `swift/Sources/NucleusReactRuntime/cxx/include/NucleusReactRuntime/WebSocketModule.hpp`
  declaring `nucleus::react::WebSocketModule : public facebook::react::NativeWebSocketModuleCxxSpec<WebSocketModule>`.
  Methods:
  - `void connect(jsi::Runtime& rt, jsi::String url, jsi::Array protocols, jsi::Object options, double socketId)`
  - `void close(jsi::Runtime& rt, double code, jsi::String reason, double socketId)`
  - `void send(jsi::Runtime& rt, jsi::String message, double socketId)` — text frame
  - `void sendBinary(jsi::Runtime& rt, jsi::String base64, double socketId)` — decoded once, sent as a binary frame
  - `void ping(jsi::Runtime& rt, double socketId)`
  - `void addListener(jsi::Runtime&, jsi::String)` /
    `void removeListeners(jsi::Runtime&, double)`
- Events fire via `DeviceEventEmitter.emit`:
  - `websocketOpen` payload: `{ id }`
  - `websocketMessage` payload: `{ id, type: "text" | "binary", data: string }`
    (for binary, `data` is the blob ID — JS consumers reconstruct
    via the BlobModule integration)
  - `websocketClosed` payload: `{ id, code, reason, wasClean }`
  - `websocketFailed` payload: `{ id, message }`

#### BlobModule integration

- `BlobModule.sendOverSocket(blob, socketId)` forwards to
  `WebSocketModule.send` with a `binaryBlob` payload, bypassing
  base64 encoding on the JS→native boundary (the Rust impl already
  used this pattern for performance).

#### Tests

- New: `swift/Tests/NucleusNetworkingTests/WebSocketEngineTests.swift`:
  - Connect to a local NIO `NIOWebSocketServerUpgrader` test
    server; send text, verify echo.
  - Send a 1 MiB binary frame; verify roundtrip and that the
    inbound blob ID is valid in `BlobStore`.
  - Send a 17 MiB frame; verify connection closes with code 1009.
  - Inbound ping → outbound pong handshake.
  - Close handshake: client `close(1000, "bye")` → server reciprocal
    close → `closed(1000, "bye", wasClean: true)` event.

### Files touched

- New: `swift/Sources/NucleusNetworking/WebSocketEngine.swift`
- New: `swift/Sources/NucleusReactRuntime/cxx/include/NucleusReactRuntime/WebSocketModule.hpp`
- New: `swift/Sources/NucleusReactRuntime/cxx/WebSocketModule.cpp`
- Modified: `swift/Sources/NucleusReactRuntime/cxx/ReactRuntimeHost.cpp`
  (instantiate engine, register module)
- New tests: `swift/Tests/NucleusNetworkingTests/WebSocketEngineTests.swift`,
  `swift/Tests/NucleusReactRuntimeCxxTests/WebSocketModuleTests.swift`

### Verification

- `swift build` green.
- `swift test -Xswiftc -cxx-interoperability-mode=default
  --filter NucleusNetworkingTests --filter NucleusReactRuntimeCxxTests` green.
- Test bundle: `const ws = new WebSocket("wss://echo.websocket.org/");
  ws.onopen = () => ws.send("ping"); ws.onmessage = e => console.log(e.data);`
  prints "ping" via the echo server (or local equivalent).
- Test bundle exercising binary `ws.send(new Uint8Array(2048))` →
  `ws.onmessage` receives a Blob; `blob.arrayBuffer()` matches bytes.

### Exit criteria

`new WebSocket(url)` over `ws://` and `wss://` connects, sends text
and binary frames, handles pings, fragmentation, and the close
handshake per RFC 6455. Binary frames integrate with the BlobModule
without redundant base64 conversions.

## Phase 6 — JS Boot Integration

### Goal

Confirm stock React Native `InitializeCore` boots the global
`fetch`, `XMLHttpRequest`, `WebSocket`, `FormData`, `Blob`, and `URL`
against the three new TurboModules. Patch nothing in the vendored
RN tree; resolve the JS-side module routing (`Platform.OS` →
`.ios.js` variant) through the existing `PlatformConstants` module.

### Work

#### Platform routing

- `PlatformConstants` already returns a constants object. Audit its
  `osName` field to confirm it returns `"ios"` (or whatever value
  routes Metro to load `*.ios.js` variants of the spec files,
  matching the existing topbar bundle's assumption).
- If `osName` returns something else, this is the right place to
  fix it — Metro's resolver in `tools/rn-shell/metro.config.js`
  controls which `.ios.js` vs `.android.js` variant gets bundled.
- Verify by inspecting the rn-shell topbar bundle's output: it
  should already import `RCTNetworking.ios.js` and
  `NativeNetworkingIOS.js`. No change to JS or RN tree needed if
  the routing is already correct.

#### Module name verification

- The TurboModule lookup names in our registry must match what the
  JS specs call:
  - `Networking` (from `TurboModuleRegistry.getEnforcing<Spec>('Networking')`
    inside `NativeNetworkingIOS.js`)
  - `WebSocketModule` (from `NativeWebSocketModule.js`)
  - `BlobModule` (from `NativeBlobModule.js`)
- Add a runtime trace log in the registry on first lookup of each
  to confirm the names match.

#### Hermes global wiring

- `InitializeCore` (loaded via `react-native/Libraries/Core/InitializeCore.js`)
  sets up `globalThis.fetch`, `globalThis.XMLHttpRequest`,
  `globalThis.WebSocket`, `globalThis.FormData`, `globalThis.Blob`,
  `globalThis.URL`, `globalThis.URLSearchParams`. With Phases 1–5
  landed, all three native modules they depend on are present, so
  the polyfills wire automatically.
- If Hermes' Intl support is needed for `Headers.normalize` or URL
  parsing of IDN domains, confirm the existing Hermes config in
  `ReactRuntimeHost.cpp` enables it (it does, per the `Builder`
  call at construction).

#### Boot bundle test

- New: `bundles/shell/networking-smoke/index.jsx`. A bundle that
  registers a single component which fires off:
  - `fetch("https://httpbin.org/get")` and logs status + first 200
    response bytes.
  - `new WebSocket("wss://echo.websocket.events")`, sends `"hello"`,
    logs the echo.
  - `new FormData(); fd.append("name", "value");
    fetch(url, { method: "POST", body: fd })` and logs the
    response.
- Runs via `tools/profile/capture-compositor --launch --rn-shell-bundle=networking-smoke`.
- Verify in `nucleus_drm.log`: each native event arrives on the JS
  thread; no thread-mismatch assertions fire; the bundle completes
  without errors.

### Files touched

- New: `bundles/shell/networking-smoke/index.jsx`
- Modified: `build_zig/rn_shell.zig` (register the new bundle)
- Possibly modified: `swift/Sources/NucleusReactRuntime/cxx/ReactRuntimeHost.cpp`
  (PlatformConstants `osName` audit; trace logs)

### Verification

- `capture-compositor --launch --rn-shell-bundle=networking-smoke
  --seconds 30` shows all three operations succeed.
- Hermes inspector (Phase 7) shows fetch / WS as proper network
  entries.

### Exit criteria

A stock RN bundle using `fetch`, `WebSocket`, `FormData`, and `Blob`
without any custom imports runs end-to-end against real network
endpoints. No patches to the vendored RN tree.

## Phase 7 — DevTools Network Reporter

### Goal

Surface request and WebSocket activity in Hermes' inspector network
panel. Mirror the Rust impl's instrumentation: connection timing,
redirect chain, response body preview (1 MiB cap), per-frame
WebSocket data. Tracy zones around connection lifecycle, TLS
handshake, ALPN negotiation, redirect hops.

### Work

#### Inspector network reporter

- New: `swift/Sources/NucleusNetworking/NetworkInspectorReporter.swift`.
  A Swift type holding a weak reference to Hermes'
  `jsinspector_modern::HostTarget`. Subscribes to
  `HTTPClientEngine`'s and `WebSocketEngine`'s lifecycle events via
  an additional `EventSink`. Forwards events as CDP
  `Network.requestWillBeSent`, `Network.responseReceived`,
  `Network.dataReceived`, `Network.loadingFinished`,
  `Network.loadingFailed`, `Network.webSocketCreated`,
  `Network.webSocketFrameSent`, `Network.webSocketFrameReceived`.
- The C++ side of the runtime host already knows about the
  inspector (`HermesRuntime`'s inspector adapter is installed
  during construction). Add a `setNetworkInspectorReporter`
  facade method that hands the reporter the inspector pointer.

#### Tracy instrumentation

- Tracy zones (via the existing `Tracy` module):
  - `nucleus.net.acquire_channel` — Transport.acquireChannel
  - `nucleus.net.tls_handshake` — NIOSSLClientHandler completion
  - `nucleus.net.alpn` — recorded protocol on completion
  - `nucleus.net.redirect` — each redirect hop
  - `nucleus.net.http_request` — full request lifetime
  - `nucleus.net.http_response_chunk` — per inbound chunk
  - `nucleus.ws.upgrade` — WebSocket handshake
  - `nucleus.ws.frame` — per frame inbound/outbound
- Zones use the standard `TracyMessageL` payload format for
  request IDs, URLs (truncated to 256 chars), and status codes.

#### Body preview cap

- Response bodies and WebSocket binary frames preview up to 1 MiB
  in the inspector network panel. Larger payloads emit
  `Network.dataReceived` with the full byte count but
  `Network.loadingFinished.encodedDataLength` only — body preview
  is omitted. Same shape as the Rust impl.

### Files touched

- New: `swift/Sources/NucleusNetworking/NetworkInspectorReporter.swift`
- Modified: `swift/Sources/NucleusReactRuntime/cxx/ReactRuntimeHost.cpp`
  (wire reporter to inspector)
- Modified: `swift/Sources/NucleusNetworking/HTTPClientEngine.swift`,
  `WebSocketEngine.swift`, `Transport.swift` (Tracy zones,
  reporter event sink)

### Verification

- Chrome DevTools attached to the runtime via Hermes inspector
  shows fetch / WS entries with timing, headers, body preview.
- Tracy capture shows `nucleus.net.*` zones during a
  networking-smoke bundle run, with TLS handshake nested inside
  `acquire_channel`.

### Exit criteria

Inspector users can debug networking in JS exactly as on stock RN
iOS. Tracy zones cover the connection-establishment hot path
enough to attribute latency.

## Phase 8 — Hardening, Edge Cases, Sweep

### Goal

Address known rough edges from the legacy Rust impl, harden module
teardown, write fuzz / fixture / cross-thread regression tests, and
update documentation.

### Work

#### Cookie persistence hardening

- Confirm `CookieJar.persistIfNeeded`'s debounce coalesces N
  concurrent writes into one `rename(2)` call. Add a stress test
  that fires 1000 concurrent `setCookies` calls and verifies the
  final state matches the last write.
- Add file-locking via `flock(2)` on the persisted path so two
  compositor instances starting simultaneously cannot torch each
  other's state. The Rust impl had no such guard.

#### Cancellation timing bounds

- Add a regression test asserting `abortRequest` causes
  `didCompleteNetworkResponse` to fire within 5 EventLoop ticks
  (measured via `EmbeddedEventLoop`).
- Add a regression test asserting `WebSocketModule.close` results
  in `websocketClosed` within 10 EventLoop ticks under normal
  conditions.

#### Multipart fixtures

- Add fixture-based tests comparing our multipart output against
  curl's `-F` output for the same inputs (boundary aside).
- Verify Content-Disposition encoding for filenames containing
  non-ASCII characters per RFC 5987.

#### TLS edge cases

- Self-signed certs return a `didCompleteNetworkResponse` with the
  expected TLS error code. Verify against a local NIOSSL server
  using a self-signed cert.
- Server name indication (SNI) — confirm `NIOSSLClientHandler` is
  constructed with the request host so virtual-hosted servers
  return the correct cert.

#### HTTP/2 stream limits

- Test against an h2 server that enforces
  `SETTINGS_MAX_CONCURRENT_STREAMS = 1`; verify our request
  engine queues subsequent requests rather than failing.
- Test pseudo-header generation: `:method`, `:scheme`,
  `:authority`, `:path` match RFC 9113.

#### WebSocket edge cases

- Fragmented inbound text frames (one frame with `fin: false` plus
  continuation frames) aggregate correctly.
- Inbound utf-8 invalid bytes on a text frame trigger close with
  code 1007 (per RFC 6455).
- Server-initiated close while client is mid-send: client's pending
  write completes or fails cleanly; close handshake completes.

#### Teardown sweep

- Add a `RuntimeHostTeardownTests.swift` test that constructs a
  host, fires off five concurrent fetches and two WebSocket
  connections, then destroys the host. Verify:
  - All in-flight tasks cancel within 5 s.
  - `EventLoopGroup.shutdownGracefully` returns within 1 s after
    task cancellation.
  - No memory leaks (run under address sanitizer if practical).

#### Documentation

- Update this plan's `Outcome` section.
- Update `CLAUDE.md`'s Ownership Map row for "RN runtime host" to
  cite the new `swift/Sources/NucleusNetworking/` module.
- Add a paragraph to `CLAUDE.md`'s "Submodules" section pointing at
  the three new NIO submodules.

### Files touched

- Modified: `swift/Sources/NucleusNetworking/CookieJar.swift` (file
  locking)
- New tests: `swift/Tests/NucleusNetworkingTests/HardeningTests.swift`,
  `swift/Tests/NucleusReactRuntimeCxxTests/RuntimeHostTeardownTests.swift`
- Modified: `CLAUDE.md`
- Modified: this file (Outcome)

### Verification

- `swift build` and full test sweep green.
- All known gaps from the Rust impl are either resolved or
  explicitly recorded as out-of-scope follow-ups.

### Exit criteria

The networking stack survives compositor restart, concurrent
writers, hostile servers (slow loris, oversized frames, malformed
TLS), and clean teardown. No dangling resources, no race conditions
between cancellation and completion events.

## Phase 9 — Dev Server, Source Maps, and Inspector Reattach

### Goal

Wire up React Native's developer tooling against the now-real
networking stack: un-exclude `DevServerHelper.cpp`, replace the
`NucleusSourceCodeModule` shim with the portable `SourceCodeModule`,
register `DevSettingsModule`, `LogBoxModule`, `DevLoadingViewModule`,
and `NativeDevMenu`, route Hermes' inspector through Metro's
`/inspector/device` WebSocket, format `NativeExceptionsManager`
errors against fetched source maps, and land Fast Refresh.

This phase exists because the runtime-host interop work (Phase 6a.2)
ships a
`NucleusSourceCodeModule` shim and excludes `DevServerHelper.cpp`
from `react_cxx_platform`. Both are deliberate placeholders pending
this phase: `DevServerHelper` calls into RN's `IHttpClient` /
`IWebSocketClient` factories, which only exist once Phases 4 and 5
land. Once those factories are wired, the portable module shape
becomes available and the shim goes away.

Dev tooling is gated. Production builds skip every module
registered in this phase. `NUCLEUS_RN_DEV=1` (env) or
`--rn-dev` (compositor flag) flips dev mode on; the host's module
registry consults the flag at construction.

### Work

#### Un-exclude DevServerHelper

- Drop `"DevServerHelper.cpp"` from `cxx_platform_excludes` in
  `build_zig/react_native.zig` so the portable source compiles into
  `react_cxx_platform`. The exclude comment also needs to go.
- `DevServerHelper` declares `IHttpClient` / `IWebSocketClient`
  factory consumption via Phase 2's `Transport` actor — already
  wired through the Phase 4 / Phase 5 module factories. No
  additional OpenSSL link is required; swift-nio-ssl's BoringSSL
  (Phase 2) provides the TLS path that `DevServerHelper`'s
  `IHttpClient` factory uses internally.
- Verify `nm` on `react_cxx_platform.a` shows
  `facebook::react::DevServerHelper::getBundleUrl() const` and the
  other methods our modules will reference.

#### Drop NucleusSourceCodeModule

- Delete `swift/Sources/NucleusReactRuntime/cxx/NucleusSourceCodeModule.cpp`
  and `…/include/NucleusReactRuntime/NucleusSourceCodeModule.hpp`.
- Remove the registration in `ReactRuntimeHost.cpp`'s
  `registerCoreTurboModules` for `NucleusSourceCodeModule`.
- Re-add the portable `<react/devsupport/SourceCodeModule.h>`
  include and register
  `std::make_shared<facebook::react::SourceCodeModule>(invoker, devServerHelper_)`
  under name `"SourceCode"`. The runtime host now constructs a
  `std::shared_ptr<facebook::react::DevServerHelper>` at startup
  when dev mode is on; the shared pointer flows into the
  registration closure by capture.
- Drop the build entry for `NucleusSourceCodeModule.cpp` in
  `build_zig/rn_shell.zig`.

#### DevServerHelper construction

- Add to `ReactRuntimeHostImpl`'s constructor (dev-mode-only path):
  ```
  devServerHelper_ = std::make_shared<facebook::react::DevServerHelper>(
      /*packagerServerHost=*/devServerHost_,
      /*packagerServerPort=*/devServerPort_,
      /*deviceId=*/deviceId_,
      /*httpClientFactory=*/httpClientFactory_,
      /*webSocketClientFactory=*/webSocketClientFactory_);
  ```
- The `httpClientFactory_` and `webSocketClientFactory_` come from
  Phase 4 / Phase 5 — both registered as `Transport`-backed
  factories on the host. Pass through directly.
- `devServerHost_` / `devServerPort_` resolve in order:
  `NUCLEUS_RN_DEV_SERVER` env var → `RCT_METRO_PORT` env var →
  `localhost:8081` default. The compositor's `--rn-dev-server`
  flag overrides both.
- `deviceId_` is a stable per-machine ID stored at
  `${XDG_CACHE_HOME:-~/.cache}/nucleus/dev-device-id` (UUIDv4 on
  first launch, persisted via temp+rename).

#### DevSettingsModule

- Register portable `facebook::react::DevSettingsModule` under
  name `"DevSettings"`:
  ```
  registry.add("DevSettings",
      [helper = devServerHelper_, liveReload = makeLiveReloadCallback()]
      (std::shared_ptr<CallInvoker> invoker) {
        return std::make_shared<facebook::react::DevSettingsModule>(
            std::move(invoker), helper, liveReload);
      });
  ```
- `liveReloadCallback` is a `std::function<void()>` that signals
  the compositor to:
  1. Stop the active surfaces (`host->stopSurface(id)` for each
     attached widget).
  2. Re-fetch the bundle from Metro via DevServerHelper.
  3. Re-evaluate, `runApplication`, re-attach.
- The callback runs on the JS thread (posted through
  `jsInvoker_->invokeAsync`). Reload tears down the per-bundle
  state but keeps the host alive — module registry, transport,
  cookie jar, blob store all persist across reloads.

#### LogBoxModule

- Register portable `facebook::react::LogBoxModule` under name
  `"LogBox"`:
  ```
  registry.add("LogBox",
      [delegate = logBoxSurfaceDelegate_]
      (std::shared_ptr<CallInvoker> invoker) {
        return std::make_shared<facebook::react::LogBoxModule>(
            std::move(invoker), delegate);
      });
  ```
- `logBoxSurfaceDelegate_` is a new Swift type
  `NucleusLogBoxSurfaceDelegate` (in
  `swift/Sources/NucleusReactRuntimeCxx/LogBoxSurfaceDelegate.swift`)
  conforming to `facebook::react::SurfaceDelegate` via C++ interop.
  Methods:
  - `void show()` — attaches a new hosted surface at the top of the
    overlay scene (full-screen, z-order above all widgets) that
    renders LogBox's JS-side `LogBoxInspector` component.
  - `void hide()` — detaches the surface.
  - `bool isShown()`
- The LogBox bundle is the same RN bundle's LogBox module; no
  separate bundle build. The surface ID is `99999` (LogBox
  reserves) and the host registers it lazily on first show.

#### DevLoadingViewModule

- Register portable `facebook::react::DevLoadingViewModule` under
  name `"DevLoadingView"`:
  ```
  registry.add("DevLoadingView",
      [delegate = devUIDelegate_]
      (std::shared_ptr<CallInvoker> invoker) {
        return std::make_shared<facebook::react::DevLoadingViewModule>(
            std::move(invoker), delegate);
      });
  ```
- `devUIDelegate_` is a Swift `NucleusDevUIDelegate` conforming to
  `IDevUIDelegate`. It surfaces a small "Loading from Metro…" /
  "Connecting to debugger…" overlay via the same hosted-surface
  path as LogBox, at a fixed top-left position. Methods:
  - `void showMessage(const std::string &message,
        const std::string &color, const std::string &backgroundColor)`
  - `void hide()`
  - `void updateProgress(const std::string &status, int done, int total)`

#### NativeDevMenu

- Register portable `facebook::react::NativeDevMenu` (lives in
  RN's spec output, not ReactCxxPlatform; the spec's CxxSpec base
  provides a default empty impl). Subclass it as
  `NucleusDevMenu`:
  ```
  swift/Sources/NucleusReactRuntime/cxx/NucleusDevMenu.{hpp,cpp}
  ```
- Methods:
  - `show()` — attaches a hosted overlay surface rendering RN's
    JS-side `DevMenu` component (reload, toggle Fast Refresh,
    show inspector, configure bundler, etc.).
  - `reload()` — calls `liveReloadCallback`.
  - `debugRemotely(enable)` — toggles the inspector connection
    via `DevServerHelper`.
  - `setProfilingEnabled(enable)` — toggles Hermes' sampling
    profiler (already exposed by `HermesRuntime` config).
  - `setHotLoadingEnabled(enable)` — passes through to
    `DevSettingsModule`.
- Hot-key trigger: the compositor's input layer reserves
  `Ctrl+Alt+D` (Linux-conventional dev shortcut) and routes through the
  direct overlay host path into Swift, which calls `NucleusDevMenu::show`
  on the host.

#### Source-map-aware exception formatting

- `NativeExceptionsManager`'s `onJsError` callback (Phase 6a.2
  registered it with a logging stub) gains source-map resolution:
  ```
  swift/Sources/NucleusNetworking/SourceMapResolver.swift
  ```
  A Swift `actor SourceMapResolver` fetches and caches source
  maps from Metro via the HTTP engine
  (`http://${host}:${port}/${bundleName}.map`). Each entry is
  parsed once via the swift-nio-tarred sourcemap parser
  (new dependency: `third-party/swift-sourcemap`, a small Apple
  package; if absent, write a minimal parser — V3 source maps
  are well-specified).
- The `onJsError` callback, on each stack frame, queries the
  resolver for the (file, line, column) → (originalFile,
  originalLine, originalLine, originalSymbol) mapping. Frames
  format as `${originalSymbol} (${originalFile}:${origLine}:${origCol})`.
- Production builds (dev mode off) skip resolution and use the
  raw frame (file:line:col from the bundle).
- The resolver caches per-bundle URL; a reload invalidates the
  cache.

#### Hermes inspector full attach

- Phase 7's `NetworkInspectorReporter` already exposes the
  `Network.*` CDP domain. This phase wires the rest:
  - `Runtime.*` — Hermes provides natively via
    `jsinspector_modern::HostTarget`; just connect.
  - `Debugger.*` — Hermes provides via the same adapter.
  - `Console.*` — Hermes provides; route `console.log` /
    `console.warn` / `console.error` through it (the current
    `installConsole` in `ReactRuntimeHost.cpp` logs to stderr;
    add an inspector channel alongside).
  - `Profiler.*` — Hermes provides via its sampling profiler.
- The inspector connects to Metro's `/inspector/device` WebSocket
  (via DevServerHelper's `getInspectorDeviceUrl()`). The host
  registers itself as a target. Chrome DevTools' `chrome://inspect`
  page enumerates the host through Metro's targets list.
- New: `swift/Sources/NucleusReactRuntime/cxx/InspectorPackagerConnection.{hpp,cpp}`
  — a thin C++ class holding the WS connection and routing CDP
  messages between Hermes' inspector and Metro. Mirrors RN's
  iOS `RCTInspectorPackagerConnection` shape.

#### Fast Refresh

- Bundle build switches when dev mode is on:
  - `build_zig/rn_shell.zig` adds a dev-mode bundle target that
    runs Metro with `--dev=true --hot=true --minify=false` and
    points to a Metro server URL rather than producing a static
    HBC. The compositor evaluates the bundle by fetching it
    over HTTP via DevServerHelper on each launch.
- React Refresh runtime is bundled with the JS (Metro injects it
  in dev mode). HMR updates arrive over Metro's HMR WebSocket
  endpoint (`/hot`), routed through the `WebSocketModule`
  registered in Phase 5.
- The HMR client lives JS-side
  (`react-native/Libraries/Utilities/HMRClient.js`) and consumes
  the WebSocket as a plain `new WebSocket(...)` — no native
  changes beyond the modules already registered.
- `DevSettingsModule.setHotLoadingEnabled(true)` is what flips
  the HMR client on; the host calls it once during dev-mode boot.

#### Module wiring

- The `ReactRuntimeHostImpl::registerCoreTurboModules` method
  gains a dev-mode branch:
  ```cpp
  if (devModeEnabled_) {
    registerDevTurboModules();
  }
  ```
- `registerDevTurboModules` registers the seven dev modules
  above (`SourceCode` re-registration is in the main path; the
  shim swap is unconditional once Phase 9 lands).

#### Tests

- New: `swift/Tests/NucleusNetworkingTests/SourceMapResolverTests.swift`:
  - Resolve a V3 source map mapping a bundle position to the
    original `Clock.jsx:14:5`.
  - Cache eviction on bundle URL change.
  - 404 on `.map` → falls back to raw frame.
- New: `swift/Tests/NucleusReactRuntimeCxxTests/DevServerHelperTests.swift`:
  - Construct host with `NUCLEUS_RN_DEV=1` env, verify
    `DevServerHelper` is non-null and resolves a fake bundle URL
    against a local NIO HTTP server.
  - `liveReloadCallback` invocation tears down and re-attaches
    surfaces in order without leaking surface registrations.
- New: `swift/Tests/NucleusReactRuntimeCxxTests/InspectorPackagerConnectionTests.swift`:
  - Open a local NIO WS server that mimics Metro's
    `/inspector/device` protocol.
  - Assert `Runtime.enable` round-trips between Hermes and our
    fake Metro.

### Files touched

- Modified: `build_zig/react_native.zig` (drop `DevServerHelper.cpp`
  exclude)
- Deleted: `swift/Sources/NucleusReactRuntime/cxx/NucleusSourceCodeModule.cpp`,
  `…/include/NucleusReactRuntime/NucleusSourceCodeModule.hpp`
- Modified: `build_zig/rn_shell.zig` (drop NucleusSourceCodeModule
  entry; add dev-mode bundle target)
- New: `swift/Sources/NucleusReactRuntimeCxx/LogBoxSurfaceDelegate.swift`
- New: `swift/Sources/NucleusReactRuntimeCxx/DevUIDelegate.swift`
- New: `swift/Sources/NucleusReactRuntime/cxx/NucleusDevMenu.{hpp,cpp}`
- New: `swift/Sources/NucleusReactRuntime/cxx/InspectorPackagerConnection.{hpp,cpp}`
- New: `swift/Sources/NucleusNetworking/SourceMapResolver.swift`
- Modified: `swift/Sources/NucleusReactRuntime/cxx/ReactRuntimeHost.cpp`
  (DevServerHelper construction; dev-module registration branch;
  inspector packager connection; rich `onJsError` formatting)
- Modified: `swift/Sources/NucleusReactRuntime/cxx/include/NucleusReactRuntime/ReactRuntimeHostFacade.hpp`
  (`setDevMode(bool)`, `setDevServer(host, port)` facade entries)
- Modified: `swift/Sources/NucleusReactRuntimeCxx/Module.swift` and
  `Host.swift` (Swift wrappers for the new facade entries)
- Modified: `compositor-core/Sources/NucleusCompositorOverlayScene/Runtime.swift`
  (read `NUCLEUS_RN_DEV` env and `--rn-dev-server` flag, pass to
  the `NucleusReactRuntime` host on first construction)
- Modified: `compositor/Sources/NucleusCompositor/main.swift` and
  `compositor-core/Sources/NucleusCompositorOverlayScene/Runtime.swift`
  (direct Swift overlay host call + input hotkey routing)
- Modified: this file (Outcome)
- New tests as listed above

### Verification

- `swift build` green; `react_cxx_platform.a` now
  contains `DevServerHelper`.
- `swift test -Xswiftc -cxx-interoperability-mode=default
  --filter NucleusNetworkingTests --filter NucleusReactRuntimeCxxTests` green.
- `NUCLEUS_RN_DEV=1 ./tools/profile/capture-compositor --launch
  --rn-shell-bundle=topbar --seconds 30` boots against a running
  `metro start` instance; bundle loads from Metro, not from the
  pre-compiled HBC.
- Edit `bundles/shell/topbar/index.jsx`, save; Fast Refresh
  patches the running surface without a compositor restart.
- Trigger a JS exception (`throw new Error("test")` in the
  Topbar component); LogBox surface appears with the original
  source location (`index.jsx:14:5`) — not the bundle position.
- `Ctrl+Alt+D` shows the dev menu overlay.
- Chrome attached to `chrome://inspect` shows the runtime under
  the Metro-served devices list; setting a breakpoint in
  `Clock.jsx` hits it on next tick.

### Exit criteria

The dev loop is: edit `.jsx` → save → Fast Refresh applies
without restart. Exceptions surface with original-source stacks
in LogBox. The Chrome inspector attaches via Metro. The
production build (dev mode off) registers none of these modules
and continues to ship pre-compiled HBC.

## Risks

### swift-nio-ssl BoringSSL coexistence with Skia

Skia vendors its own BoringSSL. swift-nio-ssl vendors a different
fork (`CNIOBoringSSL_*` namespace). Both compile into static
libraries with namespaced symbols — collision is unlikely but not
zero. Mitigation: Phase 2's verification step checks `nm` output for
overlapping unprefixed symbols, and the linker order is documented
in `Package.swift` so the failure mode (if any) is a build-time
duplicate-symbol error, not a runtime miscompare. Fallback if a
collision surfaces: rebuild swift-nio-ssl's BoringSSL with a custom
symbol prefix via the upstream `BoringSSL.gni`-style prefix mechanism.

### Hermes inspector network panel CDP shape

CDP's `Network.*` domain is large and Hermes' inspector implements a
subset. Mismatches between what we emit and what Hermes' inspector
forwards will simply not appear in the panel rather than crash, but
debugging that gap is annoying. Mitigation: Phase 7 references the
Rust impl's `devtools_network_reporter.rs` for the exact CDP fields
that proved to land; deviations are explicit.

### Cross-thread JSI hazards in Phase 1

`RuntimeJSCallInvoker` posting to `RuntimeScheduler::scheduleTask`
relies on the scheduler outliving any in-flight task. The runtime
host's destructor must synchronize: cancel all module operations,
drain the scheduler, then destroy. The current host's destructor
order is implicit; Phase 1 makes it explicit and assertion-checked,
which can surface latent bugs in EventBeat / timer paths that the
synchronous invoker masked. Mitigation: Phase 1's verification runs
the topbar bundle end-to-end with the new invoker before any
networking module lands.

### HTTP/2 connection coalescing

HTTP/2 allows multiple origins to share a connection if certificates
cover them. swift-nio-http2 supports this via
`HTTP2StreamMultiplexer` but our connection pool keys on
`(scheme, host, port)` — losing the optimization. The Rust impl
also did not coalesce. Mitigation: leave coalescing as a Phase 9
follow-up if performance demands it; the pool's per-bucket limit
of 6 connections gives adequate parallelism for most workloads.

### `NIOAsyncChannel` API stability

The Swift Concurrency bridge in swift-nio matured in 2.x; current
working copy supports it but specific APIs (e.g., `executeThenClose`)
may shift in patch releases. Pinning the submodule to a specific
release tag (Phase 2) avoids drift. Upgrading the pin is a deliberate
operation tracked the same way as any other dependency bump.

### Blob lifetime across module boundaries

A blob created by `BlobModule.createFromParts`, referenced by an
in-flight HTTP request body, and concurrently `BlobModule.release`d
must survive until the request completes. The retain in
`HTTPClientEngine` covers this, but the cross-actor sequencing
(BlobStore is an actor; HTTPClientEngine is an actor; the retain
happens during request submit) is testable but not trivial. Phase 3
includes a regression test for "release before request completes",
and Phase 8's teardown test exercises the related "host destroyed
mid-transfer" path.

### NixOS trust root path

`NIOSSLContext`'s default Linux trust root search may not find
the host operating system's certificate store at runtime. The compositor host environment
provides a path via the `SSL_CERT_FILE` env var; the production
binary needs equivalent. Mitigation: Phase 2 reads `SSL_CERT_FILE`
explicitly (with fallback to `NIO_SSL_TRUST_ROOTS_PATH` and then the
NIO default search). Document in `CLAUDE.md` that compositor
deployments must set one of these.

### React Native version drift

`NativeNetworkingIOS`, `NativeWebSocketModule`, and `NativeBlobModule`
are in `specs_DEPRECATED/` per the upstream source layout we read.
The non-deprecated successor specs may land in a future RN bump and
require us to subclass updated codegen interfaces. Mitigation: each
phase's TurboModule subclass derives from the codegen-generated
class name (e.g. `NativeNetworkingIOSCxxSpec<T>`), so a spec rename
shows up as a build-time compile error against the new generated
header. The breaking change is mechanical.

### Dev-mode surface routing through hosted surfaces

Phase 9's LogBox, DevLoadingView, and DevMenu render via hosted
overlay surfaces (the same path RN-rendered shell widgets use).
That couples dev tooling to the topbar/dock surface machinery and
means a regression in the overlay scene's hosted-surface
publication path can hide a JS exception. Mitigation: dev tooling
surfaces use reserved high-numbered surface IDs (99990–99999); a
fallback `stderr` log path in `NativeExceptionsManager` fires
unconditionally so even a broken LogBox path leaves a trace.

### Inspector packager connection lifetime

The `InspectorPackagerConnection` WebSocket lives for the runtime
host's lifetime. Metro disconnects (server restart) leave the
host in a quiet state with no inspector; reconnect logic mirrors
RN's iOS impl (exponential backoff, max 30s). Mitigation: the
connection holds no JS-visible state — a dead connection just
means no debugger attach. Phase 9's verification covers the
reconnect cycle.

### Source-map fetch latency in `onJsError`

Resolving a stack frame against a remotely-fetched source map
introduces async latency in the exception path. The first
exception of a session can take a full network round trip to the
Metro source-map endpoint before LogBox renders. Mitigation: the
resolver pre-fetches the bundle's source map on `evaluateBundle`
completion (when the bundle URL is known). Subsequent exceptions
hit the warm cache.

### Fast Refresh state preservation

React Refresh preserves component-local state across patches.
Components hooked into native state (mount consumer references,
substrate handles) can desync if their JS-side identity survives
but their native-side identity is stale. Mitigation: the topbar
bundle is small enough that any state-loss bug is obvious; the
networking-smoke bundle (Phase 6) is the proper stress test for
Fast Refresh boundary correctness.

## Outcome

(To be filled in once Phase 8 lands.)
