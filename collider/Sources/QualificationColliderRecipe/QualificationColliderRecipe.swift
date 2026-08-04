import ColliderCore
import SystemPackage

public enum SanitizerKind: String, CaseIterable, Equatable, Sendable {
    case address
    case undefined
    case thread

    public var entrypoint: ComponentEntrypointID {
        switch self {
        case .address: .sanitizeAddress
        case .undefined: .sanitizeUndefined
        case .thread: .sanitizeThread
        }
    }

    fileprivate var runtimeEnvironment: [String: String] {
        switch self {
        case .address:
            [
                "ASAN_OPTIONS":
                    "detect_leaks=1:halt_on_error=1:abort_on_error=1:strict_string_checks=1",
                "LSAN_OPTIONS": "exitcode=23:report_objects=1:use_unaligned=0",
            ]
        case .undefined:
            [
                "UBSAN_OPTIONS":
                    "halt_on_error=1:abort_on_error=1:print_stacktrace=1"
            ]
        case .thread:
            [
                "TSAN_OPTIONS":
                    "halt_on_error=1:abort_on_error=1:history_size=7:second_deadlock_stack=1"
            ]
        }
    }
}

public enum BenchmarkColliderRecipe: ColliderComponent {
    public static let descriptor = ComponentDescriptor(
        id: ComponentID(rawValue: "benchmark"),
        canonicalName: "benchmark",
        directoryName: "core/benchmarks")

    public static func makeComponent(
        in context: RecipeContext
    ) throws -> ComponentDefinition {
        let targetArtifacts = try context.targetArtifacts(
            for: NativeLinuxTarget(architecture: .arm64))
        let swiftPM = try context.swiftPM(
            .linux(.arm64, configuration: .release))
        let environment = context.environment.merging([
            "NUCLEUS_BENCHMARK_SWIFT_VERSION": swiftPM.context.toolchainIdentity
        ]) { _, configured in configured }
        let suites = [
            ("core", "NucleusHeadlessBenchmarks", "core"),
            ("platform-linux/desktop", "NucleusLinuxBenchmarks", "linux"),
            ("react-native", "NucleusReactBenchmarks", "react-native"),
        ]
        let tasks = try suites.map { package, product, outputDirectory in
            let executable = swiftPM.executable(product)
            let output = context.repositoryRoot.appending(
                ".nucleus/benchmarks/\(outputDirectory)")
            var builder = TaskBuilder(
                id: TaskID(rawValue: "benchmark.\(outputDirectory)"),
                component: descriptor.id)
            builder.consume(targetArtifacts)
            let _: ArtifactReference<DirectoryArtifact> = try builder.output(
                "results",
                path: output,
                validation: .nonEmptyDirectory)
            return builder.build(
                swiftProducts: [
                    swiftPM.product(
                        package: package,
                        product: product,
                        packageRoot: context.repositoryRoot.appending(package),
                        environment: environment,
                        expectedOutputs: [
                            PathPostcondition(
                                path: executable,
                                validation: .executableFile)
                        ])
                ],
                inputs: [swiftPM.identityInput],
                locks: [.checkout("benchmark-\(outputDirectory)")],
                assessmentPolicy: .always,
                operation: .sequence([
                    .action(
                        try AnyColliderAction(
                            PrepareBenchmarkOutputAction(output: output))),
                    swiftPM.operation(
                        executable: executable,
                        arguments: ["--output", output.string, "--iterations", "3"],
                        workingDirectory: context.repositoryRoot,
                        environment: environment),
                ]))
        }
        return try ComponentDefinition(
            descriptor: descriptor,
            tasks: tasks,
            entrypoints: [
                ComponentEntrypoint(id: .benchmark, roots: Set(tasks.map(\.id)))
            ])
    }
}

private struct PrepareBenchmarkOutputAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let output: FilePath

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: output.string)
        }
    }

    static let kind: ActionKind = "benchmark.prepare-output"

    let output: FilePath

    var identity: Identity { Identity(output: output) }

    var requirements: ActionRequirements {
        ActionRequirements(effects: [
            ActionEffect(.write, scope: .output(output))
        ])
    }

    func execute(in context: ActionContext) async throws {
        try context.files.remove(output)
    }
}

