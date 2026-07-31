import ArgumentParser
import FoundationEssentials

enum DoctorScope: String, CaseIterable, ExpressibleByArgument {
    case all
    case runtime
    case toolchain
    case android
    case browser
}

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
    let evaluate: () async -> String?
}

/// Read-only validation for the host contracts consumed by Collider workflows.
struct WorkspaceDoctor {
    let context: WorkspaceContext

    func run(
        scope: DoctorScope,
        dryRun: Bool,
        json: Bool,
        quiet: Bool = false
    ) async throws {
        let prerequisites = selectedPrerequisites(scope: scope)
        var checks: [DoctorCheck] = []
        for prerequisite in prerequisites {
            if dryRun {
                checks.append(DoctorCheck(
                    id: prerequisite.id,
                    scope: prerequisite.scope,
                    description: prerequisite.description,
                    status: .planned,
                    detail: nil))
                continue
            }
            let detail = await prerequisite.evaluate()
            checks.append(DoctorCheck(
                id: prerequisite.id,
                scope: prerequisite.scope,
                description: prerequisite.description,
                status: detail == nil ? .failed : .passed,
                detail: detail))
        }
        let report = DoctorReport(
            scope: scope.rawValue,
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

    private func selectedPrerequisites(
        scope: DoctorScope
    ) -> [HostPrerequisite] {
        let all = runtimePrerequisites + toolchainPrerequisites
            + androidPrerequisites + browserPrerequisites
        let selected = scope == .all
            ? all
            : all.filter { $0.scope == scope.rawValue }
        var seen: Set<String> = []
        return selected.filter { seen.insert($0.id).inserted }
    }

    private var runtimePrerequisites: [HostPrerequisite] {
        [swiftVersion(scope: "runtime"), lavapipe(scope: "runtime"),
         xwayland(scope: "runtime"), pidfd(scope: "runtime")]
            + executables(
                [
                    "swift", "swiftc", "git", "cmake", "ninja", "pkg-config",
                    "corepack", "bun", "tar", "python3", "ccache", "readelf",
                    "ldd", "patchelf", "strip", "install", "bash",
                    "systemd-analyze",
                ],
                scope: "runtime")
            + paths(
                [
                    "Package.swift",
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
                [
                    "swift", "swiftc", "git", "cmake", "ninja", "python3",
                    "tar", "ccache",
                ],
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
        executables(["swift", "swiftc", "java", "ccache"], scope: "android")
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
                "podman",
            ],
            scope: "browser")
            + paths(
                [
                    "cef/apt-deps.txt", "chromium/source.lock.json",
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
            guard let output = try? await context.run(
                "swift", ["--version"], capture: true),
                let firstLine = output.split(separator: "\n").first,
                firstLine.hasPrefix("Swift version 6.4")
            else { return nil }
            return String(firstLine)
        }
    }

    private func lavapipe(scope: String) -> HostPrerequisite {
        HostPrerequisite(
            id: "vulkan:lavapipe",
            scope: scope,
            description: "staged Mesa lavapipe Vulkan ICD"
        ) {
            guard let artifact = try? LavapipeTestArtifact.resolve(
                context: context),
                FileManager.default.isReadableFile(
                    atPath: artifact.stagedManifest.string),
                FileManager.default.isReadableFile(
                    atPath: artifact.library.string)
            else { return nil }
            return "\(artifact.stagedManifest) -> \(artifact.library)"
        }
    }

    private func xwayland(scope: String) -> HostPrerequisite {
        HostPrerequisite(
            id: "executable:Xwayland",
            scope: scope,
            description: "verified Xwayland executable"
        ) {
            try? resolveXwaylandExecutable(
                environment: context.environment)
        }
    }

    private func pidfd(scope: String) -> HostPrerequisite {
        HostPrerequisite(
            id: "kernel:pidfd-open",
            scope: scope,
            description: "Linux pidfd_open support"
        ) {
            let path = "/proc/self/fd"
            guard FileManager.default.fileExists(atPath: path) else {
                return nil
            }
            let result = try? await self.context.run(
                "python3",
                [
                    "-c",
                    "import os; fd=os.pidfd_open(os.getpid()); os.close(fd); print('pidfd_open')",
                ],
                capture: true)
            return result?.trimmingCharacters(in: .whitespacesAndNewlines)
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
        context.nativeSDKRoot
    }
}
