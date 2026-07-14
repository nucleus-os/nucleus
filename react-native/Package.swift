// swift-tools-version:6.4
//
// The out-of-tree React Native platform for Nucleus (`NucleusReactNative`).
// Extracted from the `nucleus` core repo: this package owns only the RN slice —
// the Hermes/JSI + folly C++ bridge, the Fabric runtime host, the Swift RN
// runtime modules, and the RN build/provisioning command plugins. It consumes
// the monorepo core at `../core` as a local SwiftPM package, consuming the
// render/UI-core targets (NucleusUI, NucleusRenderer, …) as products from there.
// The native C++ stack is consumed through the same versioned native SDKs at a
// stable cache path: the `render` SDK (Skia/Vulkan) points into the core; the
// `rn` SDK (Hermes/Fabric/folly) points into this package's
// third-party/ + .rn-build/, which this package owns and provisions.

import PackageDescription
import Foundation

// SwiftPM runs clang with the package's PARENT as the working directory, so
// relative -I would resolve one level too high — paths are absolute off repoRoot.
let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

// ── The Nucleus native SDKs (render + RN) ──────────────────────────────────────
// Provision one named SDK under the shared cache root as symlinks into the tree (a
// no-op in a consumer repo, which pre-provisions real files). `links` skip a missing
// target; `forceLinks` tolerate a not-yet-existing target — the staged host-cxx archive
// (.cxx-build) is produced by `provision-cxx-libs` AFTER this eval, so its symlink is
// created dangling and resolves once staging runs.
func provisionSDK(_ name: String, links: [(String, String)], forceLinks: [(String, String)] = []) -> String {
    let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
    let sdk = home + "/.cache/nucleus/nucleus-native-sdk/" + name
    let fm = FileManager.default
    func mk(_ path: String) {
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true)
    }
    for (dest, target) in links {
        let path = sdk + "/" + dest
        guard fm.fileExists(atPath: target) else { continue }
        if let existing = try? fm.destinationOfSymbolicLink(atPath: path) {
            if existing == target { continue }
            try? fm.removeItem(atPath: path)
        } else if fm.fileExists(atPath: path) { continue }
        mk(path); try? fm.createSymbolicLink(atPath: path, withDestinationPath: target)
    }
    for (dest, target) in forceLinks {
        let path = sdk + "/" + dest
        if let existing = try? fm.destinationOfSymbolicLink(atPath: path) {
            if existing == target { continue }
            try? fm.removeItem(atPath: path)
        } else if fm.fileExists(atPath: path) { continue }
        mk(path); try? fm.createSymbolicLink(atPath: path, withDestinationPath: target)
    }
    return sdk
}
// The render SDK — Skia Graphite archives + headers and the Skia text-backend source.
// Owned by the nucleus core repo; here its link targets point INTO the nucleus
// monorepo core (repoRoot + "/../core/…").
let renderSDK = provisionSDK("render", links: [
    ("include/skia", repoRoot + "/../core/third-party/skia"),
    ("lib/skia-graphite", repoRoot + "/../core/.skia-build/graphite"),
    ("include/skia-text", repoRoot + "/../core/render-cxx/skia"),
])
// The RN SDK — Hermes/folly/Fabric headers + built archives, the RN facade bridge +
// runtime headers, and the staged host-cxx archive. Owned by THIS package: its link
// targets point into this repo's own third-party/ + .rn-build/ (no /nucleus prefix).
let rnSDK = provisionSDK("rn", links: [
    ("include/hermes", repoRoot + "/third-party/hermes"),
    ("include/folly", repoRoot + "/third-party/folly"),
    ("include/boost", repoRoot + "/third-party/boost"),
    ("include/glog", repoRoot + "/third-party/glog"),
    ("include/glog-gen", repoRoot + "/.rn-build/glog"),
    ("include/rn-gen", repoRoot + "/.rn-build/include"),
    ("include/rn-codegen", repoRoot + "/.rn-build/generated"),
    ("include/fmt", repoRoot + "/third-party/fmt"),
    ("include/fast_float", repoRoot + "/third-party/fast_float"),
    ("include/react-native", repoRoot + "/third-party/react-native"),
    ("lib/rn", repoRoot + "/.rn-build"),
    ("include/react-bridge", repoRoot + "/swiftpm/cmodules/NucleusReactRuntimeCxxBridge"),
    ("include/react-runtime", repoRoot + "/swift/Sources/NucleusReactRuntime/cxx"),
], forceLinks: [
    ("lib/nucleus-cxx-libs", repoRoot + "/.cxx-build"),
])

