import ColliderCore
import Foundation
import SystemPackage

public enum WaylandColliderRecipe {
    public static func buildNativeSDK(
        root: FilePath,
        sdkRoot: FilePath,
        environment: [String: String],
        target: NativeLinuxTarget,
        builder: NativeOCIConfiguration
    ) -> TaskDeclaration {
        let source = root.appending("third-party/wayland")
        let build = root.appending(".wayland-build/\(target.identifier)")
        let sdk = sdkRoot.appending(target.identifier).appending("wayland")
        let nativeScannerSDK = sdkRoot.appending("linux-arm64/wayland")
        let targetSDKMount = target.architecture == .arm64 ? "/native-wayland" : "/sdk"
        var dependencies = [TaskID(rawValue: "native.builder")]
        var inputs: [ArtifactInput] = [
            .tree(source),
            .dependencyOutput(builder.imageID),
        ]
        if target.architecture == .x86_64 {
            dependencies.append(TaskID(rawValue: "wayland.native-sdk.linux-arm64"))
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
            id: TaskID(rawValue: "wayland.native-sdk.\(target.identifier)"),
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
                    validation: .exists),
                OutputDeclaration(
                    path: sdk.appending("lib/libwayland-client.so"),
                    validation: .exists),
            ]
                + (target.architecture == .arm64
                    ? [
                        OutputDeclaration(
                            path: sdk.appending("bin/wayland-scanner"),
                            validation: .executableFile)
                    ] : []),
            locks: [.checkout("wayland-native-\(target.identifier)")],
            cachePolicy: .contentAddressed,
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

    public static func build(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) -> TaskDeclaration {
        task(
            "wayland.build", root, environment, ["build"],
            swiftPM: swiftPM)
    }

    public static func test(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) -> TaskDeclaration {
        let requirement = swiftPM.testProduct(
            package: "swift-wayland",
            testProduct: "swift-waylandPackageTests",
            packageRoot: root,
            environment: environment)
        return TaskDeclaration(
            id: TaskID(rawValue: "wayland.test"),
            component: ComponentID(rawValue: "wayland"),
            dependencies: [TaskID(rawValue: "wayland.build")],
            subsumedDependencies: [TaskID(rawValue: "wayland.build")],
            swiftTests: [requirement],
            locks: [.checkout("wayland")],
            cachePolicy: .always,
            operation: .runSwiftTest(
                SwiftTestExecution(
                    requirement: requirement)))
    }

    public static func generate(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
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
            operations += [
                scanner(
                    "server-header",
                    record: record,
                    output: server.appending(
                        "\(record.name)-server-protocol.h"),
                    root: root,
                    environment: environment),
                scanner(
                    "client-header",
                    record: record,
                    output: client.appending(
                        "\(record.name)-client-protocol.h"),
                    root: root,
                    environment: environment),
                scanner(
                    "public-code",
                    record: record,
                    output: protocols.appending(
                        "\(record.name)-protocol.c"),
                    root: root,
                    environment: environment),
            ]
        }
        operations += [
            .removePath(server.appending("generated-protocols.tsv")),
            .removePath(client.appending("generated-protocols.tsv")),
        ]
        return TaskDeclaration(
            id: TaskID(rawValue: "wayland.generate"),
            component: ComponentID(rawValue: "wayland"),
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
                swiftPM.identityInput,
                .tool(.named("swift")),
                .tool(.named("wayland-scanner")),
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
                path: FilePath(url.path)))
    }
    return records.sorted { $0.path.string < $1.path.string }
}

private func scanner(
    _ mode: String,
    record: WaylandProtocolRecord,
    output: FilePath,
    root: FilePath,
    environment: [String: String]
) -> TaskOperation {
    .command(
        CommandSpec(
            executable: .named("wayland-scanner"),
            arguments: [mode, record.path.string, output.string],
            workingDirectory: root,
            environment: environment))
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

private func task(
    _ id: String,
    _ root: FilePath,
    _ environment: [String: String],
    _ arguments: [String],
    _ dependencies: [TaskID] = [],
    subsumedDependencies: [TaskID] = [],
    includesTests: Bool = false,
    swiftPM: SwiftPMInvocation
) -> TaskDeclaration {
    let isBuild = arguments == ["build"]
    return TaskDeclaration(
        id: TaskID(rawValue: id),
        component: ComponentID(rawValue: "wayland"),
        dependencies: dependencies,
        subsumedDependencies: subsumedDependencies,
        swiftProducts: isBuild
            ? [
                swiftPM.product(
                    package: "swift-wayland",
                    product: "WaylandServer",
                    packageRoot: root,
                    environment: environment),
                swiftPM.product(
                    package: "swift-wayland",
                    product: "WaylandClient",
                    packageRoot: root,
                    environment: environment),
            ] : [],
        inputs: [
            .tree(root.appending("Sources"))
        ] + (includesTests ? [.tree(root.appending("Tests"))] : []) + [
            swiftPM.identityInput,
            .tool(.named("swift")),
        ],
        postconditions: [swiftPM.postcondition],
        locks: [.checkout("wayland")] + (isBuild ? [] : [swiftPM.lock]),
        operation: isBuild
            ? .sequence([])
            : .command(
                swiftPM.command(
                    arguments: arguments,
                    workingDirectory: root,
                    environment: environment)))
}
