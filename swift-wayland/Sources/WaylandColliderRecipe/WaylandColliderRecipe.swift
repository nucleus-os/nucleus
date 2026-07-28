import ColliderCore
import Foundation
import SystemPackage

public enum WaylandColliderRecipe {
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
        task(
            "wayland.test", root, environment, ["test"],
            [TaskID(rawValue: "wayland.build")],
            swiftPM: swiftPM)
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
        let waylandXML = protocolsRoot.appending("protocols/wayland.xml")
        let xmlPaths = records.map(\.path.string)
        let searchArguments = [
            "--search-dir", protocolsRoot.appending("protocols").string,
            "--search-dir", protocolsRoot.appending("wayland-protocols").string,
        ]
        let generator = swiftPM.executable("SwiftWaylandGen")
        var operations: [TaskOperation] = [
            .command(swiftPM.command(
                arguments: ["build", "--product", "SwiftWaylandGen"],
                workingDirectory: root,
                environment: environment)),
        ]
        operations += generatedDirectories.map(TaskOperation.removePath)
        operations += generatedDirectories.map(TaskOperation.createDirectory)
        operations += [
            .createDirectory(protocols.appending("include")),
            .writeFile(protocols.appending("include/.gitkeep"), bytes: []),
            .command(CommandSpec(
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
            .command(CommandSpec(
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
            inputs: [
                .file(root.appending("Package.swift")),
                .tree(root.appending("Sources/SwiftWaylandGen")),
                .tree(root.appending("Sources/SwiftWaylandGenerator")),
                .tree(root.appending("Sources/WaylandProtocolModel")),
                .tree(root.appending("Protocols")),
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
            locks: [.checkout("wayland"), swiftPM.lock],
            operation: .sequence(operations))
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
    guard let enumerator = manager.enumerator(
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
        records.append(WaylandProtocolRecord(
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
    .command(CommandSpec(
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
    swiftPM: SwiftPMInvocation
) -> TaskDeclaration {
    TaskDeclaration(
        id: TaskID(rawValue: id),
        component: ComponentID(rawValue: "wayland"),
        dependencies: dependencies,
        inputs: [
            .file(root.appending("Package.swift")),
            .tree(root.appending("Sources")),
            swiftPM.identityInput,
            .tool(.named("swift")),
        ],
        postconditions: [swiftPM.postcondition],
        locks: [.checkout("wayland"), swiftPM.lock],
        operation: .command(swiftPM.command(
            arguments: arguments,
            workingDirectory: root,
            environment: environment)))
}
