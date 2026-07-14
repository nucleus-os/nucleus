// swift-tools-version:6.4
//
// The Nucleus Android host package (render-stack Phase 0 / build-harness Phase 2).
//
// Cross-compiled with the registered Swift Android SDK to produce the JNI native
// library the Kotlin `nucleus` module loads:
//
//   swift build --package-path platform-android \
//     --swift-sdk swift-release-6.4.x_android --static-swift-stdlib -c release
//
// → .build/out/Products/Release-android-aarch64/libnucleus-android.so
//
// --static-swift-stdlib bakes the Swift runtime into the .so (so no libswiftCore.so
// ships) by selecting the SDK's swift_static-aarch64 resources. It is a build flag,
// not a linkerSettings flag: passing -static-stdlib in the manifest makes the
// driver look for static-stdlib-args.lnk under the dynamic resource dir and fail.
//
// It is a SwiftPM package distinct from the root library and compositor app packages: those pull
// in Linux-only modules (wayland/drm/io_uring) that cannot cross-compile, whereas
// `swift build --product` here builds only the host's closure. The render stack
// (Vulkan / NucleusUI* / NucleusSkiaGraphite) is added as cross-compile-clean
// dependencies in the render-stack plan's later phases; today the host imports
// only Foundation + the JNI C façade.

import PackageDescription
import Foundation

// The repo root is this package's parent. The render core's Android Skia bridge
// (root package) resolves Skia's vendored headers against it; the host target adds
// the vulkan-headers include so it can read NucleusRenderer's C++-interop interface.
let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().path

// `--static-swift-stdlib` searches the SDK's `swift_static-aarch64` resource dir,
// which ships libswiftCore.a but NOT the C++-interop static libs (libswiftCxx.a /
// libswiftCxxStdlib.a) — those live only in the regular `swift-aarch64/android`
// resource dir. Linking the render core (C++ interop → Skia Graphite) statically
// therefore needs that dir on the search path. Locate it in the provisioned SDK
// artifact bundle (the two known install roots), so the static .a resolve while
// the rest of the runtime still comes from swift_static-aarch64.
func swiftAndroidCxxStaticLibDir() -> String? {
    let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
    let rel = "/swift-android/swift-resources/usr/lib/swift-aarch64/android"
    let candidates = [
        home + "/.swiftpm/swift-sdks/swift-release-6.4.x_android.artifactbundle" + rel,
        home + "/.cache/nucleus/swift-android-sdks/release-6.4.x/swift-release-6.4.x_android.artifactbundle" + rel,
    ]
    return candidates.first { FileManager.default.fileExists(atPath: $0 + "/libswiftCxx.a") }
}
let swiftCxxStaticLinkFlags: [String] =
    swiftAndroidCxxStaticLibDir().map { ["-L", $0] } ?? []

