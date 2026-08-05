import ColliderCore
import Foundation
import SystemPackage

package enum ChromiumTaskIDs {
    package static let source = TaskID(rawValue: "browser.source")
    package static let cefBuild = TaskID(rawValue: "browser.cef.build")
    package static let cefArtifact = TaskID(rawValue: "browser.cef")
    package static let browserBuild = TaskID(rawValue: "browser.product.build")
    package static let browserArtifact = TaskID(rawValue: "browser.artifact")
    package static let retention = TaskID(rawValue: "browser.retention")
    package static let test = TaskID(rawValue: "browser.test")
    package static let install = TaskID(rawValue: "browser.install")
}

public struct ChromiumRecipeLayout: Hashable, Sendable {
    public let sourceID: String
    public let cacheRoot: FilePath
    public let installPrefix: FilePath
    public let jobs: Int

    public init(
        sourceID: String,
        cacheRoot: FilePath,
        installPrefix: FilePath,
        jobs: Int
    ) {
        self.sourceID = sourceID
        self.cacheRoot = cacheRoot
        self.installPrefix = installPrefix
        self.jobs = jobs
    }
}

public enum ChromiumColliderRecipe: ColliderComponent {
    public static let descriptor = ComponentDescriptor(
        id: ComponentID(rawValue: "browser"),
        canonicalName: "browser",
        directoryName: "chromium",
        aliases: ["chromium"])

    public static func makeComponent(
        in context: RecipeContext
    ) throws -> ComponentDefinition {
        let lock = try JSONDecoder().decode(
            ChromiumSourceLock.self,
            from: Data(
                contentsOf: URL(
                    fileURLWithPath: context.repositoryRoot.appending(
                        "chromium/source.lock.json"
                    ).string)))
        try validateSourceLock(lock)
        let sourceID =
            ([lock.depotTools.commit]
            + lock.repositories.sorted(by: { $0.name < $1.name }).map(\.commit))
            .map { String($0.prefix(32)) }
            .joined(separator: "-")
        let prefix =
            context.environment["PREFIX"]
            ?? context.environment["HOME"].map { FilePath($0).appending(".local").string }
            ?? "/tmp/nucleus-browser"
        let tasks = try tasks(
            workspaceRoot: context.repositoryRoot,
            environment: context.environment,
            layout: ChromiumRecipeLayout(
                sourceID: sourceID,
                cacheRoot: context.cacheRoot.appending("nucleus/cef"),
                installPrefix: FilePath(prefix),
                jobs: Int(context.environment["NUCLEUS_CHROMIUM_JOBS"] ?? "")
                    ?? 16))
        return try ComponentDefinition(
            descriptor: descriptor,
            tasks: tasks,
            entrypoints: [
                ComponentEntrypoint(
                    id: .bootstrap,
                    roots: [ChromiumTaskIDs.source]),
                ComponentEntrypoint(id: .build, roots: [ChromiumTaskIDs.retention]),
                ComponentEntrypoint(id: .testDefault, roots: [ChromiumTaskIDs.test]),
                ComponentEntrypoint(id: .install, roots: [ChromiumTaskIDs.install]),
            ])
    }

