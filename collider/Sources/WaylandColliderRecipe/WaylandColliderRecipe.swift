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
    public static let descriptor = ComponentDescriptor(
        id: ComponentID(rawValue: "wayland"),
        canonicalName: "wayland",
        directoryName: "swift-wayland")

    public static func makeComponent(
        in context: RecipeContext
    ) throws -> ComponentDefinition {
        let root = context.componentRoot(descriptor)
        var tasks: [TaskDeclaration] = []
        var bootstrapRoots: Set<TaskID> = []
        for architecture in PlatformArchitecture.allCases {
            let target = NativeLinuxTarget(architecture: architecture)
            let sdk = buildNativeSDK(
                root: root,
                sdkRoot: context.nativeSDK(for: target),
                environment: context.environment,
                target: target,
                builder: context.nativeBuilder)
            tasks.append(sdk)
            bootstrapRoots.insert(sdk.id)
        }
        let scannerTarget = NativeLinuxTarget(architecture: .arm64)
        let generation = try generate(
            root: root,
            environment: context.environment,
            swiftPM: context.swiftPM(.linux(.arm64)),
            builder: context.nativeBuilder,
            scannerSDK: context.nativeSDK(for: scannerTarget).appending("wayland"))
        tasks.append(generation)
        return try ComponentDefinition(
            descriptor: descriptor,
            tasks: tasks,
            entrypoints: [
                ComponentEntrypoint(id: .bootstrap, roots: bootstrapRoots),
                ComponentEntrypoint(id: .generate, roots: [generation.id]),
            ])
    }

    public static func buildNativeSDK(
        root: FilePath,
        sdkRoot: FilePath,
        environment: [String: String],
        target: NativeLinuxTarget,
        builder: NativeOCIConfiguration
    ) -> TaskDeclaration {
        let source = root.appending("third-party/wayland")
        let build = root.appending(".wayland-build/\(target.identifier)")
        let sdk = sdkRoot.appending("wayland")
        let nativeScannerSDK = sdkRoot.removingLastComponent().appending(
            "linux-arm64/wayland")
        let targetSDKMount = target.architecture == .arm64 ? "/native-wayland" : "/sdk"
        var dependencies = [NativeBuilderTaskIDs.prepare]
        var inputs: [ArtifactInput] = [
            .tree(source),
            .dependencyOutput(builder.imageID),
        ]
        if target.architecture == .x86_64 {
            dependencies.append(
                WaylandTaskIDs.nativeSDK(
                    NativeLinuxTarget(architecture: .arm64)))
            inputs += [
                .file(root.appending("build-support/linux-x86_64.ini")),
                .dependencyOutput(nativeScannerSDK),
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

        return TaskDeclaration(
            id: WaylandTaskIDs.nativeSDK(target),
            component: ComponentID(rawValue: "wayland"),
            dependencies: dependencies,
            inputs: inputs,
            outputs: [
                OutputDeclaration(
                    path: sdk.appending("include/wayland-server.h"),
                    validation: .regularFile),
                OutputDeclaration(
                    path: sdk.appending("include/wayland-server-protocol.h"),
                    validation: .regularFile),
                OutputDeclaration(
                    path: sdk.appending("lib/libwayland-server.so"),
                    validation: .symlinkTarget),
                OutputDeclaration(
                    path: sdk.appending("lib/libwayland-client.so"),
                    validation: .symlinkTarget),
            ]
                + (target.architecture == .arm64
                    ? [
                        OutputDeclaration(
                            path: sdk.appending("bin/wayland-scanner"),
                            validation: .executableFile)
                    ] : []),
            locks: [.checkout("wayland-native-\(target.identifier)")],
            assessmentPolicy: .incremental,
            operation: .sequence([
                .removePath(build),
                .removePath(sdk),
                .createDirectory(build),
                .createDirectory(sdk),
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
            ]))
    }

    public static func generate(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation,
        builder: NativeOCIConfiguration,
        scannerSDK: FilePath
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
        let xmlPaths = records.map(\.path.string)
        let searchArguments = [
            "--search-dir", protocolsRoot.appending("protocols").string,
            "--search-dir", protocolsRoot.appending("wayland-protocols").string,
        ]
        let generator = swiftPM.executable("SwiftWaylandGen")
        var scannerArguments: [String] = []
        var operations: [TaskOperation] = []
        operations += generatedDirectories.map(TaskOperation.removePath)
        operations += generatedDirectories.map(TaskOperation.createDirectory)
        operations += [
            .createDirectory(protocols.appending("include")),
            .writeFile(protocols.appending("include/.gitkeep"), bytes: []),
            .command(
                CommandSpec(
                    executable: .taskOutput(generator),
                    arguments: [
                        "--mode", "server",
                        "--module", "WaylandServerC",
                    ] + searchArguments + [
                        "--types", protocolTypes.string,
                        "--dispatch", serverDispatch.string,
                        server.string,
                        waylandXML.string,
                    ] + xmlPaths,
                    workingDirectory: root,
                    environment: environment)),
            .command(
                CommandSpec(
                    executable: .taskOutput(generator),
                    arguments: [
                        "--mode", "client",
                        "--module", "WaylandClientC",
                    ] + searchArguments + [
                        "--dispatch", clientDispatch.string,
                        client.string,
                        waylandXML.string,
                    ] + xmlPaths,
                    workingDirectory: root,
                    environment: environment)),
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
                scannerSDK: scannerSDK,
                builder: builder,
                arguments: scannerArguments,
                environment: environment))
        operations += [
            .removePath(server.appending("generated-protocols.tsv")),
            .removePath(client.appending("generated-protocols.tsv")),
        ]
        return TaskDeclaration(
            id: TaskID(rawValue: "wayland.generate"),
            component: ComponentID(rawValue: "wayland"),
            dependencies: [
                NativeBuilderTaskIDs.prepare,
                WaylandTaskIDs.nativeSDK(
                    NativeLinuxTarget(architecture: .arm64)),
            ],
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
                .dependencyOutput(scannerSDK.appending("bin/wayland-scanner")),
                swiftPM.identityInput,
            ],
            outputs: [
                server, client, protocols, protocolTypes,
                serverDispatch, clientDispatch,
            ].map {
                OutputDeclaration(
                    path: $0,
                    validation: .nonEmptyDirectory)
            },
            locks: [.checkout("wayland")],
            operation: .sequence(operations))
    }
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
