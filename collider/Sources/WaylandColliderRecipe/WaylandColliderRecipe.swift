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
        package let scanner: ArtifactReference<ExecutableArtifact>?
        package let outputs: ArtifactReferenceSet
    }

    package struct ComponentArtifacts: Sendable {
        package let component: ComponentDefinition
        package let nativeSDKs: [NativeLinuxTarget: ArtifactReferenceSet]
    }

    package struct Generation: Sendable {
        package let tasks: [TaskDeclaration]
        package let task: TaskDeclaration
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
            environment: context.environment,
            swiftPM: context.swiftPM(.linux(.arm64)),
            builder: native.builder,
            scanner: scanner)
        tasks.append(contentsOf: generation.tasks)
        let storage = PlatformArchitecture.allCases.flatMap { architecture in
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
                    cleanupPolicy: .explicitClean,
                    retention: "the validated Wayland SDK remains published")
            ]
        }
        let component = try ComponentDefinition(
            descriptor: descriptor,
            tasks: tasks,
            entrypoints: [
                ComponentEntrypoint(id: .bootstrap, roots: bootstrapRoots),
                ComponentEntrypoint(id: .generate, roots: [generation.task.id]),
            ],
            storage: storage)
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
        nativeScanner: ArtifactReference<ExecutableArtifact>?,
        builder: NativeOCIConfiguration
    ) throws -> NativeSDKArtifacts {
        let source = root.appending("third-party/wayland")
        let sdk = sdkRoot.appending("wayland")
        let workspaces = WaylandNativeWorkspaces(target: target)
        let nativeScannerSDK =
            nativeScanner?.path.removingLastComponent()
            .removingLastComponent() ?? sdk
        let targetSDKMount = target.architecture == .arm64 ? "/native-wayland" : "/sdk"
        var inputs: [ArtifactInput] = [
            .sourceCheckout(source)
        ]
        if target.architecture == .x86_64 {
            guard nativeScanner != nil else {
                preconditionFailure("the x86_64 Wayland build requires the native scanner")
            }
            inputs += [
                .file(root.appending("build-support/linux-x86_64.ini"))
            ]
        }

        let configureArguments =
            [
                "meson", "setup", "/build", "/src",
                "--prefix=\(targetSDKMount)", "--libdir=lib",
                "--buildtype=release",
                "-Dtests=false", "-Ddocumentation=false",
                "-Ddtd_validation=false",
                "-Dscanner=\(target.architecture == .arm64 ? "true" : "false")",
            ]
            + (target.architecture == .x86_64
                ? ["--cross-file=/build-support/linux-x86_64.ini"] : [])

        var task = TaskBuilder(
            id: WaylandTaskIDs.nativeSDK(target),
            component: ComponentID(rawValue: "wayland"))
        task.consume(builder.image)
        task.consume(builder.swiftSDK)
        if let nativeScanner {
            task.consume(nativeScanner)
        }
        var outputs = ArtifactReferenceSet()
        let serverHeader: ArtifactReference<FileArtifact> = try task.output(
            "server-header",
            path: sdk.appending("include/wayland-server.h"),
            validation: .regularFile)
        outputs.append(serverHeader)
        let serverProtocolHeader: ArtifactReference<FileArtifact> = try task.output(
            "server-protocol-header",
            path: sdk.appending("include/wayland-server-protocol.h"),
            validation: .regularFile)
        outputs.append(serverProtocolHeader)
        let serverLibrary: ArtifactReference<PathArtifact> = try task.output(
            "server-library",
            path: sdk.appending("lib/libwayland-server.so"),
            validation: .symlinkTarget)
        outputs.append(serverLibrary)
        let clientLibrary: ArtifactReference<PathArtifact> = try task.output(
            "client-library",
            path: sdk.appending("lib/libwayland-client.so"),
            validation: .symlinkTarget)
        let scanner: ArtifactReference<ExecutableArtifact>? =
            if target.architecture == .arm64 {
                try task.output(
                    "scanner",
                    path: sdk.appending("bin/wayland-scanner"),
                    validation: .executableFile)
            } else {
                nil
            }
        outputs.append(clientLibrary)
        if let scanner {
            outputs.append(scanner)
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
                                command: ["meson", "compile", "-C", "/build"]),
                            try nativeExecution(
                                root: root,
                                source: source,
                                sdk: sdk,
                                nativeScannerSDK: nativeScannerSDK,
                                builder: builder,
                                target: target,
                                workspaces: workspaces,
                                environment: environment,
                                command: ["meson", "install", "-C", "/build", "--no-rebuild"]),
                        ]))
        )
        return NativeSDKArtifacts(
            task: declaration,
            scanner: scanner,
            outputs: outputs)
    }

    package static func generate(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation,
        builder: NativeOCIConfiguration,
        scanner: ArtifactReference<ExecutableArtifact>
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
        let stagedServer = waylandGenerationCandidate(server)
        let stagedClient = waylandGenerationCandidate(client)
        let stagedProtocols = waylandGenerationCandidate(protocols)
        let stagedProtocolTypes = waylandGenerationCandidate(protocolTypes)
        let stagedServerDispatch = waylandGenerationCandidate(serverDispatch)
        let stagedClientDispatch = waylandGenerationCandidate(clientDispatch)
        let stagedDirectories = [
            stagedServer,
            stagedClient,
            stagedProtocols,
            stagedProtocolTypes,
            stagedServerDispatch,
            stagedClientDispatch,
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
        let generator: ArtifactReference<ExecutableArtifact> =
            try generatorBuilder.output(
                "executable",
                path: swiftPM.executable("SwiftWaylandGen"),
                validation: .executableFile)
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
        var scannerArguments: [String] = []
        for record in records {
            scannerArguments += [
                "server-header", record.path.string,
                stagedServer.appending("\(record.name)-server-protocol.h").string,
                "client-header", record.path.string,
                stagedClient.appending("\(record.name)-client-protocol.h").string,
                "public-code", record.path.string,
                stagedProtocols.appending("\(record.name)-protocol.c").string,
            ]
        }
        let manifests = [
            stagedServer.appending("generated-protocols.tsv"),
            stagedClient.appending("generated-protocols.tsv"),
        ]
        var task = TaskBuilder(
            id: TaskID(rawValue: "wayland.generate"),
            component: ComponentID(rawValue: "wayland"))
        task.consume(generator)
        task.consume(scanner)
        task.consume(swiftOCI.image)
        task.consume(builder.swiftSDK)
        for (index, directory) in generatedDirectories.enumerated() {
            let _: ArtifactReference<DirectoryArtifact> = try task.output(
                OutputSlotID(rawValue: "generated-\(index)"),
                path: directory,
                validation: .nonEmptyDirectory)
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
                        stagedDirectories: stagedDirectories,
                        stagedProtocols: stagedProtocols,
                        executions: [
                            sourceGenerationExecution(
                                root: root,
                                generatedDirectories: stagedDirectories,
                                generatorScratch: swiftPM.scratchPath,
                                scannerSDK: scanner.path.removingLastComponent()
                                    .removingLastComponent(),
                                swiftSDKRoot: builder.swiftSDKRoot,
                                swiftOCI: swiftOCI,
                                command: [generator.path.string]
                                    + serverArguments(
                                        protocolsRoot: protocolsRoot,
                                        protocolTypes: stagedProtocolTypes,
                                        serverDispatch: stagedServerDispatch,
                                        server: stagedServer,
                                        waylandXML: waylandXML,
                                        xmlPaths: records.map(\.path)),
                                environment: environment),
                            sourceGenerationExecution(
                                root: root,
                                generatedDirectories: stagedDirectories,
                                generatorScratch: swiftPM.scratchPath,
                                scannerSDK: scanner.path.removingLastComponent()
                                    .removingLastComponent(),
                                swiftSDKRoot: builder.swiftSDKRoot,
                                swiftOCI: swiftOCI,
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
                                generatedDirectories: stagedDirectories,
                                generatorScratch: swiftPM.scratchPath,
                                scannerSDK: scanner.path.removingLastComponent()
                                    .removingLastComponent(),
                                swiftSDKRoot: builder.swiftSDKRoot,
                                swiftOCI: swiftOCI,
                                command: [generator.path.string]
                                    + clientArguments(
                                        protocolsRoot: protocolsRoot,
                                        clientDispatch: stagedClientDispatch,
                                        client: stagedClient,
                                        waylandXML: waylandXML,
                                        xmlPaths: records.map(\.path)),
                                environment: environment),
                        ],
                        manifests: manifests))
        )
        return Generation(
            tasks: [generatorTask, generationTask],
            task: generationTask)
    }
}

private struct GenerateWaylandSwiftSourcesAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let generator: FilePath
        let scanner: FilePath
        let protocolsRoot: FilePath
        let waylandXML: FilePath
        let generatedDirectories: [FilePath]
        let stagedDirectories: [FilePath]
        let stagedProtocols: FilePath
        let pipeline: OCIExecutionPipelineIdentity
        let manifests: [FilePath]

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: generator.string)
            encoder.append(tag: 2, string: scanner.string)
            encoder.append(tag: 3, string: protocolsRoot.string)
            encoder.append(tag: 4, string: waylandXML.string)
            encoder.append(
                tag: 5,
                string: generatedDirectories.map(\.string).joined(separator: "\0"))
            encoder.append(
                tag: 6,
                string: stagedDirectories.map(\.string).joined(separator: "\0"))
            encoder.append(tag: 7, nested: pipeline)
            encoder.append(
                tag: 8,
                string: manifests.map(\.string).joined(separator: "\0"))
            encoder.append(tag: 9, string: stagedProtocols.string)
        }
    }

    static let kind: ActionKind = "wayland.generate-swift-sources"

    let generator: ArtifactReference<ExecutableArtifact>
    let scanner: ArtifactReference<ExecutableArtifact>
    let protocolsRoot: FilePath
    let waylandXML: FilePath
    let generatedDirectories: [FilePath]
    let stagedDirectories: [FilePath]
    let stagedProtocols: FilePath
    let pipeline: OCIExecutionPipeline
    let manifests: [FilePath]

    init(
        generator: ArtifactReference<ExecutableArtifact>,
        scanner: ArtifactReference<ExecutableArtifact>,
        protocolsRoot: FilePath,
        waylandXML: FilePath,
        generatedDirectories: [FilePath],
        stagedDirectories: [FilePath],
        stagedProtocols: FilePath,
        executions: [OCIExecution],
        manifests: [FilePath]
    ) throws {
        self.generator = generator
        self.scanner = scanner
        self.protocolsRoot = protocolsRoot
        self.waylandXML = waylandXML
        self.generatedDirectories = generatedDirectories
        self.stagedDirectories = stagedDirectories
        self.stagedProtocols = stagedProtocols
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
            stagedDirectories: stagedDirectories,
            stagedProtocols: stagedProtocols,
            pipeline: pipeline.identity,
            manifests: manifests)
    }

    var requirements: ActionRequirements {
        var effects =
            [
                ActionEffect(.read, scope: .checkout(protocolsRoot)),
                ActionEffect(.read, scope: .input(waylandXML)),
            ]
            + generatedDirectories.map {
                ActionEffect(.readWrite, scope: .output($0))
            }
            + generatedDirectories.map {
                ActionEffect(.readWrite, scope: .scratch(waylandGenerationBackup($0)))
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
        for directory in stagedDirectories {
            try context.files.remove(directory)
            try context.files.createDirectory(directory)
        }
        defer {
            for directory in stagedDirectories {
                try? context.files.remove(directory)
            }
        }
        try context.files.createDirectory(stagedProtocols.appending("include"))
        try context.files.write([], to: stagedProtocols.appending("include/.gitkeep"))

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
        try validateStagedDirectories(context.files)
        try publishStagedDirectories(context.files)
    }

    private func validateStagedDirectories(_ files: ActionFileSystem) throws {
        guard stagedDirectories.count == generatedDirectories.count else {
            throw WaylandGenerationFailure.mismatchedDirectorySets
        }
        for directory in stagedDirectories {
            guard try files.metadata(for: directory)?.type == .directory,
                try !files.listRecursively(directory).isEmpty
            else {
                throw WaylandGenerationFailure.emptyCandidate(directory)
            }
        }
    }

    private func publishStagedDirectories(_ files: ActionFileSystem) throws {
        var publications: [(destination: FilePath, backup: FilePath, replaced: Bool)] = []
        do {
            for (candidate, destination) in zip(stagedDirectories, generatedDirectories) {
                let backup = waylandGenerationBackup(destination)
                try files.remove(backup)
                let replaced = try files.metadataWithoutFollowingSymlinks(for: destination) != nil
                if replaced {
                    try files.move(from: destination, to: backup)
                }
                do {
                    try files.move(from: candidate, to: destination)
                } catch {
                    if replaced { try? files.move(from: backup, to: destination) }
                    throw error
                }
                publications.append((destination, backup, replaced))
            }
        } catch {
            for publication in publications.reversed() {
                try? files.remove(publication.destination)
                if publication.replaced {
                    try? files.move(
                        from: publication.backup,
                        to: publication.destination)
                }
            }
            throw error
        }
        for publication in publications where publication.replaced {
            try files.remove(publication.backup)
        }
    }
}