    public static func tasks(
        workspaceRoot: FilePath,
        environment: [String: String],
        layout: ChromiumRecipeLayout
    ) throws -> [TaskDeclaration] {
        let chromium = workspaceRoot.appending("chromium")
        let sourceLockFile = chromium.appending("source.lock.json")
        let sourceLock = try JSONDecoder().decode(
            ChromiumSourceLock.self,
            from: Data(
                contentsOf: URL(
                    fileURLWithPath: sourceLockFile.string)))
        try validateSourceLock(sourceLock)
        var repositories: [String: ChromiumSourceRepository] = [:]
        for repository in sourceLock.repositories {
            guard
                repositories.updateValue(
                    repository,
                    forKey: repository.name
                ) == nil
            else {
                throw ChromiumRecipeFailure.invalidSourceLock
            }
        }
        guard let chromiumRepository = repositories["chromium"],
            let cefRepository = repositories["cef"],
            repositories["angle"] != nil,
            repositories["skia"] != nil,
            repositories["v8"] != nil,
            repositories["dawn"] != nil,
            repositories.count == 6
        else {
            throw ChromiumRecipeFailure.invalidSourceLock
        }
        let cache = layout.cacheRoot
        let sources = cache.appending("source-generations")
        let source = sources.appending(layout.sourceID)
        let chromiumSource = source.appending("chromium/src")
        let buildGeneration = cache.appending("build").appending(
            layout.sourceID)
        let cefOutput = buildGeneration.appending("cef")
        let browserOutput = buildGeneration.appending("browser")
        let cefDistribution = cache.appending("dist")
        let browserDistribution = cache.appending("browser-dist")
        let depotTools = cache.appending("depot_tools")
        let builderContext = chromium.appending("build-container")
        let builderImageID = cache.appending("build-container/image-id")
        let childEnvironment = environment.merging([
            "NUCLEUS_CHROMIUM_ORCHESTRATED": "1",
            "NUCLEUS_CEF_BRANCH": sourceLock.cefBranch,
            "NUCLEUS_CEF_CHECKOUT": cefRepository.commit,
            "NUCLEUS_CEF_CHROMIUM_VERSION": sourceLock.chromiumVersion,
            "NUCLEUS_CHROMIUM_CHECKOUT": chromiumRepository.commit,
            "NUCLEUS_DEPOT_TOOLS_REVISION": sourceLock.depotTools.commit,
            "NUCLEUS_CEF_CACHE_ROOT": cache.string,
            "NUCLEUS_CEF_DEPOT_TOOLS": depotTools.string,
            "NUCLEUS_CHROMIUM_SOURCE_ID": layout.sourceID,
            "NUCLEUS_CHROMIUM_SOURCE_GENERATIONS": sources.string,
            "NUCLEUS_CHROMIUM_SOURCE_CURRENT": sources.appending(
                "current"
            ).string,
            "NUCLEUS_CEF_SRC_ROOT": source.string,
            "NUCLEUS_CHROMIUM_SRC_ROOT": chromiumSource.string,
            "CHROMIUM_BROWSER_OUT": browserOutput.string,
            "NUCLEUS_CEF_DIST_ROOT": cefDistribution.string,
            "NUCLEUS_BROWSER_DIST_ROOT": browserDistribution.string,
            "NUCLEUS_CEF_LOG_DIR": cache.appending("logs").string,
            "NUCLEUS_CHROMIUM_JOBS": String(layout.jobs),
            "GN_DEFINES": cefGNArguments,
            "CHROMIUM_BROWSER_GN_DEFINES_BASE": browserGNArguments,
            "PREFIX": layout.installPrefix.string,
        ]) { _, required in required }
        let depotEnvironment = childEnvironment.merging([
            "PATH": depotTools.string + ":"
                + (childEnvironment["PATH"] ?? "/usr/bin:/bin")
        ]) { _, required in required }
        let commonInputs: [ArtifactInput] =
            [
                .value(name: "source-id", bytes: Array(layout.sourceID.utf8)),
                .file(sourceLockFile),
                .file(chromium.appending("launcher/nucleus-browser")),
                .file(
                    chromium.appending(
                        "share/applications/dev.nucleus.Browser.desktop.in")),
            ]
        var depotToolsBuilder = TaskBuilder(
            id: TaskID(rawValue: "browser.depot-tools"),
            component: ComponentID(rawValue: "browser"))
        let _: ArtifactReference<FileArtifact> = try depotToolsBuilder.output(
            "head",
            path: depotTools.appending(".git/HEAD"),
            validation: .regularFile)
        let depotBootstrapExecutable: ArtifactReference<ExecutableArtifact> =
            try depotToolsBuilder.output(
                "bootstrap-executable",
                path: depotTools.appending("ensure_bootstrap"),
                validation: .executableFile)
        let depotToolsTask = depotToolsBuilder.build(
            inputs: [
                .value(
                    name: "depot-tools-revision",
                    bytes: Array(sourceLock.depotTools.commit.utf8)),
                .tool(.named("git")),
            ],
            locks: [.shared(cache.appending("locks/depot-tools.lock"))],
            assessmentPolicy: .always,
            action:
                try AnyColliderAction(
                    PrepareChromiumDepotToolsAction(
                        repository: depotTools,
                        remote: sourceLock.depotTools.remote,
                        commit: sourceLock.depotTools.commit,
                        environment: childEnvironment)))
        var bootstrapBuilder = TaskBuilder(
            id: TaskID(rawValue: "browser.depot-tools-bootstrap"),
            component: ComponentID(rawValue: "browser"))
        bootstrapBuilder.consume(depotBootstrapExecutable)
        let bootstrapMarker: ArtifactReference<FileArtifact> = try bootstrapBuilder.output(
            "python-relative-directory",
            path: depotTools.appending("python3_bin_reldir.txt"),
            validation: .regularFile)
        let depotBootstrap = bootstrapBuilder.build(
            locks: [.shared(cache.appending("locks/depot-tools.lock"))],
            action:
                try AnyColliderAction(
                    BootstrapChromiumDepotToolsAction(
                        executable: depotBootstrapExecutable.path,
                        repository: depotTools,
                        environment: depotEnvironment)))
        let sourcePreparation = ChromiumSourcePreparation(
            sourceID: layout.sourceID,
            sourceRoot: source,
            sourceGenerations: sources,
            current: sources.appending("current"),
            depotTools: depotTools,
            sourceLockFile: sourceLockFile,
            sourceLock: sourceLock,
            environment: childEnvironment)
        var sourceBuilder = TaskBuilder(
            id: ChromiumTaskIDs.source,
            component: ComponentID(rawValue: "browser"))
        sourceBuilder.consume(bootstrapMarker)
        let sourceProvenance: ArtifactReference<JSONArtifact> = try sourceBuilder.output(
            "provenance",
            path: source.appending("source-provenance.json"),
            validation: .json)
        let sourceTask = sourceBuilder.build(
            inputs: commonInputs,
            locks: [
                .shared(cache.appending("locks/source.lock"))
            ],
            action:
                try AnyColliderAction(
                    PrepareChromiumSourceAction(
                        preparation: sourcePreparation)))
        var imageBuilder = TaskBuilder(
            id: TaskID(rawValue: "browser.builder"),
            component: ComponentID(rawValue: "browser"))
        let builderImage: ArtifactReference<FileArtifact> = try imageBuilder.output(
            "image-id",
            path: builderImageID,
            validation: .regularFile)
        let builderTask = imageBuilder.build(
            inputs: [
                .tree(builderContext)
            ],
            locks: [.shared(cache.appending("locks/builder.lock"))],
            action:
                try AnyColliderAction(
                    PrepareChromiumBuilderImageAction(
                        preparation: OCIImagePreparation(
                            executionPlatform: .linuxARM64OCI,
                            context: builderContext,
                            containerFile: builderContext.appending("Containerfile"),
                            imageID: builderImageID,
                            imageName: "localhost/nucleus-chromium-build",
                            environment: childEnvironment))))
        let cefAssembly = CEFArtifactAssembly(
            chromiumSource: chromiumSource,
            buildOutput: cefOutput,
            depotTools: depotTools,
            containerImageID: builderImageID,
            distributionRoot: cefDistribution,
            cefCheckout: cefRepository.commit,
            chromiumVersion: sourceLock.chromiumVersion,
            environment: childEnvironment)
        var cefBuildBuilder = TaskBuilder(
            id: ChromiumTaskIDs.cefBuild,
            component: ComponentID(rawValue: "browser"))
        cefBuildBuilder.consume(sourceProvenance)
        cefBuildBuilder.consume(builderImage)
        let cefBuildArtifact: ArtifactReference<DirectoryArtifact> =
            try cefBuildBuilder.output(
                "build-output",
                path: cefOutput,
                validation: .nonEmptyDirectory)
        let cefBuildTask = cefBuildBuilder.build(
            inputs: commonInputs,
            locks: [
                .shared(cache.appending("locks/cef-output.lock"))
            ],
            action:
                try AnyColliderAction(
                    BuildChromiumProductAction(
                        build: ChromiumProductBuild(
                            product: .cef,
                            sourceRoot: source,
                            output: cefOutput,
                            depotTools: depotTools,
                            containerImageID: builderImageID,
                            gnArguments: cefGNArguments,
                            targets: ["libcef", "chrome_sandbox"],
                            jobs: UInt32(layout.jobs),
                            environment: childEnvironment))))
        var cefBuilder = TaskBuilder(
            id: ChromiumTaskIDs.cefArtifact,
            component: ComponentID(rawValue: "browser"))
        cefBuilder.consume(sourceProvenance)
        cefBuilder.consume(cefBuildArtifact)
        cefBuilder.consume(builderImage)
        let cefPublication: ArtifactReference<PathArtifact> = try cefBuilder.output(
            "publication",
            path: cefDistribution.appending("current"),
            validation: .symlinkTarget)
        let cefTask = cefBuilder.build(
            inputs: commonInputs,
            locks: [
                .shared(cache.appending("locks/cef-publication.lock"))
            ],
            action:
                try AnyColliderAction(
                    AssembleCEFArtifactAction(
                        assembly: cefAssembly)))
        let browserAssembly = BrowserArtifactAssembly(
            chromiumSource: chromiumSource,
            buildOutput: browserOutput,
            containerImageID: builderImageID,
            distributionRoot: browserDistribution,
            launcher: chromium.appending("launcher/nucleus-browser"),
            desktopTemplate: chromium.appending(
                "share/applications/dev.nucleus.Browser.desktop.in"),
            environment: childEnvironment)
        var browserBuilder = TaskBuilder(
            id: ChromiumTaskIDs.browserBuild,
            component: ComponentID(rawValue: "browser"))
        browserBuilder.consume(sourceProvenance)
        browserBuilder.consume(builderImage)
        let browserBuildArtifact: ArtifactReference<DirectoryArtifact> =
            try browserBuilder.output(
                "build-output",
                path: browserOutput,
                validation: .nonEmptyDirectory)
        let browserBuildTask = browserBuilder.build(
            inputs: commonInputs,
            locks: [
                .shared(cache.appending("locks/browser-output.lock"))
            ],
            action:
                try AnyColliderAction(
                    BuildChromiumProductAction(
                        build: ChromiumProductBuild(
                            product: .browser,
                            sourceRoot: source,
                            output: browserOutput,
                            depotTools: depotTools,
                            containerImageID: builderImageID,
                            gnArguments: browserGNArguments,
                            targets: ["chrome", "chrome_sandbox"],
                            jobs: UInt32(layout.jobs),
                            environment: childEnvironment))))
        var browserArtifactBuilder = TaskBuilder(
            id: ChromiumTaskIDs.browserArtifact,
            component: ComponentID(rawValue: "browser"))
        browserArtifactBuilder.consume(browserBuildArtifact)
        browserArtifactBuilder.consume(builderImage)
        let browserPublication: ArtifactReference<PathArtifact> =
            try browserArtifactBuilder.output(
                "publication",
                path: browserDistribution.appending("current"),
                validation: .symlinkTarget)
        let browserTask = browserArtifactBuilder.build(
            inputs: commonInputs,
            locks: [
                .shared(cache.appending("locks/browser-publication.lock"))
            ],
            action:
                try AnyColliderAction(
                    AssembleBrowserArtifactAction(
                        assembly: browserAssembly)))
        var retentionBuilder = TaskBuilder(
            id: ChromiumTaskIDs.retention,
            component: ComponentID(rawValue: "browser"))
        retentionBuilder.consume(browserPublication)
        retentionBuilder.consume(cefPublication)
        let retention = retentionBuilder.build(
            inputs: commonInputs,
            locks: [
                .shared(cache.appending("locks/cache-retention.lock"))
            ],
            assessmentPolicy: .always,
            action:
                try AnyColliderAction(
                    PruneChromiumCacheAction(
                        plan: DirectoryRetentionPlan(
                            safetyRoot: cache,
                            rules: [
                                DirectoryRetentionRule(
                                    root: sources,
                                    current: sources.appending("current"),
                                    retain: 1,
                                    naming: .contentIdentity),
                                DirectoryRetentionRule(
                                    root: cache.appending("build"),
                                    current: nil,
                                    retain: 1,
                                    naming: .contentIdentity),
                                DirectoryRetentionRule(
                                    root: cefDistribution.appending("releases"),
                                    current: cefDistribution.appending("current-release"),
                                    retain: 2,
                                    naming: .contentIdentity),
                                DirectoryRetentionRule(
                                    root: browserDistribution.appending("generations"),
                                    current: browserDistribution.appending("current"),
                                    retain: 2,
                                    naming: .contentIdentity),
                            ]))))
        var testBuilder = TaskBuilder(
            id: ChromiumTaskIDs.test,
            component: ComponentID(rawValue: "browser"))
        testBuilder.consume(browserPublication)
        testBuilder.consume(browserBuildArtifact)
        testBuilder.consume(builderImage)
        let test = testBuilder.build(
            inputs: commonInputs,
            locks: [
                .shared(cache.appending("locks/cef-output.lock")),
                .shared(cache.appending("locks/browser-output.lock")),
            ],
            assessmentPolicy: .always,
            action:
                try AnyColliderAction(
                    RunChromiumTestsAction(
                        execution: chromiumBuildExecution(
                            imageID: builderImageID,
                            source: source,
                            depotTools: depotTools,
                            output: browserOutput,
                            jobs: layout.jobs,
                            targets: [
                                "ui/ozone:ozone_unittests",
                                "components/viz/service:"
                                    + "output_presenter_ozone_unittests",
                            ],
                            environment: childEnvironment),
                        output: browserOutput,
                        environment: childEnvironment)))
        var installBuilder = TaskBuilder(
            id: ChromiumTaskIDs.install,
            component: ComponentID(rawValue: "browser"))
        installBuilder.consume(browserPublication)
        let install = installBuilder.build(
            inputs: commonInputs,
            locks: [
                .shared(cache.appending("locks/browser-publication.lock"))
            ],
            assessmentPolicy: .always,
            action:
                try AnyColliderAction(
                    InstallBrowserAction(
                        installation: BrowserInstallation(
                            distributionRoot: browserDistribution,
                            prefix: layout.installPrefix,
                            environment: childEnvironment))))
        return [
            depotToolsTask, depotBootstrap,
            sourceTask, builderTask, cefBuildTask, cefTask,
            browserBuildTask, browserTask, retention,
            test, install,
        ]
    }

