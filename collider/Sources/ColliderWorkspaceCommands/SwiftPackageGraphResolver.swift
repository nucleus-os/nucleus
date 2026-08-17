import ColliderCore
import ColliderPersistence
import Foundation
import SystemPackage

/// Materializes SwiftPM's package graph on the host and retains it until one
/// of the files that determine package structure or dependency resolution
/// changes.
package final class SwiftPackageGraphResolver: @unchecked Sendable {
    private struct Description: Codable {
        struct Dependency: Codable {
            let identity: String
            let path: String?
            let type: String
        }

        struct Product: Codable {
            let name: String
            let targets: [String]
        }

        struct Target: Codable {
            let name: String
            let path: String
            let targetDependencies: [String]?
            let productDependencies: [String]?
            let type: String

            enum CodingKeys: String, CodingKey {
                case name
                case path
                case targetDependencies = "target_dependencies"
                case productDependencies = "product_dependencies"
                case type
            }
        }

        let name: String
        let path: String
        let dependencies: [Dependency]
        let products: [Product]
        let targets: [Target]
    }

    private struct GraphIdentity: Codable {
        let path: String
        let digest: ArtifactDigest
    }

    private struct PackageLocation: Codable, Hashable {
        let identity: String
        let path: String
    }

    private struct DependencyNode: Decodable {
        let identity: String
        let path: String
        let dependencies: [DependencyNode]
    }

    private struct Cache: Codable {
        let identities: [GraphIdentity]
        let locations: [PackageLocation]
        let packages: [Description]
    }

    private let cacheRoot: FilePath
    private let environment: [String: String]
    private let lock = NSLock()
    private var memory: [FilePath: SwiftPackageSourceGraph] = [:]

    package init(
        cacheRoot: FilePath,
        environment: [String: String]
    ) {
        self.cacheRoot = cacheRoot
        self.environment = environment
    }

    package func graph(
        packageRoot: FilePath,
        swiftExecutable: FilePath
    ) throws -> SwiftPackageSourceGraph {
        lock.lock()
        defer { lock.unlock() }
        if let graph = memory[packageRoot] { return graph }

        let cacheFile = cacheRoot.appending(
            ArtifactHasher.digest(bytes: Array(packageRoot.string.utf8)).hexadecimal
                + ".json")
        if let data = try? Data(contentsOf: URL(fileURLWithPath: cacheFile.string)),
            let cache = try? JSONDecoder().decode(Cache.self, from: data),
            try identitiesMatch(cache.identities, packageRoot: packageRoot)
        {
            let graph = try sourceGraph(
                root: packageRoot,
                locations: cache.locations,
                descriptions: cache.packages)
            memory[packageRoot] = graph
            return graph
        }

        let locations = try dependencyLocations(
            packageRoot,
            swift: swiftExecutable)
        let descriptions = try locations.map {
            try describe(FilePath($0.path), swift: swiftExecutable)
        }.sorted { $0.path < $1.path }

        let graph = try sourceGraph(
            root: packageRoot,
            locations: locations,
            descriptions: descriptions)
        var identityPaths = descriptions.map {
            FilePath($0.path).appending("Package.swift")
        }
        for path in [
            packageRoot.appending("Package.resolved"),
            packageRoot.appending(".swiftpm/configuration/mirrors.json"),
        ] where FileManager.default.fileExists(atPath: path.string) {
            identityPaths.append(path)
        }
        let identities = try Set(identityPaths).map {
            GraphIdentity(
                path: $0.string,
                digest: try ArtifactHasher.digest(file: $0))
        }.sorted { $0.path < $1.path }
        try FileManager.default.createDirectory(
            atPath: cacheRoot.string,
            withIntermediateDirectories: true)
        var cacheData = try JSONEncoder.sorted.encode(
            Cache(
                identities: identities,
                locations: locations,
                packages: descriptions))
        cacheData.append(0x0a)
        try cacheData.write(
            to: URL(fileURLWithPath: cacheFile.string),
            options: .atomic)
        memory[packageRoot] = graph
        return graph
    }

    private func identitiesMatch(
        _ identities: [GraphIdentity],
        packageRoot: FilePath
    ) throws -> Bool {
        guard !identities.isEmpty else { return false }
        let cachedPaths = Set(identities.map(\.path))
        for resolutionPath in [
            packageRoot.appending("Package.resolved"),
            packageRoot.appending(".swiftpm/configuration/mirrors.json"),
        ] {
            guard
                FileManager.default.fileExists(atPath: resolutionPath.string)
                    == cachedPaths.contains(resolutionPath.string)
            else { return false }
        }
        for identity in identities {
            let path = FilePath(identity.path)
            guard FileManager.default.fileExists(atPath: path.string),
                try ArtifactHasher.digest(file: path) == identity.digest
            else { return false }
        }
        return true
    }

    private func dependencyLocations(
        _ packageRoot: FilePath,
        swift: FilePath
    ) throws -> [PackageLocation] {
        let data = try runSwiftPackage(
            packageRoot,
            swift: swift,
            arguments: ["show-dependencies", "--format", "json"])
        let root: DependencyNode
        do {
            root = try JSONDecoder().decode(DependencyNode.self, from: data)
        } catch {
            throw SwiftPackageGraphFailure.invalidDependencyGraph(
                packageRoot, error)
        }
        var pathsByIdentity: [String: String] = [:]
        func collect(_ node: DependencyNode) throws {
            if let existing = pathsByIdentity[node.identity],
                existing != node.path
            {
                throw SwiftPackageGraphFailure.ambiguousDependency(
                    node.identity, existing, node.path)
            }
            pathsByIdentity[node.identity] = node.path
            for dependency in node.dependencies {
                try collect(dependency)
            }
        }
        try collect(root)
        return pathsByIdentity.map {
            PackageLocation(identity: $0.key, path: $0.value)
        }.sorted { $0.identity < $1.identity }
    }

    private func describe(
        _ packageRoot: FilePath,
        swift: FilePath
    ) throws -> Description {
        let data = try runSwiftPackage(
            packageRoot,
            swift: swift,
            arguments: ["describe", "--type", "json"])
        do {
            return try JSONDecoder().decode(Description.self, from: data)
        } catch {
            throw SwiftPackageGraphFailure.invalidDescription(packageRoot, error)
        }
    }

    private func runSwiftPackage(
        _ packageRoot: FilePath,
        swift: FilePath,
        arguments: [String]
    ) throws -> Data {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: swift.string)
        process.arguments =
            ["package", "--package-path", packageRoot.string]
            + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: packageRoot.string)
        var processEnvironment = environment
        processEnvironment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = processEnvironment
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw SwiftPackageGraphFailure.couldNotLaunch(swift, error)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SwiftPackageGraphFailure.packageCommandFailed(
                packageRoot,
                String(decoding: errorData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return data
    }

    private func sourceGraph(
        root: FilePath,
        locations: [PackageLocation],
        descriptions: [Description]
    ) throws -> SwiftPackageSourceGraph {
        let canonicalRoot = canonicalPath(root)
        let roots = Set(descriptions.map { canonicalPath(FilePath($0.path)) })
        guard roots.contains(canonicalRoot) else {
            throw SwiftPackageGraphFailure.missingRoot(root)
        }
        let pathByIdentity = Dictionary(
            uniqueKeysWithValues: locations.map {
                ($0.identity, canonicalPath(FilePath($0.path)))
            })
        let descriptionByRoot = Dictionary(
            uniqueKeysWithValues: descriptions.map {
                (canonicalPath(FilePath($0.path)), $0)
            })
        var localRoots: Set<FilePath> = [canonicalRoot]
        var pendingLocalRoots = [canonicalRoot]
        while let packageRoot = pendingLocalRoots.popLast() {
            guard let description = descriptionByRoot[packageRoot] else { continue }
            for dependency in description.dependencies where dependency.type == "fileSystem" {
                guard
                    let dependencyRoot = dependency.path.map({
                        canonicalPath(FilePath($0))
                    }) ?? pathByIdentity[dependency.identity],
                    localRoots.insert(dependencyRoot).inserted
                else { continue }
                pendingLocalRoots.append(dependencyRoot)
            }
        }
        return SwiftPackageSourceGraph(
            root: canonicalRoot,
            packages: descriptions.map { description in
                let packageRoot = canonicalPath(FilePath(description.path))
                let dependencyRoots = description.dependencies.compactMap { dependency in
                    if let path = dependency.path {
                        return canonicalPath(FilePath(path))
                    }
                    return pathByIdentity[dependency.identity]
                }
                return SwiftPackageSourceGraph.Package(
                    identity: description.name,
                    root: packageRoot,
                    isLocal: localRoots.contains(packageRoot),
                    dependencyRoots: dependencyRoots,
                    products: description.products.map {
                        SwiftPackageSourceGraph.Product(
                            name: $0.name,
                            targets: $0.targets)
                    },
                    targets: description.targets.map { target in
                        let targetPath = FilePath(target.path)
                        return SwiftPackageSourceGraph.Target(
                            name: target.name,
                            path: targetPath.isAbsolute
                                ? canonicalPath(targetPath)
                                : canonicalPath(
                                    packageRoot.appending(targetPath.components)),
                            targetDependencies: target.targetDependencies ?? [],
                            productDependencies: target.productDependencies ?? [],
                            isTest: target.type == "test")
                    })
            })
    }
}

