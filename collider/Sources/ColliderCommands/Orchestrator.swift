import ColliderCore
import Foundation
import SystemPackage

enum WorkspaceComponent: String, Hashable, Sendable {
    case tracy
    case vulkan
    case wayland
    case core
    case linux
    case rn
    case compositor
    case shell

}

struct Orchestrator {
    let context: WorkspaceContext

    func runRepositoryWideTestGates() async throws {
        for suite in releaseStructuralSuites {
            try await testReleaseSuite(suite)
        }
    }

    private struct ReleaseStructuralSuite {
        let component: WorkspaceComponent
        let name: String
    }

    private var releaseStructuralSuites: [ReleaseStructuralSuite] {
        [
            ReleaseStructuralSuite(
                component: .core,
                name: "NucleusFoundationPublicationStressTests"),
            ReleaseStructuralSuite(
                component: .core,
                name: "NucleusFoundationLifecycleStressTests"),
            ReleaseStructuralSuite(
                component: .core,
                name: "NucleusTextEditorStressTests"),
            ReleaseStructuralSuite(
                component: .core,
                name: "NucleusCollectionStressTests"),
            ReleaseStructuralSuite(
                component: .shell,
                name: "NucleusPlatformTransportStressTests"),
            ReleaseStructuralSuite(
                component: .compositor,
                name: "NucleusCompositorTransitionStressTests"),
        ]
    }

    private func testReleaseSuite(
        _ suite: ReleaseStructuralSuite
    ) async throws {
        // These gates run the same packages the task graph builds, one
        // configuration over. Driving them through the release build context
        // shares one build directory across all of them instead of leaving a
        // release build tree beside every package they touch, and gives the
        // manifests the generated header directory that context belongs to.
        let swiftPM = try context.swiftPMInvocation(configuration: .release)
        var arguments = ["test"]
        arguments += ["--filter", suite.name]
        try await runTest(
            component: suite.component.rawValue,
            package: ".",
            configuration: "release",
            suite: suite.name,
            arguments: swiftPM.commandArguments(arguments),
            environmentOverrides: swiftPM.commandEnvironment([:]),
            directory: context.root)
    }

    private func runTest(
        component: String,
        package: String,
        configuration: String,
        suite: String,
        arguments: [String],
        environmentOverrides: [String: String] = [:],
        directory: URL
    ) async throws {
        let identity =
            "component=\(component) package=\(package) "
            + "configuration=\(configuration) suite=\(suite)"
        print("==> test \(identity)")
        do {
            try await context.run(
                "swift",
                arguments,
                directory: directory,
                environmentOverrides: environmentOverrides)
        } catch {
            throw WorkspaceFailure.message("test failed [\(identity)]: \(error)")
        }
    }
}