    private static func validateSourceLock(
        _ sourceLock: ChromiumSourceLock
    ) throws {
        let expected:
            [String: (
                path: String,
                remote: String,
                upstream: String
            )] = [
                "chromium": (
                    "chromium/src",
                    "https://github.com/nucleus-os/chromium.git",
                    "https://chromium.googlesource.com/chromium/src.git"
                ),
                "cef": (
                    "chromium/src/cef",
                    "https://github.com/nucleus-os/cef.git",
                    "https://github.com/chromiumembedded/cef.git"
                ),
                "angle": (
                    "chromium/src/third_party/angle",
                    "https://github.com/nucleus-os/angle.git",
                    "https://chromium.googlesource.com/angle/angle.git"
                ),
                "skia": (
                    "chromium/src/third_party/skia",
                    "https://github.com/nucleus-os/skia.git",
                    "https://skia.googlesource.com/skia.git"
                ),
                "v8": (
                    "chromium/src/v8",
                    "https://github.com/nucleus-os/v8.git",
                    "https://chromium.googlesource.com/v8/v8.git"
                ),
                "dawn": (
                    "chromium/src/third_party/dawn",
                    "https://github.com/nucleus-os/dawn.git",
                    "https://dawn.googlesource.com/dawn.git"
                ),
            ]
        guard sourceLock.repositories.count == expected.count,
            sourceLock.cefBranch.allSatisfy(\.isNumber),
            !sourceLock.cefBranch.isEmpty,
            sourceLock.chromiumVersion.split(separator: ".").count == 4,
            sourceLock.depotTools.remote
                == "https://chromium.googlesource.com/chromium/tools/depot_tools.git",
            isGitObjectID(sourceLock.depotTools.commit)
        else {
            throw ChromiumRecipeFailure.invalidSourceLock
        }
        for repository in sourceLock.repositories {
            guard let requirement = expected[repository.name],
                repository.checkoutPath == requirement.path,
                repository.remote == requirement.remote,
                repository.upstreamRemote == requirement.upstream,
                isGitObjectID(repository.upstreamCommit),
                isGitObjectID(repository.commit),
                isGitObjectID(repository.tree)
            else {
                throw ChromiumRecipeFailure.invalidSourceLock
            }
        }
    }

