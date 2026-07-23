// swift-tools-version:6.4
import PackageDescription

// swift-wayland — self-contained Swift-importable Wayland protocol bindings, generated from the
// vendored protocol XML (core wayland.xml, upstream wayland-protocols @ v1.48+2, curated kde/wlr
// extras) by Collider through SwiftWaylandGen + wayland-scanner. Unlike a fixed API (see swift-vulkan),
// Wayland is a menu of protocols consumed in one of two modes; this package ships BOTH pre-built,
// over the full vendored protocol set, so a consumer just imports the module for its role:
//
//   * a compositor imports WaylandServerC (server-side event senders + request vtables),
//   * a client imports WaylandClientC (client-side proxy inlines),
//   * both link WaylandProtocolsC (the wl_interface marshalling — identical for either mode).
//
// The three modules are committed (regenerate on a protocol bump via
// `tools/collider generate wayland`). The systemLibrary modules façade libwayland's own wayland-{server,client}.h,
// so a consumer needs libwayland at build/link time but no protocol XML, no wayland-scanner, and
// no codegen of its own — protocol selection is a runtime decision (which globals it advertises /
// binds), not a compile-time one.
let package = Package(
    name: "swift-wayland",
    products: [
        .library(name: "WaylandColliderRecipe", targets: ["WaylandColliderRecipe"]),
        // Server-side bindings (event senders, request-handler vtables) + the shared marshalling.
        .library(name: "WaylandServerC", targets: ["WaylandServerC"]),
        // Client-side bindings (proxy inlines) + the shared marshalling.
        .library(name: "WaylandClientC", targets: ["WaylandClientC"]),
        // The mode-independent wl_interface marshalling (wayland-scanner private-code). Consumed
        // alongside WaylandServerC or WaylandClientC (both reference these interface symbols).
        .library(name: "WaylandProtocolsC", targets: ["WaylandProtocolsC"]),
        // Ergonomic Swift server layer over WaylandServerC: safe wl_resource ownership, wl_global
        // RAII, and the wl_display / event-loop / socket owner. Policy-free — the plumbing every
        // Swift Wayland server reimplements.
        .library(name: "WaylandServer", targets: ["WaylandServer"]),
        // Generated typed request dispatch over WaylandServer(C): per-interface handler
        // protocols + typed handles + trampolines. Consumers implement the protocol (pure policy).
        .library(name: "WaylandServerDispatch", targets: ["WaylandServerDispatch"]),
        // The client mirror: generated typed EVENT dispatch over WaylandClientC — per-interface
        // handler protocols + the libwayland listener + addListener. Consumers implement the protocol.
        .library(name: "WaylandClientDispatch", targets: ["WaylandClientDispatch"]),
        // Ergonomic Swift client layer over WaylandClient(C/Dispatch): the wl_display connection +
        // event loop, and a generic registry that binds a declared set of globals. The client mirror
        // of WaylandServer — the plumbing every Swift Wayland client reimplements.
        .library(name: "WaylandClient", targets: ["WaylandClient"]),
        // The unified server/client generator, kept vended so an external consumer can generate a
        // bespoke protocol set; Collider drives it to regenerate this package.
        .executable(name: "SwiftWaylandGen", targets: ["SwiftWaylandGen"]),
    ],
    dependencies: [.package(path: "../collider/engine")],
    targets: [
        .target(
            name: "WaylandColliderRecipe",
            dependencies: [.product(name: "ColliderCore", package: "engine")]),
        .executableTarget(name: "SwiftWaylandGen", path: "Sources/SwiftWaylandGen"),
        // The aggregating server/client header + module.modulemap (systemLibrary so the header is
        // processed at each import site, façading <wayland-server.h> / <wayland-client.h>).
        // pkgConfig propagates libwayland's include dirs + link flags to consumers (find
        // <wayland-{server,client}.h>, link -lwayland-{server,client}) — as the per-consumer
        // modules did before this package absorbed them.
        .systemLibrary(name: "WaylandServerC", path: "Sources/WaylandServerC", pkgConfig: "wayland-server"),
        .systemLibrary(name: "WaylandClientC", path: "Sources/WaylandClientC", pkgConfig: "wayland-client"),
        // The wl_interface definitions — one <name>-protocol.c per protocol, compiled once and
        // linked by whichever mode module the consumer uses.
        .target(name: "WaylandProtocolsC", path: "Sources/WaylandProtocolsC"),
        // The ergonomic Swift server layer. Builds under C++ interop (matching how consumers import
        // WaylandServerC) so the wl_* pointer types it exposes are identical to the consumer's.
        .target(
            name: "WaylandServer",
            dependencies: ["WaylandServerC"],
            path: "Sources/WaylandServer",
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
        // The typed request-dispatch layer (currently: wl_surface; the generator will emit the rest).
        .target(
            name: "WaylandServerDispatch",
            dependencies: ["WaylandServerC", "WaylandServer"],
            path: "Sources/WaylandServerDispatch",
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
        // The client event-dispatch layer (mirror of WaylandServerDispatch). Builds under C++ interop
        // to match how consumers import WaylandClientC.
        .target(
            name: "WaylandClientDispatch",
            dependencies: ["WaylandClientC"],
            path: "Sources/WaylandClientDispatch",
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
        // The ergonomic Swift client layer (mirror of WaylandServer): the wl_display connection +
        // event-loop wrapper and the generic registry (binds a declared global set via WlRegistryEvents).
        .target(
            name: "WaylandClient",
            dependencies: ["WaylandClientC", "WaylandClientDispatch"],
            path: "Sources/WaylandClient",
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
        // Standalone proof the client module imports under C++ interop + the marshalling links
        // (the compositor build exercises the server side; the client's consumer can't build here).
        .testTarget(
            name: "WaylandClientCTests",
            dependencies: ["WaylandClientC", "WaylandProtocolsC"],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
        // Exercises the ergonomic server layer end-to-end: create a wl_display + event loop + SHM,
        // read the loop fd, dispatch/flush with no clients — no socket or client needed.
        .testTarget(
            name: "WaylandServerTests",
            dependencies: ["WaylandServer"],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
        // Proves the ergonomic client layer imports under C++ interop, and that connecting to a
        // nonexistent socket fails cleanly (no compositor is available in the test env).
        .testTarget(
            name: "WaylandClientTests",
            dependencies: ["WaylandClient"],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
        // Conformance loopback: a real server (WaylandDisplay + a wl_output global) and a real client
        // (WaylandConnection + WaylandRegistry + the generated client dispatch) over a socketpair,
        // in one process. Exercises BOTH generated dispatch directions on the wire — the only test of
        // the client listener trampolines + arg marshalling. Links both libwayland-server and -client.
        .testTarget(
            name: "WaylandLoopbackTests",
            dependencies: ["WaylandServer", "WaylandServerDispatch",
                           "WaylandClient", "WaylandClientDispatch", "WaylandProtocolsC"],
            swiftSettings: [.interoperabilityMode(.Cxx)]
        ),
    ]
)


for target in package.targets {
    switch target.type {
    case .regular, .executable, .test:
        break
    default:
        continue
    }
    var swiftSettings = (target.swiftSettings ?? []) + [
        .unsafeFlags(["-warnings-as-errors"]),
        .unsafeFlags(["-Werror", "StrictLanguageFeatures"]),
    ]
    if let feature = Context.environment["NUCLEUS_SWIFT_DIAGNOSTIC_FEATURE"] {
        swiftSettings.append(.unsafeFlags(["-enable-upcoming-feature", feature]))
    }
    target.swiftSettings = swiftSettings
    target.cSettings = (target.cSettings ?? []) + [
        .unsafeFlags(["-Werror"]),
    ]
    target.cxxSettings = (target.cxxSettings ?? []) + [
        .unsafeFlags(["-Werror"]),
    ]
}
