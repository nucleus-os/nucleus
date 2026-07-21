// swift-tools-version:6.4
import PackageDescription

// swift-tracy — Swift bindings for the Tracy frame profiler (github.com/wolfpld/tracy). A thin
// C++ shim compiles the Tracy client as a single translation unit and exposes a Swift `Trace`
// API (zones, plots, messages, frames) over C++ interop. The Tracy client source comes from the
// pinned third-party/tracy submodule, so nothing depends on a system Tracy.
//
// The whole client is INERT unless TRACY_ENABLE is defined: both TUs compile to nothing and the
// Swift API is safe no-ops. Turn it on for a build with `-Xcc -DTRACY_ENABLE` (the flag reaches
// this package's C++ target through the build graph, exactly as it did in-tree). Keeping it off
// by default means release builds pay nothing.
let package = Package(
    name: "swift-tracy",
    products: [
        // The Swift Trace API; transitively links the C++ bridge + pinned Tracy client.
        .library(name: "Tracy", targets: ["Tracy"]),
    ],
    targets: [
        // The C++ shim: TraceBridge.cpp (the swift_tracy::TraceBridge façade) + TracyClientShim.cpp
        // (#include "TracyClient.cpp" from the Tracy submodule). The Tracy symbols must live in the same
        // archive as the bridge the Swift side links, so the client is co-located here — not a
        // separate target — because SwiftBuild drops a standalone C++ archive from the cxx-interop link.
        .target(
            name: "TracyBridge",
            path: "Sources/TracyBridge",
            sources: ["TraceBridge.cpp", "TracyClientShim.cpp"],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("../../third-party/tracy/public"),
                .unsafeFlags(["-std=c++20"]),
            ],
            linkerSettings: [
                .linkedLibrary("pthread"),
                .linkedLibrary("dl"),
            ]
        ),
        .target(
            name: "Tracy",
            dependencies: ["TracyBridge"],
            path: "Sources/Tracy",
            sources: ["Trace.swift"]
        ),
        .testTarget(
            name: "TracyTests",
            dependencies: ["Tracy"]
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
    target.swiftSettings = (target.swiftSettings ?? []) + [
        .unsafeFlags(["-warnings-as-errors"]),
    ]
    target.cSettings = (target.cSettings ?? []) + [
        .unsafeFlags(["-Werror"]),
    ]
    target.cxxSettings = (target.cxxSettings ?? []) + [
        .unsafeFlags(["-Werror"]),
    ]
}