    private static func isGitObjectID(_ value: String) -> Bool {
        value.utf8.count == 40
            && value.utf8.allSatisfy {
                ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
            }
    }
}

private struct PrepareChromiumBuilderImageAction: ColliderAction {
    static let kind: ActionKind = "browser.prepare-builder-image"

    let identity: OCIImagePreparationActionIdentity

    init(preparation: OCIImagePreparation) {
        identity = OCIImagePreparationActionIdentity(preparation)
    }

    var requirements: ActionRequirements {
        ociImagePreparationActionRequirements(preparation: identity.preparation)
    }

    var environment: [String: String] { identity.preparation.environment }

    func execute(in context: ActionContext) async throws {
        try await context.containers.prepareImage(identity.preparation)
    }
}

private struct RunChromiumTestsAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let execution: OCIExecution
        let output: FilePath

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(
                tag: 1,
                nested: OCIExecutionActionIdentity(execution))
            encoder.append(tag: 2, string: output.string)
            encoder.append(tag: 3, string: "*OzonePresenter*")
            encoder.append(tag: 4, string: "OutputPresenterOzoneTest.*")
            encoder.append(tag: 5, string: "single-process-tests")
        }
    }

    static let kind: ActionKind = "browser.run-tests"

    let execution: OCIExecution
    let output: FilePath
    let environment: [String: String]

    var identity: Identity {
        Identity(execution: execution, output: output)
    }

    var requirements: ActionRequirements {
        let executionRequirements = ociActionRequirements(execution: execution)
        return ActionRequirements(
            tools: [
                ActionToolRequirement(
                    "ozone-tests",
                    executable: .taskOutput(output.appending("ozone_unittests")),
                    role: .operational),
                ActionToolRequirement(
                    "output-presenter-tests",
                    executable: .taskOutput(
                        output.appending("output_presenter_ozone_unittests")),
                    role: .operational),
            ],
            effects: executionRequirements.effects,
            resources: executionRequirements.resources,
            executionPlatform: executionRequirements.executionPlatform,
            artifactTarget: executionRequirements.artifactTarget)
    }

    func execute(in context: ActionContext) async throws {
        try await context.containers.run(execution)
        try await run(
            executable: output.appending("ozone_unittests"),
            arguments: [
                "--gtest_filter=*OzonePresenter*",
                "--single-process-tests",
            ],
            context: context)
        try await run(
            executable: output.appending("output_presenter_ozone_unittests"),
            arguments: [
                "--gtest_filter=OutputPresenterOzoneTest.*",
                "--single-process-tests",
            ],
            context: context)
    }

    private func run(
        executable: FilePath,
        arguments: [String],
        context: ActionContext
    ) async throws {
        let result = try await context.commands.execute(
            CommandSpec(
                executable: .taskOutput(executable),
                arguments: arguments,
                workingDirectory: output,
                environment: environment))
        guard result.status == 0 else {
            throw ChromiumOzoneTestFailure.commandFailed(result.status)
        }
    }
}

