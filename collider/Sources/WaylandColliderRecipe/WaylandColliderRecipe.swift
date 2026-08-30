import ColliderCore
import Foundation
import NativeBuilderColliderRecipe
import SystemPackage

package enum WaylandTaskIDs {
    package static func nativeSDK(_ target: NativeLinuxTarget) -> TaskID {
        TaskID(rawValue: "wayland.native-sdk.\(target.identifier)")
    }
}

public enum WaylandColliderRecipe: ColliderComponent {
    package struct NativeSDKArtifacts: Sendable {
        package let task: TaskDeclaration
        package let scanner: ExecutableReference?
        package let outputs: ArtifactReferenceSet
    }

    package struct ComponentArtifacts: Sendable {
        package let component: ComponentDefinition
        package let nativeSDKs: [NativeLinuxTarget: ArtifactReferenceSet]
    }

    package struct Generation: Sendable {
        package let tasks: [TaskDeclaration]
        package let task: TaskDeclaration
        package let verification: TaskDeclaration
        package let mappings: [GeneratedSourceMapping]
    }

    public static let descriptor = ComponentDescriptor(
        id: ComponentID(rawValue: "wayland"),
        canonicalName: "wayland",
        directoryName: "swift-wayland")

    public static func makeComponent(
        in context: RecipeContext
    ) throws -> ComponentDefinition {
        try prepare(in: context).component
    }

    package static func prepare(
        in context: RecipeContext
    ) throws -> ComponentArtifacts {
        let native = try context.configuration(
            NativeBuilderGraphConfiguration.self,
            for: NativeBuilderColliderRecipe.descriptor.id)
        let root = context.componentRoot(descriptor)
        let armTarget = NativeLinuxTarget(architecture: .arm64)
        let armSDK = try buildNativeSDK(
            root: root,
            sdkRoot: native.nativeSDK(for: armTarget),
            environment: context.environment,
            target: armTarget,
            nativeScanner: nil,
            builder: native.builder)
        guard let scanner = armSDK.scanner else {
            preconditionFailure("the native Wayland SDK must produce wayland-scanner")
        }
        let x86Target = NativeLinuxTarget(architecture: .x86_64)
        let x86SDK = try buildNativeSDK(
            root: root,
            sdkRoot: native.nativeSDK(for: x86Target),
            environment: context.environment,
            target: x86Target,
            nativeScanner: scanner,
            builder: native.builder)
        var tasks = [armSDK.task, x86SDK.task]
        let bootstrapRoots: Set<TaskID> = [armSDK.task.id, x86SDK.task.id]
        let generation = try generate(
            root: root,
            generationRoot: context.cacheRoot.appending("generation/wayland"),
            environment: context.environment,
            placement: context.identityPathMap,
            swiftPM: context.swiftPM(.linux(.arm64)),
            builder: native.builder,
            scanner: scanner)
        tasks.append(contentsOf: generation.tasks)
        var storage = [
            // What generation produces. It was staging for a publication into
            // the checkout; now it is the output itself, and the committed copy
            // is authored state no task declares itself the producer of.
            StorageDeclaration(
                id: "wayland-generated-sources",
                owner: descriptor.id,
                producers: [.task(generation.task.id)],
                storageClass: .published,
                root: context.cacheRoot.appending("generation/wayland"),
                safetyRoot: context.cacheRoot.appending("generation"),
                retentionPolicy: .singleWorkingSet)
        ]
        storage += PlatformArchitecture.allCases.flatMap { architecture in
            let target = NativeLinuxTarget(architecture: architecture)
            let sdkRoot = native.nativeSDK(for: target)
            let producers: Set<StorageProducer> = [
                .task(TaskID(rawValue: "wayland.native-sdk.\(target.identifier)"))
            ]
            return [
                StorageDeclaration(
                    id: "wayland-sdk-\(target.identifier)",
                    owner: descriptor.id,
                    producers: producers,
                    storageClass: .published,
                    root: sdkRoot.appending("wayland"),
                    safetyRoot: sdkRoot,
                    retentionPolicy: .singleWorkingSet)
            ]
        }
        let component = try ComponentDefinition(
            descriptor: descriptor,
            tasks: tasks,
            entrypoints: [
                ComponentEntrypoint(id: .bootstrap, roots: bootstrapRoots),
                ComponentEntrypoint(id: .generate, roots: [generation.task.id]),
                ComponentEntrypoint(
                    id: .verifyGeneratedSources,
                    roots: [generation.verification.id]),
            ],
            storage: storage,
            generatedSources: generation.mappings)
        return ComponentArtifacts(
            component: component,
            nativeSDKs: [
                armTarget: armSDK.outputs,
                x86Target: x86SDK.outputs,
            ])
    }

