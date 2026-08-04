import AndroidRuntimeColliderRecipe
import ArgumentParser
import ColliderCore
import Foundation
import NativeBuilderColliderRecipe

enum RuntimeSanitizer: String, CaseIterable, Equatable, ExpressibleByArgument {
    case address
    case undefined
    case thread

    var runtimeEnvironment: [String: String] {
        switch self {
        case .address:
            [
                "ASAN_OPTIONS":
                    "detect_leaks=1:halt_on_error=1:abort_on_error=1:strict_string_checks=1",
                "LSAN_OPTIONS": "exitcode=23:report_objects=1:use_unaligned=0",
            ]
        case .undefined:
            [
                "UBSAN_OPTIONS": "halt_on_error=1:abort_on_error=1:print_stacktrace=1"
            ]
        case .thread:
            [
                "TSAN_OPTIONS":
                    "halt_on_error=1:abort_on_error=1:history_size=7:second_deadlock_stack=1"
            ]
        }
    }
}

enum SanitizerSelection: String, CaseIterable, ExpressibleByArgument {
    case all
    case address
    case undefined
    case thread

    var sanitizers: [RuntimeSanitizer] {
        switch self {
        case .all: RuntimeSanitizer.allCases
        case .address: [.address]
        case .undefined: [.undefined]
        case .thread: [.thread]
        }
    }
}

struct SanitizerCommand {
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

    let context: WorkspaceContext

    func run(
        _ selection: SanitizerSelection,
        controls: TaskControls
    ) async throws {
        let registry = ComponentRegistry(context: context)
        var tasks = try registry.linuxArchitectureTasks()
        var selected: [TaskID] = []
        for sanitizer in selection.sanitizers {
            let swiftPM = try registry.linuxSwiftPMInvocation(
                sanitizer: sanitizer.rawValue,
                linkerFlags: sanitizer == .undefined ? ["-lubsan"] : [])
            var environment = context.taskEnvironment
            environment.merge(sanitizer.runtimeEnvironment) { _, configured in configured }
            if sanitizer == .address {
                let suppressions = context.layout.tools.appending(
                    "lsan-suppressions.txt")
                environment["LSAN_OPTIONS", default: ""] +=
                    ":suppressions=\(suppressions.string)"
            }
            environment["NUCLEUS_TEST_SEED"] = "0x4e55434c455553"
            for invocation in invocations(for: sanitizer) {
                let task = task(
                    invocation,
                    sanitizer: sanitizer,
                    swiftPM: swiftPM,
                    environment: environment)
                tasks.append(task)
                selected.append(task.id)
            }
        }
        try await context.execute(
            tasks: tasks,
            selected: selected,
            controls: controls)
    }

    private func task(
        _ invocation: Invocation,
        sanitizer: RuntimeSanitizer,
        swiftPM: SwiftPMInvocation,
        environment: [String: String]
    ) -> TaskDeclaration {
        let id = TaskID(rawValue: "sanitize.\(sanitizer.rawValue).\(invocation.id)")
        let dependencies = [
            NativeBuilderTaskIDs.prepare,
            AndroidRuntimeTaskIDs.gfxstream(
                NativeLinuxTarget(architecture: .arm64)),
        ]
        let prerequisiteIdentity = ArtifactInput.value(
            name: "prerequisite-targets",
            bytes: Array(invocation.prerequisiteTargets.joined(separator: "\u{0}").utf8))
        switch invocation.workload {
        case .test(let suite):
            let requirement = swiftPM.testProduct(
                package: invocation.package,
                testProduct: suite,
                packageRoot: context.layout.root,
                environment: environment,
                arguments: ["--filter", suite])
            return TaskDeclaration(
                id: id,
                component: ComponentID(rawValue: "sanitize"),
                dependencies: dependencies,
                swiftTests: [requirement],
                inputs: [swiftPM.identityInput, prerequisiteIdentity],
                locks: [.checkout("sanitize-\(sanitizer.rawValue)")],
                cachePolicy: .always,
                operation: .sequence([]))
        case .executable(let product):
            let executable = swiftPM.executable(product)
            let requirement = swiftPM.product(
                package: invocation.package,
                product: product,
                packageRoot: context.layout.root,
                environment: environment,
                prebuildTargets: invocation.prerequisiteTargets,
                expectedOutputs: [
                    PathPostcondition(
                        path: executable,
                        validation: .executableFile)
                ])
            return TaskDeclaration(
                id: id,
                component: ComponentID(rawValue: "sanitize"),
                dependencies: dependencies,
                swiftProducts: [requirement],
                inputs: [swiftPM.identityInput, prerequisiteIdentity],
                locks: [.checkout("sanitize-\(sanitizer.rawValue)")],
                cachePolicy: .always,
                operation: swiftPM.operation(
                    executable: executable,
                    arguments: [],
                    workingDirectory: context.layout.root,
                    environment: environment))
        }
    }

    private func invocations(for kind: RuntimeSanitizer) -> [Invocation] {
        switch kind {
        case .address:
            [
                Invocation(
                    id: "wayland-resource-failure", package: "swift-wayland",
                    suite: "WaylandResourceOwnershipTests"),
                Invocation(
                    id: "core-runtime-graph", package: "core", suite: "NucleusRuntimeGraphTests"),
                Invocation(
                    id: "core-publication-lifetime", package: "core",
                    suite: "ViewPublicationAuthorityTests"),
                Invocation(
                    id: "linux-dbus", package: "platform-linux", suite: "DBusConnectionTests"),
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
                    id: "rn-host-lifecycle", package: "react-native", suite: "FabricRuntimeTests"),
            ]
        case .undefined:
            [
                Invocation(
                    id: "core-boundaries", package: "core", suite: "NucleusVulkanDmaBufTests"),
                Invocation(
                    id: "core-pixel-boundaries", package: "core", suite: "RawPixelBufferTests"),
                Invocation(
                    id: "linux-accessibility-numeric-boundaries", package: "platform-linux",
                    suite: "AtSPIWireBoundaryTests"),
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