package struct PrepareChromiumDepotToolsAction: ColliderAction {
    package struct Identity: ColliderActionIdentity {
        let repository: FilePath
        let remote: String
        let commit: String

        package func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: repository.string)
            encoder.append(tag: 2, string: remote)
            encoder.append(tag: 3, string: commit)
        }
    }

    package static let kind: ActionKind = "browser.prepare-depot-tools"

    let repository: FilePath
    let remote: String
    let commit: String
    package let environment: [String: String]

    package init(
        repository: FilePath,
        remote: String,
        commit: String,
        environment: [String: String]
    ) {
        self.repository = repository
        self.remote = remote
        self.commit = commit
        self.environment = environment
    }

    package var identity: Identity {
        Identity(repository: repository, remote: remote, commit: commit)
    }

    package var requirements: ActionRequirements {
        ActionRequirements(
            tools: [
                ActionToolRequirement(
                    "git",
                    executable: .named("git"),
                    role: .operational)
            ],
            effects: [
                ActionEffect(
                    .readWrite,
                    scope: .checkout(repository.removingLastComponent()))
            ],
            executionPlatform: .macOSARM64Native)
    }

    package func execute(in context: ActionContext) async throws {
        let gitMetadata = repository.appending(".git")
        if try context.files.metadata(for: gitMetadata) == nil {
            guard try context.files.metadata(for: repository) == nil else {
                throw ChromiumDepotToolsFailure.nonGitCheckout(repository)
            }
            try context.files.createDirectory(repository.removingLastComponent())
            try await requireSuccess(
                ["init", repository.string],
                workingDirectory: repository.removingLastComponent(),
                context: context)
            try await requireSuccess(
                ["-C", repository.string, "remote", "add", "origin", remote],
                workingDirectory: repository,
                context: context)
        } else {
            try await requireTrackedCheckoutIsClean(context)
            try await requireSuccess(
                ["-C", repository.string, "remote", "set-url", "origin", remote],
                workingDirectory: repository,
                context: context)
        }

        let object = try await git(
            ["-C", repository.string, "cat-file", "-e", "\(commit)^{commit}"],
            workingDirectory: repository,
            context: context)
        if object.status != 0 {
            try await requireSuccess(
                ["-C", repository.string, "fetch", "--no-tags", "--depth=1", "origin", commit],
                workingDirectory: repository,
                context: context)
        }
        try await requireSuccess(
            ["-C", repository.string, "checkout", "--detach", "--force", commit],
            workingDirectory: repository,
            context: context)
        let resolved = try await git(
            ["-C", repository.string, "rev-parse", "HEAD^{commit}"],
            workingDirectory: repository,
            context: context)
        guard resolved.status == 0,
            resolved.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                == commit
        else {
            throw ChromiumDepotToolsFailure.wrongCommit(
                expected: commit,
                actual: resolved.standardOutput)
        }
        try await requireTrackedCheckoutIsClean(context)
    }

    private func requireTrackedCheckoutIsClean(
        _ context: ActionContext
    ) async throws {
        let status = try await git(
            ["-C", repository.string, "status", "--porcelain", "--untracked-files=no"],
            workingDirectory: repository,
            context: context)
        guard status.status == 0, status.standardOutput.isEmpty else {
            throw ChromiumDepotToolsFailure.trackedModifications(repository)
        }
    }

    private func requireSuccess(
        _ arguments: [String],
        workingDirectory: FilePath,
        context: ActionContext
    ) async throws {
        let result = try await git(
            arguments,
            workingDirectory: workingDirectory,
            context: context)
        guard result.status == 0 else {
            throw ChromiumDepotToolsFailure.gitFailed(arguments, result.status)
        }
    }

    private func git(
        _ arguments: [String],
        workingDirectory: FilePath,
        context: ActionContext
    ) async throws -> CommandResult {
        try await context.commands.execute(
            CommandSpec(
                executable: .named("git"),
                arguments: arguments,
                workingDirectory: workingDirectory,
                environment: environment,
                output: .captured(limit: 4 * 1_024 * 1_024)))
    }
}

