import FoundationEssentials

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
    private static let boostVersion = "1.84.0"
    private static let boostArchiveName = "boost_1_84_0.tar.gz"
    // Published with Boost 1.84.0 at https://www.boost.org/releases/1.84.0/.
    private static let boostArchiveSHA256 =
        "a5800f405508f5df8114558ca9855d2640a2de8f0445f051fa1c7c3383045724"

    let context: WorkspaceContext

    private struct BootstrapStage {
        let name: String
        let run: () throws -> Void
    }

    func bootstrap(_ selection: String?) throws {
        let selected = try components(selection)
        if !Set(selected).isDisjoint(with: [.tracy, .core, .linux, .rn, .compositor, .shell]) {
            try context.run(
                "git",
                ["submodule", "update", "--init", "--recursive", "swift-tracy/third-party/tracy"],
                directory: context.root
            )
        }
        let runtimeComponents = Set(selected).intersection([.core, .linux, .rn, .compositor, .shell])
        if runtimeComponents.isEmpty {
            for component in selected {
                print("==> resolve \(component.rawValue)")
                try context.run("swift", ["package", "resolve"], directory: context.repository(component.directoryName))
            }
            return
        }
        for stage in bootstrapStages(for: Set(selected)) {
            print("==> \(stage.name)")
            try stage.run()
        }
    }

    private func bootstrapStages(for selected: Set<WorkspaceComponent>) -> [BootstrapStage] {
        let core = context.repository("core")
        let rn = context.repository("react-native")
        let needsCore = !selected.isDisjoint(with: [.core, .linux, .rn, .compositor, .shell])
        let needsRN = selected.contains(.rn)
        var stages: [BootstrapStage] = []

        if needsCore {
            stages.append(BootstrapStage(name: "core-source-sync", run: {
                try context.run("third-party/sync-deps.sh", [], directory: core)
                try context.run("git", ["submodule", "update", "--init", "--recursive", "core/third-party", "third-party/swift-java", "third-party/swift-java-jni-core"], directory: context.root)
            }))
            stages.append(BootstrapStage(name: "render-sdk", run: {
                try context.run("swift", ["package", "build-skia", "--allow-writing-to-package-directory"], directory: core)
            }))
        }

        if needsRN {
            stages.append(BootstrapStage(name: "rn-source-sync", run: {
                try context.run("git", ["submodule", "update", "--init", "--recursive", "react-native/third-party"], directory: context.root)
                try provisionBoost(in: rn)
                try context.run("corepack", ["yarn", "--cwd", "third-party/react-native", "install", "--frozen-lockfile"], directory: rn)
            }))
            stages.append(BootstrapStage(name: "rn-types", run: {
                // React Native's default JS API is the Strict TypeScript API; the
                // strict `types_generated/` surface ships only in the npm tarball,
                // so consuming the package from source requires generating it here.
                try context.run("corepack", ["yarn", "--cwd", "third-party/react-native", "build-types"], directory: rn)
            }))
            stages.append(BootstrapStage(name: "rn-codegen", run: {
                try context.run("swift", ["package", "generate-rn-spec", "--allow-writing-to-package-directory"], directory: rn)
            }))
            stages.append(BootstrapStage(name: "rn-sdk", run: {
                for command in ["build-hermes", "build-rn-support", "build-rn-cxx"] { try context.run("swift", ["package", command, "--allow-writing-to-package-directory"], directory: rn) }
                try context.run("swift", ["build", "--target", "NucleusReactRuntimeCxx"], directory: rn)
                try context.run(
                    "swift",
                    ["build", "--product", "NucleusReactRuntimeHostCxx"],
                    directory: rn)
                try context.run(
                    "swift",
                    ["package", "provision-cxx-libs", "debug", "--allow-writing-to-package-directory"],
                    directory: rn)
            }))
        }

        stages.append(BootstrapStage(name: "swift-products-" + selected.map(\.rawValue).sorted().joined(separator: "-"), run: {
            for component in WorkspaceComponent.allCases where selected.contains(component) { try build(component.rawValue) }
        }))

        return stages
    }

    private func provisionBoost(in rn: URL) throws {
        let manager = FileManager.default
        let destination = rn.appendingPathComponent("third-party/boost")
        if !manager.fileExists(atPath: destination.appendingPathComponent("version.hpp").path) {
            let temporary = manager.temporaryDirectory.appendingPathComponent("nucleus-boost-" + UUID().uuidString)
            try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? manager.removeItem(at: temporary) }
            let archive = temporary.appendingPathComponent(Self.boostArchiveName)
            let archiveURL =
                "https://archives.boost.io/release/\(Self.boostVersion)/source/"
                    + Self.boostArchiveName
            try context.run(
                "curl",
                [
                    "--fail", "--show-error", "--silent", "--location",
                    "--proto", "=https", "--proto-redir", "=https",
                    archiveURL, "--output", archive.path,
                ])
            try SHA256Verifier.verify(
                archive,
                expectedDigest: Self.boostArchiveSHA256,
                context: context)
            try context.run("tar", ["xzf", archive.path, "-C", temporary.path])
            try manager.createDirectory(at: destination, withIntermediateDirectories: true)
            for item in try manager.contentsOfDirectory(atPath: temporary.appendingPathComponent("boost_1_84_0/boost").path) {
                let target = destination.appendingPathComponent(item)
                if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
                try manager.copyItem(at: temporary.appendingPathComponent("boost_1_84_0/boost/" + item), to: target)
            }
        }
        let compatibilityLink = destination.appendingPathComponent("boost")
        if !manager.fileExists(atPath: compatibilityLink.path) {
            try manager.createSymbolicLink(atPath: compatibilityLink.path, withDestinationPath: ".")
        }
    }

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

    func test(_ selection: String?) throws {
        guard selection == nil || selection == "all" else {
            for component in try components(selection) {
                try testDebug(component)
            }
            return
        }

        // The order is part of the repository contract: foundational packages
        // establish their modules before downstream C++ import graphs are built.
        for component in WorkspaceComponent.allCases {
            try testDebug(component)
        }

        try CrossLanguageABIAudit(context: context).run()

        for suite in releaseStructuralSuites {
            try testReleaseSuite(suite)
        }
        try PublicAPIAudit(context: context).run()
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

    private func testDebug(_ component: WorkspaceComponent) throws {
        let directory = context.repository(component.directoryName)
        switch component {
        case .tracy, .vulkan, .wayland, .core, .linux, .rn, .shell:
            try runTest(
                component: component.rawValue,
                package: component.directoryName,
                configuration: "debug",
                suite: "all",
                arguments: ["test"],
                directory: directory)
        case .compositor:
            try runTest(
                component: component.rawValue,
                package: "compositor/compositor-core",
                configuration: "debug",
                suite: "all",
                arguments: ["test", "--package-path", "compositor-core"],
                directory: directory)
            try runTest(
                component: component.rawValue,
                package: "compositor/compositor",
                configuration: "debug",
                suite: "all",
                arguments: [
                    "test", "--package-path", "compositor",
                ],
                directory: directory)
        }
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