let skiaRoot = renderSDK + "/include/skia"          // the Skia source/header tree
let skiaLibDir = renderSDK + "/lib/skia-graphite"   // the GN/Ninja-built archive set
// React Native / Hermes / folly header roots + the built-archive dir, from the RN SDK.
let hermesInc = rnSDK + "/include/hermes"
let follyInc = rnSDK + "/include/folly"
let boostInc = rnSDK + "/include/boost"
let glogSrcInc = rnSDK + "/include/glog/src"
let glogGenInc = rnSDK + "/include/glog-gen"
let rnGenInc = rnSDK + "/include/rn-gen"
let rnCodegenRoot = rnSDK + "/include/rn-codegen"
let rnCodegenInc = rnCodegenRoot + "/FBReactNativeSpec"
let fmtInc = rnSDK + "/include/fmt/include"
let fastFloatInc = rnSDK + "/include/fast_float/include"
let rnPkg = rnSDK + "/include/react-native/packages/react-native"  // the RN tree root
let rnLibDir = rnSDK + "/lib/rn"                     // the GN/CMake-built RN archive set

let skiaBridgeCxxFlags: [String] = [
    "-std=c++20", "-DNDEBUG", "-DSK_GRAPHITE", "-DSK_DAWN", "-DSK_VULKAN",
    "-DSK_GAMMA_APPLY_TO_A8", "-DSK_ALLOW_STATIC_GLOBAL_INITIALIZERS=1",
    "-I", skiaRoot,
    "-I", skiaRoot + "/src",
    "-I", skiaRoot + "/include/third_party/vulkan",
    "-I", skiaRoot + "/src/gpu/vk/vulkanmemoryallocator",
    "-I", skiaRoot + "/third_party/externals/vulkanmemoryallocator/include",
    "-I", skiaRoot + "/third_party/externals/vulkan-headers/include",
]

// Link flags for the GN/Ninja-built Skia archive set, from the native SDK
// (lib/skia-graphite). The archives are mutually recursive → one --start-group; the
// externals + Dawn are built from vendored source, then system libs
// (vulkan/fontconfig/freetype/z) and dl/pthread/m close it out. libc++ from the toolchain.
let skiaLinkFlags: [String] = [
    "-L", skiaLibDir,
    "-Xlinker", "--start-group",
    "-lskia", "-lskshaper", "-lskparagraph", "-lskunicode_core", "-lskunicode_icu",
    "-lsvg", "-lskcms", "-lskresources", "-lfreetype2", "-lharfbuzz", "-licu",
    "-lpng", "-ljpeg", "-ljpeg12", "-ljpeg16", "-lwebp", "-lwebp_sse41", "-lexpat",
    "-lzlib", "-lwuffs", "-ldng_sdk", "-lpiex", "-ldawn_combined",
    "-lallocator_base", "-lallocator_core", "-lallocator_shim", "-lraw_ptr",
    "-Xlinker", "--end-group",
    "-lvulkan", "-lfontconfig", "-lfreetype", "-lz", "-ldl", "-lpthread", "-lm",
]

// Resolve host pkg-config flags at manifest-eval time so distro library paths are
// never hardcoded.
func pkgConfig(_ args: [String]) -> [String] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["pkg-config"] + args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do { try p.run() } catch { return [] }
    p.waitUntilExit()
    let out = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(decoding: out, as: UTF8.self)
        .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        .map(String.init)
}

