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
    }

    public static let descriptor = ComponentDescriptor(
        id: ComponentID(rawValue: "wayland"),
        canonicalName: "wayland",
        directoryName: "swift-wayland")

    public static func makeComponent(
        in context: RecipeContext
    ) throws -> ComponentDefinition {
        let root = context.componentRoot(descriptor)
        let armTarget = NativeLinuxTarget(architecture: .arm64)
        let armSDK = try buildNativeSDK(
            root: root,
            sdkRoot: context.nativeSDK(for: armTarget),
            environment: context.environment,
            target: armTarget,
            nativeScanner: nil,
            builder: context.nativeBuilder)
        guard let scanner = armSDK.scanner else {
            preconditionFailure("the native Wayland SDK must produce wayland-scanner")
        }
        let x86Target = NativeLinuxTarget(architecture: .x86_64)
        let x86SDK = try buildNativeSDK(
            root: root,
            sdkRoot: context.nativeSDK(for: x86Target),
            environment: context.environment,
            target: x86Target,
            nativeScanner: scanner,
            builder: context.nativeBuilder)
        var tasks = [armSDK.task, x86SDK.task]
        let bootstrapRoots: Set<TaskID> = [armSDK.task.id, x86SDK.task.id]
        let generation = try generate(
            root: root,
            environment: context.environment,
            swiftPM: context.swiftPM(.linux(.arm64)),
            builder: context.nativeBuilder,
            scanner: scanner)
        tasks.append(generation)
        return try ComponentDefinition(
            descriptor: descriptor,
            tasks: tasks,
            entrypoints: [
                ComponentEntrypoint(id: .bootstrap, roots: bootstrapRoots),
                ComponentEntrypoint(id: .generate, roots: [generation.id]),
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
        let build = root.appending(".wayland-build/\(target.identifier)")
        let sdk = sdkRoot.appending("wayland")
        let nativeScannerSDK =
            nativeScanner?.path.removingLastComponent()
            .removingLastComponent() ?? sdk
        let targetSDKMount = target.architecture == .arm64 ? "/native-wayland" : "/sdk"
        let dependencies = [NativeBuilderTaskIDs.prepare]
        var inputs: [ArtifactInput] = [
            .tree(source),
            .dependencyOutput(builder.imageID),
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
        if let nativeScanner {
            task.consume(nativeScanner)
        }
        let _: ArtifactReference<FileArtifact> = try task.output(
            "server-header",
            path: sdk.appending("include/wayland-server.h"),
            validation: .regularFile)
        let _: ArtifactReference<FileArtifact> = try task.output(
            "server-protocol-header",
            path: sdk.appending("include/wayland-server-protocol.h"),
            validation: .regularFile)
        let _: ArtifactReference<PathArtifact> = try task.output(
            "server-library",
            path: sdk.appending("lib/libwayland-server.so"),
            validation: .symlinkTarget)
        let _: ArtifactReference<PathArtifact> = try task.output(
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
        let declaration = task.build(
            inputs: inputs,
            locks: [.checkout("wayland-native-\(target.identifier)")],
            assessmentPolicy: .incremental,
            operation: .sequence([
                .action(
                    try AnyColliderAction(
                        PrepareWaylandNativeBuildAction(
                            build: build,
                            sdk: sdk))),
                nativeOperation(
                    root: root,
                    source: source,
                    build: build,
                    sdk: sdk,
                    nativeScannerSDK: nativeScannerSDK,
                    builder: builder,
                    target: target,
                    environment: environment,
                    command: configureArguments),
                nativeOperation(
                    root: root,
                    source: source,
                    build: build,
                    sdk: sdk,
                    nativeScannerSDK: nativeScannerSDK,
                    builder: builder,
                    target: target,
                    environment: environment,
                    command: ["meson", "compile", "-C", "/build"]),
                nativeOperation(
                    root: root,
                    source: source,
                    build: build,
                    sdk: sdk,
                    nativeScannerSDK: nativeScannerSDK,
                    builder: builder,
                    target: target,
                    environment: environment,
                    command: ["meson", "install", "-C", "/build", "--no-rebuild"]),
            ])
        ).addingDependencies(dependencies)
        return NativeSDKArtifacts(task: declaration, scanner: scanner)
    }

    public static func generate(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation,
        builder: NativeOCIConfiguration,
        scanner: ArtifactReference<ExecutableArtifact>
    ) throws -> TaskDeclaration {
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
        let waylandXML = root.appending("third-party/wayland/protocol/wayland.xml")
        let generator = swiftPM.executable("SwiftWaylandGen")
        var scannerArguments: [String] = []
        var operations: [TaskOperation] = [
            .action(
                try AnyColliderAction(
                    GenerateWaylandSwiftSourcesAction(
                        generator: generator,
                        root: root,
                        protocolsRoot: protocolsRoot,
                        waylandXML: waylandXML,
                        xmlPaths: records.map(\.path),
                        generatedDirectories: generatedDirectories,
                        server: server,
                        client: client,
                        protocols: protocols,
                        protocolTypes: protocolTypes,
                        serverDispatch: serverDispatch,
                        clientDispatch: clientDispatch,
                        environment: environment)))
        ]
        for record in records {
            scannerArguments += [
                "server-header", record.path.string,
                server.appending("\(record.name)-server-protocol.h").string,
                "client-header", record.path.string,
                client.appending("\(record.name)-client-protocol.h").string,
                "public-code", record.path.string,
                protocols.appending("\(record.name)-protocol.c").string,
            ]
        }
        operations.append(
            scannerOperation(
                root: root,
                scannerSDK: scanner.path.removingLastComponent().removingLastComponent(),
                builder: builder,
                arguments: scannerArguments,
                environment: environment))
        operations.append(
            .action(
                try AnyColliderAction(
                    FinalizeWaylandGenerationAction(
                        manifests: [
                            server.appending("generated-protocols.tsv"),
                            client.appending("generated-protocols.tsv"),
                        ]))))
        var task = TaskBuilder(
            id: TaskID(rawValue: "wayland.generate"),
            component: ComponentID(rawValue: "wayland"))
        task.consume(scanner)
        for (index, directory) in generatedDirectories.enumerated() {
            let _: ArtifactReference<DirectoryArtifact> = try task.output(
                OutputSlotID(rawValue: "generated-\(index)"),
                path: directory,
                validation: .nonEmptyDirectory)
        }
        return task.build(
            swiftProducts: [
                swiftPM.product(
                    package: "swift-wayland",
                    product: "SwiftWaylandGen",
                    packageRoot: root,
                    environment: environment,
                    expectedOutputs: [
                        PathPostcondition(
                            path: swiftPM.executable("SwiftWaylandGen"),
                            validation: .executableFile)
                    ])
            ],
            inputs: [
                .tree(root.appending("Sources/SwiftWaylandGen")),
                .tree(root.appending("Sources/SwiftWaylandGenerator")),
                .tree(root.appending("Sources/WaylandProtocolModel")),
                .tree(root.appending("Protocols")),
                .file(waylandXML),
                .dependencyOutput(builder.imageID),
                swiftPM.identityInput,
            ],
            locks: [.checkout("wayland")],
            operation: .sequence(operations)
        ).addingDependencies([NativeBuilderTaskIDs.prepare])
    }
}

private struct PrepareWaylandNativeBuildAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let build: FilePath
        let sdk: FilePath

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: build.string)
            encoder.append(tag: 2, string: sdk.string)
        }
    }

    static let kind: ActionKind = "wayland.prepare-native-build"

    let build: FilePath
    let sdk: FilePath

    var identity: Identity { Identity(build: build, sdk: sdk) }

    var requirements: ActionRequirements {
        ActionRequirements(effects: [
            ActionEffect(.readWrite, scope: .scratch(build)),
            ActionEffect(.readWrite, scope: .output(sdk)),
        ])
    }

    func execute(in context: ActionContext) async throws {
        try context.files.remove(build)
        try context.files.remove(sdk)
        try context.files.createDirectory(build)
        try context.files.createDirectory(sdk)
    }
}

private struct FinalizeWaylandGenerationAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let manifests: [FilePath]

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(
                tag: 1,
                string: manifests.map(\.string).joined(separator: "\u{0}"))
        }
    }

    static let kind: ActionKind = "wayland.finalize-generation"

    let manifests: [FilePath]

    var identity: Identity { Identity(manifests: manifests) }

    var requirements: ActionRequirements {
        ActionRequirements(
            effects: manifests.map {
                ActionEffect(.write, scope: .output($0))
            })
    }

    func execute(in context: ActionContext) async throws {
        for manifest in manifests {
            try context.files.remove(manifest)
        }
    }
}

private struct GenerateWaylandSwiftSourcesAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let generator: FilePath
        let root: FilePath
        let protocolsRoot: FilePath
        let waylandXML: FilePath
        let xmlPaths: [FilePath]
        let generatedDirectories: [FilePath]

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: generator.string)
            encoder.append(tag: 2, string: root.string)
            encoder.append(tag: 3, string: protocolsRoot.string)
            encoder.append(tag: 4, string: waylandXML.string)
            encoder.append(
                tag: 5,
                string: xmlPaths.map(\.string).joined(separator: "\0"))
            encoder.append(
                tag: 6,
                string: generatedDirectories.map(\.string).joined(separator: "\0"))
        }
    }

    static let kind: ActionKind = "wayland.generate-swift-sources"

    let generator: FilePath
    let root: FilePath
    let protocolsRoot: FilePath
    let waylandXML: FilePath
    let xmlPaths: [FilePath]
    let generatedDirectories: [FilePath]
    let server: FilePath
    let client: FilePath
    let protocols: FilePath
    let protocolTypes: FilePath
    let serverDispatch: FilePath
    let clientDispatch: FilePath
    let environment: [String: String]

    var identity: Identity {
        Identity(
            generator: generator,
            root: root,
            protocolsRoot: protocolsRoot,
            waylandXML: waylandXML,
            xmlPaths: xmlPaths,
            generatedDirectories: generatedDirectories)
    }

    var requirements: ActionRequirements {
        ActionRequirements(
            tools: [
                ActionToolRequirement(
                    "swift-wayland-generator",
                    executable: .taskOutput(generator),
                    role: .operational)
            ],
            effects: [
                ActionEffect(.read, scope: .checkout(protocolsRoot)),
                ActionEffect(.read, scope: .input(waylandXML)),
            ]
                + generatedDirectories.map {
                    ActionEffect(.readWrite, scope: .output($0))
                })
    }

    func execute(in context: ActionContext) async throws {
        for directory in generatedDirectories {
            try context.files.remove(directory)
            try context.files.createDirectory(directory)
        }
        try context.files.createDirectory(protocols.appending("include"))
        try context.files.write([], to: protocols.appending("include/.gitkeep"))

        let searchArguments = [
            "--search-dir", protocolsRoot.appending("protocols").string,
            "--search-dir", protocolsRoot.appending("wayland-protocols").string,
        ]
        try await run(
            [
                "--mode", "server",
                "--module", "WaylandServerC",
            ] + searchArguments + [
                "--types", protocolTypes.string,
                "--dispatch", serverDispatch.string,
                server.string,
                waylandXML.string,
            ] + xmlPaths.map(\.string),
            context: context)
        try await run(
            [
                "--mode", "client",
                "--module", "WaylandClientC",
            ] + searchArguments + [
                "--dispatch", clientDispatch.string,
                client.string,
                waylandXML.string,
            ] + xmlPaths.map(\.string),
            context: context)
    }

    private func run(
        _ arguments: [String],
        context: ActionContext
    ) async throws {
        let result = try await context.commands.execute(
            CommandSpec(
                executable: .taskOutput(generator),
                arguments: arguments,
                workingDirectory: root,
                environment: environment))
        guard result.status == 0 else {
            throw WaylandSourceGenerationFailure.commandFailed(result.status)
        }
    }
}

