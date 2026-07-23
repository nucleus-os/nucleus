import FoundationEssentials

struct CrossLanguageABIAudit {
    let context: WorkspaceContext

    private struct HeaderCase {
        let id: String
        let path: String
        let pkgConfigPackages: [String]
        let cAssertions: String
        let cxxAssertions: String
        let compilesAsC: Bool

        init(
            id: String,
            path: String,
            pkgConfigPackages: [String] = [],
            cAssertions: String = "",
            cxxAssertions: String = "",
            compilesAsC: Bool = true
        ) {
            self.id = id
            self.path = path
            self.pkgConfigPackages = pkgConfigPackages
            self.cAssertions = cAssertions
            self.cxxAssertions = cxxAssertions
            self.compilesAsC = compilesAsC
        }
    }

    func run() throws {
        let directory = context.root
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("cross-language-abi", isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }

        for header in headers {
            let flags = try pkgConfigFlags(header.pkgConfigPackages)
            if header.compilesAsC {
                try compile(
                    header,
                    language: "c",
                    standard: "gnu17",
                    assertions: header.cAssertions,
                    flags: flags,
                    directory: directory)
            }
            try compile(
                header,
                language: "c++",
                standard: "c++20",
                assertions: header.cxxAssertions,
                flags: flags,
                directory: directory)
        }
    }

