import ColliderCore
import ColliderPersistence
import ColliderProcess
import Foundation
import Synchronization
import SystemPackage

/// Materializes SwiftPM's package graph on the host and retains it until one
/// of the files that determine package structure or dependency resolution
/// changes.
package final class SwiftPackageGraphResolver: Sendable {
    private struct Description: Codable {
        struct Dependency: Codable {
            let identity: String
            let path: String?
            let type: String
        }

        struct Product: Codable {
            let name: String
            let targets: [String]
            let type: [String: [String]?]
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
        /// The scratch these locations were resolved against. Dependency
        /// checkout paths point into it, so a cache resolved against a
        /// differently named scratch describes packages that are no longer
        /// where it says they are.
        let resolution: String
        let identities: [GraphIdentity]
        let locations: [PackageLocation]
        let packages: [Description]
        /// Cache evaluation, never its semantic projection. Every read applies
        /// the current projection so resolver changes cannot reuse stale keys.
        let evaluatedManifests: [String: Data]
    }

    struct ManifestConfiguration: Codable {
        let package: String
        let targets: [String: String]
        let products: [String: String]
        let headerSearchPaths: [String: [String]]
    }

    private let cacheRoot: FilePath
    private let identityPathMap: IdentityPathMap
    private let environment: [String: String]
    private let memory = GraphMemory()

    /// Materializes one package root exactly once, even when two callers ask
    /// at the same time.
    ///
    /// A mutex held across the whole materialization gave that property while
    /// describing a package was synchronous. It suspends now, so what callers
    /// share is the in-flight materialization rather than the lock. A failed
    /// one is dropped so a later caller retries instead of inheriting it,
    /// which is what the mutex did by only recording successes.
    private actor GraphMemory {
        private var materializations: [FilePath: Task<SwiftPackageSourceGraph, any Error>] = [:]

        func graph(
            for packageRoot: FilePath,
            materialize:
                @Sendable @escaping () async throws ->
                SwiftPackageSourceGraph
        ) async throws -> SwiftPackageSourceGraph {
            if let existing = materializations[packageRoot] {
                return try await existing.value
            }
            let materialization = Task { try await materialize() }
            materializations[packageRoot] = materialization
            do {
                return try await materialization.value
            } catch {
                materializations[packageRoot] = nil
                throw error
            }
        }
    }

    package init(
        cacheRoot: FilePath,
        environment: [String: String],
        identityPathMap: IdentityPathMap = .empty
    ) {
        self.cacheRoot = cacheRoot
        self.environment = environment
        self.identityPathMap = identityPathMap
    }

    /// The name one package's resolution state is filed under.
    ///
    /// A package is named by where it is, which is placement, so the raw path
    /// gives one package two names across two checkouts. SwiftPM then resolves
    /// each into its own scratch, and the dependency checkouts it materializes
    /// there are build inputs, so identical source planned differently.
    /// Resolving the name through the declared roots gives one package one
    /// scratch, which both checkouts share.
    package func resolutionKey(_ packageRoot: FilePath) -> String {
        ArtifactDigest.sha256(
            Array(identityPathMap.canonicalize(packageRoot.string).utf8)
        ).hexadecimal
    }

    package func graph(
        packageRoot: FilePath,
        swiftExecutable: FilePath
    ) async throws -> SwiftPackageSourceGraph {
        try await memory.graph(for: packageRoot) {
            try await self.materialize(
                packageRoot: packageRoot,
                swiftExecutable: swiftExecutable)
        }
    }

    private func materialize(
        packageRoot: FilePath,
        swiftExecutable: FilePath
    ) async throws -> SwiftPackageSourceGraph {
        // Filed under this workspace's own name, not the canonical one: the
        // cache records absolute paths, so a second checkout reading it would
        // find descriptions for a root it does not have.
        let cacheFile = cacheRoot.appending(
            ArtifactHasher.digest(bytes: Array(packageRoot.string.utf8)).hexadecimal
                + ".json")
        if let data = try? Data(contentsOf: URL(fileURLWithPath: cacheFile.string)),
            let cache = try? JSONDecoder().decode(Cache.self, from: data),
            cache.resolution == resolutionKey(packageRoot),
            try identitiesMatch(cache.identities, packageRoot: packageRoot)
        {
            var manifests: [String: ManifestConfiguration] = [:]
            for (path, data) in cache.evaluatedManifests {
                manifests[path] = try Self.parsedManifestConfiguration(
                    data, packageRoot: FilePath(path))
            }
            let graph = try sourceGraph(
                root: packageRoot,
                locations: cache.locations,
                descriptions: cache.packages,
                manifests: manifests)
            return graph
        }

        let locations = try await dependencyLocations(
            packageRoot,
            swift: swiftExecutable)
        var described: [Description] = []
        var manifests: [String: ManifestConfiguration] = [:]
        var evaluatedManifests: [String: Data] = [:]
        for location in locations {
            let location = FilePath(location.path)
            described.append(try await describe(location, swift: swiftExecutable))
            let data = try await runSwiftPackage(
                location, swift: swiftExecutable, arguments: ["dump-package"])
            evaluatedManifests[location.string] = data
            manifests[location.string] = try Self.parsedManifestConfiguration(
                data, packageRoot: location)
        }
        let descriptions = described.sorted { $0.path < $1.path }

        let graph = try sourceGraph(
            root: packageRoot,
            locations: locations,
            descriptions: descriptions,
            manifests: manifests)
        var identityPaths = descriptions.map {
            FilePath($0.path).appending("Package.swift")
        }
        for path in [
            packageRoot.appending("Package.resolved"),
            swiftPMMirrorConfiguration(under: packageRoot),
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
                resolution: resolutionKey(packageRoot),
                identities: identities,
                locations: locations,
                packages: descriptions,
                evaluatedManifests: evaluatedManifests))
        cacheData.append(0x0a)
        try cacheData.write(
            to: URL(fileURLWithPath: cacheFile.string),
            options: .atomic)
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
            swiftPMMirrorConfiguration(under: packageRoot),
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
    ) async throws -> [PackageLocation] {
        let data = try await runSwiftPackage(
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

    /// The manifest's own view of a package, which is the only place build
    /// settings appear. `describe` reports structure and omits them.
    private struct Manifest: Decodable {
        struct Target: Decodable {
            struct Setting: Decodable {
                struct Kind: Decodable {
                    struct HeaderSearchPath: Decodable {
                        let path: String

                        enum CodingKeys: String, CodingKey {
                            case path = "_0"
                        }
                    }

                    let headerSearchPath: HeaderSearchPath?
                }

                let kind: Kind
            }

            let name: String
            let settings: [Setting]?
        }

        let targets: [Target]
    }

    private func describe(
        _ packageRoot: FilePath,
        swift: FilePath
    ) async throws -> Description {
        let data = try await runSwiftPackage(
            packageRoot,
            swift: swift,
            arguments: ["describe", "--type", "json"])
        do {
            return try JSONDecoder().decode(Description.self, from: data)
        } catch {
            throw SwiftPackageGraphFailure.invalidDescription(packageRoot, error)
        }
    }

    /// Evaluated package-wide semantics and independently selectable target
    /// and product declarations. `describe` still resolves their source paths.
    static func parsedManifestConfiguration(_ data: Data, packageRoot: FilePath) throws
        -> ManifestConfiguration
    {
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            throw SwiftPackageGraphFailure.invalidDescription(packageRoot, error)
        }
        let headerSearchPaths = manifest.targets.reduce(into: [String: [String]]()) {
            result, target in
            let paths = (target.settings ?? []).compactMap {
                $0.kind.headerSearchPath?.path
            }
            if !paths.isEmpty { result[target.name] = paths }
        }
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let targets = object.removeValue(forKey: "targets") as? [[String: Any]],
            let products = object.removeValue(forKey: "products") as? [[String: Any]]
        else {
            throw SwiftPackageGraphFailure.invalidDescription(
                packageRoot,
                SwiftManifestIdentityFailure("manifest has no target/product arrays"))
        }
        // Dependency declarations select graph nodes; the visited products and
        // their source closures identify those nodes. Unvisited dependencies
        // and targets do not contribute to a selected product's semantics.
        object.removeValue(forKey: "dependencies")
        // PackageKind describes how SwiftPM located this package and embeds
        // its absolute checkout path. It is not compiler configuration; graph
        // edges and selected source closures already identify the package.
        object.removeValue(forKey: "packageKind")
        func canonical(_ value: Any) throws -> String {
            let bytes = try JSONSerialization.data(
                withJSONObject: value,
                options: [.sortedKeys, .withoutEscapingSlashes])
            return String(decoding: bytes, as: UTF8.self)
        }
        func named(_ values: [[String: Any]]) throws -> [String: String] {
            var result: [String: String] = [:]
            for value in values {
                guard let name = value["name"] as? String, result[name] == nil else {
                    throw SwiftManifestIdentityFailure("manifest declarations require unique names")
                }
                result[name] = try canonical(value)
            }
            return result
        }
        return ManifestConfiguration(
            package: try canonical(object),
            targets: try named(targets), products: try named(products),
            headerSearchPaths: headerSearchPaths)
    }

    /// Was in the deadlock class: standard output was read to end of file
    /// before standard error, so a SwiftPM run that filled standard error with
    /// diagnostics would have stalled against a parent not yet reading it.
    private func runSwiftPackage(
        _ packageRoot: FilePath,
        swift: FilePath,
        arguments: [String]
    ) async throws -> Data {
        // Describing a package makes SwiftPM materialize workspace state, and
        // without a scratch path it writes `.build` beside the manifest. The
        // packages described here are vendored inside the checkout, which the
        // identity that builds may only read, so the scratch belongs in the
        // cache. One directory per package: SwiftPM treats a scratch path as
        // belonging to a single workspace.
        let scratch = cacheRoot.appending(
            "package-graph/scratch/" + resolutionKey(packageRoot))
        let packageGraphCache = cacheRoot.appending("package-graph/cache")
        let packageArguments =
            [
                "package", "--package-path", packageRoot.string,
                "--scratch-path", scratch.string,
                // Directed, as every other SwiftPM invocation Collider makes
                // directs it. Left out, SwiftPM's manifest cache follows the
                // environment's home, so a caller that relocates home -- which
                // the storage-ownership tests do deliberately -- recompiles
                // every manifest in the closure. One cache for every package
                // described here, because that is what a manifest cache is for.
                "--cache-path", packageGraphCache.string,
                // The pinned closure is authoritative and lives in a checkout
                // the resolving identity may only read. Left to solve versions
                // itself, SwiftPM rewrites the resolved file whenever a
                // manifest changes, which fails there and leaves no identity
                // able to resolve at all: the builder cannot write the
                // checkout, and the account that owns the checkout cannot
                // write this cache. A genuine dependency change is an explicit
                // update to the pin, not a side effect of describing a graph.
                "--only-use-versions-from-resolved-file",
            ]
            + arguments
        var packageEnvironment = environment
        packageEnvironment["GIT_TERMINAL_PROMPT"] = "0"
        let capture: CapturedChildProcess.Capture
        do {
            capture = try await CapturedChildProcess.capture(
                executable: swift,
                arguments: packageArguments,
                workingDirectory: packageRoot,
                environment: packageEnvironment)
        } catch {
            throw SwiftPackageGraphFailure.couldNotLaunch(swift, error)
        }
        guard capture.status == 0 else {
            throw SwiftPackageGraphFailure.packageCommandFailed(
                packageRoot,
                capture.standardErrorText)
        }
        return Data(capture.standardOutput)
    }

    private func sourceGraph(
        root: FilePath,
        locations: [PackageLocation],
        descriptions: [Description],
        manifests: [String: ManifestConfiguration]
    ) throws -> SwiftPackageSourceGraph {
        let canonicalPath = CanonicalPathCache()
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
            packages: try descriptions.map { description in
                let packageRoot = canonicalPath(FilePath(description.path))
                guard let manifest = manifests[description.path] else {
                    throw SwiftManifestIdentityFailure(
                        "missing evaluated manifest for \(description.path)")
                }
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
                    products: try description.products.map {
                        // SwiftPM also synthesizes products (for example for
                        // executable targets). Their resolved description is
                        // authoritative when no manifest product declares them.
                        let configuration =
                            try manifest.products[$0.name]
                            ?? String(decoding: JSONEncoder.sorted.encode($0), as: UTF8.self)
                        return SwiftPackageSourceGraph.Product(
                            name: $0.name,
                            targets: $0.targets, manifestConfiguration: configuration)
                    },
                    targets: try description.targets.map { target in
                        let configuration = try Self.targetConfiguration(
                            name: target.name, type: target.type,
                            declared: manifest.targets[target.name],
                            resolved: JSONEncoder.sorted.encode(target), packageRoot: packageRoot)
                        let targetPath = FilePath(target.path)
                        let resolved =
                            targetPath.isAbsolute
                            ? canonicalPath(targetPath)
                            : canonicalPath(
                                packageRoot.appending(targetPath.components))
                        return SwiftPackageSourceGraph.Target(
                            name: target.name,
                            path: resolved,
                            targetDependencies: target.targetDependencies ?? [],
                            productDependencies: target.productDependencies ?? [],
                            isTest: target.type == "test",
                            headerSearchPaths: (manifest.headerSearchPaths[target.name] ?? []).map {
                                canonicalPath(
                                    resolved.appending(FilePath($0).components))
                            }, manifestConfiguration: configuration)
                    }, manifestConfiguration: manifest.package)
            })
    }

    static func targetConfiguration(
        name: String, type: String, declared: String?,
        resolved: Data, packageRoot: FilePath
    ) throws -> String {
        if let declared { return declared }
        // SwiftPM creates one executable target per Snippets/*.swift file;
        // these have no manifest declaration. Their resolved description and
        // source closure are their complete configuration.
        guard type == "snippet" else {
            throw SwiftManifestIdentityFailure(
                "missing target semantics for \(name) (\(type)) in \(packageRoot)")
        }
        return String(decoding: resolved, as: UTF8.self)
    }
}

/// Resolves a path's symbolic links, remembering what it resolved.
///
/// `resolvingSymlinksInPath` stats every component of every path it is given,
/// and reconstructing a package graph asks about the same paths repeatedly: a
/// package root, then each of its targets beneath that root, then the header
/// search paths beneath those. Across seventy-odd packages that is thousands of
/// walks over a few dozen distinct directories. Resolution depends only on the
/// filesystem, which does not change while one graph is being built, so the
/// answers are shared for the duration of one reconstruction.
private struct SwiftManifestIdentityFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private final class CanonicalPathCache {
    private var resolved: [FilePath: FilePath] = [:]

    func callAsFunction(_ path: FilePath) -> FilePath {
        if let existing = resolved[path] { return existing }
        let result = FilePath(
            URL(fileURLWithPath: path.string).resolvingSymlinksInPath().path
        ).lexicallyNormalized()
        resolved[path] = result
        return result
    }
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