private func canonicalPath(_ path: FilePath) -> FilePath {
    FilePath(
        URL(fileURLWithPath: path.string).resolvingSymlinksInPath().path
    ).lexicallyNormalized()
}

package enum SwiftPackageGraphFailure: Error, CustomStringConvertible {
    case couldNotLaunch(FilePath, any Error)
    case packageCommandFailed(FilePath, String)
    case invalidDescription(FilePath, any Error)
    case invalidDependencyGraph(FilePath, any Error)
    case missingRoot(FilePath)
    case ambiguousDependency(String, String, String)

    package var description: String {
        switch self {
        case .couldNotLaunch(let swift, let error):
            "could not launch SwiftPM graph materialization with \(swift): \(error)"
        case .packageCommandFailed(let root, let message):
            "SwiftPM package graph command failed for \(root): \(message)"
        case .invalidDescription(let root, let error):
            "SwiftPM returned an invalid package description for \(root): \(error)"
        case .invalidDependencyGraph(let root, let error):
            "SwiftPM returned an invalid dependency graph for \(root): \(error)"
        case .missingRoot(let root):
            "SwiftPM package graph is missing root \(root)"
        case .ambiguousDependency(let identity, let first, let second):
            "SwiftPM dependency \(identity) resolves to both \(first) and \(second)"
        }
    }
}
