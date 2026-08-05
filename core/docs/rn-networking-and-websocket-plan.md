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

Compile the selected RN `react/http`, `react/io`, and runtime-provider sources
in the RN native SDK. Register `NetworkingModule` and `WebSocketModule` through
the existing Nucleus TurboModule provider and `RuntimeJSCallInvoker`.

Gate: upstream RN module tests and Nucleus registry/lifecycle tests instantiate,
invoke, and destroy both modules without a platform network implementation.

## Phase 2 — Supply production HTTP and WebSocket clients

Implement the `IHttpClient` and `IWebSocketClient` factories with one portable
production backend supporting TLS verification, redirects, cookies, headers,
streaming request/response bodies, cancellation, binary frames, ping/pong,
close handshakes, bounded buffering, and deterministic teardown.

Keep the backend behind RN's existing interfaces. Do not patch vendored React
Native and do not expose backend types to Swift domain models.

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
