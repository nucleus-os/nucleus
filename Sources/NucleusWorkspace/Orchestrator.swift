import Foundation

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
        let shell = context.repository("shell")
        let needsCore = !selected.isDisjoint(with: [.core, .linux, .rn, .compositor, .shell])
        let needsRN = !selected.isDisjoint(with: [.rn, .shell])
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

        if selected.contains(.shell) {
            stages.append(BootstrapStage(name: "js-bundles", run: {
                try context.run("bun", ["install", "--cwd", "js", "--frozen-lockfile"], directory: shell)
                try context.run("swift", ["package", "build-shell-bundle", "--allow-writing-to-package-directory"], directory: shell)
            }))
        }
        return stages
    }

    private func provisionBoost(in rn: URL) throws {
        let manager = FileManager.default
        let destination = rn.appendingPathComponent("third-party/boost")
        if !manager.fileExists(atPath: destination.appendingPathComponent("version.hpp").path) {
            let temporary = manager.temporaryDirectory.appendingPathComponent("nucleus-boost-" + UUID().uuidString)
            try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? manager.removeItem(at: temporary) }
            let archive = temporary.appendingPathComponent("boost.tar.gz")
            try context.run("curl", ["-fsSL", "https://archives.boost.io/release/1.84.0/source/boost_1_84_0.tar.gz", "-o", archive.path])
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
            if component == .rn {
                // Shell debug products link this archive. Provision it from the
                // exact debug product before any downstream package is tested.
                try provisionHostArchive(configuration: "debug")
            }
        }

        try provisionHostArchive(configuration: "release")
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

    private struct HostArchiveMetadata: Decodable {
        let schemaVersion: Int
        let configuration: String
        let productDirectory: String
        let archive: String
        let byteCount: UInt64
        let fingerprint: String
    }

    private func provisionHostArchive(configuration: String) throws {
        let directory = context.repository("react-native")
        let identity = "component=rn package=react-native configuration=\(configuration)"
        print("==> provision \(identity) archive=libNucleusReactRuntimeHostCxx.a")
        do {
            try context.run(
                "swift",
                [
                    "build", "-c", configuration,
                    "--target", "NucleusReactRuntimeCxx",
                ],
                directory: directory)
            try context.run(
                "swift",
                [
                    "build", "-c", configuration,
                    "--product", "NucleusReactRuntimeHostCxx",
                ],
                directory: directory)
            try context.run(
                "swift",
                [
                    "package", "provision-cxx-libs", configuration,
                    "--allow-writing-to-package-directory",
                ],
                directory: directory)
            try verifyHostArchive(configuration: configuration, directory: directory)
        } catch {
            throw WorkspaceFailure.message("archive provisioning failed [\(identity)]: \(error)")
        }
    }

    private func verifyHostArchive(configuration: String, directory: URL) throws {
        let archiveName = "libNucleusReactRuntimeHostCxx.a"
        let output = directory
            .appendingPathComponent(".cxx-build", isDirectory: true)
            .appendingPathComponent(configuration, isDirectory: true)
        let archive = output.appendingPathComponent(archiveName)
        let metadataURL = output.appendingPathComponent("\(archiveName).metadata.json")
        guard FileManager.default.fileExists(atPath: archive.path),
              FileManager.default.fileExists(atPath: metadataURL.path)
        else {
            throw WorkspaceFailure.message(
                "missing staged \(configuration) archive or metadata under \(output.path)")
        }
        let metadata = try JSONDecoder().decode(
            HostArchiveMetadata.self,
            from: Data(contentsOf: metadataURL))
        let stagedByteCount = try fileSize(archive)
        let stagedFingerprint = try fnv1a64(archive)
        guard metadata.schemaVersion == 1,
              metadata.configuration == configuration,
              metadata.archive == archiveName,
              metadata.byteCount == stagedByteCount,
              metadata.fingerprint == stagedFingerprint
        else {
            throw WorkspaceFailure.message(
                "staged \(configuration) archive metadata does not match its bytes")
        }
        let source = directory
            .appendingPathComponent(".build/out/Products", isDirectory: true)
            .appendingPathComponent(metadata.productDirectory, isDirectory: true)
            .appendingPathComponent(archiveName)
        let sourceByteCount = try fileSize(source)
        let sourceFingerprint = try fnv1a64(source)
        guard FileManager.default.fileExists(atPath: source.path),
              sourceByteCount == metadata.byteCount,
              sourceFingerprint == metadata.fingerprint
        else {
            throw WorkspaceFailure.message(
                "staged \(configuration) archive fingerprint differs from \(source.path)")
        }
    }

    private func fileSize(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw WorkspaceFailure.message("could not read archive size: \(url.path)")
        }
        return size.uint64Value
    }

    private func fnv1a64(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash: UInt64 = 0xcbf29ce484222325
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            for byte in data {
                hash ^= UInt64(byte)
                hash &*= 0x100000001b3
            }
        }
        return String(format: "%016llx", hash)
    }

    private func components(_ selection: String?) throws -> [WorkspaceComponent] {
        guard let selection, selection != "all" else { return WorkspaceComponent.allCases }
        guard let component = WorkspaceComponent(rawValue: selection) else {
            throw WorkspaceFailure.message("unknown component '\(selection)'; expected all, tracy, vulkan, wayland, core, linux, rn, compositor, or shell")
        }
        return [component]
    }
}