private enum WaylandSourceGenerationFailure: Error {
    case commandFailed(Int32)
}

private func scannerOperation(
    root: FilePath,
    scannerSDK: FilePath,
    builder: NativeOCIConfiguration,
    arguments: [String],
    environment: [String: String]
) -> TaskOperation {
    .runOCI(
        OCIExecution(
            executionPlatform: .linuxARM64OCI,
            artifactTarget: .linuxARM64,
            imageID: builder.imageID,
            hostname: "wayland-source-generation",
            workingDirectory: root.string,
            hostWorkingDirectory: root,
            mounts: [
                OCIMount(source: root, target: root.string, access: .readWrite),
                OCIMount(
                    source: scannerSDK,
                    target: "/native-wayland",
                    access: .readOnly),
            ],
            networkPolicy: .externalDisabled,
            userPolicy: .builder,
            capabilityPolicy: .dropAll,
            privilegePolicy: .prohibitAcquisition,
            processFilesystemPolicy: .standard,
            resourceLimits: .parallelBuild,
            containerEnvironment: [:],
            command: [
                "wayland-generate",
                "sh", "-eu", "-c",
                "scanner=/native-wayland/bin/wayland-scanner; "
                    + "while [ \"$#\" -ne 0 ]; do "
                    + "\"$scanner\" \"$1\" \"$2\" \"$3\"; shift 3; done",
                "wayland-scanner",
            ] + arguments,
            environment: environment,
            output: .logged))
}

