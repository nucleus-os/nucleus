import ColliderCore
import SystemPackage

public struct ShellRuntimePublicationConfiguration: RecipeConfiguration {
    public let swiftPM: SwiftPMInvocation
    public let prefix: FilePath
    public let generationsRoot: FilePath
    public let packageManifestsRoot: FilePath
    public let sessionPackage: FilePath
    public let buildMetadata: String
    public let environment: [String: String]

    public init(
        swiftPM: SwiftPMInvocation,
        prefix: FilePath,
        generationsRoot: FilePath,
        packageManifestsRoot: FilePath,
        sessionPackage: FilePath,
        buildMetadata: String,
        environment: [String: String]
    ) {
        self.swiftPM = swiftPM
        self.prefix = prefix
        self.generationsRoot = generationsRoot
        self.packageManifestsRoot = packageManifestsRoot
        self.sessionPackage = sessionPackage
        self.buildMetadata = buildMetadata
        self.environment = environment
    }
}

public enum ShellColliderRecipe: ColliderComponent {
    static let rollbackGenerationCount: UInt32 = 2

    public static let descriptor = ComponentDescriptor(
        id: ComponentID(rawValue: "shell"),
        canonicalName: "shell",
        directoryName: "shell")

    public static func makeComponent(
        in context: RecipeContext
    ) throws -> ComponentDefinition {
        #if os(Linux)
        let configuration = try context.configuration(
            ShellRuntimePublicationConfiguration.self,
            for: descriptor.id)
        let task = try publicationTask(
            configuration: configuration,
            repositoryRoot: context.repositoryRoot)
        let tracy = try tracyReceiversTask(in: context)
        return try ComponentDefinition(
            descriptor: descriptor,
            tasks: [task, tracy],
            entrypoints: [
                ComponentEntrypoint(id: .install, roots: [task.id]),
                ComponentEntrypoint(id: .bootstrap, roots: [tracy.id]),
            ],
            storage: [
                StorageDeclaration(
                    id: "shell-runtime-generations",
                    owner: descriptor.id,
                    producers: [.task(task.id)],
                    storageClass: .generation,
                    root: configuration.generationsRoot,
                    safetyRoot: configuration.generationsRoot.removingLastComponent(),
                    retentionPolicy: .keepActiveAndRollback(count: rollbackGenerationCount),
                    activeGenerationLink: configuration.prefix,
                    generationNaming: .contentIdentity,
                    interruptedCandidateNaming: nil),
                StorageDeclaration(
                    id: "shell-package-manifest-generations",
                    owner: descriptor.id,
                    producers: [.task(task.id)],
                    storageClass: .generation,
                    root: configuration.packageManifestsRoot,
                    safetyRoot: configuration.packageManifestsRoot.removingLastComponent(),
                    retentionPolicy: .keepActiveAndRollback(count: rollbackGenerationCount),
                    activeGenerationLink: configuration.packageManifestsRoot.appending("current"),
                    generationNaming: .contentIdentity,
                    interruptedCandidateNaming: nil),
                StorageDeclaration(
                    id: "shell-tracy-receivers",
                    owner: descriptor.id,
                    producers: [.task(tracy.id)],
                    storageClass: .incremental,
                    root: context.repositoryRoot.appending("compositor/.tracy-build"),
                    safetyRoot: context.repositoryRoot.appending("compositor"),
                    retentionPolicy: .singleWorkingSet),
            ])
        #else
        return try ComponentDefinition(
            descriptor: descriptor,
            tasks: [],
            entrypoints: [])
        #endif
    }

    #if os(Linux)
    private static func publicationTask(
        configuration: ShellRuntimePublicationConfiguration,
        repositoryRoot: FilePath
    ) throws -> TaskDeclaration {
        let products = [
            "NucleusCompositor",
            "NucleusSessionSupervisor",
            "NucleusConfigService",
            "NucleusControlService",
            "NucleusShell",
            "NucleusShellPamHelper",
            "nucleus",
        ]
        let requirements = products.map { product in
            configuration.swiftPM.product(
                package: "nucleus",
                product: product,
                packageRoot: repositoryRoot,
                environment: configuration.environment,
                expectedOutputs: [
                    PathPostcondition(
                        path: configuration.swiftPM.executable(product),
                        validation: .executableFile)
                ])
        }
        var inputs: [ArtifactInput] = [configuration.swiftPM.identityInput]
        inputs.append(
            contentsOf: RuntimeHostIntegration.sourceFiles.map {
                .file(configuration.sessionPackage.appending($0))
            })
        var builder = TaskBuilder(
            id: TaskID(rawValue: "shell.publish-runtime"),
            component: descriptor.id)
        let _: ArtifactReference = try builder.output(
            "active-runtime-generation",
            path: configuration.prefix,
            validation: .symlinkTarget)
        let _: ArtifactReference = try builder.output(
            "active-package-manifests",
            path: configuration.packageManifestsRoot.appending("current"),
            validation: .symlinkTarget)
        return builder.build(
            swiftProducts: requirements,
            inputs: inputs,
            locks: [
                .shared(configuration.generationsRoot.appending(".publication.lock"))
            ],
            action:
                try AnyColliderAction(
                    PublishRuntimeGenerationAction(configuration: configuration)))
    }

