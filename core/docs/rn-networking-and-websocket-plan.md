# React Native networking, WebSocket, and Blob plan

Status: active.

## Invariant

Nucleus uses React Native's portable C++ `NetworkingModule` and
`WebSocketModule` from `ReactCxxPlatform`. It does not maintain parallel Swift
implementations of RN's request, response, event, and socket semantics. Nucleus
owns the platform client factories, loader integration, missing Blob contract,
and qualification required by its Linux and Android products.

Callbacks enter Hermes only through the runtime's existing `CallInvoker`.
Network threads never mutate JS, UI, Fabric, or renderer state directly. Every
request, stream, socket, callback, and retained buffer has cancellation and
shutdown ownership.

## Phase 1 — Admit the upstream portable modules

Status: complete.

Compile the selected RN `react/http`, `react/io`, and runtime-provider sources
in the RN native SDK. Register `NetworkingModule` and `WebSocketModule` through
the existing Nucleus TurboModule provider and `RuntimeJSCallInvoker`.

Gate: Nucleus registry and lifecycle tests instantiate, invoke, and destroy
both upstream modules without a platform network implementation.

Achieved state: the existing ReactCxxPlatform native target compiles RN 0.87's
`react/http` and `react/io` sources, including the portable `NetworkingModule`
and `WebSocketModule`; the minimal Folly archive includes the `IOBuf`
implementation those sources require. The React runtime registers both
upstream TurboModules through its existing registry and runtime-owned
`CallInvoker`. Private unavailable client factories make pre-backend requests
fail through RN's normal completion and socket event contracts instead of
adding parallel request or event semantics.

Gate evidence: the Fabric runtime contract test resolves both modules, invokes
HTTP cancellation and WebSocket lifecycle methods, observes their asynchronous
RN device events, and destroys the host cleanly under `collider test runtime`.

## Phase 2 — Supply production HTTP and WebSocket clients

Status: active.

Implement `IHttpClient` with AsyncHTTPClient and `IWebSocketClient` with
NIOWebSocket. Both clients share SwiftNIO's singleton event-loop group. Swift
owns connections, TLS, redirects, cookies, streaming, cancellation, bounded
buffers, and shutdown. Thin C++ adapters translate React Native's existing
interfaces into one typed per-runtime C++ transport façade. Self-contained
request values cross by value, `std::function` captures own Swift transport and
callback lifetimes, and request/socket tokens own cancellation and teardown.
No NIO or AsyncHTTPClient type, opaque context pointer, C vtable, or manual
retain/release callback crosses that boundary.

Support TLS verification, redirects, headers, text and base64 request bodies,
streaming responses with backpressure, request cancellation, WebSocket text
frames, ping/pong, close handshakes, and deterministic teardown. Phase 3 adds
multipart, Blob, and WebSocket binary payloads because RN's portable client
interfaces do not carry those types to a platform backend.

Keep one runtime-owned cookie jar above AsyncHTTPClient, which parses cookies
but intentionally does not store them. Apply domain, path, secure, expiration,
and deletion rules before dispatch and after every response, including redirect
responses.

Gate: local HTTP/HTTPS and WebSocket fixtures cover success, malformed peers,
redirects, cancellation, backpressure, disconnect, runtime shutdown, and
reconnect behavior.

## Phase 3 — Complete Blob integration

Inventory the JS Blob/File/FormData contract not supplied by the portable C++
modules. Implement only the missing store, slice, URI, request-body, response,
and socket-binary integration through first-party TurboModule code. Bound blob
memory and temporary storage and cancel all transfers when either the blob or
runtime retires.

Gate: RN compatibility tests cover text, binary, multipart, upload/download
progress, blob slicing, blob-backed requests, blob responses, and WebSocket
binary delivery.

## Phase 4 — Qualify Linux and Android

Run one contract suite on Linux/arm64, Linux/x86_64, and Android/arm64. Measure
large-transfer memory, callback latency, idle wakeups, cancellation latency, and
teardown cleanliness.

Gate: all targets expose the same RN behavior, use libc++, validate TLS through
their declared trust store, and leave no worker, socket, request, callback, or
temporary blob resource after runtime shutdown.
