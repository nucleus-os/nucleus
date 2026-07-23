import ColliderCore
import FoundationEssentials
import SystemPackage

enum WorkspaceComponent: String, CaseIterable, Hashable, Sendable {
    case tracy
    case vulkan
    case wayland
    case core
    case linux
    case rn
    case compositor
    case shell

    var directoryName: String {
        switch self {
        case .tracy: "swift-tracy"
        case .vulkan: "swift-vulkan"
        case .wayland: "swift-wayland"
        case .core: "core"
        case .linux: "platform-linux"
        case .rn: "react-native"
        case .compositor: "compositor"
        case .shell: "shell"
        }
    }
}

struct Orchestrator {
    let context: WorkspaceContext

    func build(_ selection: String?) throws {
        for component in try components(selection) {
            print("==> build \(component.rawValue)")
            switch component {
            case .tracy, .vulkan, .wayland:
                try context.run("swift", ["build"], directory: context.repository(component.directoryName))
            case .core, .linux:
                try context.run("swift", ["build"], directory: context.repository(component.directoryName))
            case .rn:
                try context.run("swift", ["build", "--target", "NucleusReactRuntimeCxx"], directory: context.repository(component.directoryName))
                try context.run("swift", ["build"], directory: context.repository(component.directoryName))
            case .compositor:
                let directory = context.repository(component.directoryName)
                try context.run("swift", ["build", "--package-path", "compositor-core"], directory: directory)
                try context.run("swift", ["build", "--package-path", "compositor"], directory: directory)
            case .shell:
                try context.run("swift", ["build"], directory: context.repository(component.directoryName))
            }
        }
    }

    func runRepositoryWideTestGates() throws {
        for suite in releaseStructuralSuites {
            try testReleaseSuite(suite)
        }
    }

    private struct ReleaseStructuralSuite {
        let component: WorkspaceComponent
        let packagePath: String?
        let name: String
    }

    private var releaseStructuralSuites: [ReleaseStructuralSuite] {
        [
            ReleaseStructuralSuite(
                component: .core, packagePath: nil,
                name: "NucleusFoundationPublicationStressTests"),
            ReleaseStructuralSuite(
                component: .core, packagePath: nil,
                name: "NucleusFoundationLifecycleStressTests"),
            ReleaseStructuralSuite(
                component: .core, packagePath: nil,
                name: "NucleusTextEditorStressTests"),
            ReleaseStructuralSuite(
                component: .core, packagePath: nil,
                name: "NucleusCollectionStressTests"),
            ReleaseStructuralSuite(
                component: .shell, packagePath: nil,
                name: "NucleusPlatformTransportStressTests"),
            ReleaseStructuralSuite(
                component: .compositor, packagePath: "compositor-core",
                name: "NucleusCompositorTransitionStressTests"),
        ]
    }

    private func testReleaseSuite(_ suite: ReleaseStructuralSuite) throws {
        var arguments = [
            "test", "-c", "release",
        ]
        if let packagePath = suite.packagePath {
            arguments += ["--package-path", packagePath]
        }
        arguments += ["--filter", suite.name]
        let package = suite.packagePath.map {
            suite.component.directoryName + "/" + $0
        } ?? suite.component.directoryName
        try runTest(
            component: suite.component.rawValue,
            package: package,
            configuration: "release",
            suite: suite.name,
            arguments: arguments,
            directory: context.repository(suite.component.directoryName))
    }

    private func runTest(
        component: String,
        package: String,
        configuration: String,
        suite: String,
        arguments: [String],
        directory: URL
    ) throws {
        let identity = "component=\(component) package=\(package) "
            + "configuration=\(configuration) suite=\(suite)"
        print("==> test \(identity)")
        do {
            try context.run("swift", arguments, directory: directory)
        } catch {
            throw WorkspaceFailure.message("test failed [\(identity)]: \(error)")
        }
    }

    private func components(_ selection: String?) throws -> [WorkspaceComponent] {
        guard let selection, selection != "all" else { return WorkspaceComponent.allCases }
        guard let component = WorkspaceComponent(rawValue: selection) else {
            throw WorkspaceFailure.message("unknown component '\(selection)'; expected all, tracy, vulkan, wayland, core, linux, rn, compositor, or shell")
        }
        return [component]
    }
}
