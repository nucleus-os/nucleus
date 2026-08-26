import SystemPackage

/// The manifest-resolved source ownership graph for one Swift package and its
/// local package dependencies.
///
/// Recipes name products and tests. This graph translates those selections
/// into the target directories SwiftPM actually owns, without assuming the
/// conventional `Sources` and `Tests` layout or duplicating manifest paths in
/// recipes.
public struct SwiftPackageSourceGraph: Hashable, Sendable {
    public struct Product: Hashable, Sendable {
        public let name: String
        public let targets: [String]

        public init(name: String, targets: [String]) {
            self.name = name
            self.targets = targets.sorted()
        }
    }

    public struct Target: Hashable, Sendable {
        public let name: String
        public let path: FilePath
        public let targetDependencies: [String]
        public let productDependencies: [String]
        public let isTest: Bool
        /// Directories the manifest tells the compiler to search for this
        /// target's headers, resolved against the target that declares them.
        public let headerSearchPaths: [FilePath]

        public init(
            name: String,
            path: FilePath,
            targetDependencies: [String] = [],
            productDependencies: [String] = [],
            isTest: Bool = false,
            headerSearchPaths: [FilePath] = []
        ) {
            self.name = name
            self.path = path
            self.targetDependencies = targetDependencies.sorted()
            self.productDependencies = productDependencies.sorted()
            self.isTest = isTest
            self.headerSearchPaths = headerSearchPaths.sorted {
                $0.string < $1.string
            }
        }
    }

    public struct Package: Hashable, Sendable {
        public let identity: String
        public let root: FilePath
        public let isLocal: Bool
        public let dependencyRoots: [FilePath]
        public let products: [Product]
        public let targets: [Target]

        public init(
            identity: String,
            root: FilePath,
            isLocal: Bool = true,
            dependencyRoots: [FilePath] = [],
            products: [Product],
            targets: [Target]
        ) {
            self.identity = identity
            self.root = root
            self.isLocal = isLocal
            self.dependencyRoots = dependencyRoots.sorted {
                $0.string < $1.string
            }
            self.products = products.sorted { $0.name < $1.name }
            self.targets = targets.sorted { $0.name < $1.name }
        }
    }

    private enum Storage: Hashable, Sendable {
        case resolved(root: FilePath, packages: [Package])
        case packageWide([ArtifactInput])
    }

    private let storage: Storage

    public init(root: FilePath, packages: [Package]) {
        precondition(
            packages.contains { $0.root == root },
            "Swift package source graph is missing its root package")
        storage = .resolved(
            root: root,
            packages: packages.sorted { $0.root.string < $1.root.string })
    }

    /// The whole package, for an invocation with no resolved manifest graph.
    /// The pinned SwiftPM overlay builds this way, because resolving a graph
    /// needs the SwiftPM that build produces.
    ///
    /// The package is named as a source checkout rather than as a directory
    /// tree. A tree digest is every byte under the root, which for a package
    /// inside a working copy includes the repository database and whatever
    /// build residue Git is ignoring, so the same commit hashes differently
    /// depending on how its checkout was materialized. Git already identifies
    /// exactly the source, and it is the same identity the working-copy
    /// contract uses everywhere else.
    public static func packageWide(_ packageRoot: FilePath) -> Self {
        Self(
            storage: .packageWide([
                .file(packageRoot.appending("Package.swift")),
                .sourceCheckout(packageRoot),
            ]))
    }

    private init(storage: Storage) {
        self.storage = storage
    }

    public func inputs(forProduct productName: String) -> [ArtifactInput] {
        switch storage {
        case .packageWide(let inputs):
            return inputs
        case .resolved(let root, let packages):
            let packageByRoot = Dictionary(
                uniqueKeysWithValues: packages.map { ($0.root, $0) })
            guard let rootPackage = packageByRoot[root],
                let product = rootPackage.products.first(where: {
                    $0.name == productName
                })
            else {
                preconditionFailure(
                    "Swift package graph has no product named \(productName)")
            }
            return inputs(
                roots: product.targets.map { (root, $0) },
                packageByRoot: packageByRoot)
        }
    }