    package static func buildNativeSDK(
        root: FilePath,
        sdkRoot: FilePath,
        environment: [String: String],
        target: NativeLinuxTarget,
        nativeScanner: ExecutableReference?,
        builder: NativeOCIConfiguration
    ) throws -> NativeSDKArtifacts {
        let source = root.appending("third-party/wayland")
        let sdk = sdkRoot.appending("wayland")
        let workspaces = WaylandNativeWorkspaces(target: target)
        let nativeScannerSDK =
            nativeScanner?.path.removingLastComponent()
            .removingLastComponent() ?? sdk
        let targetSDKMount = target.architecture == .arm64 ? "/native-wayland" : "/sdk"
        let inputs: [ArtifactInput] = [
            .sourceCheckout(source)
        ]
        if target.architecture == .x86_64 {
            guard nativeScanner != nil else {
                preconditionFailure("the x86_64 Wayland build requires the native scanner")
            }
        }

        let buildDirectory = MesonBuildDirectory(
            path: "/build/wayland",
            source: "/src",
            target: target,
            nativeToolchain: .guestDefault,
            options: [
                "--prefix=\(targetSDKMount)", "--libdir=lib",
                "--buildtype=release",
                "-Dtests=false", "-Ddocumentation=false",
                "-Ddtd_validation=false",
                "-Dscanner=\(target.architecture == .arm64 ? "true" : "false")",
            ])
        let configureArguments = ["bash", "-lc", buildDirectory.setupScript]

        var task = TaskBuilder(
            id: WaylandTaskIDs.nativeSDK(target),
            component: ComponentID(rawValue: "wayland"))
        task.consume(builder.image)
        task.consume(builder.nativeSysroot)
        if let nativeScanner {
            task.consume(nativeScanner)
        }
        var outputs = ArtifactReferenceSet()
        let serverHeader: ArtifactReference = try task.output(
            "server-header",
            path: sdk.appending("include/wayland-server.h"),
            validation: .regularFile)
        outputs.append(serverHeader)
        let serverProtocolHeader: ArtifactReference = try task.output(
            "server-protocol-header",
            path: sdk.appending("include/wayland-server-protocol.h"),
            validation: .regularFile)
        outputs.append(serverProtocolHeader)
        let serverLibrary: ArtifactReference = try task.output(
            "server-library",
            path: sdk.appending("lib/libwayland-server.so"),
            validation: .symlinkTarget)
        outputs.append(serverLibrary)
        let clientLibrary: ArtifactReference = try task.output(
            "client-library",
            path: sdk.appending("lib/libwayland-client.so"),
            validation: .symlinkTarget)
        let scanner: ExecutableReference? =
            if target.architecture == .arm64 {
                try task.executableOutput(
                    "scanner",
                    path: sdk.appending("bin/wayland-scanner"))
            } else {
                nil
            }
        outputs.append(clientLibrary)
        if let scanner {
            outputs.append(scanner.artifact)
        }
        let declaration = task.build(
            inputs: inputs,
            locks: [.checkout("wayland-native-\(target.identifier)")],
            assessmentPolicy: .incremental,
            action:
                try AnyColliderAction(
                    RunWaylandNativeBuildAction(
                        sdk: sdk,
                        executions: [
                            try nativeExecution(
                                root: root,
                                source: source,
                                sdk: sdk,
                                nativeScannerSDK: nativeScannerSDK,
                                builder: builder,
                                target: target,
                                workspaces: workspaces,
                                environment: environment,
                                command: configureArguments),
                            try nativeExecution(
                                root: root,
                                source: source,
                                sdk: sdk,
                                nativeScannerSDK: nativeScannerSDK,
                                builder: builder,
                                target: target,
                                workspaces: workspaces,
                                environment: environment,
                                command: ["meson", "compile", "-C", buildDirectory.path]),
                            try nativeExecution(
                                root: root,
                                source: source,
                                sdk: sdk,
                                nativeScannerSDK: nativeScannerSDK,
                                builder: builder,
                                target: target,
                                workspaces: workspaces,
                                environment: environment,
                                command: [
                                    "meson", "install", "-C", buildDirectory.path,
                                    "--no-rebuild",
                                ]),
                        ]))
        )
        return NativeSDKArtifacts(
            task: declaration,
            scanner: scanner,
            outputs: outputs)
    }

