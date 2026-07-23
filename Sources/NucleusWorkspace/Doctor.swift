import FoundationEssentials

/// Read-only validation for the host contract consumed by the complete-checkout
/// bootstrap, build, and test entry points.
struct Doctor {
    let context: WorkspaceContext

    func run() throws {
        var failures: [String] = []

        checkSwiftVersion(failures: &failures)

        for executable in [
            "swift", "swiftc", "git", "cmake", "ninja", "pkg-config",
            "python3", "corepack", "bun", "curl", "tar",
            SHA256Verifier.executable,
        ] {
            checkExecutable(executable, failures: &failures)
        }

        for relativePath in [
            "Package.swift",
            "swift-tracy/Package.swift",
            "swift-vulkan/Package.swift",
            "swift-wayland/Package.swift",
            "core/Package.swift",
            "platform-linux/Package.swift",
            "react-native/Package.swift",
            "compositor/compositor-core/Package.swift",
            "compositor/compositor/Package.swift",
            "shell/Package.swift",
            "third-party/swift-java-jni-core/Package.swift",
        ] {
            checkPath(relativePath, under: context.root, failures: &failures)
        }

        let nativeSDK = nativeSDKRoot()
        for relativePath in [
            "render/include",
            "render/lib/skia-graphite",
            "render/manifest.json",
            "rn/include",
            "rn/lib/rn",
            "rn/lib/nucleus-cxx-libs",
        ] {
            checkPath(relativePath, under: nativeSDK, failures: &failures)
        }

        guard failures.isEmpty else {
            for failure in failures {
                print("  MISSING  \(failure)")
            }
            throw WorkspaceFailure.message(
                "doctor found \(failures.count) host prerequisite violation(s)")
        }
        print("doctor: complete-checkout host contract satisfied")
    }

    private func checkSwiftVersion(failures: inout [String]) {
        guard let output = try? context.run(
            "swift", ["--version"], capture: true),
            let firstLine = output.split(separator: "\n").first,
            firstLine.hasPrefix("Swift version 6.4")
        else {
            failures.append("Swift 6.4 toolchain")
            return
        }
        print("  ok       Swift: \(firstLine)")
    }

    private func checkExecutable(
        _ name: String,
        failures: inout [String]
    ) {
        guard let path = executablePath(name) else {
            failures.append("executable \(name)")
            return
        }
        print("  ok       \(name): \(path)")
    }

    private func executablePath(_ name: String) -> String? {
        guard let path = context.environment["PATH"] else { return nil }
        for directory in path.split(separator: ":", omittingEmptySubsequences: false) {
            let candidate = URL(
                fileURLWithPath: String(directory),
                isDirectory: true
            ).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func nativeSDKRoot() -> URL {
        let cacheRoot: URL
        if let path = context.environment["XDG_CACHE_HOME"], !path.isEmpty {
            cacheRoot = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            cacheRoot = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache", isDirectory: true)
        }
        return cacheRoot
            .appendingPathComponent("nucleus", isDirectory: true)
            .appendingPathComponent("nucleus-native-sdk", isDirectory: true)
    }

    private func checkPath(
        _ relativePath: String,
        under root: URL,
        failures: inout [String]
    ) {
        let path = root.appendingPathComponent(relativePath).path
        guard FileManager.default.fileExists(atPath: path) else {
            failures.append(path)
            return
        }
        print("  ok       \(path)")
    }
}