    /// Git-owned paths that contribute source bytes to one product. This is
    /// the source-closure boundary for product provenance; generated build
    /// state, tool identities, and dependency locks remain separate inputs.
    public func sourcePaths(forProduct productName: String) -> [FilePath] {
        switch storage {
        case .packageWide(let inputs):
            return inputs.flatMap { input -> [FilePath] in
                switch input {
                case .file(let path), .tree(let path), .sourceCheckout(let path):
                    [path]
                case .sourceCheckoutClosure(let paths):
                    paths
                case .value, .string, .environment, .swiftBuildContext, .tool:
                    []
                }
            }
        case .resolved(let root, let packages):
            let packageByRoot = Dictionary(
                uniqueKeysWithValues: packages.map { ($0.root, $0) })
            guard let rootPackage = packageByRoot[root],
                let product = rootPackage.products.first(where: {
                    $0.name == productName
                })
            else {
                preconditionFailure(
                    "Swift package graph has no product named \(productName)")
            }
            struct TargetID: Hashable {
                let packageRoot: FilePath
                let name: String
            }
            var visited: Set<TargetID> = []
            var paths: Set<FilePath> = []

            func visitProduct(_ name: String, from package: Package) {
                let candidates = package.dependencyRoots.compactMap { dependencyRoot in
                    packageByRoot[dependencyRoot].flatMap { dependency in
                        dependency.products.first(where: { $0.name == name }).map {
                            (dependency, $0)
                        }
                    }
                }
                precondition(
                    candidates.count == 1,
                    "Swift package graph cannot uniquely resolve product \(name) from \(package.identity)"
                )
                for target in candidates[0].1.targets {
                    visitTarget(target, in: candidates[0].0)
                }
            }

            func visitTarget(_ name: String, in package: Package) {
                let id = TargetID(packageRoot: package.root, name: name)
                guard visited.insert(id).inserted else { return }
                guard let target = package.targets.first(where: { $0.name == name }) else {
                    preconditionFailure(
                        "Swift package graph has no target \(name) in \(package.identity)")
                }
                if package.isLocal {
                    paths.insert(package.root.appending("Package.swift"))
                    paths.insert(target.path)
                }
                for dependency in target.targetDependencies {
                    visitTarget(dependency, in: package)
                }
                for dependency in target.productDependencies {
                    visitProduct(dependency, from: package)
                }
            }

            for target in product.targets {
                visitTarget(target, in: rootPackage)
            }
            return paths.sorted { $0.string < $1.string }
        }
    }

    /// Every directory the graph names as a target's source.
    ///
    /// `inputs(forProduct:)` answers for one product, which is what provenance
    /// needs. A build environment is established once and reused across the
    /// products it builds, so it needs the union: what any product might read
    /// rather than what one does.
    ///
    /// The union stops at a dependency's tests, which no product and no test
    /// of this package compiles.
    public var targetRoots: [FilePath] {
        switch storage {
        case .packageWide(let inputs):
            return inputs.compactMap { input in
                switch input {
                case .tree(let path), .sourceCheckout(let path): path
                case .file, .sourceCheckoutClosure, .value, .string, .environment,
                    .swiftBuildContext, .tool:
                    nil
                }
            }
        case .resolved(let root, let packages):
            var roots: Set<FilePath> = []
            for package in packages {
                for target in package.targets {
                    // A package manager builds only the root package's tests,
                    // so a dependency's test target is source that nothing in
                    // this graph ever compiles.
                    if target.isTest && package.root != root { continue }
                    roots.insert(target.path)
                }
            }
            return roots.sorted { $0.string < $1.string }
        }
    }

    /// Every directory a target's settings name as a header search path.
    ///
    /// Separate from `targetRoots` because such a path may leave the target
    /// that declares it: `TracyBridge` reaches
    /// `swift-tracy/third-party/tracy/public`, so a set derived from target
    /// directories alone omits a directory the compiler is told to read and
    /// the build fails on a header it was pointed at. Taken exactly rather
    /// than widened, for the same reason a vendored include root is: the path
    /// names what it needs inside a tree that is mostly not that.
    public var headerSearchRoots: [FilePath] {
        switch storage {
        case .packageWide:
            return []
        case .resolved(_, let packages):
            var roots: Set<FilePath> = []
            for package in packages {
                for target in package.targets {
                    roots.formUnion(target.headerSearchPaths)
                }
            }
            return roots.sorted { $0.string < $1.string }
        }
    }