public enum SanitizerColliderRecipe: ColliderComponent {
    public static let descriptor = ComponentDescriptor(
        id: ComponentID(rawValue: "sanitize"),
        canonicalName: "sanitize",
        directoryName: "integration-tests/sanitizers")

    public static func makeComponent(
        in context: RecipeContext
    ) throws -> ComponentDefinition {
        let targetArtifacts = try context.targetArtifacts(
            for: NativeLinuxTarget(architecture: .arm64))
        var tasks: [TaskDeclaration] = []
        var entrypoints: [ComponentEntrypoint] = []
        for sanitizer in SanitizerKind.allCases {
            let swiftPM = try context.swiftPM(
                .linux(.arm64, sanitizer: sanitizer.rawValue))
            var environment = context.environment
            environment.merge(sanitizer.runtimeEnvironment) { _, configured in configured }
            if sanitizer == .address {
                let suppressions = context.repositoryRoot.appending(
                    "tools/lsan-suppressions.txt")
                environment["LSAN_OPTIONS", default: ""] +=
                    ":suppressions=\(suppressions.string)"
            }
            environment["NUCLEUS_TEST_SEED"] = "0x4e55434c455553"
            let sanitizerTasks = invocations(for: sanitizer).map {
                task(
                    $0,
                    sanitizer: sanitizer,
                    swiftPM: swiftPM,
                    environment: environment,
                    context: context,
                    targetArtifacts: targetArtifacts)
            }
            tasks += sanitizerTasks
            entrypoints.append(
                ComponentEntrypoint(
                    id: sanitizer.entrypoint,
                    roots: Set(sanitizerTasks.map(\.id))))
        }
        return try ComponentDefinition(
            descriptor: descriptor,
            tasks: tasks,
            entrypoints: entrypoints)
    }

    private struct Invocation {
        enum Workload {
            case test(suite: String)
            case executable(product: String)
        }

        let id: String
        let package: String
        let prerequisiteTargets: [String]
        let workload: Workload

        init(id: String, package: String, suite: String) {
            self.id = id
            self.package = package
            prerequisiteTargets = []
            workload = .test(suite: suite)
        }

        init(
            id: String,
            package: String,
            prerequisiteTargets: [String] = [],
            executable: String
        ) {
            self.id = id
            self.package = package
            self.prerequisiteTargets = prerequisiteTargets
            workload = .executable(product: executable)
        }
    }

    private static func task(
        _ invocation: Invocation,
        sanitizer: SanitizerKind,
        swiftPM: SwiftPMInvocation,
        environment: [String: String],
        context: RecipeContext,
        targetArtifacts: ArtifactReferenceSet
    ) -> TaskDeclaration {
        let id = TaskID(rawValue: "sanitize.\(sanitizer.rawValue).\(invocation.id)")
        let prerequisiteIdentity = ArtifactInput.value(
            name: "prerequisite-targets",
            bytes: Array(invocation.prerequisiteTargets.joined(separator: "\u{0}").utf8))
        switch invocation.workload {
        case .test(let suite):
            let requirement = swiftPM.testProduct(
                package: invocation.package,
                testProduct: suite,
                packageRoot: context.repositoryRoot.appending(invocation.package),
                environment: environment,
                arguments: ["--filter", suite])
            var builder = TaskBuilder(
                id: id,
                component: descriptor.id)
            builder.consume(targetArtifacts)
            return builder.build(
                swiftTests: [requirement],
                inputs: [swiftPM.identityInput, prerequisiteIdentity],
                locks: [.checkout("sanitize-\(sanitizer.rawValue)")],
                assessmentPolicy: .always,
                operation: .sequence([]))
        case .executable(let product):
            let executable = swiftPM.executable(product)
            let requirement = swiftPM.product(
                package: invocation.package,
                product: product,
                packageRoot: context.repositoryRoot.appending(invocation.package),
                environment: environment,
                prebuildTargets: invocation.prerequisiteTargets,
                expectedOutputs: [
                    PathPostcondition(
                        path: executable,
                        validation: .executableFile)
                ])
            var builder = TaskBuilder(
                id: id,
                component: descriptor.id)
            builder.consume(targetArtifacts)
            return builder.build(
                swiftProducts: [requirement],
                inputs: [swiftPM.identityInput, prerequisiteIdentity],
                locks: [.checkout("sanitize-\(sanitizer.rawValue)")],
                assessmentPolicy: .always,
                operation: swiftPM.operation(
                    executable: executable,
                    arguments: [],
                    workingDirectory: context.repositoryRoot,
                    environment: environment))
        }
    }