private func nativeOperation(
    root: FilePath,
    source: FilePath,
    build: FilePath,
    sdk: FilePath,
    nativeScannerSDK: FilePath,
    builder: NativeOCIConfiguration,
    target: NativeLinuxTarget,
    environment: [String: String],
    command: [String]
) -> TaskOperation {
    var mounts = [
        OCIMount(source: source, target: "/src", access: .readOnly),
        OCIMount(source: build, target: "/build", access: .readWrite),
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
    return .runOCI(
        OCIExecution(
            executionPlatform: .linuxARM64OCI,
            artifactTarget: target.artifactTarget,
            imageID: builder.imageID,
            hostname: "native-wayland-\(target.architecture.rawValue)",
            workingDirectory: "/src",
            hostWorkingDirectory: root,
            mounts: mounts,
            networkPolicy: .externalDisabled,
            userPolicy: .builder,
            capabilityPolicy: .dropAll,
            privilegePolicy: .prohibitAcquisition,
            processFilesystemPolicy: .standard,
            intelBinaryTranslationPolicy: target.intelBinaryTranslationPolicy,
            resourceLimits: .parallelBuild,
            containerEnvironment: containerEnvironment,
            command: ["wayland"] + command,
            environment: environment,
            output: .logged))
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
    let expression = try NSRegularExpression(
        pattern: #"<protocol\s+name\s*=\s*"([^"]+)""#)
    var records: [WaylandProtocolRecord] = []
    for case let url as URL in enumerator where url.pathExtension == "xml" {
        if url.lastPathComponent == "wayland.xml"
            || excludedProtocolSuffixes.contains(where: { url.path.hasSuffix($0) })
        {
            continue
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        let range = NSRange(source.startIndex..., in: source)
        guard let match = expression.firstMatch(in: source, range: range),
            let nameRange = Range(match.range(at: 1), in: source)
        else { continue }
        records.append(
            WaylandProtocolRecord(
                name: String(source[nameRange]),
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
