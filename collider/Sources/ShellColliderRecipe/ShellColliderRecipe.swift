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
        let tracy = tracyReceiversTask(in: context)
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
        return TaskDeclaration(
            id: TaskID(rawValue: "shell.install"),
            component: descriptor.id,
            swiftProducts: requirements,
            inputs: inputs,
            outputs: [
                OutputDeclaration(
                    path: configuration.prefix,
                    validation: .symlinkTarget)
            ],
            locks: [
                .shared(configuration.generationsRoot.appending(".install.lock"))
            ],
            operation: .action(
                AnyColliderAction(
                    InstallRuntimeAction(configuration: configuration))))
    }

    private static func tracyReceiversTask(
        in context: RecipeContext
    ) -> TaskDeclaration {
        let source = context.repositoryRoot.appending(
            "swift-tracy/third-party/tracy")
        let build = context.repositoryRoot.appending(
            "compositor/.tracy-build")
        var environment = context.environment
        environment["CPM_SOURCE_CACHE"] = build.appending(".cpm-cache").string
        var operations = [
            "source", "build-tracy-capture", "build-tracy-csvexport",
        ].map { TaskOperation.removePath(build.appending($0)) }
        operations.append(.createDirectory(build))
        for (name, subdirectory) in [
            ("tracy-capture", "capture"),
            ("tracy-csvexport", "csvexport"),
        ] {
            let toolBuild = build.appending("build-submodule-\(name)")
            operations += [
                .command(
                    CommandSpec(
                        executable: .named("cmake"),
                        arguments: [
                            "-S", source.appending(subdirectory).string,
                            "-B", toolBuild.string,
                            "-DCMAKE_BUILD_TYPE=Release",
                            "-DDOWNLOAD_CAPSTONE=ON",
                            "-DCMAKE_CXX_FLAGS=-stdlib=libc++",
                            "-DCMAKE_EXE_LINKER_FLAGS=-stdlib=libc++ -static-libgcc",
                        ],
                        workingDirectory: context.repositoryRoot,
                        environment: environment)),
                .command(
                    CommandSpec(
                        executable: .named("cmake"),
                        arguments: [
                            "--build", toolBuild.string, "--parallel",
                            "--target", name,
                        ],
                        workingDirectory: context.repositoryRoot,
                        environment: environment)),
                .copyFile(
                    source: toolBuild.appending(name),
                    destination: build.appending(name)),
            ]
        }
        return TaskDeclaration(
            id: TaskID(rawValue: "shell.tracy-receivers"),
            component: descriptor.id,
            inputs: [
                .tree(source),
                .tool(.named("cmake")),
            ],
            outputs: [
                OutputDeclaration(
                    path: build.appending("tracy-capture"),
                    validation: .executableFile),
                OutputDeclaration(
                    path: build.appending("tracy-csvexport"),
                    validation: .executableFile),
            ],
            locks: [.checkout("shell-tracy-receivers")],
            operation: .sequence(operations))
    }
    #endif
}