    package static func generate(
        root: FilePath,
        generationRoot: FilePath,
        environment: [String: String],
        placement: IdentityPathMap,
        swiftPM: SwiftPMInvocation,
        builder: NativeOCIConfiguration,
        scanner: ExecutableReference
    ) throws -> Generation {
        let protocolsRoot = root.appending("Protocols")
        let records = try protocolRecords(under: protocolsRoot)
        let server = root.appending("Sources/WaylandServerC")
        let client = root.appending("Sources/WaylandClientC")
        let protocols = root.appending(
            "protocol-runtime/Sources/WaylandProtocolsC")
        let serverDispatchRoot = root.appending(
            "Sources/WaylandServerDispatch")
        let serverDispatch = serverDispatchRoot.appending("Generated")
        let clientDispatchRoot = root.appending(
            "Sources/WaylandClientDispatch")
        let clientDispatch = clientDispatchRoot.appending("Generated")
        let protocolTypesRoot = root.appending(
            "protocol-runtime/Sources/WaylandProtocolTypes")
        let protocolTypes = protocolTypesRoot.appending("Generated")
        let generatedDirectories = [
            server, client, protocols, protocolTypes, serverDispatch, clientDispatch,
        ]
        let generatedServer = waylandGeneratedDirectory(
            "server-c", under: generationRoot)
        let generatedClient = waylandGeneratedDirectory(
            "client-c", under: generationRoot)
        let generatedProtocols = waylandGeneratedDirectory(
            "protocols-c", under: generationRoot)
        let generatedProtocolTypes = waylandGeneratedDirectory(
            "protocol-types", under: generationRoot)
        let generatedServerDispatch = waylandGeneratedDirectory(
            "server-dispatch", under: generationRoot)
        let generatedClientDispatch = waylandGeneratedDirectory(
            "client-dispatch", under: generationRoot)
        let generatedOutputDirectories = [
            generatedServer,
            generatedClient,
            generatedProtocols,
            generatedProtocolTypes,
            generatedServerDispatch,
            generatedClientDispatch,
        ]
        let waylandXML = root.appending("third-party/wayland/protocol/wayland.xml")
        guard case .oci(let swiftOCI) = swiftPM.context.execution else {
            throw SwiftPMInvocationExecutionFailure.requiresOCIContext
        }
        var generatorBuilder = TaskBuilder(
            id: TaskID(rawValue: "wayland.generator"),
            component: descriptor.id)
        generatorBuilder.consume(swiftOCI.image)
        generatorBuilder.consume(builder.swiftSDK)
        let generator: ExecutableReference =
            try generatorBuilder.executableOutput(
                "executable",
                path: swiftPM.executable("SwiftWaylandGen"))
        let generatorTask = generatorBuilder.build(
            swiftProducts: [
                swiftPM.product(
                    package: "swift-wayland",
                    product: "SwiftWaylandGen",
                    packageRoot: root,
                    environment: environment,
                    expectedOutputs: [
                        PathPostcondition(
                            path: generator.path,
                            validation: .executableFile)
                    ])
            ],
            locks: [.checkout("wayland")])
        // wayland-scanner writes the input path into a comment at the head of
        // every file it generates, so these are the paths the container sees.
        let executionPath = placement.executionPath
        var scannerArguments: [String] = []
        for record in records {
            scannerArguments += [
                "server-header", executionPath(record.path),
                executionPath(
                    generatedServer.appending("\(record.name)-server-protocol.h")),
                "client-header", executionPath(record.path),
                executionPath(
                    generatedClient.appending("\(record.name)-client-protocol.h")),
                "public-code", executionPath(record.path),
                executionPath(
                    generatedProtocols.appending("\(record.name)-protocol.c")),
            ]
        }
        let manifests = [
            generatedServer.appending("generated-protocols.tsv"),
            generatedClient.appending("generated-protocols.tsv"),
        ]
        var task = TaskBuilder(
            id: TaskID(rawValue: "wayland.generate"),
            component: ComponentID(rawValue: "wayland"))
        task.consume(generator)
        task.consume(scanner)
        task.consume(swiftOCI.image)
        task.consume(builder.swiftSDK)
        var generatedOutputs: [ArtifactReference] = []
        for (index, directory) in generatedOutputDirectories.enumerated() {
            let output: ArtifactReference = try task.output(
                OutputSlotID(rawValue: "generated-\(index)"),
                path: directory,
                validation: .nonEmptyDirectory)
            generatedOutputs.append(output)
        }
        let generationTask = task.build(
            inputs: [
                .sourceCheckout(root.appending("Protocols")),
                .file(waylandXML),
            ],
            locks: [.checkout("wayland")],
            action:
                try AnyColliderAction(
                    GenerateWaylandSwiftSourcesAction(
                        generator: generator,
                        scanner: scanner,
                        protocolsRoot: protocolsRoot,
                        waylandXML: waylandXML,
                        generatedDirectories: generatedDirectories,
                        generatedOutputDirectories: generatedOutputDirectories,
                        generatedProtocols: generatedProtocols,
                        executions: [
                            sourceGenerationExecution(
                                root: root,
                                generatedDirectories: generatedOutputDirectories,
                                generatorScratch: swiftPM.productsDirectory,
                                scannerSDK: scanner.path.removingLastComponent()
                                    .removingLastComponent(),
                                swiftSDKRoot: builder.swiftSDKRoot,
                                swiftOCI: swiftOCI,
                                placement: placement,
                                command: [placement.executionPath(generator.path)]
                                    + serverArguments(
                                        protocolsRoot: protocolsRoot,
                                        protocolTypes: generatedProtocolTypes,
                                        serverDispatch: generatedServerDispatch,
                                        server: generatedServer,
                                        waylandXML: waylandXML,
                                        xmlPaths: records.map(\.path),
                                        placement: placement),
                                environment: environment),
                            sourceGenerationExecution(
                                root: root,
                                generatedDirectories: generatedOutputDirectories,
                                generatorScratch: swiftPM.productsDirectory,
                                scannerSDK: scanner.path.removingLastComponent()
                                    .removingLastComponent(),
                                swiftSDKRoot: builder.swiftSDKRoot,
                                swiftOCI: swiftOCI,
                                placement: placement,
                                command: [
                                    "sh", "-eu", "-c",
                                    "scanner=/native-wayland/bin/wayland-scanner; "
                                        + "while [ \"$#\" -ne 0 ]; do "
                                        + "\"$scanner\" \"$1\" \"$2\" \"$3\"; shift 3; done",
                                    "wayland-scanner",
                                ] + scannerArguments,
                                environment: environment),
                            sourceGenerationExecution(
                                root: root,
                                generatedDirectories: generatedOutputDirectories,
                                generatorScratch: swiftPM.productsDirectory,
                                scannerSDK: scanner.path.removingLastComponent()
                                    .removingLastComponent(),
                                swiftSDKRoot: builder.swiftSDKRoot,
                                swiftOCI: swiftOCI,
                                placement: placement,
                                command: [placement.executionPath(generator.path)]
                                    + clientArguments(
                                        protocolsRoot: protocolsRoot,
                                        clientDispatch: generatedClientDispatch,
                                        client: generatedClient,
                                        waylandXML: waylandXML,
                                        xmlPaths: records.map(\.path),
                                        placement: placement),
                                environment: environment),
                        ],
                        manifests: manifests))
        )
        let mappings = zip(generatedOutputDirectories, generatedDirectories).map {
            GeneratedSourceMapping(generated: $0, committed: $1)
        }
        var verifier = TaskBuilder(
            id: TaskID(rawValue: "wayland.verify-generated-sources"),
            component: descriptor.id)
        for output in generatedOutputs {
            verifier.consume(output)
        }
        let verificationTask = verifier.build(
            inputs: generatedDirectories.map { .sourceCheckout($0) },
            locks: [.checkout("wayland")],
            action:
                try AnyColliderAction(
                    VerifyWaylandGeneratedSourcesAction(mappings: mappings)))
        return Generation(
            tasks: [generatorTask, generationTask, verificationTask],
            task: generationTask,
            verification: verificationTask,
            mappings: mappings)
    }
}

private struct GenerateWaylandSwiftSourcesAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let generator: FilePath
        let scanner: FilePath
        let protocolsRoot: FilePath
        let waylandXML: FilePath
        let generatedDirectories: [FilePath]
        let generatedOutputDirectories: [FilePath]
        let generatedProtocols: FilePath
        let pipeline: OCIExecutionPipelineIdentity
        let manifests: [FilePath]

        func encode(into encoder: inout IdentityEncoder) {
            encoder.append(path: generator)
            encoder.append(path: scanner)
            encoder.append(path: protocolsRoot)
            encoder.append(path: waylandXML)
            encoder.appendSequence(generatedDirectories) { $0.append(path: $1) }
            encoder.appendSequence(generatedOutputDirectories) { $0.append(path: $1) }
            encoder.append(nested: pipeline)
            encoder.appendSequence(manifests) { $0.append(path: $1) }
            encoder.append(path: generatedProtocols)
        }
    }

    static let kind: ActionKind = "wayland.generate-swift-sources"

    let generator: ExecutableReference
    let scanner: ExecutableReference
    let protocolsRoot: FilePath
    let waylandXML: FilePath
    let generatedDirectories: [FilePath]
    let generatedOutputDirectories: [FilePath]
    let generatedProtocols: FilePath
    let pipeline: OCIExecutionPipeline
    let manifests: [FilePath]

    init(
        generator: ExecutableReference,
        scanner: ExecutableReference,
        protocolsRoot: FilePath,
        waylandXML: FilePath,
        generatedDirectories: [FilePath],
        generatedOutputDirectories: [FilePath],
        generatedProtocols: FilePath,
        executions: [OCIExecution],
        manifests: [FilePath]
    ) throws {
        self.generator = generator
        self.scanner = scanner
        self.protocolsRoot = protocolsRoot
        self.waylandXML = waylandXML
        self.generatedDirectories = generatedDirectories
        self.generatedOutputDirectories = generatedOutputDirectories
        self.generatedProtocols = generatedProtocols
        pipeline = try OCIExecutionPipeline(executions)
        self.manifests = manifests
    }

    var identity: Identity {
        Identity(
            generator: generator.path,
            scanner: scanner.path,
            protocolsRoot: protocolsRoot,
            waylandXML: waylandXML,
            generatedDirectories: generatedDirectories,
            generatedOutputDirectories: generatedOutputDirectories,
            generatedProtocols: generatedProtocols,
            pipeline: pipeline.identity,
            manifests: manifests)
    }

    var requirements: ActionRequirements {
        var effects =
            [
                ActionEffect(.read, scope: .checkout(protocolsRoot)),
                ActionEffect(.read, scope: .input(waylandXML)),
            ]
            // Generation writes storage only. The committed copy is read by
            // verification and written by a human.
            + generatedOutputDirectories.map {
                ActionEffect(.readWrite, scope: .output($0))
            }
        for effect in pipeline.requirements.effects where !effects.contains(effect) {
            effects.append(effect)
        }
        return ActionRequirements(
            tools: [
                ActionToolRequirement(
                    "swift-wayland-generator",
                    executable: generator.executable,
                    role: .semantic),
                ActionToolRequirement(
                    "wayland-scanner",
                    executable: scanner.executable,
                    role: .semantic),
            ],
            effects: effects,
            lane: pipeline.requirements.lane,
            networkAccess: pipeline.requirements.networkAccess,
            executionPlatform: pipeline.requirements.executionPlatform,
            artifactTarget: pipeline.requirements.artifactTarget)
    }

    var environment: [String: String] { pipeline.environment }

    func execute(in context: ActionContext) async throws {
        for directory in generatedOutputDirectories {
            try context.files.remove(directory)
            try context.files.createDirectory(directory)
        }
        try context.files.createDirectory(generatedProtocols.appending("include"))
        try context.files.write([], to: generatedProtocols.appending("include/.gitkeep"))

        for execution in pipeline.executions.dropLast() {
            try context.cancellation.check()
            try await context.containers.run(execution)
        }
        for manifest in manifests {
            try context.files.remove(manifest)
        }
        if let clientExecution = pipeline.executions.last {
            try context.cancellation.check()
            try await context.containers.run(clientExecution)
        }
        for manifest in manifests {
            try context.files.remove(manifest)
        }
        // Generation stops here. What it produced is the output; the copy
        // beside the sources is authored state a human adopts, and a build that
        // wrote it would be rewriting the checkout it reads.
        try validateGeneratedDirectories(context.files)
    }

    private func validateGeneratedDirectories(_ files: ActionFileSystem) throws {
        guard generatedOutputDirectories.count == generatedDirectories.count else {
            throw WaylandGenerationFailure.mismatchedDirectorySets
        }
        for directory in generatedOutputDirectories {
            guard try files.metadata(for: directory)?.type == .directory,
                try !files.listRecursively(directory).isEmpty
            else {
                throw WaylandGenerationFailure.emptyOutput(directory)
            }
        }
    }

}