let package = Package(
    name: "NucleusAndroidHost",
    products: [
        // Product name drives the emitted dynamic library name → libnucleus-android.so,
        // matching System.loadLibrary("nucleus-android") in the Kotlin Nucleus class.
        // Built from the non-cxx JNI target; the cxx-interop core links in as a
        // dependency target, so the single .so carries both.
        .library(name: "nucleus-android", type: .dynamic, targets: ["NucleusAndroidJNI"]),
    ],
    dependencies: [
        // The Nucleus library package — source of the cross-compile-clean render
        // modules the Android host consumes. Render-stack Phase 1 takes Vulkan
        // + VulkanC (platform-agnostic: vendored Khronos headers + the vulkan
        // loader). `swift build --product` builds only the consumed closure, so the
        // root package's Linux-only targets never enter the Android cross-compile.
        .package(name: "Nucleus", path: ".."),
        // The Vulkan bindings, extracted from Nucleus into their own package (vendored
        // Khronos headers → cross-compile-clean for Android). Consumed directly since a
        // package cannot re-vend a dependency's product.
        .package(name: "swift-vulkan", path: "../../swift-vulkan"),
        // swift-java (jextract, JNI mode): generates the Java binding + Java_… Swift
        // thunks for AndroidHost's `public` surface. Pinned upstream submodule,
        // path-referenced like every other third-party dependency.
        .package(name: "swift-java", path: "../../third-party/swift-java"),
    ],
    targets: [
        // The JNI C façade: the small NDK-helper translation unit (ANativeWindow /
        // AAssetManager bindings) behind `module NucleusAndroidC`. jni.h + the
        // android/* headers resolve from the Swift Android SDK's NDK sysroot. The
        // header + module.modulemap live alongside the .c, so the dir is its own
        // public-headers root.
        .target(
            name: "NucleusAndroidC",
            path: "c",
            publicHeadersPath: "."
        ),
        // The C++-interop host core: lifecycle/surface/frame/input state, the asset +
        // event-queue paths, and the renderer/runtime/Vulkan stack that requires
        // cxx-interop to call NucleusRenderer's C++ Skia-Graphite interface. Its public
        // API (AndroidHostCore) exposes only primitive / String / opaque-pointer types,
        // so the non-cxx JNI facade can wrap it without any C++ type crossing the
        // module boundary. swift-java's generated JNI thunks cannot compile under
        // cxx-interop (the NDK jni.h imports JNIEnv as the C++ `_JNIEnv` struct), which
        // is exactly why the JNI surface lives in a separate non-cxx target.
        .target(
            name: "NucleusAndroidCore",
            dependencies: [
                "NucleusAndroidC",
                .product(name: "Vulkan", package: "swift-vulkan"),
                .product(name: "VulkanC", package: "swift-vulkan"),
                // The platform-agnostic render core, cross-compiled for Android. It
                // pulls the Android Skia bridge (Vulkan Graphite) transitively via its
                // `.when(platforms: [.android])` dependency. The host drives it through
                // the `PresentationBackend` the Vulkan swapchain presenter implements.
                .product(name: "NucleusRenderer", package: "Nucleus"),
                .product(name: "NucleusRenderModel", package: "Nucleus"),
            ],
            path: "swift-core",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .interoperabilityMode(.Cxx),
                .unsafeFlags([
                    "-Xcc", "-I", "-Xcc",
                    repoRoot + "/third-party/skia/third_party/externals/vulkan-headers/include",
                    // Do not serialize this target's C++-interop internals for
                    // cross-module inlining. The non-cxx JNI facade imports this module
                    // for AndroidHostCore's primitive API only; package-level CMO would
                    // otherwise drag the C++ render/Skia clang modules into the JNI
                    // compile, which cannot build them without cxx-interop.
                    "-disable-cmo",
                ]),
            ],
            linkerSettings: [
                // The Vulkan loader (NDK libvulkan.so). VulkanC's modulemap
                // autolinks "vulkan" too; explicit here so it lands in NEEDED
                // deterministically for the capability-qualified render core.
                .linkedLibrary("vulkan"),
                .unsafeFlags(swiftCxxStaticLinkFlags),
            ]
        ),
        // The non-cxx JNI surface: the swift-java-extracted AndroidHost facade, the
        // generated Java_…AndroidHost_… thunks (via the JExtractSwiftPlugin), and the
        // hand-written Java_…NucleusNative_… thunks for the NDK-handle entry points
        // (Surface / AssetManager). This is the product's root target; NucleusAndroidCore
        // links in as a dependency, so libnucleus-android.so carries the whole stack
        // with -landroid, the soname the loader expects, and Android's 16 KB page size.
        .target(
            name: "NucleusAndroidJNI",
            dependencies: [
                "NucleusAndroidCore",
                "NucleusAndroidC",
                .product(name: "SwiftJava", package: "swift-java"),
            ],
            path: "swift-jni",
            exclude: ["swift-java.config"],
            swiftSettings: [
                // Unified on v6 + cxx-interop after the C-ABI collapse: the facade
                // imports NucleusAndroidCore (v6) directly, and the forked swift-java's
                // generated JNI thunks + the hand-written NDK thunks all compile clean
                // under Swift 6 strict concurrency.
                .swiftLanguageMode(.v6),
                .interoperabilityMode(.Cxx),
            ],
            linkerSettings: [
                .linkedLibrary("android"),
                .unsafeFlags([
                    "-Xlinker", "-soname", "-Xlinker", "libnucleus-android.so",
                    "-Xlinker", "-z", "-Xlinker", "max-page-size=16384",
                ]),
            ],
            plugins: [
                // Generates AndroidHost.java + the Java_…AndroidHost_… Swift thunks from
                // AndroidHost's `public` API. Runs the host swift-java CLI at build time;
                // reads swift-java.config from this directory.
                .plugin(name: "JExtractSwiftPlugin", package: "swift-java"),
            ]
        ),
    ]
)