    private var headers: [HeaderCase] {
        let drmC = """
        _Static_assert(sizeof(struct nucleus_drm_sync_file_snapshot) == 16,
                       "nucleus_drm_sync_file_snapshot size changed");
        _Static_assert(offsetof(struct nucleus_drm_sync_file_snapshot, status) == 0,
                       "status offset changed");
        _Static_assert(offsetof(struct nucleus_drm_sync_file_snapshot, fence_count) == 4,
                       "fence_count offset changed");
        _Static_assert(offsetof(struct nucleus_drm_sync_file_snapshot, latest_timestamp_ns) == 8,
                       "latest_timestamp_ns offset changed");
        """
        let drmCxx = drmC.replacing("_Static_assert", with: "static_assert")
        let tracyC = """
        _Static_assert(sizeof(SwiftTracyZoneContext) == 8,
                       "SwiftTracyZoneContext size changed");
        _Static_assert(offsetof(SwiftTracyZoneContext, id) == 0,
                       "SwiftTracyZoneContext.id offset changed");
        _Static_assert(offsetof(SwiftTracyZoneContext, active) == 4,
                       "SwiftTracyZoneContext.active offset changed");
        """
        let tracyCxx = tracyC.replacing("_Static_assert", with: "static_assert")
        let graphiteCxx = """
        #include <type_traits>
        static_assert(sizeof(nucleus::skia::Status) == sizeof(int32_t));
        static_assert(sizeof(nucleus::skia::Color) == 4 * sizeof(float));
        static_assert(sizeof(nucleus::skia::RectF) == 4 * sizeof(float));
        static_assert(sizeof(nucleus::skia::RRectRadii) == 4 * sizeof(float));
        static_assert(std::is_standard_layout_v<nucleus::skia::VulkanContextDescriptor>);
        static_assert(std::is_trivially_copyable_v<nucleus::skia::Paint>);
        """

        return [
            HeaderCase(
                id: "benchmark-metrics",
                path: "core/swift/Benchmarks/NucleusBenchmarkMetricsC/include/NucleusBenchmarkMetricsC.h"),
            HeaderCase(
                id: "compositor-drm",
                path: "compositor/compositor-core/Sources/NucleusCompositorDrmC/NucleusCompositorDrmC.h",
                pkgConfigPackages: ["libdrm", "gbm"],
                cAssertions: drmC,
                cxxAssertions: drmCxx),
            HeaderCase(
                id: "compositor-input",
                path: "compositor/compositor-core/Sources/NucleusCompositorInputC/NucleusCompositorInputC.h",
                pkgConfigPackages: ["libinput", "libudev", "libseat", "xkbcommon"]),
            HeaderCase(
                id: "compositor-xcb",
                path: "compositor/compositor-core/Sources/NucleusCompositorXcbC/NucleusCompositorXcbC.h",
                pkgConfigPackages: [
                    "xcb-ewmh", "xcb", "xcb-icccm", "xcb-composite",
                    "xcb-xfixes", "xcb-res",
                ]),
            HeaderCase(
                id: "compositor-signal",
                path: "compositor/compositor/Sources/NucleusCompositorSignalC/include/NucleusCompositorSignalC.h"),
            HeaderCase(
                id: "android-jni",
                path: "core/platform-android/c/nucleus_android_jni.h"),
            HeaderCase(
                id: "linux-dbus",
                path: "platform-linux/Sources/NucleusLinuxDBusC/NucleusLinuxDBusC.h",
                pkgConfigPackages: ["libsystemd"]),
            HeaderCase(
                id: "linux-reactor",
                path: "platform-linux/Sources/NucleusLinuxReactorC/include/NucleusLinuxReactorC.h"),
            HeaderCase(
                id: "react-native-c-abi",
                path: "react-native/swift/Sources/NucleusReactNativeCxxBridge/include/NucleusReactNativeCxxBridge/Bridge.h"),
            HeaderCase(
                id: "shell-input",
                path: "shell/Sources/NucleusShellInputC/NucleusShellInputC.h",
                pkgConfigPackages: ["xkbcommon"]),
            HeaderCase(
                id: "shell-pam",
                path: "shell/Sources/NucleusShellPamC/NucleusShellPamC.h"),
            HeaderCase(
                id: "shell-signal",
                path: "shell/Sources/NucleusShellSignalC/include/NucleusShellSignalC.h"),
            HeaderCase(
                id: "tracy-c-abi",
                path: "swift-tracy/Sources/TracyBridge/include/TracyBridge/TraceBridge.h",
                cAssertions: tracyC,
                cxxAssertions: tracyCxx),
            HeaderCase(
                id: "vulkan",
                path: "swift-vulkan/Sources/VulkanC/VulkanC.h"),
            HeaderCase(
                id: "wayland-client",
                path: "swift-wayland/Sources/WaylandClientC/WaylandClientC.h",
                pkgConfigPackages: ["wayland-client"]),
            HeaderCase(
                id: "wayland-server",
                path: "swift-wayland/Sources/WaylandServerC/WaylandServerC.h",
                pkgConfigPackages: ["wayland-server"]),
            HeaderCase(
                id: "skia-graphite-cxx",
                path: "core/swift/Sources/NucleusSkiaGraphite/cxx/include/NucleusSkiaGraphite/Graphite.hpp",
                cxxAssertions: graphiteCxx,
                compilesAsC: false),
        ]
    }

    private func compile(
        _ header: HeaderCase,
        language: String,
        standard: String,
        assertions: String,
        flags: [String],
        directory: URL
    ) throws {
        let source = directory.appendingPathComponent(
            header.id + (language == "c" ? ".c" : ".cc"))
        let headerPath = context.root.appendingPathComponent(header.path).path
        let contents = """
        #include <stddef.h>
        #include "\(headerPath)"
        \(assertions)
        """
        try contents.write(to: source, atomically: true, encoding: .utf8)
        let compiler = language == "c" ? "clang" : "clang++"
        print("==> abi header=\(header.id) language=\(language)")
        do {
            try context.run(
                compiler,
                [
                    "-x", language,
                    "-std=\(standard)",
                    "-fsyntax-only",
                    "-Wall", "-Wextra", "-Werror",
                ] + flags + [source.path],
                directory: context.root)
        } catch {
            throw WorkspaceFailure.message(
                "cross-language header gate failed "
                    + "[header=\(header.path) language=\(language)]: \(error)")
        }
    }

    private func pkgConfigFlags(_ packages: [String]) throws -> [String] {
        guard !packages.isEmpty else { return [] }
        let output = try context.run(
            "pkg-config", ["--cflags"] + packages,
            directory: context.root,
            capture: true)
        return output.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }
}