// ── React Native C++ stack (Phase 5) ──────────────────────────────────────────
// Compile flags for the Hermes-JSI + folly bridge: the Hermes API/jsi headers,
// folly + its deps (boost headers, glog generated+source, double-conversion via a
// prefix symlink, fmt, fast_float), and folly's mobile defines. Built by the
// Build{Hermes,RNSupportLibs,ReactNativeCxx} command plugins into .rn-build/.
let rnBridgeCxxFlags: [String] = [
    "-std=c++20",
    "-I", hermesInc + "/API",
    "-I", hermesInc + "/API/jsi",
    "-I", hermesInc + "/public",
    "-I", hermesInc + "/include",
    "-I", follyInc,
    "-I", boostInc,
    "-I", glogGenInc,
    "-I", glogSrcInc,
    "-I", rnGenInc,
    "-I", fmtInc,
    "-I", fastFloatInc,
    "-DFOLLY_NO_CONFIG=1", "-DFOLLY_MOBILE=0", "-DFOLLY_USE_LIBCPP=1",
    "-DFOLLY_CFG_NO_COROUTINES=1", "-DFOLLY_HAVE_CLOCK_GETTIME=1", "-DFOLLY_HAVE_PTHREAD=1",
]
// ICU (libicuuc + libicui18n) — Hermes's Intl/Unicode dependency. With a static
// Hermes, ICU is no longer pulled transitively through libhermes_lean.so; it
// stays a system shared lib (like libc++/vulkan), resolved at runtime from the
// host loader path. `-L<libdir> -licuuc -licui18n`.
let icuLinkFlags = pkgConfig(["--libs", "icu-uc", "icu-i18n"])
// ICU's host libdir as an rpath so non-standard distro layouts work without
// LD_LIBRARY_PATH. The shared libhermes_lean.so used to carry this; with static
// Hermes the consumer must.
let icuRpathFlags = pkgConfig(["--variable=libdir", "icu-uc"]).flatMap { ["-Xlinker", "-rpath", "-Xlinker", $0] }
// Link the GN/CMake-built RN stack fully statically: the Hermes lean VM + jsi
// closure merged into one archive by the BuildHermes plugin, plus the static
// folly/glog/fmt/double-conversion (mutually recursive → one group). No
// libhermes_lean.so / libjsi.so, so no rpath. libc++ comes from the Swift
// toolchain; ICU is a system shared lib.
let rnLinkFlags: [String] = [
    "-Xlinker", "--start-group",
    rnLibDir + "/hermes/libhermes_lean_combined.a",
    rnLibDir + "/reactnative/libfolly_runtime.a",
    rnLibDir + "/glog/libglog.a",
    rnLibDir + "/fmt/libfmt.a",
    rnLibDir + "/double-conversion/src/libdouble-conversion.a",
    "-Xlinker", "--end-group",
] + icuLinkFlags + icuRpathFlags + [
    "-lpthread", "-ldl", "-lm",
]

// The full RN fabric link set (rnLinkFlags + react_native/react_cxx_platform/
// yogacore + -latomic) — the same set the compositor links. Used by the
// Fabric-runtime test, which drives the whole runtime headless.
let rnFabricLinkFlags: [String] = [
    "-Xlinker", "--start-group",
    rnLibDir + "/hermes/libhermes_lean_combined.a",
    rnLibDir + "/reactnative/libreact_native.a",
    rnLibDir + "/reactnative/libreact_cxx_platform.a",
    rnLibDir + "/reactnative/libyogacore.a",
    rnLibDir + "/reactnative/libfolly_runtime.a",
    rnLibDir + "/glog/libglog.a",
    rnLibDir + "/fmt/libfmt.a",
    rnLibDir + "/double-conversion/src/libdouble-conversion.a",
    "-Xlinker", "--end-group",
    "-latomic",
] + icuLinkFlags + icuRpathFlags + [
    "-lpthread", "-ldl", "-lm",
]