private enum WaylandGenerationFailure: Error {
    case mismatchedDirectorySets
    case emptyOutput(FilePath)
}

private func waylandGeneratedDirectory(
    _ name: String,
    under generationRoot: FilePath
) -> FilePath {
    generationRoot.appending(name)
}

/// Every path this execution names is the path the container sees, which is
/// where the declared placement roots put it rather than where the host keeps
/// it. The command's own arguments are mapped by the caller for the same
/// reason: a generated file recording an argument would otherwise record the
/// checkout it was generated from.
private func sourceGenerationExecution(
    root: FilePath,
    generatedDirectories: [FilePath],
    generatorScratch: FilePath,
    scannerSDK: FilePath,
    swiftSDKRoot: FilePath,
    swiftOCI: SwiftPMOCIExecution,
    placement: IdentityPathMap,
    command: [String],
    environment: [String: String]
) -> OCIExecution {
    return OCIExecution(
        executionPlatform: swiftOCI.executionPlatform,
        artifactTarget: swiftOCI.artifactTarget,
        imageID: swiftOCI.imageID,
        hostname: "wayland-source-generation",
        workingDirectory: placement.executionPath(root),
        hostWorkingDirectory: root,
        mounts: [
            OCIMount(
                source: root,
                target: placement.executionPath(root),
                access: .readOnly),
            OCIMount(
                source: generatorScratch,
                target: placement.executionPath(generatorScratch),
                access: .readOnly),
            OCIMount(
                source: scannerSDK,
                target: "/native-wayland",
                access: .readOnly),
            OCIMount(
                source: swiftSDKRoot,
                target: "/swift-sdk",
                access: .readOnly),
        ]
            + generatedDirectories.map {
                OCIMount(boundedExport: $0, target: placement.executionPath($0))
            },
        userPolicy: .builder,
        capabilityPolicy: .dropAll,
        privilegePolicy: .prohibitAcquisition,
        processFilesystemPolicy: swiftOCI.processFilesystemPolicy,
        resourceLimits: swiftOCI.resourceLimits,
        containerEnvironment: swiftOCI.containerEnvironment,
        command: ["wayland-generate"] + command,
        environment: environment,
        output: .logged)
}

