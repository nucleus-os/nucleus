# Swift / C++ Stdlib Alignment — Cleanup Catalog

## Position

This doc catalogs the concrete code-quality wins that become available
now that `swift-toolchain/` bakes libc++ in as the
default C++ stdlib and the Swift `CxxStdlib` overlay binds to
`std::__1::basic_string` cleanly.

It is **not** a plan: nothing here gates the toolchain work itself
(which is done in the external repo). Items are grouped by category,
each cited by file path and line range, with before/after sketches.
Use this as the punch list when collapsing the in-tree workarounds
and as input to related plans
(`docs/rn-networking-and-websocket-plan.md`).

Each entry's line-count estimates are approximations; the point is
that several hundred lines of carefully-written workaround machinery
collapses into about a third the volume of natural C++ + thin Swift.

## Status at a glance

| Item | Status | Landed in |
| --- | --- | --- |
| 1. FabricMountEventCallback → MountingObserver | ✅ Done | `9c0ca8c9` (initial); event-driven `didFinishTransaction` batch boundary added per Phase 4 finishing pass |
| 2. Dual `std::string` / `const char *` pairs | ✅ Done | `1ad70db5` |
| 3. Mirror types in `Module.swift` | ✅ Done | `9c0ca8c9` |
| 4. `Host.swift` / `HostSurfaceAttachment.swift` simplification | ✅ Done | `9c0ca8c9` |
| 5. `MountConsumer.swift` reads typed values | ✅ Done | `9c0ca8c9`; event-driven via `didFinishTransaction` + `MountSurfaceContext` per Phase 4 finishing pass |
| 6. Networking plan workarounds preempt themselves | 🟡 Available | Apply when the networking plan's Phases 3–5 land |
| 7. `NucleusTextLayoutManager` Swift-side override | ✅ Done | |
| 8. Tests | ✅ Done | `1ad70db5` + `9c0ca8c9` |
| 9. `Bridge.hpp` becomes a smaller seam | 🟡 Implicit | Scope narrows by convention; no diff required |
| A. `std::string_view` for read-only string params | 🟡 Available | Apply opportunistically |
| B. Typed container parameters | 🟡 Available | Apply by default to new APIs |
| C. Swift subclasses C++ classes (mixed-library bridge) | ✅ Pattern established | `9c0ca8c9` (`MountingObserver`) + text-layout (`SwiftTextLayoutManager`) — Hermes `HostFunction`, JSI `HostObject`, etc. follow the same shape |
| D. libc++ hardening for debug builds | ⬜ Pending | One-line `-D_LIBCPP_HARDENING_MODE=…` |
| E. Sanitizer uniformity | ⬜ Pending | No upfront work; benefits accrue on next sanitizer build |
| F. C++ exceptions across the boundary | ⬜ Deferred | Revisit on next IPC / JSI error-propagation refactor |
| G. Direct JSI calls from Swift | ⬜ Deferred | Revisit during later runtime-host plan phases |
| H. Direct Skia calls from Swift | ⬜ Deferred | Revisit on text/framebuffer-effect work |
| I. C++20 `import std;` | ⬜ Deferred | Revisit when bridge compile times become a bottleneck |
| J. Umbrella header for bridge `.cpp` files | ✅ Done | |
| K. STL specialization bridge helpers (`create_*`) | ⬜ Deferred | Land alongside the first Swift call site that constructs an STL specialization (likely networking Phase 3) |
| L. `std::function` wrapper for Swift closures | ⬜ Deferred | Land alongside the first Swift call site that registers a closure into a C++ API taking `std::function`. **Not** triggered by Phase 6 — RN ships portable C++ TurboModules that handle the JSI host functions C++-side. Trigger is whenever we want Swift to expose a JSI `HostFunction` / `HostObject` method directly. |
| P5. Phase 5 — component descriptor parity (Image) | ✅ Done | `ReactImageComponentView` + `imageSource` field on `MountMutation`; local-file / `file://` URIs render via substrate image registry |
| P5. Phase 5 — component descriptor parity (ScrollView) | ⬜ Deferred | Land alongside the first shell widget that needs overflow / scrolling |
| P5. Phase 5 — component descriptor parity (Pressable / touch) | ⬜ Deferred | Highest-leverage Phase 5 add for interactive shell widgets; needs gesture event delivery from compositor input |
| P5. Phase 5 — component descriptor parity (TextInput) | ⬜ Deferred | Needs keyboard event plumbing; substantial cross-cutting work |

Legend: ✅ landed in tree · 🟡 unlocked and ready to apply · ⬜ pending or deferred.

## Catalog

### 1. FabricMountEventCallback — the 34-parameter C function pointer

**Status:** ✅ Landed in `9c0ca8c9`. The 34-arg callback type,
`@convention(c)` shim, `RuntimeMountEventSink`-as-trampoline-context,
and Swift mirror types are deleted. The runtime-host `.so` is now a
mixed C++/Swift artifact.
`SwiftMountingObserverBridge.cpp` holds a `SwiftMountingObserver`
Swift class instance and forwards `MountingObserver::didMount(...)`
into Swift via `NucleusReactRuntimeCxx.h`.

**Phase 4 finishing pass:** the abstract `MountingObserver` gained a
`didFinishTransaction(surfaceId)` method that the C++
`NucleusMountingObserver` fires at the end of each
`captureTransaction`. The Swift wrapper, bridge `.cpp`, and
`MountingObserverHandler` protocol all carry the new method; the
Swift consumer accumulates events from `didMount` and materializes
the batch in `didFinishTransaction`. The intermediate
`RuntimeMountEventSink` polling buffer and the
`drainMountEvents`/`pendingMountEventCount` facade APIs are deleted —
mount delivery is now event-driven, not poll-driven.

**Where:**
- `swift/Sources/NucleusReactRuntime/cxx/include/NucleusReactRuntime/ReactRuntimeHost.hpp:5-40`
  (callback type declaration)
- `swift/Sources/NucleusReactRuntime/cxx/ReactRuntimeHost.cpp:781-854`
  (`NucleusMountingObserver::emitEvent`, the C++ call site)
- `swift/Sources/NucleusReactRuntimeCxx/Module.swift:219-298`
  (the Swift `@convention(c)` shim that reassembles a struct from
  positional args)

**Why it exists today:**
Two constraints conspired into the current shape:
1. Swift cannot take `std::string` parameters cleanly through interop
   under the pre-libc++-aligned toolchain, so every text field flows
   through `const char *`. Every optional field is "flattened" by
   adding a companion `int hasFoo` flag (e.g. `hasBackgroundColor`,
   `hasTextAttributes`, `hasTextColor`).
2. Swift's C++ interop **cannot subclass a C++ class from Swift
   across module boundaries**, even with `SWIFT_SHARED_REFERENCE`
   annotations. (Verified — see "Toolchain interop reality" below.)

The result is one function pointer with 34 positional arguments —
eight integers, six floats, four doubles, four `const char *`, and
an opaque context pointer. Swift implements the callback with a
`@convention(c)` shim and an `Unmanaged.passUnretained` context
pointer that the shim casts back to a Swift class.

**Toolchain interop reality (Swift 6.4-dev with libc++):**

