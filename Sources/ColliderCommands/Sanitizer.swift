import FoundationEssentials

private extension RuntimeSanitizer {
    /// The strict runtime option strings used when `sanitize` drives a suite or
    /// harness (leak detection on, deterministic aborts). The interactive
    /// `run` command uses a distinct, more permissive policy.
    var runtimeEnvironment: [String: String] {
        switch self {
        case .address:
            [
                "ASAN_OPTIONS": "detect_leaks=1:halt_on_error=1:abort_on_error=1:strict_string_checks=1",
                "LSAN_OPTIONS": "exitcode=23:report_objects=1:use_unaligned=0",
            ]
        case .undefined:
            [
                "UBSAN_OPTIONS": "halt_on_error=1:abort_on_error=1:print_stacktrace=1",
            ]
        case .thread:
            [
                "TSAN_OPTIONS": "halt_on_error=1:abort_on_error=1:history_size=7:second_deadlock_stack=1",
            ]
        }
    }
}

struct SanitizerCommand {
    let context: WorkspaceContext

    private struct Invocation {
        enum Workload {
            case test(suite: String)
            case executable(product: String)

            var label: String {
                switch self {
                case .test(let suite): "suite=\(suite)"
                case .executable(let product): "executable=\(product)"
                }
            }
        }

        let id: String
        let package: String
        let packagePath: String?
        let workload: Workload

        init(
            id: String,
            package: String,
            packagePath: String?,
            suite: String
        ) {
            self.id = id
            self.package = package
            self.packagePath = packagePath
            self.workload = .test(suite: suite)
        }

        init(
            id: String,
            package: String,
            packagePath: String? = nil,
            executable: String
        ) {
            self.id = id
            self.package = package
            self.packagePath = packagePath
            self.workload = .executable(product: executable)
        }
    }

    func run(_ arguments: ArraySlice<String>) throws {
        guard arguments.count <= 1 else { throw usageFailure() }
        let kinds: [RuntimeSanitizer]
        if let value = arguments.first, value != "all" {
            guard let kind = RuntimeSanitizer(rawValue: value) else { throw usageFailure() }
            kinds = [kind]
        } else {
            kinds = RuntimeSanitizer.allCases
        }

        let seed = "0x4e55434c455553"
        for kind in kinds {
            for invocation in invocations(for: kind) {
                try run(invocation, sanitizer: kind, seed: seed)
            }
        }
    }

    private func invocations(for kind: RuntimeSanitizer) -> [Invocation] {
        switch kind {
        case .address:
            [
                Invocation(
                    id: "wayland-resource-failure", package: "swift-wayland",
                    packagePath: nil, suite: "WaylandResourceOwnershipTests"),
                Invocation(
                    id: "core-runtime-graph", package: "core", packagePath: nil,
                    suite: "NucleusRuntimeGraphTests"),
                Invocation(
                    id: "core-publication-lifetime", package: "core", packagePath: nil,
                    suite: "ViewPublicationAuthorityTests"),
                Invocation(
                    id: "linux-dbus", package: "platform-linux", packagePath: nil,
                    suite: "DBusConnectionTests"),
                Invocation(
                    id: "linux-accessibility-wire", package: "platform-linux",
                    packagePath: nil, suite: "AtSPIWireBoundaryTests"),
                Invocation(
                    id: "compositor-wayland-lifetime", package: "compositor",
                    packagePath: "compositor-core",
                    suite: "WaylandProtocolConformanceTests"),
                Invocation(
                    id: "compositor-seat-open-failure", package: "compositor",
                    packagePath: "compositor-core",
                    suite: "SeatSessionOwnershipTests"),
                Invocation(
                    id: "compositor-drm-lifecycle", package: "compositor",
                    packagePath: "compositor-core",
                    suite: "RendererRetirementCoordinatorTests"),
                Invocation(
                    id: "shell-transfer-lifetime", package: "shell", packagePath: nil,
                    suite: "NucleusPlatformTransportStressTests"),
                Invocation(
                    id: "rn-host-lifecycle", package: "react-native", packagePath: nil,
                    suite: "FabricRuntimeTests"),
            ]
        case .undefined:
            [
                Invocation(
                    id: "core-boundaries", package: "core", packagePath: nil,
                    suite: "NucleusVulkanDmaBufTests"),
                Invocation(
                    id: "core-pixel-boundaries", package: "core", packagePath: nil,
                    suite: "RawPixelBufferTests"),
                Invocation(
                    id: "linux-accessibility-numeric-boundaries",
                    package: "platform-linux", packagePath: nil,
                    suite: "AtSPIWireBoundaryTests"),
                Invocation(
                    id: "compositor-layout-boundaries", package: "compositor",
                    packagePath: "compositor-core",
                    suite: "DmabufLayoutValidatorTests"),
                Invocation(
                    id: "shell-wire-boundaries", package: "shell", packagePath: nil,
                    suite: "ShellTextInputWireTests"),
            ]
        case .thread:
            [
                Invocation(
                    id: "core-image-workers", package: "core",
                    executable: "NucleusCoreThreadSanitizerHarness"),
                Invocation(
                    id: "linux-reactor", package: "platform-linux",
                    executable: "NucleusLinuxThreadSanitizerHarness"),
                // One direct executable owns both the cross-thread render-wake
                // race and real Wayland client/resource teardown. Avoid filtered
                // Swift Testing here: SwiftPM launches every compositor test
                // runner, and zero-match runners abort in dispatch_main teardown
                // under TSan before the selected suite can be evaluated.
                Invocation(
                    id: "compositor-callbacks", package: "compositor",
                    packagePath: "compositor",
                    executable: "NucleusCompositorThreadSanitizerHarness"),
                Invocation(
                    id: "shell-callbacks", package: "shell",
                    executable: "NucleusShellThreadSanitizerHarness"),
                Invocation(
                    id: "rn-runtime-workers", package: "react-native",
                    executable: "NucleusReactThreadSanitizerHarness"),
            ]
        }
    }