    private static func invocations(for kind: SanitizerKind) -> [Invocation] {
        switch kind {
        case .address:
            [
                Invocation(
                    id: "wayland-resource-failure", package: "swift-wayland",
                    suite: "WaylandResourceOwnershipTests"),
                Invocation(
                    id: "core-runtime-graph", package: "core",
                    suite: "NucleusRuntimeGraphTests"),
                Invocation(
                    id: "core-publication-lifetime", package: "core",
                    suite: "ViewPublicationAuthorityTests"),
                Invocation(
                    id: "linux-dbus", package: "platform-linux",
                    suite: "DBusConnectionTests"),
                Invocation(
                    id: "linux-accessibility-wire", package: "platform-linux",
                    suite: "AtSPIWireBoundaryTests"),
                Invocation(
                    id: "compositor-wayland-lifetime", package: "compositor",
                    suite: "WaylandProtocolConformanceTests"),
                Invocation(
                    id: "compositor-seat-open-failure", package: "compositor",
                    suite: "SeatSessionOwnershipTests"),
                Invocation(
                    id: "compositor-drm-lifecycle", package: "compositor",
                    suite: "RendererRetirementCoordinatorTests"),
                Invocation(
                    id: "shell-transfer-lifetime",
                    package: "integration-tests/window-client-conformance",
                    suite: "NucleusPlatformTransportStressTests"),
                Invocation(
                    id: "rn-host-lifecycle", package: "react-native",
                    suite: "FabricRuntimeTests"),
            ]
        case .undefined:
            [
                Invocation(
                    id: "core-boundaries", package: "core",
                    suite: "NucleusVulkanDmaBufTests"),
                Invocation(
                    id: "core-pixel-boundaries", package: "core",
                    suite: "RawPixelBufferTests"),
                Invocation(
                    id: "linux-accessibility-numeric-boundaries",
                    package: "platform-linux", suite: "AtSPIWireBoundaryTests"),
                Invocation(
                    id: "compositor-layout-boundaries", package: "compositor",
                    suite: "DmabufLayoutValidatorTests"),
                Invocation(
                    id: "shell-wire-boundaries",
                    package: "integration-tests/window-client-conformance",
                    suite: "NucleusDesktopTextInputWireTests"),
            ]
        case .thread:
            [
                Invocation(
                    id: "core-image-workers", package: "core",
                    executable: "NucleusCoreThreadSanitizerHarness"),
                Invocation(
                    id: "linux-reactor", package: "platform-linux",
                    executable: "NucleusLinuxThreadSanitizerHarness"),
                Invocation(
                    id: "android-runtime-lifetimes", package: "android-runtime",
                    executable: "NucleusAndroidThreadSanitizerHarness"),
                Invocation(
                    id: "compositor-callbacks", package: "compositor",
                    executable: "NucleusRenderServerThreadSanitizerHarness"),
                Invocation(
                    id: "shell-callbacks", package: "shell",
                    executable: "NucleusShellThreadSanitizerHarness"),
                Invocation(
                    id: "rn-runtime-workers",
                    package: "react-native",
                    prerequisiteTargets: ["NucleusReactRuntimeCxx"],
                    executable: "NucleusReactThreadSanitizerHarness"),
            ]
        }
    }
}