private enum ChromiumDepotToolsFailure: Error {
    case gitFailed([String], Int32)
    case nonGitCheckout(FilePath)
    case trackedModifications(FilePath)
    case wrongCommit(expected: String, actual: String)
}

private struct PruneChromiumCacheAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let plan: DirectoryRetentionPlan

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: plan.safetyRoot.string)
            encoder.append(
                tag: 2,
                string: plan.rules.map {
                    [
                        $0.root.string,
                        $0.current?.string ?? "",
                        String($0.retain),
                        $0.naming.rawValue,
                    ].joined(separator: "\u{0}")
                }.joined(separator: "\u{1}"))
        }
    }

    static let kind: ActionKind = "browser.prune-cache"

    let plan: DirectoryRetentionPlan

    var identity: Identity { Identity(plan: plan) }

    var requirements: ActionRequirements {
        ActionRequirements(
            effects: plan.rules.map {
                ActionEffect(.readWrite, scope: .scratch($0.root))
            },
            executionPlatform: .macOSARM64Native)
    }

    func execute(in context: ActionContext) async throws {
        try context.files.pruneDirectories(plan)
    }
}

private struct BootstrapChromiumDepotToolsAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let executable: FilePath
        let repository: FilePath

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: executable.string)
            encoder.append(tag: 2, string: repository.string)
        }
    }

    static let kind: ActionKind = "browser.bootstrap-depot-tools"

    let executable: FilePath
    let repository: FilePath
    let environment: [String: String]

    var identity: Identity {
        Identity(executable: executable, repository: repository)
    }

    var requirements: ActionRequirements {
        ActionRequirements(
            tools: [
                ActionToolRequirement(
                    "ensure-bootstrap",
                    executable: .taskOutput(executable),
                    role: .operational)
            ],
            effects: [
                ActionEffect(.readWrite, scope: .checkout(repository))
            ],
            executionPlatform: .macOSARM64Native)
    }

    func execute(in context: ActionContext) async throws {
        let result = try await context.commands.execute(
            CommandSpec(
                executable: .taskOutput(executable),
                arguments: [],
                workingDirectory: repository,
                environment: environment))
        guard result.status == 0 else {
            throw ChromiumBootstrapFailure.commandFailed(result.status)
        }
    }
}