    private func run(
        _ invocation: Invocation,
        sanitizer: RuntimeSanitizer,
        seed: String
    ) throws {
        let packageDirectory = context.repository(invocation.package)
        let scratch = context.root
            .appendingPathComponent(".build/nucleus-sanitizers", isDirectory: true)
            .appendingPathComponent(sanitizer.rawValue, isDirectory: true)
            .appendingPathComponent(invocation.id, isDirectory: true)
        var commonArguments = [
            "--scratch-path", scratch.path,
            "--sanitize", sanitizer.rawValue,
        ]
        // SwiftPM instruments every product in the package graph. Its Linux
        // UBSan link invocation does not add the runtime for unrelated C++
        // executable products, so make that runtime explicit for every link.
        if sanitizer == .undefined {
            commonArguments += ["-Xlinker", "-lubsan"]
        }
        if let packagePath = invocation.packagePath {
            commonArguments += ["--package-path", packagePath]
        }

        var environment = context.environment
        for (key, value) in sanitizer.runtimeEnvironment {
            environment[key] = value
        }
        if sanitizer == .address {
            let suppressions = context.root.appendingPathComponent(
                "tools/lsan-suppressions.txt")
            environment["LSAN_OPTIONS", default: ""] +=
                ":suppressions=\(suppressions.path)"
        }
        environment["NUCLEUS_TEST_SEED"] = seed
        let instrumentedContext = WorkspaceContext(
            root: context.root,
            environment: environment)
        let packageIdentity = invocation.packagePath.map {
            invocation.package + "/" + $0
        } ?? invocation.package
        let options = sanitizer.runtimeEnvironment
            .map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
        print(
            "==> sanitize package=\(packageIdentity) "
                + "sanitizer=\(sanitizer.rawValue) \(invocation.workload.label) "
                + "seed=\(seed) scratch=\(scratch.path) \(options)")
        do {
            switch invocation.workload {
            case .test(let suite):
                try instrumentedContext.run(
                    "swift",
                    ["test"] + commonArguments + ["--filter", suite],
                    directory: packageDirectory)
            case .executable(let product):
                let buildArguments = ["build"] + commonArguments
                    + ["--product", product]
                try instrumentedContext.run(
                    "swift", buildArguments,
                    directory: packageDirectory)
                let output = try instrumentedContext.run(
                    "swift", buildArguments + ["--show-bin-path"],
                    directory: packageDirectory,
                    capture: true)
                guard let binPath = output.split(separator: "\n").last else {
                    throw WorkspaceFailure.message(
                        "SwiftPM did not report a binary path for \(product)")
                }
                let executable = URL(fileURLWithPath: String(binPath))
                    .appendingPathComponent(product)
                guard FileManager.default.isExecutableFile(
                    atPath: executable.path)
                else {
                    throw WorkspaceFailure.message(
                        "sanitizer executable is missing: \(executable.path)")
                }
                try instrumentedContext.run(
                    executable.path, [],
                    directory: packageDirectory)
            }
        } catch {
            throw WorkspaceFailure.message(
                "sanitizer failed [package=\(packageIdentity) "
                    + "sanitizer=\(sanitizer.rawValue) "
                    + "\(invocation.workload.label) "
                    + "seed=\(seed)]: \(error)")
        }
    }

    private func usageFailure() -> WorkspaceFailure {
        .message("usage: tools/collider sanitize [all|address|undefined|thread]")
    }
}