Probed `swift/Sources/NucleusReactRuntime/cxx/CxxVirtualOverrideProbe.{hpp,cpp}`
+ `swift/Tests/NucleusReactRuntimeCxxTests/CxxVirtualOverrideSmokeTests.swift`.
Findings:

| Pattern attempted | Result |
|---|---|
| Plain C++ class with virtual method, Swift subclasses it | ❌ Class imports as Swift struct, not class type. |
| `SWIFT_SHARED_REFERENCE` C++ class, Swift subclasses it | ❌ Class imports as Swift class, but `cannot inherit from non-open class outside its defining module`. `bridging.h` has no `SWIFT_OPEN_CLASS` macro and `swift_attr("open")` doesn't lift it. |
| Swift closure converts to `std::function<>` | ❌ `std::function` imports as Swift value type with no closure-from-Swift conversion. |
| `@convention(c)` callback with `UnsafePointer<C++ struct>` arg | ❌ C++ struct with `std::string` members isn't C-representable. |
| `@convention(c)` callback with `void* context` + `const void*` opaque to mutation, Swift unwraps with `assumingMemoryBound` | ✅ Works today. Keeps Unmanaged + @convention(c) Swift boilerplate. |
| C++ holds Swift class via `-emit-clang-header` and calls Swift method (Nitro's pattern) | ✅ Works in principle. Our build emits the headers but doesn't currently expose `NucleusReactRuntimeCxx`'s emitted header to C++ — requires build wiring. |

The first three patterns are all variations of "Swift subclasses
C++". None work cross-module. Nitro (the production reference at
`~/Developer/nitro`) demonstrates that the supported pattern is the
inverse: C++ holds Swift class as a refcounted member and forwards
virtual calls to it. Nitro's own Swift code never subclasses C++ —
their `class HybridChild: HybridChildSpec` inherits a *Swift*
typealias (`HybridChildSpec_protocol & HybridChildSpec_base`),
both codegen'd Swift types that bridge to C++.

Item 1's design follows the same shape. See "Sketch of target shape"
below.

**Sketch of current shape:**

```cpp
// ReactRuntimeHost.hpp
using FabricMountEventCallback = void (*)(
    void *context,
    int surfaceId, int eventType, int tag, int parentTag,
    int oldTag, int newTag, int index,
    const char *componentName,
    const char *nativeId,
    double frameX, double frameY, double frameWidth, double frameHeight,
    int hasBackgroundColor,
    float backgroundRed, float backgroundGreen, float backgroundBlue, float backgroundAlpha,
    int layoutDirection,
    const char *text,
    int hasTextAttributes,
    const char *fontFamily,
    float fontSize, int fontWeight, int fontSlant,
    int hasTextColor,
    float textRed, float textGreen, float textBlue, float textAlpha,
    double lineHeight, int textAlignment, int maximumNumberOfLines, int lineBreakMode);
```

**Sketch of target shape (Nitro-equivalent — C++ holds Swift):**

Three pieces working together. The Swift class never subclasses
anything C++ — that's not a supported feature. The C++ bridge class
is the actual subclass of the abstract observer.

```cpp
// 1. Value-type mutation struct (typed fields, safe now that libc++
//    is aligned).
struct MountMutation {
  facebook::react::SurfaceId surfaceId;
  MountEventType type;
  facebook::react::Tag tag, parentTag, oldTag, newTag;
  int index;
  std::string componentName;
  std::optional<std::string> nativeId;
  Rect frame;
  std::optional<Color> backgroundColor;
  LayoutDirection layoutDirection;
  std::optional<std::string> text;
  std::optional<TextAttributes> textAttributes;
};

// 2. C++ abstract observer — what the Fabric mounting machinery
//    holds and calls. Pure C++; no Swift involvement at this layer.
class MountingObserver {
 public:
  virtual ~MountingObserver() = default;
  virtual void didMount(const MountMutation &mutation) = 0;
};
```

```swift
// 3a. Swift implementation class — a regular Swift class.
//     Lives in NucleusReactRuntimeCxx, gets exposed to C++ via
//     -emit-clang-header.
public class SwiftMountingObserver {
    public init() { }
    public var received: [MountMutation] = []
    public func didMount(_ mutation: nucleus.react.MountMutation) {
        received.append(mutation)
    }
}
```

```cpp
// 3b. C++ bridge class — subclasses the C++ abstract MountingObserver
//     and holds the Swift class as a member. Each virtual call
//     forwards into the Swift instance. Lives in a new bridge C++
//     file that compiles after Swift modules emit their headers.
#include "NucleusReactRuntimeCxx-Swift.h"

class SwiftMountingObserverBridge final : public MountingObserver {
  NucleusReactRuntimeCxx::SwiftMountingObserver swiftPart_;
 public:
  explicit SwiftMountingObserverBridge(
      NucleusReactRuntimeCxx::SwiftMountingObserver swift)
    : swiftPart_(std::move(swift)) {}

  void didMount(const MountMutation &mutation) override {
    swiftPart_.didMount(mutation);  // C++ → Swift method call
  }
};
```

