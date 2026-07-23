import FoundationEssentials

private struct DoctorReport: Codable {
    let scope: String
    let success: Bool
    let checks: [DoctorCheck]
}

private struct DoctorCheck: Codable {
    enum Status: String, Codable {
        case planned
        case passed
        case failed
    }

    let id: String
    let scope: String
    let description: String
    let status: Status
    let detail: String?
}

private struct HostPrerequisite {
    let id: String
    let scope: String
    let description: String
    let evaluate: () -> String?
}

/// Read-only validation for the host contracts consumed by Collider workflows.
struct WorkspaceDoctor {
    let context: WorkspaceContext

    func run(
        scope: String,
        dryRun: Bool,
        json: Bool,
        quiet: Bool = false
    ) throws {
        let prerequisites = selectedPrerequisites(scope: scope)
        let checks = prerequisites.map { prerequisite in
            if dryRun {
                return DoctorCheck(
                    id: prerequisite.id,
                    scope: prerequisite.scope,
                    description: prerequisite.description,
                    status: .planned,
                    detail: nil)
            }
            let detail = prerequisite.evaluate()
            return DoctorCheck(
                id: prerequisite.id,
                scope: prerequisite.scope,
                description: prerequisite.description,
                status: detail == nil ? .failed : .passed,
                detail: detail)
        }
        let report = DoctorReport(
            scope: scope,
            success: checks.allSatisfy { $0.status != .failed },
            checks: checks)
        if quiet {
            // Callers that compose doctor with a machine-readable task report
            // still use the same prerequisite registry without a second payload.
        } else if json {
            print(String(
                decoding: try JSONEncoder.sorted.encode(report), as: UTF8.self))
        } else {
            for check in checks {
                let marker = switch check.status {
                case .planned: "plan"
                case .passed: "ok"
                case .failed: "MISSING"
                }
                print("  \(marker.padding(toLength: 7, withPad: " ", startingAt: 0))  \(check.description)"
                    + (check.detail.map { ": \($0)" } ?? ""))
            }
            if report.success {
                print(dryRun
                    ? "doctor: \(scope) prerequisite plan resolved"
                    : "doctor: \(scope) host contract satisfied")
            }
        }
        guard report.success else {
            let failures = checks.filter { $0.status == .failed }
            throw WorkspaceFailure.message(
                "doctor found \(failures.count) \(scope) prerequisite violation(s)")
        }
    }

    private func selectedPrerequisites(scope: String) -> [HostPrerequisite] {
        let all = runtimePrerequisites + toolchainPrerequisites
            + androidPrerequisites + browserPrerequisites
        let selected = scope == "all" ? all : all.filter { $0.scope == scope }
        var seen: Set<String> = []
        return selected.filter { seen.insert($0.id).inserted }
    }

    private var runtimePrerequisites: [HostPrerequisite] {
        [swiftVersion(scope: "runtime")]
            + executables(
                [
                    "swift", "swiftc", "git", "cmake", "ninja", "pkg-config",
                    "corepack", "bun", "tar",
                ],
                scope: "runtime")
            + paths(
                [
                    "Package.swift", "swift-tracy/Package.swift",
                    "swift-vulkan/Package.swift", "swift-wayland/Package.swift",
                    "core/Package.swift", "platform-linux/Package.swift",
                    "react-native/Package.swift",
                    "compositor/compositor-core/Package.swift",
                    "compositor/compositor/Package.swift", "shell/Package.swift",
                    "third-party/swift-java-jni-core/Package.swift",
                ],
                under: context.root,
                scope: "runtime")
            + paths(
                [
                    "render/include", "render/lib/skia-graphite",
                    "render/manifest.json", "rn/include", "rn/lib/rn",
                    "rn/lib/nucleus-cxx-libs",
                ],
                under: nativeSDKRoot(),
                scope: "runtime")
    }

    private var toolchainPrerequisites: [HostPrerequisite] {
        [swiftVersion(scope: "toolchain")]
            + executables(
                ["swift", "swiftc", "git", "cmake", "ninja", "python3", "tar"],
                scope: "toolchain")
            + paths(
                [
                    "swift-toolchain/Package.swift",
                    "swift-toolchain/nucleus-build-presets.ini",
                    "swift-toolchain/nucleus-build-presets-macos.ini",
                ],
                under: context.root,
                scope: "toolchain")
    }

    private var androidPrerequisites: [HostPrerequisite] {
        executables(["swift", "swiftc", "java"], scope: "android")
            + paths(
                [
                    "core/android/gradlew", "core/platform-android/Package.swift",
                    "swift-toolchain/Package.swift",
                ],
                under: context.root,
                scope: "android")
    }

    private var browserPrerequisites: [HostPrerequisite] {
        executables(
            [
                "git", "python3", "tar", "timeout", "readelf", "ldd", "cc",
            ],
            scope: "browser")
            + paths(
                [
                    "chromium/Package.swift", "cef/apt-deps.txt",
                    "chromium/patches/common", "chromium/patches/browser",
                    "chromium/patches/dawn", "cef/patches",
                ],
                under: context.root,
                scope: "browser")
    }

    private func swiftVersion(scope: String) -> HostPrerequisite {
        HostPrerequisite(
            id: "swift-6.4",
            scope: scope,
            description: "Swift 6.4 toolchain"
        ) {
            guard let output = try? context.run(
                "swift", ["--version"], capture: true),
                let firstLine = output.split(separator: "\n").first,
                firstLine.hasPrefix("Swift version 6.4")
            else { return nil }
            return String(firstLine)
        }
    }

    private func executables(
        _ names: [String],
        scope: String
    ) -> [HostPrerequisite] {
        names.map { name in
            HostPrerequisite(
                id: "executable:\(name)",
                scope: scope,
                description: "executable \(name)"
            ) { executablePath(name) }
        }
    }

    private func paths(
        _ relativePaths: [String],
        under root: URL,
        scope: String
    ) -> [HostPrerequisite] {
        relativePaths.map { relativePath in
            let path = root.appendingPathComponent(relativePath).path
            return HostPrerequisite(
                id: "path:\(path)",
                scope: scope,
                description: path
            ) {
                FileManager.default.fileExists(atPath: path) ? path : nil
            }
        }
    }

    private func executablePath(_ name: String) -> String? {
        guard let path = context.environment["PATH"] else { return nil }
        for directory in path.split(separator: ":", omittingEmptySubsequences: false) {
            let candidate = URL(
                fileURLWithPath: String(directory), isDirectory: true)
                .appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func nativeSDKRoot() -> URL {
        context.cacheRoot.appendingPathComponent(
            "nucleus/nucleus-native-sdk", isDirectory: true)
    }
}