private enum ChromiumBootstrapFailure: Error {
    case commandFailed(Int32)
}

private enum ChromiumOzoneTestFailure: Error {
    case commandFailed(Int32)
}

private func chromiumBuildExecution(
    imageID: FilePath,
    source: FilePath,
    depotTools: FilePath,
    output: FilePath,
    jobs: Int,
    targets: [String],
    environment: [String: String]
) -> OCIExecution {
    OCIExecution(
        executionPlatform: .linuxARM64OCI,
        artifactTarget: .linuxX86_64,
        imageID: imageID,
        hostname: "chromium-build",
        workingDirectory: "/source/chromium/src",
        hostWorkingDirectory: source.appending("chromium/src"),
        mounts: [
            OCIMount(
                source: source,
                target: "/source",
                access: .readOnly),
            OCIMount(
                source: depotTools,
                target: "/depot_tools",
                access: .readOnly),
            OCIMount(
                source: output.removingLastComponent().appending(".inputs"),
                target: "/inputs",
                access: .readOnly),
            OCIMount(
                source: output,
                target: "/build",
                access: .readWrite),
        ],
        temporaryDirectory: output.removingLastComponent().appending(
            ".temporary"),
        networkPolicy: .externalDisabled,
        userPolicy: .builder,
        capabilityPolicy: .dropAll,
        privilegePolicy: .prohibitAcquisition,
        processFilesystemPolicy: .standard,
        intelBinaryTranslationPolicy: .required,
        resourceLimits: .build,
        containerEnvironment: [
            "DEPOT_TOOLS_UPDATE": "0",
            "HOME": "/tmp/nucleus-home",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "PYTHONDONTWRITEBYTECODE": "1",
            "TZ": "UTC",
        ],
        command: ["build", String(jobs)] + targets,
        environment: environment,
        output: .logged)
}