    /// The manifest of every package in the graph.
    ///
    /// Separate from `targetRoots` because a manifest is a file beside a
    /// package's other contents rather than a directory of source: a consumer
    /// widening a target directory must not widen a manifest into the package
    /// root it sits in.
    public var manifestPaths: [FilePath] {
        switch storage {
        case .packageWide(let inputs):
            return inputs.compactMap { input in
                if case .file(let path) = input { path } else { nil }
            }
        case .resolved(_, let packages):
            return packages.map { $0.root.appending("Package.swift") }
                .sorted { $0.string < $1.string }
        }
    }

    public var testInputs: [ArtifactInput] {
        switch storage {
        case .packageWide(let inputs):
            return inputs
        case .resolved(let root, let packages):
            let packageByRoot = Dictionary(
                uniqueKeysWithValues: packages.map { ($0.root, $0) })
            guard let rootPackage = packageByRoot[root] else {
                preconditionFailure("Swift package graph has no root package")
            }
            return inputs(
                roots: rootPackage.targets.filter(\.isTest).map {
                    (root, $0.name)
                },
                packageByRoot: packageByRoot)
        }
    }

    private func inputs(
        roots: [(FilePath, String)],
        packageByRoot: [FilePath: Package]
    ) -> [ArtifactInput] {
        struct TargetID: Hashable {
            let packageRoot: FilePath
            let name: String
        }

        var visited: Set<TargetID> = []
        var manifestInputs: Set<ArtifactInput> = []
        var sourcePathsByPackage: [FilePath: Set<FilePath>] = [:]

        func visitProduct(_ name: String, from package: Package) {
            let candidates = package.dependencyRoots.compactMap { dependencyRoot in
                packageByRoot[dependencyRoot].flatMap { dependency in
                    dependency.products.first(where: { $0.name == name }).map {
                        (dependency, $0)
                    }
                }
            }
            precondition(
                candidates.count == 1,
                "Swift package graph cannot uniquely resolve product \(name) from \(package.identity)"
            )
            for target in candidates[0].1.targets {
                visitTarget(target, in: candidates[0].0)
            }
        }

        func visitTarget(_ name: String, in package: Package) {
            let id = TargetID(packageRoot: package.root, name: name)
            guard visited.insert(id).inserted else { return }
            guard let target = package.targets.first(where: { $0.name == name }) else {
                preconditionFailure(
                    "Swift package graph has no target \(name) in \(package.identity)")
            }
            manifestInputs.insert(.file(package.root.appending("Package.swift")))
            sourcePathsByPackage[package.root, default: []].insert(target.path)
            for dependency in target.targetDependencies {
                visitTarget(dependency, in: package)
            }
            for dependency in target.productDependencies {
                visitProduct(dependency, from: package)
            }
        }

        for (packageRoot, target) in roots.sorted(by: {
            ($0.0.string, $0.1) < ($1.0.string, $1.1)
        }) {
            guard let package = packageByRoot[packageRoot] else {
                preconditionFailure(
                    "Swift package graph has no package at \(packageRoot)")
            }
            visitTarget(target, in: package)
        }
        let sourceInputs = sourcePathsByPackage.map { packageRoot, paths in
            ArtifactInput.sourceCheckoutClosure(
                paths.sorted { $0.string < $1.string })
        }
        return (Array(manifestInputs) + sourceInputs).sorted {
            inputSortKey($0) < inputSortKey($1)
        }
    }
}

private func inputSortKey(_ input: ArtifactInput) -> String {
    switch input {
    case .file(let path): "file:\(path)"
    case .sourceCheckout(let path): "source:\(path)"
    case .sourceCheckoutClosure(let paths):
        "source-closure:" + paths.map(\.string).joined(separator: "\0")
    default: String(describing: input)
    }
}
