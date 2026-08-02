# RN networking, WebSocket, and Blob native modules

Status: active.

**Invariant: networking is a portable Swift service owned by the RN platform. JavaScript callbacks enter Hermes only through the runtime executor, all transfers are cancellable and bounded, and desktop and Android share one behavioral implementation.**

## Current disposition

`RuntimeJSCallInvoker` already provides thread-safe asynchronous dispatch, is
owned by `ReactRuntimeHost`, is shared with C++ TurboModules, and clears queued
work during shutdown. Networking is not blocked on creating a second executor.

## Phase 1 — Qualify and expose the existing asynchronous JS dispatch seam

Use the existing runtime-owned call invoker for TurboModule callbacks, promise
resolution, and event delivery. Add only the ownership or interface exposure
needed by the networking modules. Cancellation makes queued work inert after
runtime teardown.

Gate: behavioral tests prove ordering, cancellation, executor affinity, and teardown under concurrent completion.

## Phase 2 — Implement HTTP

Implement the React Native networking contract over `URLSession` where available and the selected Linux Foundation transport elsewhere. Support request headers, redirects, cancellation, timeout, text, binary, and file-backed bodies. Bound in-memory buffering and stream large payloads.

Gate: a local fixture server covers redirects, cancellation, malformed responses, upload/download streaming, and runtime destruction.

## Phase 3 — Implement Blob storage

Add a runtime-scoped blob registry backed by bounded memory and private temporary files. Blob handles are opaque, reference-counted, and invalid after runtime teardown. Networking and WebSocket modules consume the same registry.

Gate: tests cover slicing, reference release, file cleanup, limit enforcement, and rejected stale handles.

## Phase 4 — Implement WebSocket

Implement connection lifecycle, headers, protocols, text/binary messages, ping/pong, close codes, bounded send queues, and deterministic cancellation. Deliver events through the executor seam only.

Gate: fixture tests cover fragmentation, binary blobs, backpressure, peer failure, reconnect, and teardown races.

## Phase 5 — Register the platform modules

Register the modules in the current `NucleusReactRuntimeHostCxx` TurboModule provider and generated RN specification. Keep native implementation in first-party targets and do not patch vendored React Native.

Gate: Fabric headless tests resolve each module and execute an end-to-end request and WebSocket exchange.

## Phase 6 — Qualify both platforms

Run the same contract suite on Linux/amd64 and Android/arm64, then measure large-transfer memory, callback tail latency, idle wakeups, and teardown cleanliness.

Gate: both platforms pass identical observable behavior with bounded resource use and no leaked worker, descriptor, or temporary file.