// The full RN include set (+ Skia + folly deps) as -Xcc flags, for the Swift
// modules that import the RN facade (NucleusReactRuntimeCxxBridge) under C++
// interop — the facade headers pull in the RN fabric + Skia headers. Mirrors
// react_native.zig's include set + the shared defines.
private let rn = rnPkg
private let rc = rn + "/ReactCommon"
private let sk = skiaRoot
let rnRuntimeIncludeDirs: [String] = [
    // The facade header root (its headers cross-include via "NucleusReactRuntime/…").
    // These two are core-owned sources (kept repo-relative; the compositor consumes
    // them as the shared-C++ surface — see the native SDK note).
    repoRoot + "/swiftpm/cmodules/NucleusReactRuntimeCxxBridge",
    repoRoot + "/swift/Sources/NucleusReactRuntime/cxx/include",
    // The core text-layout vocabulary (nucleus::text) — TextLayoutManager.hpp includes
    // <nucleus/text/TextLayoutBuilder.hpp>. These headers moved from this tree into the
    // core (render-cxx/skia/include); read them from THIS repo's own nested nucleus
    // (repo-relative, not the shared render-SDK skia-text symlink, which is a first-
    // provisioner-wins cache and may point at another checkout). The RN Fabric text
    // layout manager now consumes the single core copy.
    repoRoot + "/../core/render-cxx/skia/include",
    // RN's own ReactCommon/jsi must precede Hermes's API/jsi: as of RN 0.87 RN's
    // jsi/hermes-interfaces.h defines the hermes interfaces (IEventLoopControl, …)
    // RuntimeScheduler needs; Hermes bundles an older copy, so RN's must win.
    rc + "/jsi",
    // Generated specs must win over RN's checked-in snapshot. Some RN headers use
    // <FBReactNativeSpec/...> while others include FBReactNativeSpecJSI.h directly.
    rnCodegenRoot, rnCodegenInc, rc, rn + "/React",
    rc + "/callinvoker", rc + "/jsiexecutor", rc + "/yoga", rc + "/runtimeexecutor",
    rc + "/react/nativemodule/core", rn,
    hermesInc + "/API", hermesInc + "/API/jsi", hermesInc + "/public",
    rc + "/react/renderer/components/view/platform/cxx",
    rc + "/react/renderer/components/scrollview/platform/cxx",
    rc + "/react/renderer/graphics/platform/cxx",
    rc + "/react/renderer/imagemanager", rc + "/react/renderer/imagemanager/platform/cxx",
    rc + "/react/utils/platform/cxx",
    rc + "/react/renderer/components/text/platform/cxx",
    rc + "/react/renderer/textlayoutmanager/platform/cxx",
    rc + "/reactperflogger", rn + "/ReactCxxPlatform",
    follyInc, boostInc,
    glogGenInc, glogSrcInc,
    rnGenInc, fmtInc,
    fastFloatInc,
    sk, sk + "/src", sk + "/third_party/externals/vulkan-headers/include",
    sk + "/src/gpu/vk/vulkanmemoryallocator",
    sk + "/third_party/externals/vulkanmemoryallocator/include",
]
let rnRuntimeXccFlags: [String] =
    rnRuntimeIncludeDirs.flatMap { ["-Xcc", "-I", "-Xcc", $0] } + [
        "-Xcc", "-DJS_RUNTIME_HERMES=1", "-Xcc", "-DHERMES_V1_ENABLED=1",
        "-Xcc", "-DREACT_NATIVE_DEBUG=1", "-Xcc", "-DFOLLY_NO_CONFIG=1",
        "-Xcc", "-DFOLLY_MOBILE=0", "-Xcc", "-DFOLLY_CFG_NO_COROUTINES=1",
        "-Xcc", "-DFMT_USE_CONSTEVAL=0", "-Xcc", "-DSK_GRAPHITE", "-Xcc", "-DSK_VULKAN",
        "-Xcc", "-std=c++20",
    ]