private func serverArguments(
    protocolsRoot: FilePath,
    protocolTypes: FilePath,
    serverDispatch: FilePath,
    server: FilePath,
    waylandXML: FilePath,
    xmlPaths: [FilePath],
    placement: IdentityPathMap
) -> [String] {
    let path = placement.executionPath
    return [
        "--mode", "server",
        "--module", "WaylandServerC",
        "--search-dir", path(protocolsRoot.appending("protocols")),
        "--search-dir", path(protocolsRoot.appending("wayland-protocols")),
        "--types", path(protocolTypes),
        "--dispatch", path(serverDispatch),
        path(server),
        path(waylandXML),
    ] + xmlPaths.map(path)
}

private func clientArguments(
    protocolsRoot: FilePath,
    clientDispatch: FilePath,
    client: FilePath,
    waylandXML: FilePath,
    xmlPaths: [FilePath],
    placement: IdentityPathMap
) -> [String] {
    let path = placement.executionPath
    return [
        "--mode", "client",
        "--module", "WaylandClientC",
        "--search-dir", path(protocolsRoot.appending("protocols")),
        "--search-dir", path(protocolsRoot.appending("wayland-protocols")),
        "--dispatch", path(clientDispatch),
        path(client),
        path(waylandXML),
    ] + xmlPaths.map(path)
}

