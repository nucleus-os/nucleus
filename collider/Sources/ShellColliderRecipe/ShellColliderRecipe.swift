import ColliderCore
import SystemPackage

public struct ShellRuntimeInstallConfiguration: RecipeConfiguration {
    public let swiftPM: SwiftPMInvocation
    public let prefix: FilePath
    public let generationsRoot: FilePath
    public let sessionPackage: FilePath
    public let kernelContract: FilePath
    public let trustKey: FilePath?
    public let buildMetadata: String
    public let environment: [String: String]

    public init(
        swiftPM: SwiftPMInvocation,
        prefix: FilePath,
        generationsRoot: FilePath,
        sessionPackage: FilePath,
        kernelContract: FilePath,
        trustKey: FilePath?,
        buildMetadata: String,
        environment: [String: String]
    ) {
        self.swiftPM = swiftPM
        self.prefix = prefix
        self.generationsRoot = generationsRoot
        self.sessionPackage = sessionPackage
        self.kernelContract = kernelContract
        self.trustKey = trustKey
        self.buildMetadata = buildMetadata
        self.environment = environment
    }
}

public enum ShellColliderRecipe: ColliderComponent {
    public static let descriptor = ComponentDescriptor(
        id: ComponentID(rawValue: "shell"),
        canonicalName: "shell",
        directoryName: "shell")

    public static func makeComponent(
        in context: RecipeContext
    ) throws -> ComponentDefinition {
        #if os(Linux)
        let configuration = try context.configuration(
            ShellRuntimeInstallConfiguration.self,
            for: descriptor.id)
        let task = installTask(
            configuration: configuration,
            repositoryRoot: context.repositoryRoot)
        let tracy = try tracyReceiversTask(in: context)
        return try ComponentDefinition(
            descriptor: descriptor,
            tasks: [task, tracy],
            entrypoints: [
                ComponentEntrypoint(id: .install, roots: [task.id]),
                ComponentEntrypoint(id: .bootstrap, roots: [tracy.id]),
            ])
        #else
        return try ComponentDefinition(
            descriptor: descriptor,
            tasks: [],
            entrypoints: [])
        #endif
    }

    #if os(Linux)
    private static func installTask(
        configuration: ShellRuntimeInstallConfiguration,
        repositoryRoot: FilePath
    ) -> TaskDeclaration {
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
        var inputs: [ArtifactInput] = [
            configuration.swiftPM.identityInput,
            .file(configuration.sessionPackage.appending("nucleus-session")),
            .file(
                configuration.sessionPackage.appending(
                    "nucleus-session-validate")),
            .file(configuration.sessionPackage.appending("nucleus@.service")),
            .file(configuration.kernelContract),
        ]
        if let trustKey = configuration.trustKey {
            inputs.append(.file(trustKey))
        }
        var builder = TaskBuilder(
            id: TaskID(rawValue: "shell.install"),
            component: descriptor.id)
        let _: ArtifactReference<PathArtifact> = try builder.output(
            "active-installation",
            path: configuration.prefix,
            validation: .symlinkTarget)
        return builder.build(
            swiftProducts: requirements,
            inputs: inputs,
            locks: [
                .shared(configuration.generationsRoot.appending(".install.lock"))
            ],
            action:
                try AnyColliderAction(
                    InstallRuntimeAction(configuration: configuration)))
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
        let _: ArtifactReference<ExecutableArtifact> = try builder.output(
            "tracy-capture",
            path: build.appending("tracy-capture"),
            validation: .executableFile)
        let _: ArtifactReference<ExecutableArtifact> = try builder.output(
            "tracy-csvexport",
            path: build.appending("tracy-csvexport"),
            validation: .executableFile)
        return builder.build(
            inputs: [
                .tree(source),
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

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: source.string)
            encoder.append(tag: 2, string: build.string)
            encoder.append(tag: 3, string: workingDirectory.string)
            encoder.append(tag: 4, string: "tracy-capture\0capture")
            encoder.append(tag: 5, string: "tracy-csvexport\0csvexport")
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
            ])
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
        guard result.status == 0 else {
            throw TracyReceiverBuildFailure.commandFailed(result.status)
        }
    }
}

private enum TracyReceiverBuildFailure: Error {
    case commandFailed(Int32)
}
#endif