private enum WaylandGenerationFailure: Error {
    case mismatchedDirectorySets
    case emptyCandidate(FilePath)
}

private func waylandGenerationCandidate(_ destination: FilePath) -> FilePath {
    destination.removingLastComponent().appending(
        ".\(destination.lastComponent?.string ?? "generated").collider-candidate")
}

private func waylandGenerationBackup(_ destination: FilePath) -> FilePath {
    destination.removingLastComponent().appending(
        ".\(destination.lastComponent?.string ?? "generated").collider-previous")
}

private func sourceGenerationExecution(
    root: FilePath,
    generatedDirectories: [FilePath],
    generatorScratch: FilePath,
    scannerSDK: FilePath,
    swiftSDKRoot: FilePath,
    swiftOCI: SwiftPMOCIExecution,
    command: [String],
    environment: [String: String]
) -> OCIExecution {
    let target = NativeLinuxTarget(architecture: .arm64)
    return OCIExecution(
        executionPlatform: swiftOCI.executionPlatform,
        artifactTarget: swiftOCI.artifactTarget,
        imageID: swiftOCI.imageID,
        hostname: "wayland-source-generation",
        workingDirectory: root.string,
        hostWorkingDirectory: root,
        mounts: [
            OCIMount(source: root, target: root.string, access: .readOnly),
            OCIMount(
                source: generatorScratch,
                target: generatorScratch.string,
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
                OCIMount(source: $0, target: $0.string, access: .readWrite)
            },
        userPolicy: .builder,
        capabilityPolicy: .dropAll,
        privilegePolicy: .prohibitAcquisition,
        processFilesystemPolicy: swiftOCI.processFilesystemPolicy,
        intelBinaryTranslationPolicy: swiftOCI.intelBinaryTranslationPolicy,
        resourceLimits: swiftOCI.resourceLimits,
        containerEnvironment: [
            "LD_LIBRARY_PATH":
                target.containerSwiftSDKRoot + "/usr/lib/swift/linux:"
                + target.containerRuntimeLibraryPath
        ],
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
    xmlPaths: [FilePath]
) -> [String] {
    [
        "--mode", "server",
        "--module", "WaylandServerC",
        "--search-dir", protocolsRoot.appending("protocols").string,
        "--search-dir", protocolsRoot.appending("wayland-protocols").string,
        "--types", protocolTypes.string,
        "--dispatch", serverDispatch.string,
        server.string,
        waylandXML.string,
    ] + xmlPaths.map(\.string)
}

private func clientArguments(
    protocolsRoot: FilePath,
    clientDispatch: FilePath,
    client: FilePath,
    waylandXML: FilePath,
    xmlPaths: [FilePath]
) -> [String] {
    [
        "--mode", "client",
        "--module", "WaylandClientC",
        "--search-dir", protocolsRoot.appending("protocols").string,
        "--search-dir", protocolsRoot.appending("wayland-protocols").string,
        "--dispatch", clientDispatch.string,
        client.string,
        waylandXML.string,
    ] + xmlPaths.map(\.string)
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
            journal: .writeback64MiB)
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
            source: sdk,
            target: target.architecture == .arm64 ? "/native-wayland" : "/sdk",
            access: .readWrite),
        OCIMount(
            source: root.appending("build-support"),
            target: "/build-support",
            access: .readOnly),
        OCIMount(
            source: builder.swiftSDKRoot,
            target: "/swift-sdk",
            access: .readOnly),
    ]
    var containerEnvironment = [
        "CC": "clang",
        "CCACHE_BASEDIR": "/src",
        "CCACHE_DIR": "/ccache",
        "CCACHE_LOGFILE": "/ccache/ccache.log",
        "LD_LIBRARY_PATH": target.containerRuntimeLibraryPath,
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
        intelBinaryTranslationPolicy: target.intelBinaryTranslationPolicy,
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

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: sdk.string)
            encoder.append(tag: 2, nested: pipeline)
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