private struct WaylandNativeWorkspaces {
    let intermediates: PersistentWorkspaceDeclaration
    let compilerCache: PersistentWorkspaceDeclaration

    init(target: NativeLinuxTarget) {
        intermediates = PersistentWorkspaceDeclaration(
            identity: PersistentWorkspaceIdentity(
                key: "wayland-native-intermediates",
                artifactTarget: target.artifactTarget,
                role: "build"),
            capacityBytes: 100 * 1_024 * 1_024 * 1_024,
            filesystem: .ext4,
            journal: .writeback64MiB)
        compilerCache = PersistentWorkspaceDeclaration(
            identity: PersistentWorkspaceIdentity(
                key: "wayland-native-ccache",
                artifactTarget: target.artifactTarget,
                role: "compiler-cache"),
            capacityBytes: 50 * 1_024 * 1_024 * 1_024,
            filesystem: .ext4,
            journal: .writeback64MiB,
            retentionPolicy: .toolManagedLimit(maximumBytes: 50 * 1_024 * 1_024 * 1_024))
    }
}

private func nativeExecution(
    root: FilePath,
    source: FilePath,
    sdk: FilePath,
    nativeScannerSDK: FilePath,
    builder: NativeOCIConfiguration,
    target: NativeLinuxTarget,
    workspaces: WaylandNativeWorkspaces,
    environment: [String: String],
    command: [String]
) throws -> OCIExecution {
    var mounts = [
        OCIMount(source: source, target: "/src", access: .readOnly),
        OCIMount(
            boundedExport: sdk,
            target: target.architecture == .arm64 ? "/native-wayland" : "/sdk"),
        OCIMount(
            source: builder.swiftSDKRoot,
            target: "/swift-sdk",
            access: .readOnly),
    ]
    var containerEnvironment = [
        "CC": "/usr/bin/clang",
        "CCACHE_BASEDIR": "/src",
        "CCACHE_DIR": "/ccache",
        "CCACHE_LOGFILE": "/ccache/ccache.log",
        "NUCLEUS_WAYLAND_SDK": target.architecture == .arm64 ? "/native-wayland" : "/sdk",
        "PKG_CONFIG_LIBDIR":
            "/usr/lib/\(target.gnuArchitecture)/pkgconfig:/usr/share/pkgconfig",
    ]
    if target.architecture == .x86_64 {
        mounts.append(
            OCIMount(
                source: nativeScannerSDK,
                target: "/native-wayland",
                access: .readOnly))
        containerEnvironment["PATH"] =
            "/native-wayland/bin:/opt/cmake/bin:/opt/swift/usr/bin:/usr/lib/ccache:"
            + "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        containerEnvironment["PKG_CONFIG_PATH"] = "/native-wayland/lib/pkgconfig"
        containerEnvironment["PKG_CONFIG_PATH_FOR_BUILD"] =
            "/native-wayland/lib/pkgconfig"
        containerEnvironment["PKG_CONFIG_LIBDIR_FOR_BUILD"] =
            "/native-wayland/lib/pkgconfig"
    }
    return OCIExecution(
        executionPlatform: .linuxARM64OCI,
        artifactTarget: target.artifactTarget,
        imageID: builder.imageID,
        hostname: "native-wayland-\(target.architecture.rawValue)",
        workingDirectory: "/src",
        hostWorkingDirectory: root,
        mounts: mounts,
        persistentWorkspaceMounts: [
            OCIPersistentWorkspaceMount(
                workspace: workspaces.intermediates,
                target: "/build",
                access: .readWrite),
            OCIPersistentWorkspaceMount(
                workspace: workspaces.compilerCache,
                target: "/ccache",
                access: .readWrite),
        ],
        userPolicy: .builder,
        capabilityPolicy: .dropAll,
        privilegePolicy: .prohibitAcquisition,
        processFilesystemPolicy: .standard,
        resourceLimits: .parallelBuild,
        containerEnvironment: containerEnvironment,
        command: ["wayland"] + command,
        environment: environment,
        output: .logged)
}

private struct RunWaylandNativeBuildAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let sdk: FilePath
        let pipeline: OCIExecutionPipelineIdentity

        func encode(into encoder: inout IdentityEncoder) {
            encoder.append(path: sdk)
            encoder.append(nested: pipeline)
        }
    }

    static let kind: ActionKind = "wayland.build-native-sdk"

    let sdk: FilePath
    let pipeline: OCIExecutionPipeline

    init(sdk: FilePath, executions: [OCIExecution]) throws {
        self.sdk = sdk
        pipeline = try OCIExecutionPipeline(executions)
    }

    var identity: Identity {
        Identity(sdk: sdk, pipeline: pipeline.identity)
    }

    var requirements: ActionRequirements {
        var effects = pipeline.requirements.effects
        for effect in [
            ActionEffect(.readWrite, scope: .output(sdk))
        ] where !effects.contains(effect) {
            effects.append(effect)
        }
        return ActionRequirements(
            effects: effects,
            persistentWorkspaceEffects: pipeline.requirements.persistentWorkspaceEffects,
            lane: pipeline.requirements.lane,
            networkAccess: pipeline.requirements.networkAccess,
            executionPlatform: pipeline.requirements.executionPlatform,
            artifactTarget: pipeline.requirements.artifactTarget)
    }

    var environment: [String: String] { pipeline.environment }

    func execute(in context: ActionContext) async throws {
        try context.files.remove(sdk)
        try context.files.createDirectory(sdk)
        try await pipeline.execute(in: context)
    }
}

private struct WaylandProtocolRecord {
    let name: String
    let path: FilePath
}

private let excludedProtocolSuffixes = [
    "wayland-protocols/unstable/tablet/tablet-unstable-v2.xml",
    "wayland-protocols/unstable/xdg-shell/xdg-shell-unstable-v5.xml",
    "wayland-protocols/unstable/linux-dmabuf/linux-dmabuf-unstable-v1.xml",
    "protocols/presentation-time.xml",
]

private func protocolRecords(
    under protocolsRoot: FilePath
) throws -> [WaylandProtocolRecord] {
    let manager = FileManager.default
    guard
        let enumerator = manager.enumerator(
            at: URL(fileURLWithPath: protocolsRoot.string),
            includingPropertiesForKeys: [.isRegularFileKey])
    else {
        throw WaylandRecipeFailure.cannotEnumerate(protocolsRoot)
    }
    var records: [WaylandProtocolRecord] = []
    for case let url as URL in enumerator where url.pathExtension == "xml" {
        if url.lastPathComponent == "wayland.xml"
            || excludedProtocolSuffixes.contains(where: { url.path.hasSuffix($0) })
        {
            continue
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        guard let match = source.firstMatch(of: /<protocol\s+name\s*=\s*"([^"]+)"/)
        else { continue }
        records.append(
            WaylandProtocolRecord(
                name: String(match.1),
                path: FilePath(url.path(percentEncoded: false))))
    }
    return records.sorted { $0.path.string < $1.path.string }
}

public enum WaylandRecipeFailure: Error, CustomStringConvertible {
    case cannotEnumerate(FilePath)

    public var description: String {
        switch self {
        case .cannotEnumerate(let path):
            "cannot enumerate vendored Wayland protocols at \(path)"
        }
    }
}
