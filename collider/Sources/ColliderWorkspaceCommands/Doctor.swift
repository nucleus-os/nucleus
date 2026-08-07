import ArgumentParser
import ColliderCore
import ColliderRuntime
import Foundation
import NativeBuilderColliderRecipe
import SystemPackage

enum DoctorScope: String, CaseIterable, ExpressibleByArgument {
    case all
    case runtime
    case swiftSDK = "swift-sdk"
    case android
    case browser
    case ciMacOSBuilder = "ci-macos-builder"
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

struct HostPrerequisite {
    let id: String
    let scope: String
    let description: String
    let remediation: String?
    let evaluate: () async -> String?

    init(
        id: String,
        scope: String,
        description: String,
        remediation: String? = nil,
        evaluate: @escaping () async -> String?
    ) {
        self.id = id
        self.scope = scope
        self.description = description
        self.remediation = remediation
        self.evaluate = evaluate
    }
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
                checks.append(
                    DoctorCheck(
                        id: prerequisite.id,
                        scope: prerequisite.scope,
                        description: prerequisite.description,
                        status: .planned,
                        detail: nil))
                continue
            }
            let detail = await prerequisite.evaluate()
            checks.append(
                DoctorCheck(
                    id: prerequisite.id,
                    scope: prerequisite.scope,
                    description: prerequisite.description,
                    status: detail == nil ? .failed : .passed,
                    detail: detail ?? prerequisite.remediation))
        }
        let report = DoctorReport(
            scope: scope.rawValue,
            success: checks.allSatisfy { $0.status != .failed },
            checks: checks)
        if quiet {
            // Callers that compose doctor with a machine-readable task report
            // still use the same prerequisite registry without a second payload.
        } else if json {
            print(
                String(
                    decoding: try JSONEncoder.sorted.encode(report), as: UTF8.self))
        } else {
            for check in checks {
                let marker =
                    switch check.status {
                    case .planned: "plan"
                    case .passed: "ok"
                    case .failed: "MISSING"
                    }
                print(
                    "  \(marker.padding(toLength: 7, withPad: " ", startingAt: 0))  \(check.description)"
                        + (check.detail.map { ": \($0)" } ?? ""))
            }
            if report.success {
                print(
                    dryRun
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
        var all =
            runtimePrerequisites + swiftSDKPrerequisites
            + androidPrerequisites + browserPrerequisites
        if RunnerPlatform.current
            == RunnerPlatform(
                operatingSystem: .macOS,
                architecture: .arm64)
            || scope == .ciMacOSBuilder
        {
            all += macOSBuilderPrerequisites
        }
        let selected =
            scope == .all
            ? all
            : all.filter { $0.scope == scope.rawValue }
        var seen: Set<String> = []
        return selected.filter { seen.insert($0.id).inserted }
    }

    private var macOSBuilderPrerequisites: [HostPrerequisite] {
        MacOSBuilderDoctor(context: context).prerequisites
    }

    private var runtimePrerequisites: [HostPrerequisite] {
        [ociExecutor(scope: "runtime")]
            + executables(
                [
                    "git", "tar", "python3", "unzip",
                ],
                scope: "runtime")
            + paths(
                [
                    "Package.swift",
                    "third-party/swift-java-jni-core/Package.swift",
                ],
                under: context.root,
                scope: "runtime")
            + [nativeSDKLayout(scope: "runtime")]
            + paths(
                [
                    "render/include", "render/lib/skia-graphite",
                    "rn/include", "rn/lib/rn",
                    "wayland/bin/wayland-scanner", "wayland/include",
                    "wayland/lib",
                ],
                under: context.nativeSDKRoot(
                    for: NativeLinuxTarget(architecture: .arm64)),
                scope: "runtime")
            + paths(
                [
                    "render/include", "render/lib/skia-graphite",
                    "rn/include", "rn/lib/rn",
                    "wayland/include", "wayland/lib",
                ],
                under: context.nativeSDKRoot(
                    for: NativeLinuxTarget(architecture: .x86_64)),
                scope: "runtime")
            + paths(
                [
                    "nucleus-swift-6.4-linux.artifactbundle/swift-linux/"
                        + "aarch64-unknown-linux-gnu/swift-sdk.json",
                    "nucleus-swift-6.4-linux.artifactbundle/swift-linux/"
                        + "x86_64-unknown-linux-gnu/swift-sdk.json",
                ],
                under: runtimeSwiftSDKRoot(),
                scope: "runtime")
    }

    private var swiftSDKPrerequisites: [HostPrerequisite] {
        [swiftVersion(scope: "swift-sdk"), ociExecutor(scope: "swift-sdk")]
            + executables(
                [
                    "swift", "git", "pkgutil", "tar", "xcrun",
                ],
                scope: "swift-sdk")
            + paths(
                [
                    "swift-sdk/source",
                    "swift-sdk/target-sdk-inputs.json",
                    "swift-sdk/validate-target-sdk-artifacts.sh",
                    "swift-sdk/prepare-linux-sysroot.sh",
                    "swift-sdk/nucleus-target-runtime-presets.ini",
                    "swift-sdk/runtime-build-container/Containerfile",
                ],
                under: context.root,
                scope: "swift-sdk")
    }

    private var androidPrerequisites: [HostPrerequisite] {
        [ociExecutor(scope: "android")]
            + executables(
                ["swift", "swiftc", "java", "ccache"], scope: "android")
            + paths(
                [
                    "Package.swift", "core/android/gradlew",
                ],
                under: context.root,
                scope: "android")
    }

    private var browserPrerequisites: [HostPrerequisite] {
        [ociExecutor(scope: "browser")]
            + executables(
                [
                    "git", "python3", "tar",
                ],
                scope: "browser")
            + paths(
                [
                    "cef/apt-deps.txt", "chromium/source.lock.json",
                ],
                under: context.root,
                scope: "browser")
    }

    private func ociExecutor(scope: String) -> HostPrerequisite {
        let runner = RunnerPlatform.current
        let backend: String
        switch (runner.operatingSystem, runner.architecture) {
        case (.macOS, .arm64):
            backend = ExecutionBackend.appleContainer.rawValue
        case (.macOS, .x86_64), (.linux, .arm64), (.linux, .x86_64),
            (.android, .arm64), (.android, .x86_64):
            return HostPrerequisite(
                id: "oci-executor",
                scope: scope,
                description: "supported OCI executor"
            ) { nil }
        }
        return HostPrerequisite(
            id: "oci-executor:\(backend)",
            scope: scope,
            description: "\(backend) OCI executor"
        ) {
            guard let health = try? await context.runtime.ociRuntimeHealth(),
                health.apiServerAppName == "container-apiserver"
            else { return nil }
            guard
                let network = try? await context.runtime.ociRuntimeNetwork(
                    named: context.ociConfiguration.isolatedNetwork),
                network.mode == "hostOnly"
            else { return nil }
            return "\(runner.operatingSystem.rawValue)/"
                + "\(runner.architecture.rawValue) via \(backend); "
                + health.apiServerVersion
        }
    }

    private func nativeSDKLayout(scope: String) -> HostPrerequisite {
        let root = context.nativeSDKRoot
        return HostPrerequisite(
            id: "native-sdk:per-target-layout",
            scope: scope,
            description: "per-target native SDK ownership"
        ) {
            let expected = "linux-\(RunnerPlatform.current.architecture.rawValue)"
            guard root.lastComponent?.string == expected else { return nil }
            return root.string
        }
    }

    private func swiftVersion(scope: String) -> HostPrerequisite {
        HostPrerequisite(
            id: "swift-6.4",
            scope: scope,
            description: "Swift 6.4 toolchain"
        ) {
            guard
                let output = try? await context.run(
                    "swift", ["--version"], capture: true),
                let firstLine = output.split(separator: "\n").first,
                firstLine.contains("Swift version 6.4")
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
        under root: FilePath,
        scope: String
    ) -> [HostPrerequisite] {
        relativePaths.map { relativePath in
            let path = root.appending(relativePath).string
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
                fileURLWithPath: String(directory), isDirectory: true
            )
            .appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func runtimeSwiftSDKRoot() -> FilePath {
        context.cacheRoot.appending(
            "nucleus/swift-target-sdks/current/swift-sdks")
    }
}