The user-facing Swift API is natural — a public Swift class with
methods. The mechanism (C++ bridge holding Swift class, calling
methods through Swift's emitted C++ header) is hidden inside the
runtime-host facade.

**Build wiring required:**

- Emit the `NucleusReactRuntimeCxx` target's Swift→C++ header by
  adding `-emit-clang-header-path` to its `swiftSettings`
  (`.unsafeFlags`) in the RN platform's `Package.swift`, so its
  generated header is available to C++.
- Ensure the bridge C++ file lives in a target that depends on
  `NucleusReactRuntimeCxx` so SwiftPM sequences it **after** the
  Swift module has emitted its header (a dedicated bridge C target,
  or the existing runtime-host C++ target with the emitted-header
  directory added to its dependency edge).
- Make the emitted header path visible to that bridge compile via a
  header-search-path flag (`-I` / `.unsafeFlags(["-I", ...])`) in the
  bridge target's settings.

**Delta:**
- Delete: callback type declaration (~36 lines), `emitEvent`'s
  argument-marshaling block (~75 lines), Swift's `@convention(c)`
  shim (~80 lines), Swift mirror types `RuntimeMountEvent`,
  `RuntimeTextAttributes`, `RuntimeLineBreakMode`,
  `RuntimeTextAlignment`, `RuntimeLayoutDirection`,
  `RuntimeMountEventType` and the `RuntimeMountEventSink` plumbing
  (~120 lines combined in `Module.swift:4-95`).
- Add: `MountMutation` struct (~25 lines C++), abstract
  `MountingObserver` (~10 lines C++), `SwiftMountingObserverBridge`
  (~25 lines C++), `SwiftMountingObserver` Swift class (~30 lines),
  SwiftPM manifest wiring (~30-50 lines).
- **Net: ~310 lines deleted, ~120 added** (the SwiftPM manifest
  wiring bumps the add column; the deletion stays the same). And the
  "what does argument 24 mean" question stops existing.

### 2. Dual `std::string` / `const char *` method pairs on the facade

**Status:** ✅ Landed in `1ad70db5`. Every paired `*Path` / `*CStr` /
`*Key` overload collapsed to the single `std::string` variant; Swift
call sites use `std.string(swiftString)` and `String(cxxString)`.

**Where:**
- `swift/Sources/NucleusReactRuntime/cxx/include/NucleusReactRuntime/ReactRuntimeHostFacade.hpp`
  has five method pairs (lines 30-59):
  - `evaluateBytecode(const std::string &)` / `evaluateBytecodePath(const char *)`
  - `runApplication(int, const std::string &)` / `runApplicationKey(int, const char *)`
  - `evaluateJavaScriptSource(const std::string &, const std::string &)` / `evaluateJavaScriptSourceCStr(const char *, const char *)`
    (added in `docs/rn-networking-and-websocket-plan.md` Phase 1)
  - `emitDeviceEvent(const std::string &, const std::string &)` / `emitDeviceEventCStr(const char *, const char *)`
    (same)
- Plus the two-phase string readback API:
  `evaluateJavaScriptForStoredResult(const char *, const char *)` +
  `lastEvaluationResult() const` (also Phase 1).

**Why it exists today:**
Each `const std::string &` overload is the "natural" C++ signature.
The `*Path` / `*CStr` / `*Key` twin exists solely so Swift can pass
`const char *` from `withCString { ... }` without engaging the
libstdc++-shaped CxxStdlib bridge that would fail to link.

**Sketch of current shape:**

```cpp
// facade .hpp — every input string has two methods
void evaluateBytecode(const std::string &path);
void evaluateBytecodePath(const char *path);
```

```swift
// Module.swift — Swift always uses the CStr variant
public func evaluateBytecode(at path: String) {
    path.withCString { pathPointer in
        facade.evaluateBytecodePath(pathPointer)
    }
}
```

**Sketch of target shape:**

```cpp
// facade .hpp — one method
void evaluateBytecode(const std::string &path);
```

```swift
// Module.swift — direct std.string bridge
public func evaluateBytecode(at path: String) {
    facade.evaluateBytecode(std.string(path))
}
```

**Delta:**
- Delete the five `*Path` / `*CStr` / `*Key` overloads in the
  facade header (~10 lines) plus their bodies in `ReactRuntimeHost.cpp`
  (~50 lines total). Delete the `withCString` ladders on the Swift
  side (~30 lines across eight call sites in `Module.swift:115-181`).
- Two-phase readback collapses: `evaluateJavaScriptForStoredResult`
  + `lastEvaluationResult` + `lastEvalResult_` member become a
  single `std::string evaluateJavaScriptForString(...)` returning
  by value (~30 lines deleted, ~5 added).
- **Net: ~110 lines deleted, ~20 added.** The asymmetry between
  C++ callers (who use the `std::string` overload) and Swift callers
  (who used the char* overload) disappears.

### 3. Mirror types in `Module.swift`

**Status:** ✅ Landed in `9c0ca8c9`. All six enum/struct mirrors are
gone. Swift now uses `nucleus.react.MountEventType`,
`nucleus.react.LayoutDirection`, `nucleus.react.TextAlignment`,
`nucleus.react.LineBreakMode`, `nucleus.react.TextAttributes`, and
`nucleus.react.MountMutation` directly. `RuntimeMountEventSink`
remains as the name of the class that now *implements*
`MountingObserverHandler`, but its internals are the typed C++ shape
rather than the flat-positional reconstruction.

**Where:** `swift/Sources/NucleusReactRuntimeCxx/Module.swift:4-95`

Six types exist purely to receive the flat-positional-argument
explosion from the mount event callback:

- `RuntimeMountReport` (struct, lines 4-7) — could remain or
  pass through directly.
- `RuntimeMountEventType` (enum, lines 9-15)
- `RuntimeLayoutDirection` (enum, lines 17-21)
- `RuntimeTextAlignment` (enum, lines 23-28)
- `RuntimeLineBreakMode` (enum, lines 30-34)
- `RuntimeTextAttributes` (struct, lines 36-51)
- `RuntimeMountEvent` (struct, lines 53-75)
- `RuntimeMountEventSink` (final class, lines 77-95) — Swift-side
  buffer with thread-unsafe staging and a UnsafeRawPointer registry
  to the C callback.

These are reconstructions of C++-side records that already exist in
`react/renderer/mounting/ShadowViewMutation.h` and friends. Once
Swift can directly consume those C++ records, the mirrors are dead
weight.

**Target shape:**

Direct Swift access to the C++ `MountMutation` value type proposed
in §1. Swift code:

```swift
extension MyMountConsumer: nucleus.react.MountingObserver {
    func didMount(_ mutation: nucleus.react.MountMutation) {
        let surface = Int(mutation.surfaceId)
        let component = String(mutation.componentName)  // std::string -> String
        if let nativeId = mutation.nativeId {           // std::optional<std::string>
            register(nativeId: String(nativeId), tag: Int(mutation.tag))
        }
        // ...
    }
}
```

No mirror types. No `UnsafeRawPointer` registry. No `@convention(c)`
trampoline. No `@unchecked Sendable` shim on a class whose only job
is to be a function-pointer context.

**Delta:**
- Delete: ~92 lines of mirror types + the `RuntimeMountEventSink`
  class.
- Add: Swift `MountingObserver` conformance per consumer (~15 lines
  per consumer).
- **Net: ~75 lines deleted across the package.**

### 4. `Host.swift` and `HostSurfaceAttachment.swift` simplification

**Status:** ✅ Landed in `9c0ca8c9`. `Host` no longer carries an
`Unmanaged.passUnretained` opaque context or a C-callback registry.
`RuntimeHost.init` constructs a `SwiftMountingObserver(sink)` and
passes the retained pointer to `nucleus.react.makeSwiftMountingObserverBridge`,
which the facade installs via `setMountingObserver(...)`. The
opaque round-trip survives only inside `SwiftMountingObserver.toUnsafe`
/ `fromUnsafe`, which mirror Nitro's `Unmanaged` factory pattern.

**Where:**
- `swift/Sources/NucleusReactRuntimeCxx/Host.swift` (107 lines)
- `swift/Sources/NucleusReactRuntimeCxx/HostSurfaceAttachment.swift`
  (46 lines)

These currently allocate a `RuntimeMountEventSink` per host, register
it as opaque context with the C callback, and reconstruct
`RuntimeMountEvent` values on every mount. They also use
`Unmanaged.passUnretained(...).toOpaque()` to round-trip the sink
identity through C.

**Target shape:**

The host holds a `std::shared_ptr<MountingObserver>` (Swift-side
implementation, passed in via the facade). No sink, no
`UnsafeRawPointer` context, no opaque round-trip. Swift's class
identity flows naturally because the observer's `didMount` method
runs on the Swift instance.

**Delta:**
- Delete: ~40 lines of sink wiring and Unmanaged dancing across
  `Host.swift` and `HostSurfaceAttachment.swift`.
- Add: ~10 lines for `MountingObserver` conformance hookup.
- **Net: ~30 lines deleted.**

### 5. `MountConsumer.swift` reads typed values, not flat fields

**Status:** ✅ Landed in `9c0ca8c9`. The `materialize` switch is now
over `nucleus.react.MountEventType` cases; presence checks are
`event.textAttributes != nil` and `event.backgroundColor != nil`
(via the Swift `MountEvent` wrapper that surfaces
`std::optional<...>` as Swift `Optional`). A thin `MountEvent` /
`TextAttributesSnapshot` Swift struct wraps the C++ value because
methods returning `[nucleus.react.MountMutation]` don't surface
across Swift module boundaries — the wrapper preserves typed access
while keeping public Swift signatures Swift-native.

**Where:** `swift/Sources/NucleusReactRuntimeCxx/MountConsumer.swift`
(282 lines)

The consumer today receives `RuntimeMountEvent` (the mirror struct)
and rebuilds intent: was this a Paragraph mount? Was it a View? The
intent reconstruction relies on string-comparing `componentName` and
flag-checking `hasTextAttributes`.

After alignment + §1, the consumer receives `MountMutation` with:
- A typed `MountEventType` enum (not an int that maps to a Swift
  enum's raw value).
- `std::optional<TextAttributes>` — the presence check is the
  optional itself, no parallel `hasTextAttributes` flag.
- `std::optional<Color>` for background color.

`MountConsumer.swift`'s switch statements become smaller; the
"unwrap the flag, then read the field" pattern becomes "guard let
attributes = mutation.textAttributes".

**Delta:**
- ~40 lines simplified (not deleted outright — same logic, fewer
  intermediate checks).

**Phase 4 finishing pass:** the consumer no longer drains an external
buffer; it implements `MountingObserverHandler` directly. Per-surface
`MountSurfaceContext` (rootView + registry + environment) is
registered via `Host.attachSurface`, and the consumer materializes
each batch in `didFinishTransaction` against the matching context.
The old `MountingConsumer` polling class is removed; `attachSurface`
captures the materialize callback that runs the layer transaction
and committed display content. Materialize for surfaces whose
context hasn't been registered yet stays buffered until the next
attach.

### 6. Networking plan's per-method workarounds preempt themselves

**Status:** 🟡 Unlocked, not yet exercised. Apply when
`docs/rn-networking-and-websocket-plan.md` Phases 3–5 land — the
clean signatures are usable from day one and no workaround code
should be written.

**Where:** `docs/rn-networking-and-websocket-plan.md` Phases 3-5
have several signature lines marked as carrying the libstdc++ /
libc++ workaround pattern. Examples from the plan:

- Phase 4: HTTP response bodies must be returned through opaque blob
  handles + size pairs because `std::vector<uint8_t>` can't cross
  cleanly.
- Phase 4: Header maps documented as `(name, value, len)` triples
  through a callback because `std::map<std::string, std::string>`
  is blocked.
- Phase 5: WebSocket close reasons documented as
  `(const char *reason, size_t length)` instead of
  `std::optional<std::string>`.
- Phase 3: BlobStore writes must use raw pointers; reads return
  opaque handles. `std::span<uint8_t>` would be the natural shape.
- Multiple phases: timeouts use `double` seconds. `std::chrono::milliseconds`
  is the natural type.

These workarounds aren't *implemented yet* (the plan documents
them); they're scoped to land alongside Phases 3-5. After alignment,
those phases land with the cleaner signatures from day one —
**zero workaround code ever gets written.**

**Dependency:** the first Phase where a Swift caller assembles an
STL specialization from scratch (`std::vector<uint8_t>` body,
`std::map<std::string, std::string>` headers) needs item K's
`create_*` / `pushBack_*` helper pattern landed in the same change.
Receiving containers back from C++ works without K; constructing
them does not.

**Delta:**
- Negative work: the cleanup is "don't write the workaround". Hard
  to count, but the plan's Phase 4 risk-section mentions multiple
  workaround sites; conservatively each saves ~20 lines and one
  layer of mental indirection. Across HTTP + WebSocket + Blob, this
  is ~150 lines of network-module code that simply doesn't exist.

### 7. `NucleusTextLayoutManager` Swift-side virtual override

**Status:** ✅ Landed.
The C++ `NucleusTextLayoutManager` class and its `textStyle` /
`textRuns` / `textAlignment` / `makeParagraphStyle` helpers are
deleted. `FabricRuntime`'s ctor now requires a Swift handle and
constructs `SwiftTextLayoutManagerBridge` directly — there is no
fallback path.

**Where it lives now:**
- `swift/Sources/NucleusReactRuntime/cxx/include/NucleusReactRuntime/TextLayoutManager.hpp`
  — public C++ surface (`TextMeasureRequest`, `TextMeasureResult`,
  `makeSwiftTextLayoutManagerBridge`, `releaseSwiftTextLayoutManagerHandle`,
  plus the test-only `makeSingleRunMeasureRequest`).
- `swift/Sources/NucleusReactRuntime/cxx/SwiftTextLayoutManagerBridge.cpp`
  — concrete C++ subclass of `facebook::react::TextLayoutManager`
  that holds a `NucleusReactRuntimeCxx::SwiftTextLayoutManager` and
  marshals `AttributedStringBox` / `ParagraphAttributes` /
  `LayoutConstraints` into a typed `TextMeasureRequest` before
  calling into Swift.
- `swift/Sources/NucleusReactRuntimeCxx/TextLayoutManager.swift`
  — `TextLayoutManagerHandler` protocol and `SwiftTextLayoutManager`
  wrapper class (mirrors `SwiftMountingObserver`).
- `swift/Sources/NucleusReactRuntimeCxx/DefaultTextLayoutHandler.swift`
  — production handler that calls `nucleus::text::measureParagraph`
  directly through `NucleusTextCxxBridge`.
- `swift/Tests/NucleusReactRuntimeCxxTests/TextLayoutManagerTests.swift`
  — pins the Swift handler against the Skia text backend without RN
  involvement.

**Mechanism diverges from item 1's sketch:** the Swift class does
not subclass `facebook::react::TextLayoutManager` — the bridge
`.cpp` is the subclass, and it holds the Swift class by value. The
Swift handler stays free of `facebook::react` headers because the
bridge owns all RN-to-value-struct marshaling. Same pattern as
`SwiftMountingObserverBridge`, applied to the "RN supplies the
abstract base class" variant.

**Two toolchain frictions surfaced and were worked around:**

- Swift's CxxStdlib refuses to instantiate `std::vector<TextRun>`
  from scratch ("un-specialized class templates are not currently
  supported"). The bridge `.cpp` builds the request and Swift
  forwards it; tests use the C++ helper
  `makeSingleRunMeasureRequest` rather than constructing the vector
  Swift-side. See item K for the generalized pattern.
- Swift closures don't auto-construct `std::function`. The facade
  takes a `void *swiftHandlerRetained` (the result of
  `SwiftTextLayoutManager.toUnsafe()`) and the bridge `.cpp`
  consumes it through `fromUnsafe`. The `FabricRuntime` ctor accepts
  the handle and invokes `makeSwiftTextLayoutManagerBridge` with the
  freshly-built `ContextContainer` — sidestepping the factory
  closure the plan originally proposed. See item L for the
  generalized pattern.

**Delta:** ~125 lines deleted from `ReactRuntimeHost.cpp`, ~180
added across the new bridge `.cpp`, `.hpp`, and two Swift files. Net
add because the bridge layer is more code than an in-place
implementation, but the Swift handler is the natural place for
text-measurement business logic going forward.

### 8. Tests

**Status:** ✅ Landed. `evaluateJavaScriptForString`'s wrapper
collapsed alongside item 2 in `1ad70db5`. `RuntimeHostTests.swift`
moved to the typed `MountEvent` shape in `9c0ca8c9`. The
`CxxVirtualOverrideSmokeTests` were rewritten to drive the new
`Observer` + `ProbeSwiftHandler` bridge.

**Where:** `swift/Tests/NucleusReactRuntimeCxxTests/RuntimeJSCallInvokerTests.swift`

The Phase 1 invoker tests use:

```swift
let log = host.evaluateJavaScriptForString(readbackSource, sourceUrl: "...")
```

which today wraps the two-phase
`evaluateJavaScriptForStoredResult` + `lastEvaluationResult`
pattern. After §2's collapse, this is a single `std::string`
returned by value and auto-converted to Swift `String` via the
CxxStdlib `String(std.string)` initializer.

No test logic changes; the wrapper's implementation simplifies.

**Delta:** the Swift wrapper for `evaluateJavaScriptForString`
becomes a one-liner; ~12 lines of `withCString` + `String(cString:)`
dance deleted.

### 9. `Bridge.hpp` becomes a smaller seam

**Status:** 🟡 Implicit. No diff required; the file's rationale just
narrows. Future C++↔Swift seams should not invent stdlib-avoidance
wrappers, only template-avoidance ones.

**Where:** `swift/Sources/NucleusReactRuntime/cxx/include/NucleusReactRuntime/Bridge.hpp`

Today this header exists to give Swift a non-template, std-string-free
view onto a C++ class. The `HelloBridge` smoke-test class
demonstrates the pattern.

After alignment, the "non-std-string-free" constraint relaxes.
`Bridge.hpp` can be a one-pager that exists only for the
non-template requirement (Swift still can't instantiate C++
templates). The other workaround reason (stdlib type avoidance) is
gone.

**Delta:** Minor — the file stays but its scope narrows. No
immediate line-count change; future additions don't have to invent
parallel APIs.

## Phase 5 progression — RN component descriptor parity

This section is outside the original stdlib-alignment scope but
tracked here for continuity, since items 1, 5, and 7 are the
substrate Phase 5 builds on (event-driven `MountConsumer`,
typed `MountMutation`, Swift-side text-layout) and the catalog is
the running record of the RN runtime-host interop progress.

**Scope:** `ComponentDescriptorProviderRegistry` already registers
Image, ScrollView, TextInput, and the rest of the C++ descriptors in
`ReactRuntimeHost.cpp:1041` — Fabric creates the shadow nodes and
runs layout. The gap is on the Swift consumer side: until a
`ReactComponentView` subclass and factory case exist, Create events
for the component type are dropped, breaking the View tree
topology. Each Phase 5 item adds one component type.

### Image (✅ done)

**Where it lives:**
- C++: `MountMutation.imageSource` (`MountingObserver.hpp`);
  `imageProps(shadowView)` helper + extraction in `buildMountMutation`
  (`ReactRuntimeHost.cpp`).
- Swift: `swift/Sources/NucleusReactRuntimeCxx/ReactImageComponentView.swift`
  (split out so `NucleusLayers` import doesn't collide with
  `Nucleus.Rect`); `MountEvent.imageSource`, `isImageComponent`, and
  the factory case in `MountConsumer.swift`.

**Mechanism:** the Swift component holds a `Nucleus.ImageView`. On
`apply`, parses the source URI; for `file://` or absolute paths,
calls `nucleusRegisterImagePath` against the rootView's
`resourceHostHandle` to get a substrate image handle, wires it onto
the `ImageView`, and sets `imageSize` to the requested cap
dimensions. Releases the handle in `deinit` via captured scalar
copies of handle + resource-host handle (so the deinit can be
`nonisolated`).

**Scope and limits:**
- Only local file paths and `file://` URIs render. Remote URIs
  (`http(s)://`), `asset://`, and `data:` URIs land as
  `imageView.image = nil` — the View tree topology is still correct
  (bounds reserve space), but no pixels until the loading paths
  exist.
- Resource-host-handle threading goes through
  `view.backingLayer.context.commitSink.resourceHostHandle` — same
  path `WallpaperImage` uses. No new ABI plumbing.
- `<Image>` props beyond source URI (`resizeMode`, `tintColor`,
  `blurRadius`, `capInsets`) are not yet read. Additive when a
  product use case needs them.

**Pattern this established:** the per-component-type shape is now
clear — extend `MountMutation` with the props the consumer needs;
add an `is{Name}Component` predicate; add a `React{Name}ComponentView`
class implementing the Phase 4 `ReactComponentView` protocol; route
through `ReactComponentViewFactory.make`. Roughly ~150–200 lines per
component for the common case.

**Adjacent unlock:** Phase 6a wires the shared C++ Animated backend
(`AnimatedModule`) on Path 1 — `useNativeDriver: true` animations
route through Fabric mount mutations (existing `MountConsumer`) or
a direct-manipulation tag→view bridge. Phase 6b then swaps to Path 2
(`useSharedAnimatedBackend=true`), where animated prop snapshots
arrive as part of the committed shadow tree via
`AnimationBackendCommitHook` and the three-lambda bridge is
deleted. The Path 2 design — `NucleusVsyncSource` trait,
choreographer wrapper, per-platform vsync sources for the
compositor and standalone targets — is detailed in
`docs/rn-animation-backend-plan.md`. Either way, shell widgets
gain Reanimated-class animation perf as a side-effect of Phase 6;
per-component Phase 5 work doesn't need its own animation
plumbing.

### ScrollView (⬜ deferred)

**Why it matters:** unlocks any shell widget that needs to overflow
its container (settings panels, notification trays, longer menus).

**Sketch of work:**
- New props on `MountMutation`: at minimum `contentOffset`,
  `contentSize`, plus the scrollable-axis flags.
- New `ReactScrollViewComponentView` that wraps a Nucleus scroll
  surface (or a manual `View` + content layer pair if Nucleus
  doesn't have a first-class scroll view yet — needs investigation).
- Bidirectional state: scroll position changes need to flow back to
  JS via the JSI event path. That's net-new plumbing in this
  catalog (every other Swift-side consumer has been read-only).
- Phase 4's event-driven `MountConsumer` already handles the
  Update path; ScrollView updates from JS flow through naturally.

**Trigger:** first shell widget that needs scrolling.

### Pressable / touch handling (⬜ deferred — highest leverage)

**Why it matters:** every interactive shell widget needs touch
events. Today the topbar renders but cannot respond to clicks. This
is the qualitative jump from "shell widgets render" to "shell
widgets are interactive."

**Sketch of work:**
- Compositor input events (currently consumed by Wayland XDG /
  pointer state in `src/compositor/`) need a route into the React
  runtime. The natural shape: when a click hits a hosted shell
  surface, dispatch a Fabric event through the Scheduler's event
  pipeline.
- Pressable doesn't have its own component descriptor in RN — it's
  implemented in JS over `View` with `onPress`/`onPressIn`/`onPressOut`
  handlers. So the consumer side stays largely unchanged; the work
  is in event delivery: hit-testing in Swift against the registered
  view tree, then firing the corresponding RN event via
  `EventEmitter::dispatchEvent`.
- Coordinates with item G (direct JSI from Swift) and item L
  (`std::function` wrapper) — event dispatch is one place
  Swift-originated JSI calls become natural.

**Trigger:** any shell-widget product need that goes beyond static
display. Realistically the next product step after the topbar.

### TextInput (⬜ deferred — substantial)

**Why it matters:** search bars, command palettes, anything that
takes typed input. Lower priority than Pressable but a frequent
shell-widget need.

**Sketch of work:**
- IME / compositor keyboard event delivery to the React runtime
  (parallel concern to Pressable's pointer delivery).
- `MountMutation` extensions for `value`, `placeholder`, selection
  state, and the various keyboard / input-mode props.
- `ReactTextInputComponentView` wrapping a Nucleus text-input
  control (or building one if absent).
- Bidirectional state: keystrokes generate `onChangeText` events
  back to JS.

**Trigger:** product need for typed input in a shell widget.
Defer until Pressable lands, since the event-delivery scaffolding
will be reusable.

## Aggregate delta

Counting only items 1-5 + 8 (concrete code already in tree),
including the SwiftPM manifest wiring item 1 now requires:

- **Deleted:** ~620 lines across `Module.swift`, `Host.swift`,
  `HostSurfaceAttachment.swift`, `ReactRuntimeHost.{hpp,cpp}`,
  `ReactRuntimeHostFacade.{hpp,cpp}`, and the test file.
- **Added:** ~220 lines (the new `MountMutation` struct, the
  abstract `MountingObserver`, the `SwiftMountingObserverBridge`
  C++ bridge, the `SwiftMountingObserver` Swift class, the trimmer
  Swift consumers, plus the SwiftPM manifest changes to emit and
  consume Swift's C++ header).
- **Net: ~400 lines deleted.** Slightly less than the original
  ~445-line estimate because the Nitro-equivalent bridge layer is
  more code than the originally-imagined "Swift class directly
  conforms to C++ MountingObserver" shape would have been. The
  ergonomics for the consumer (Swift code authoring an observer)
  are unchanged — they still write a natural Swift class with
  methods.

Item 7 is in tree: ~125 lines of C++ deleted from
`ReactRuntimeHost.cpp`, ~180 added across the new bridge `.cpp`,
`.hpp`, two Swift files, and the new test file. Net add because the
bridge layer is more code than an in-place implementation, but the
Swift handler is the natural place for text-measurement business
logic going forward.

Item 6 is a negative-work win (cleanup that doesn't have to be
written in the first place); it doesn't show up in a diff but
materially shrinks the networking plan's Phases 3-5.

## Broader unlocks beyond the catalog

Items 1-9 above are specific code-change cleanups: each names files,
lines, and a concrete diff. They were known before the toolchain
swap as workarounds that should collapse once the alignment landed.

This section catalogs the unlocks that go *beyond* specific
cleanups — patterns to apply by default in future code, cross-cutting
opportunities, and larger architectural revisits that the alignment
makes viable but doesn't force.

### Patterns to apply by default in new C++ interop code

These don't require a refactor today. They change how new interop
APIs should be written from this point forward.

#### A. `std::string_view` for read-only string parameters

**Where:** any C++ method whose Swift caller passes a string and
only reads it (no storage, no mutation).

**Why it matters:** today `evaluateJavaScriptForString(const
std::string &source, ...)` requires every call to allocate a new
`std::string` on the C++ side from the Swift `String`. With
`std::string_view`, the C++ side borrows the Swift string's UTF-8
buffer without copying.

**Sketch:**

```cpp
// before
std::string evaluateJavaScriptForString(
    const std::string &source,
    const std::string &sourceUrl);

// after
std::string_view source / std::string_view sourceUrl on the
inbound side; std::string remains the return type since Swift
needs to own the result.
```

Swift call sites pass `String` values directly; the `CxxStdlib`
overlay materializes a `std::string_view` without allocation.

**Apply opportunistically** when touching an existing facade method
for other reasons. No big-bang sweep needed.

#### B. Typed container parameters: `std::vector`, `std::map`, `std::optional`, `std::chrono::*`

**Where:** any future API that would historically use pointer +
length, JSON-encoded payloads, has-value flags, or millisecond
integers.

**Why it matters:** previously the only safe stdlib type across the
Swift/C++ boundary was `const char *`. With alignment, every
trivially-comparable / trivially-copyable stdlib container is now
bridgeable. The natural shape stops requiring a workaround.

Concrete future targets (anticipated, not yet written):

- HTTP / WebSocket payloads: `std::vector<uint8_t>` body bytes,
  `std::map<std::string, std::string>` headers, instead of
  separate `bytes_ptr + length` and JSON-encoded header blobs.
- Timing: `std::chrono::milliseconds` instead of `int64_t ms`.
- Optional return values: `std::optional<std::string>` instead of
  `bool has_value` + `std::string value`.

These are referenced in items 6-7 above
(`rn-networking-and-websocket-plan.md`) but apply to *any* new
interop API, not just those plans.

**Caveat:** Swift can pass containers it receives from C++ back to
C++, but **cannot construct STL specializations from scratch**
("un-specialized class templates are not currently supported"). Any
new API whose Swift caller *originates* a container value needs the
bridge-helper pattern in item K.

#### C. Swift subclasses C++ classes (extending the MountingObserver pattern)

**Status:** ✅ Pattern established in `9c0ca8c9`. The bridge shape
(abstract C++ class + Swift wrapper class held by value + `void *`
`Unmanaged` factory in the public header + bridge `.cpp` that
includes the emitted Swift header) lives in
`SwiftMountingObserverBridge.cpp` and `MountingObserver.swift`, with
the test-shape mirror in `CxxVirtualOverrideBridge.cpp` /
`CxxBridgeProbe.swift`. New bridges follow the same shape.

**Where:** anywhere we have a `void *context + C-style function
pointer` callback today, or where a C++ object accepts a callback
provided by Swift.

**Why it matters:** item 1 of the catalog establishes the
`MountingObserver` pattern for the Fabric mount event flow. The same
pattern applies elsewhere:

- Hermes runtime host functions (`facebook::hermes::HostFunction`)
- JSI `facebook::jsi::HostObject` for JS-callable Swift objects
- Skia subclasses (e.g. `SkDrawLooper`, `SkPaintFilter`
  derivatives) for Swift-implemented drawing extensions

**Apply when** writing a new bridge that would historically have
needed a C-style callback. Existing code can migrate alongside
unrelated refactors of those subsystems.

**Caveat:** the pattern as established (one Swift instance held by
the bridge for the bridge's lifetime) does not cover the per-call
closure shape JSI / Hermes / Skia functor parameters need. For
those, item L's `std::function` wrapper is the right tool.

#### J. Umbrella header for bridge `.cpp` files

**Status:** ✅ Landed.

**Where:** `swift/Sources/NucleusReactRuntime/cxx/include/NucleusReactRuntime/SwiftCxxUmbrella.hpp`
includes every C++ header that defines a type Swift's public API
mentions, then includes `<NucleusReactRuntimeCxx.h>`. Bridge
`.cpp` files (`SwiftMountingObserverBridge.cpp`,
`SwiftTextLayoutManagerBridge.cpp`, `CxxVirtualOverrideBridge.cpp`)
include only the umbrella.

**Why it matters:** the emitted Swift→C++ header references every
C++ type any Swift public API mentions. If the `.cpp` that includes
it doesn't first include the headers that define those types, the
emitted header emits forward references against an empty namespace
and compilation fails — and every new Swift public type adds another
required include to every bridge `.cpp` that already exists. We hit
this twice while landing item 7 (each bridge `.cpp` had to grow a
new `#include <NucleusReactRuntime/TextLayoutManager.hpp>`). The
umbrella owns the ordering once.

**Pattern inspired by** Nitrogen's `{Module}-Swift-Cxx-Umbrella.hpp`
(`~/Developer/nitro/packages/nitrogen/src/autolinking/ios/createSwiftUmbrellaHeader.ts`),
which auto-emits the same shape with topologically-sorted forward
declarations and includes.

**Apply by:** any new bridge `.cpp` should include the umbrella, not
the emitted header directly. Any new C++ header whose types Swift's
public API mentions should be added to the umbrella's include block.
Do not put the umbrella in `NucleusReactRuntimeCxxBridge.modulemap`
— it would form a Swift-imports-its-own-output cycle.

### Cross-cutting opportunities

These touch the build system or runtime configuration rather than
individual APIs. Low effort, high signal.

#### D. libc++ hardening for debug builds

**Where:** SwiftPM debug builds and the toolchain's debug Swift modules.

**What it does:** libc++ has a runtime hardening mode that
bounds-checks all container accesses, validates iterators, and
catches use-after-move. Toggled by defining
`_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_DEBUG` (or `_FAST` /
`_EXTENSIVE` for lighter modes) before including any libc++ header.

**Why it matters:** catches a class of memory bugs in the
RN/Skia/JSI interop layer that Swift's compile-time safety cannot see
(because the bugs live in C++ code). Free for debug builds; not
appropriate for release.

**Apply by:** adding `-D_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_DEBUG`
to the C++ targets' debug `cxxSettings` (`.unsafeFlags` gated on
`.when(configuration: .debug)`) in the relevant `Package.swift`.

#### E. Sanitizer uniformity (ASan / TSan / UBSan)

**Where:** sanitizer-instrumented builds of nucleus.

**What changes:** previously, mixed-stdlib builds would have
sanitizers either skip the C++ stdlib at the boundary or generate
false positives. With a single libc++ across the whole C++ side,
sanitizer instrumentation is consistent end-to-end.

**Apply by:** running the existing sanitizer build configurations
once a memory bug is suspected. No upfront work; cleaner reports
when used.

### Future opportunities (revisit when friction shows up)

These are available but not yet needed. Their cost-benefit shifts
once specific pain points appear.

#### F. C++ exceptions across the Swift/C++ boundary

**Status:** technically viable now, not yet exercised.

**Pre-alignment:** unsafe — libstdc++ and libc++ used different
unwinding tables, so an exception thrown by one could not be caught
by the other reliably.

**Post-alignment:** Zig (libc++ via `link_libcpp = true`) and
Swift's CxxStdlib (libc++) share a single libc++abi unwinding
implementation. Swift 6's C++ interop supports translating C++
exceptions to Swift errors with the right attributes.

**Revisit when:** an interop layer has a deep error-propagation
chain that would benefit from exceptions over `Result<T, E>`
plumbing — most likely the IPC layer or the JSI host-function
bridges.

#### G. Direct JSI calls from Swift

**Status:** opportunity, not yet pursued.

**Why it matters:** `ReactRuntimeHostFacade` exists in large part
because Swift could not safely touch JSI types (`jsi::String`,
`jsi::Value`, `jsi::Function`, etc. all use `std::string`
internally). The facade marshals everything through safe C-style
APIs.

**Post-alignment:** Swift can hold and pass JSI types directly. The
facade can shrink to just the JSI-internal threading + lifetime
concerns, while value-shaped APIs move to direct Swift calls.

**Dependency:** `facebook::jsi::Function::createFromHostFunction` and
`HostObject::get`/`set` take `std::function` callbacks. If item G's
work registers JSI methods *from Swift* (rather than just calling
existing JSI APIs through interop), it pulls in item L's wrapper-class
pattern. Phase 6 sidesteps this by registering RN's portable C++
TurboModules through a C++ provider — the JSI host functions are
constructed C++-side with C++ callbacks, no Swift closures crossing.

**Revisit when:** the runtime-host-swift-cxx-interop plan's later
phases land, OR a custom NativeModule needs Swift-side business logic
RN's portable C++ catalog doesn't satisfy. Not urgent; the current
facade works.

#### H. Direct Skia calls from Swift

**Status:** opportunity, narrow scope.

**Why it matters:** Skia exposes `SkString`, `SkColor`, `SkRect`
etc. — mostly its own types, not `std::string`. Less direct payoff
than JSI. But the `framebuffer_effect_geometry.zig` Swift bridge
and skia-text-backend paths today use buffer + length marshaling
for the small subset of Skia APIs that take `std::string`.

**Revisit when:** touching the text-rendering or
framebuffer-effect layers for other reasons.

#### I. C++20 modules (`import std;`)

**Status:** experimental in libc++; viable but not stable.

**Why it might matter:** the bridge layer currently
`#include <chrono>`, `<string>`, `<vector>`, etc. across many
Swift translation units. Each TU re-parses thousands of lines of
headers. With C++20 modules, `import std;` parses once.

**Cost:** compilation speed win, currently small (the bridge is
not huge). Setup requires CMake / ninja / module precompilation.

**Revisit when:** Swift's C++ interop stabilizes C++20 modules
consumption, or when bridge compile times become a measurable
bottleneck. Currently neither.

#### K. STL specialization bridge helpers (`create_*`, `pushBack_*`)

**Status:** ⬜ Deferred until the first Swift call site that needs
to construct an STL specialization from scratch.

**Why it matters:** Swift's CxxStdlib refuses to instantiate
un-specialized class templates — `std::vector<TextRun>()`,
`std::map<std::string, std::string>()`, and friends fail with
"un-specialized class templates are not currently supported", even
when the allocator parameter is named explicitly. The current
workaround is per-site: item 7 ships a hand-written
`makeSingleRunMeasureRequest` test helper because the test needed
a populated `std::vector<TextRun>`. Production code never hit it
because the bridge `.cpp` builds the vector and Swift just forwards
the populated value.

This breaks once item B (typed containers in new APIs) plus item 6
(networking Phases 3–5) land. The natural shape for an HTTP body is
`std::vector<uint8_t>`, headers are `std::map<std::string, std::string>`,
WebSocket close reasons are `std::optional<std::string>` — and Swift
call sites that *originate* those values (assembling a request body
from a Swift `Data`, building headers from a Swift dictionary) hit
the un-specialized-template wall every time.

**Pattern from Nitro** (`packages/react-native-nitro-test/nitrogen/generated/ios/NitroTest-Swift-Cxx-Bridge.hpp`):
emit a bridge header in a dedicated namespace with `using` aliases
for every needed specialization and free-function helpers to
construct and mutate them — e.g. `bridge::create_std__vector_uint8_t_()`,
`bridge::pushBack_std__vector_uint8_t_(vec, byte)`. Swift calls those
instead of trying to instantiate the templates directly.

**Apply when:** the first networking-layer or future API needs a
Swift caller to assemble an STL specialization from scratch. Land
the helper header alongside that API's first consumer; pick a small
naming scheme (`bridge::create_*` / `bridge::pushBack_*` works) and
extend it per type as new consumers appear. Avoid building the
infrastructure speculatively — the shape becomes clear once there
are two real consumers.

#### L. `std::function` wrapper for Swift closures

**Status:** ⬜ Deferred until the first Swift call site that needs
to register a closure into a C++ API taking `std::function`.

**Why it matters:** Swift's CxxStdlib does not auto-construct a
`std::function` from a Swift closure. Item 1 and item 7 sidestepped
this by passing `void *swiftHandlerRetained` (the
`Unmanaged.passRetained` opaque pointer) and a paired
`release...Handle(void*)` function to the C++ factory — the closure
shape never appeared because each bridge has exactly one Swift
instance held for the bridge's lifetime, not a per-call closure.

The void-pointer-handle workaround doesn't generalize to the per-call
closure shape JSI needs:
`facebook::jsi::Function::createFromHostFunction` takes
`std::function<jsi::Value(jsi::Runtime&, const jsi::Value&, const jsi::Value*, size_t)>`,
`HostObject::get`/`set` take callback functors, Hermes
`HostFunction` is a `std::function`, and Skia subclasses like
`SkDrawLooper` accept functor parameters. Every direct JSI / Hermes
/ Skia binding from Swift (items C and G's downstream work) needs
this.

**Pattern from Nitro** (`packages/nitrogen/src/syntax/swift/SwiftCxxTypeHelper.ts`,
`createCxxFunctionSwiftHelper`): emit a `{FunctionName}_Wrapper`
class per closure shape that:

- Takes ownership of the function via `std::unique_ptr`.
- Captures `passRetained(closure)` inside a `std::function` lambda
  so RAII drops the retain when the wrapper is destroyed.
- Exposes a `create_*(void *swiftClosureRetained)` factory that
  produces the wrapper from the Swift side's opaque pointer.

The wrapper is constructed once at registration time; the lambda it
holds is the `std::function` the C++ API expects. Cleanup is
automatic.

**Apply when:** the first Swift call site registers a closure into
a JSI / Hermes / Skia API. Copy the wrapper shape from Nitro for
the specific closure signature; the per-shape wrapper class is the
right granularity (one wrapper per `std::function<R(Args...)>`).

## What stays the same

The alignment work does **not** improve:

- **Actual platform / C++ boundaries.** This catalog is about libc++ /
  libstdc++ alignment for C++ interop. Nucleus-owned Swift/Zig C ABI
  surfaces have since been removed. Remaining C and C++
  boundaries are for real C/C++ libraries, platform APIs, and RN/Skia
  integration.
- **Internal C++ plumbing that never crosses to Swift.** The
  `RuntimeJSCallInvoker`, `DeviceEventEmitter`, and
  `TurboModuleRegistry` from Phase 1 of the networking plan are
  C++-only, accessed via the facade. They were already idiomatic.
- **Skia interop.** Skia uses its own `SkString`, not `std::string`.
  No stdlib alignment effect.
- **Swift's own non-interop modules.** Anything that doesn't import
  `Cxx` / `CxxStdlib` or use `-cxx-interoperability-mode=default`
  is unaffected.
- **Template instantiation through interop.** Swift still cannot
  instantiate C++ templates at the call site. `std::shared_ptr<T>`
  for a non-trivial T we define stays a careful interop area.

## Sequencing

Items 1–5 and 8 are done as of `9c0ca8c9`. Item 2 had
already landed in `1ad70db5`. Item 7 is done. Item J landed as a
follow-up. The Phase 4 finishing pass — `didFinishTransaction`
batch boundary on the `MountingObserver` bridge plus event-driven
`MountConsumer` / `MountSurfaceContext` — extended items 1 and 5
beyond their original landings. The remaining items below are
scoped against work that hasn't started or is deferred.

Item 6 happens by default — `docs/rn-networking-and-websocket-plan.md`
Phases 3-5 just use the natural shapes from the start once the
toolchain is ready, and nothing in this catalog needs to be
retrofitted (modulo the item K dependency for Swift-originating
containers).

Item 8 lands with item 2 (facade collapse) since the test wrapper
follows the wrapper code being simplified.

Items A-C of "Broader unlocks beyond the catalog" are *style
guidance*, not scheduled work. They become the default when new
interop APIs are written, and migrate existing APIs only when those
APIs are touched for other reasons.

Items D and E are one-line / no-line wins: D adds a single
`-D_LIBCPP_HARDENING_MODE=...` to the C++ targets' debug
`cxxSettings`; E requires no code change and benefits any
sanitizer-instrumented build once one is needed. Land D alongside
the next time the SwiftPM manifest is touched.

Items F-I are deferred until their specific pain points appear:
* F (exceptions): IPC or JSI error-propagation refactor
* G (direct JSI): runtime-host plan's later phases — pulls in L
* H (direct Skia): text or framebuffer-effect layer refactor —
  may pull in L if Skia subclass functors are needed
* I (C++20 modules): bridge-layer compile times become a bottleneck

Items K and L are deferred until their first consumer:
* K (`create_*` STL helpers): land alongside the first Swift call
  site that constructs an STL specialization from scratch — almost
  certainly networking Phase 3 (BlobStore writes) or Phase 4 (HTTP
  request bodies / headers).
* L (`std::function` wrapper): land alongside the first Swift call
  site that registers a closure into a C++ API taking `std::function`.
  Originally expected to land with Phase 6 (NativeModules + AppRegistry),
  but the audit of `~/Developer/react-native` showed RN ships portable
  C++ TurboModules (AppState, DeviceInfo, PlatformConstants, etc.)
  that handle the JSI host functions C++-side — Phase 6 wires those
  through a C++ provider and never exposes a Swift JSI method.
  Item L is now deferred until either (a) item G (direct JSI from
  Swift) drives a use case for Swift-implemented JSI methods, or
  (b) a future NativeModule needs Swift-side business logic the
  portable C++ catalog can't satisfy.

Phase 5 (component descriptor parity) is incremental — each
component type lands independently using the pattern Image
established:
* Image: ✅ done.
* Pressable / touch: highest-leverage next add for interactive
  shell widgets. Pulls in compositor input → JS event-delivery
  scaffolding, which coordinates with items G and L.
* ScrollView: next product-driven add. Net-new Swift→JS state
  flow (scroll position) but no new toolchain dependencies.
* TextInput: pairs with the keyboard event-delivery work; defer
  until Pressable's event pipeline lands so the scaffolding is
  reusable.