// The same include set as plain -I (+ the Swift->C++ emitted header shim and the
// GeneratedModuleMaps dir where SwiftPM emits NucleusReactRuntimeCxx-Swift.h) for
// the host C++ impl target, which depends on NucleusReactRuntimeCxx so SwiftPM
// builds the Swift module (emitting the header) first.
let rnRuntimeHostCxxFlags: [String] =
    ["-std=c++20", "-fexceptions", "-frtti"] +
    rnRuntimeIncludeDirs.flatMap { ["-I", $0] } + [
        "-I", repoRoot + "/swiftpm/shims/NucleusReactRuntimeSwift",
        "-I", repoRoot + "/.build/out/Intermediates.noindex/GeneratedModuleMaps-linux-x86_64",
        "-DJS_RUNTIME_HERMES=1", "-DHERMES_V1_ENABLED=1", "-DREACT_NATIVE_DEBUG=1",
        "-DFOLLY_NO_CONFIG=1", "-DFOLLY_MOBILE=0", "-DFOLLY_CFG_NO_COROUTINES=1",
        "-DFMT_USE_CONSTEVAL=0", "-DSK_GRAPHITE", "-DSK_VULKAN",
    ]

let package = Package(
    name: "NucleusReactNative",
    // React Native runtime — statically linked into the compositor (no
    // separate host .so). The RN Swift/C++ bridge + the host C++ impl.
    products: [
        .library(name: "NucleusReactRuntime", targets: ["NucleusReactRuntime"]),
        .library(name: "NucleusReactRuntimeCxx", targets: ["NucleusReactRuntimeCxx"]),
        .library(name: "NucleusReactRuntimeHostCxx", targets: ["NucleusReactRuntimeHostCxx"]),
    ],
    // The monorepo render/UI core.
    dependencies: [
        .package(name: "Nucleus", path: "../core"),
        .package(name: "swift-tracy", path: "../swift-tracy"),
    ],
    targets: [
        // ── RN build/provisioning command plugins (Phase 5). Provisioned out of
        // band, NOT on every target build, so a consumer links prebuilt artifacts. ─
        // Regenerates RN's FBReactNativeSpec through upstream APIs into
        // .rn-build/generated. Run once per RN version bump:
        //   swift package generate-rn-spec --allow-writing-to-package-directory
        .plugin(
            name: "GenerateRNSpec",
            capability: .command(
                intent: .custom(
                    verb: "generate-rn-spec",
                    description: "Regenerate FBReactNativeSpec into .rn-build/generated"
                ),
                permissions: [.writeToPackageDirectory(reason: "Emit FBReactNativeSpec into .rn-build/generated")]
            ),
            path: "swiftpm/plugins/GenerateRNSpec"
        ),
        // Phase 5: drives upstream Hermes's CMake/Ninja to build the lean JS VM
        // runtime + hermesc (first link in the React Native C/C++ chain):
        //   swift package build-hermes --allow-writing-to-package-directory
        .plugin(
            name: "BuildHermes",
            capability: .command(
                intent: .custom(
                    verb: "build-hermes",
                    description: "Build Hermes (lean VM + hermesc) via its upstream CMake"
                ),
                permissions: [.writeToPackageDirectory(reason: "Build Hermes into .rn-build/hermes")]
            ),
            path: "swiftpm/plugins/BuildHermes"
        ),
        // Phase 5: builds the leaf RN C++ support libs with clean upstream builds
        // (fmt + double-conversion; fast_float is header-only):
        //   swift package build-rn-support --allow-writing-to-package-directory
        .plugin(
            name: "BuildRNSupportLibs",
            capability: .command(
                intent: .custom(
                    verb: "build-rn-support",
                    description: "Build the leaf RN C++ support libs (fmt, double-conversion)"
                ),
                permissions: [.writeToPackageDirectory(reason: "Build RN support libs into .rn-build/")]
            ),
            path: "swiftpm/plugins/BuildRNSupportLibs"
        ),
        // Phase 5: builds the RN-curated C++ layer — glog + folly_runtime + the
        // ReactCommon jsi (swiftpm/cmake/reactnative). Run after build-rn-support:
        //   swift package build-rn-cxx --allow-writing-to-package-directory
        .plugin(
            name: "BuildReactNativeCxx",
            capability: .command(
                intent: .custom(
                    verb: "build-rn-cxx",
                    description: "Build the RN C++ layer (glog, folly_runtime, jsi)"
                ),
                permissions: [.writeToPackageDirectory(reason: "Build the RN C++ layer into .rn-build/")]
            ),
            path: "swiftpm/plugins/BuildReactNativeCxx"
        ),
        // Stage the core-owned C++ host archives (NucleusReactRuntimeHostCxx) into
        // .cxx-build so a downstream executable links them instead of recompiling —
        // run after a build: swift package provision-cxx-libs --allow-writing-to-package-directory
        .plugin(
            name: "ProvisionCxxLibs",
            capability: .command(
                intent: .custom(verb: "provision-cxx-libs", description: "Stage core C++ host archives into .cxx-build for downstream linking"),
                permissions: [.writeToPackageDirectory(reason: "Stage host-cxx archives into .cxx-build")]
            ),
            path: "swiftpm/plugins/ProvisionCxxLibs"
        ),

        // ── The RN C++ facade cmodule. A SwiftPM-owned cmodule dir with the real
        // headers in place; loaded by the Swift RN modules via a manual
        // -fmodule-map-file (NOT a systemLibrary dep) so its modulemap is not
        // propagated to the host C++ impl, which includes the same headers textually.
        // Declared here as a systemLibrary so its directory is part of the package.
        .systemLibrary(
            name: "NucleusReactRuntimeCxxBridge",
            path: "swiftpm/cmodules/NucleusReactRuntimeCxxBridge"
        ),

        // ── Phase 5: the React Native C++ stack link proof. The C-ABI bridge
        // compiles against Hermes's JSI API + folly; NucleusReactNativeCxxTests
        // links the whole GN/CMake-built native stack (Hermes + folly/glog +
        // support libs) and runs it (a Hermes JSI runtime + a folly round-trip).
        // Build the native stack first via the build-hermes / build-rn-support /
        // build-rn-cxx command plugins.
        .target(
            name: "NucleusReactNativeCxxBridge",
            path: "swift/Sources/NucleusReactNativeCxxBridge",
            sources: ["Bridge.cpp"],
            publicHeadersPath: "include",
            cxxSettings: [.unsafeFlags(rnBridgeCxxFlags)]
        ),
        .testTarget(
            name: "NucleusReactNativeCxxTests",
            dependencies: ["NucleusReactNativeCxxBridge"],
            path: "swift/Tests/NucleusReactNativeCxxTests",
            linkerSettings: [.unsafeFlags(rnLinkFlags)]
        ),
        // Plain-C façade for the host C++ smoke entry, so the test can call it
        // without importing the cxx facade module (whose modulemap the synthesized
        // test runner can't load).
        .systemLibrary(name: "NucleusReactFabricSmokeC", path: "swiftpm/cmodules/NucleusReactFabricSmokeC"),
        // Proves the statically-linked full RN fabric *runs*: drives the RN host
        // headless (single-threaded) through Hermes-runtime + Fabric install +
        // bytecode eval. Links the same fabric set as the compositor. Depends on
        // NucleusReactRuntimeCxx for the Swift object the host C++ bridge references
        // (+ build ordering) but does not import it, so no facade module reaches the
        // runner.
        .testTarget(
            name: "NucleusReactRuntimeFabricTests",
            dependencies: [
                "NucleusReactFabricSmokeC", "NucleusReactRuntimeHostCxx",
                "NucleusReactRuntimeCxx",
                // The Skia paragraph registry + text backend, compiled once in the core.
                // The RN host C++ references the registry; this resolves it at the test's
                // final link (the compositor resolves it the same way via this product).
                .product(name: "NucleusTextBackend", package: "Nucleus"),
                .product(name: "NucleusSkiaGraphiteBridge", package: "Nucleus"),
            ],
            path: "swift/Tests/NucleusReactRuntimeFabricTests",
            linkerSettings: [.unsafeFlags(rnFabricLinkFlags + skiaLinkFlags)]
        ),

        // ── The real RN runtime modules. NucleusReactRuntimeCxx (Swift) imports the
        // C++ facade module under C++ interop. The facade is loaded via a manual
        // -fmodule-map-file (NOT a systemLibrary dep) so its modulemap is not
        // propagated to the host C++ impl below — which includes the same facade
        // headers textually and would otherwise fail to load them as a module.
        .target(
            name: "NucleusReactRuntimeCxx",
            dependencies: [
                .product(name: "NucleusUI", package: "Nucleus"),
                .product(name: "NucleusLayers", package: "Nucleus"),
                .product(name: "Tracy", package: "swift-tracy"),
                .product(name: "NucleusTextCxxBridge", package: "Nucleus"),
                .product(name: "NucleusAppHostProtocols", package: "Nucleus"),
                // The C header declaring the test-only smoke entries — imported so
                // `nucleus_rn_fabric_full_smoke` is implemented via `@c @implementation`
                // (type-checked against smoke.h) rather than a free-standing `@_cdecl`.
                "NucleusReactFabricSmokeC",
            ],
            path: "swift/Sources/NucleusReactRuntimeCxx",
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .unsafeFlags([
                    "-Xcc", "-fmodule-map-file=" + repoRoot
                        + "/swiftpm/cmodules/NucleusReactRuntimeCxxBridge/module.modulemap",
                ] + rnRuntimeXccFlags),
            ]
        ),
        // The cxx host impl. Depends on NucleusReactRuntimeCxx so SwiftPM builds the
        // Swift module first (emitting NucleusReactRuntimeCxx-Swift.h); the 3
        // Swift→C++ bridge files reach it via the shim + GeneratedModuleMaps -I.
        .target(
            name: "NucleusReactRuntimeHostCxx",
            // No SwiftPM dependency: propagating the Swift target's module map makes
            // Clang require a prebuilt Swift Clang module instead of consuming the
            // generated C++ header textually. Bootstrap explicitly builds the Swift
            // target first so that header exists on a clean checkout.
            path: "swift/Sources/NucleusReactRuntime/cxx",
            // TextRegistry.cpp is intentionally NOT here: it is the shared
            // Skia paragraph registry and is compiled by NucleusTextBackend (which
            // the compositor always links, for the text-layout-draw resolver). The
            // host's registry references resolve against that single copy at the
            // final link — compiling it here too would duplicate the symbols.
            sources: [
                "CxxVirtualOverrideBridge.cpp", "CxxVirtualOverrideProbe.cpp", "DeviceEventEmitter.cpp",
                "NucleusAppStateModule.cpp", "NucleusDeviceInfoModule.cpp", "NucleusPlatformTimerRegistry.cpp", "NucleusSourceCodeModule.cpp",
                "ReactRuntimeHost.cpp", "HostCommandBridge.cpp", "RuntimeJSCallInvoker.cpp",
                "SwiftMountingObserverBridge.cpp", "SwiftTextLayoutManagerBridge.cpp", "TurboModuleRegistry.cpp",
                // Test-only headless smoke entry (nucleus_rn_fabric_smoke); compiled
                // here so it shares the host C++ build environment.
                "FabricSmoke.cpp",
            ],
            publicHeadersPath: "empty-public",
            cxxSettings: [.unsafeFlags(rnRuntimeHostCxxFlags)]
        ),
        // The NucleusReactRuntime Swift module (the Swift part; cxx/ is the host
        // target above). Imports NucleusReactRuntimeCxx + the facade under C++ interop.
        .target(
            name: "NucleusReactRuntime",
            dependencies: [
                "NucleusReactRuntimeCxx",
                .product(name: "NucleusUI", package: "Nucleus"),
                .product(name: "NucleusLayers", package: "Nucleus"),
                .product(name: "NucleusTypes", package: "Nucleus"),
                .product(name: "NucleusAppHostProtocols", package: "Nucleus"),
                .product(name: "Tracy", package: "swift-tracy"),
                .product(name: "NucleusTextCxxBridge", package: "Nucleus"),
            ],
            path: "swift/Sources/NucleusReactRuntime",
            exclude: ["cxx"],
            swiftSettings: [
                .interoperabilityMode(.Cxx),
                .unsafeFlags([
                    "-Xcc", "-fmodule-map-file=" + repoRoot
                        + "/swiftpm/cmodules/NucleusReactRuntimeCxxBridge/module.modulemap",
                ] + rnRuntimeXccFlags),
            ]
        ),
    ]
)