    private static func tracyReceiversTask(
        in context: RecipeContext
    ) throws -> TaskDeclaration {
        let source = context.repositoryRoot.appending(
            "swift-tracy/third-party/tracy")
        let build = context.repositoryRoot.appending(
            "compositor/.tracy-build")
        var environment = context.environment
        environment["CPM_SOURCE_CACHE"] = build.appending(".cpm-cache").string
        var builder = TaskBuilder(
            id: TaskID(rawValue: "shell.tracy-receivers"),
            component: descriptor.id)
        let _: ExecutableReference = try builder.executableOutput(
            "tracy-capture",
            path: build.appending("tracy-capture"))
        let _: ExecutableReference = try builder.executableOutput(
            "tracy-csvexport",
            path: build.appending("tracy-csvexport"))
        return builder.build(
            inputs: [
                .sourceCheckout(source),
                .tool(.named("cmake")),
            ],
            locks: [.checkout("shell-tracy-receivers")],
            action:
                try AnyColliderAction(
                    BuildTracyReceiversAction(
                        source: source,
                        build: build,
                        workingDirectory: context.repositoryRoot,
                        environment: environment)))
    }
    #endif
}

#if os(Linux)
private struct BuildTracyReceiversAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let source: FilePath
        let build: FilePath
        let workingDirectory: FilePath

        func encode(into encoder: inout IdentityEncoder) {
            encoder.append(path: source)
            encoder.append(path: build)
            encoder.append(path: workingDirectory)
            encoder.append("tracy-capture\0capture")
            encoder.append("tracy-csvexport\0csvexport")
        }
    }

    static let kind: ActionKind = "shell.build-tracy-receivers"

    let source: FilePath
    let build: FilePath
    let workingDirectory: FilePath
    let environment: [String: String]

    var identity: Identity {
        Identity(
            source: source,
            build: build,
            workingDirectory: workingDirectory)
    }

    var requirements: ActionRequirements {
        ActionRequirements(
            tools: [
                ActionToolRequirement(
                    "cmake",
                    executable: .named("cmake"),
                    role: .semantic)
            ],
            effects: [
                ActionEffect(.read, scope: .checkout(source)),
                ActionEffect(.readWrite, scope: .output(build)),
            ],
            executionPlatform: ExecutionPlatform(
                environment: .native,
                operatingSystem: .linux,
                architecture: RunnerPlatform.current.architecture),
            artifactTarget: ArtifactTarget(
                operatingSystem: .linux,
                architecture: RunnerPlatform.current.architecture,
                abi: "glibc"))
    }

    func execute(in context: ActionContext) async throws {
        for directory in [
            "source", "build-tracy-capture", "build-tracy-csvexport",
        ] {
            try context.files.remove(build.appending(directory))
        }
        try context.files.createDirectory(build)
        for (name, subdirectory) in [
            ("tracy-capture", "capture"),
            ("tracy-csvexport", "csvexport"),
        ] {
            let toolBuild = build.appending("build-submodule-\(name)")
            try await run(
                [
                    "-S", source.appending(subdirectory).string,
                    "-B", toolBuild.string,
                    "-DCMAKE_BUILD_TYPE=Release",
                    "-DDOWNLOAD_CAPSTONE=ON",
                    "-DCMAKE_CXX_FLAGS=-stdlib=libc++",
                    "-DCMAKE_EXE_LINKER_FLAGS=-stdlib=libc++ -static-libgcc",
                ],
                context: context)
            try await run(
                [
                    "--build", toolBuild.string, "--parallel",
                    "--target", name,
                ],
                context: context)
            try context.files.copy(
                from: toolBuild.appending(name),
                to: build.appending(name))
        }
    }

    private func run(
        _ arguments: [String],
        context: ActionContext
    ) async throws {
        let result = try await context.commands.execute(
            CommandSpec(
                executable: .named("cmake"),
                arguments: arguments,
                workingDirectory: workingDirectory,
                environment: environment))
        guard result.succeeded else {
            throw result.executionFailure(reason: "Tracy receiver build failed")
        }
    }
}

#endif