private enum ChromiumRecipeFailure: Error {
    case invalidSourceLock
}

private let cefGNArguments =
    #"angle_enable_swiftshader=false blink_heap_inside_shared_library=true cc_wrapper="" chrome_pgo_phase=2 clang_use_chrome_plugins=false dcheck_always_on=false disable_fieldtrial_testing_config=true enable_background_mode=false enable_backup_ref_ptr_support=false enable_downgrade_processing=false enable_expensive_dchecks=false enable_linux_installer=false enable_precompiled_headers=false enable_resource_allowlist_generation=false enable_swiftshader=false enable_swiftshader_vulkan=false enable_widevine=true ffmpeg_branding="Chrome" forbid_non_component_debug_builds=false is_component_build=false is_debug=false is_official_build=true optimize_webui=true ozone_platform="wayland" ozone_platform_wayland=true ozone_platform_x11=false proprietary_codecs=true symbol_level=0 target_cpu="x64" thin_lto_enable_optimizations=true treat_warnings_as_errors=false use_allocator_shim=false use_dbus=true use_lld=true use_mold=false use_partition_alloc_as_malloc=false use_qt5=false use_qt6=false use_siso=true use_sysroot=false use_thin_lto=true use_unified_system_module=false"#

private let browserGNArguments =
    #"proprietary_codecs=true ffmpeg_branding="Chrome" is_chrome_branded=false enable_cef=false use_dbus=true enable_widevine=true is_official_build=true is_component_build=false symbol_level=0 dcheck_always_on=false enable_expensive_dchecks=false chrome_pgo_phase=2 use_thin_lto=true thin_lto_enable_optimizations=true use_mold=false use_lld=true use_siso=true cc_wrapper="" use_allocator_shim=true use_partition_alloc_as_malloc=true enable_backup_ref_ptr_support=true enable_swiftshader=false enable_swiftshader_vulkan=false angle_enable_swiftshader=false treat_warnings_as_errors=false clang_use_chrome_plugins=false ozone_platform="wayland" ozone_platform_wayland=true ozone_platform_x11=false use_sysroot=false target_cpu="x64""#
