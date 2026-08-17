import SystemPackage
import Testing

@testable import ColliderCore

@Test
func productInputsFollowTheTransitiveManifestTargetGraph() {
    let root = FilePath("/workspace")
    let dependency = root.appending("third-party/dependency")
    let graph = fixtureGraph(root: root, dependency: dependency)

    let inputs = Set(graph.inputs(forProduct: "App"))
    let sourcePaths = sourcePaths(in: inputs)
    let productSourcePaths = Set(graph.sourcePaths(forProduct: "App"))

    #expect(inputs.contains(.file(root.appending("Package.swift"))))
    #expect(sourcePaths.contains(root.appending("domains/app")))
    #expect(sourcePaths.contains(root.appending("domains/shared")))
    #expect(inputs.contains(.file(dependency.appending("Package.swift"))))
    #expect(sourcePaths.contains(dependency.appending("Sources/Library")))
    #expect(!sourcePaths.contains(root.appending("domains/unrelated")))
    #expect(!sourcePaths.contains(root.appending("tests/app")))
    #expect(!sourcePaths.contains(root))
    #expect(
        productSourcePaths
            == sourcePaths.union([
                root.appending("Package.swift"),
                dependency.appending("Package.swift"),
            ]))
}

@Test
func productSourcePathsExcludeSourceControlDependencyCheckouts() {
    let root = FilePath("/workspace")
    let external = root.appending(".build/checkouts/external")
    let graph = SwiftPackageSourceGraph(
        root: root,
        packages: [
            SwiftPackageSourceGraph.Package(
                identity: "workspace",
                root: root,
                dependencyRoots: [external],
                products: [
                    SwiftPackageSourceGraph.Product(name: "App", targets: ["App"])
                ],
                targets: [
                    SwiftPackageSourceGraph.Target(
                        name: "App",
                        path: root.appending("Sources/App"),
                        productDependencies: ["External"])
                ]),
            SwiftPackageSourceGraph.Package(
                identity: "external",
                root: external,
                isLocal: false,
                products: [
                    SwiftPackageSourceGraph.Product(
                        name: "External",
                        targets: ["External"])
                ],
                targets: [
                    SwiftPackageSourceGraph.Target(
                        name: "External",
                        path: external.appending("Sources/External"))
                ]),
        ])

    let buildInputs = sourcePaths(in: Set(graph.inputs(forProduct: "App")))
    let provenancePaths = Set(graph.sourcePaths(forProduct: "App"))

    #expect(buildInputs.contains(external.appending("Sources/External")))
    #expect(!provenancePaths.contains(external.appending("Package.swift")))
    #expect(!provenancePaths.contains(external.appending("Sources/External")))
    #expect(provenancePaths.contains(root.appending("Package.swift")))
    #expect(provenancePaths.contains(root.appending("Sources/App")))
}

@Test
func testInputsFollowEveryRootTestTargetAndItsDependencies() {
    let root = FilePath("/workspace")
    let dependency = root.appending("third-party/dependency")
    let graph = fixtureGraph(root: root, dependency: dependency)

    let inputs = Set(graph.testInputs)
    let sourcePaths = sourcePaths(in: inputs)

    #expect(sourcePaths.contains(root.appending("tests/app")))
    #expect(sourcePaths.contains(root.appending("domains/app")))
    #expect(sourcePaths.contains(root.appending("domains/shared")))
    #expect(sourcePaths.contains(dependency.appending("Sources/Library")))
    #expect(!sourcePaths.contains(root.appending("domains/unrelated")))
    #expect(!sourcePaths.contains(root))
}

private func sourcePaths(
    in inputs: Set<ArtifactInput>
) -> Set<FilePath> {
    Set(
        inputs.flatMap { input -> [FilePath] in
            guard case .sourceCheckoutClosure(let paths) = input else { return [] }
            return paths
        })
}

private func fixtureGraph(
    root: FilePath,
    dependency: FilePath
) -> SwiftPackageSourceGraph {
    SwiftPackageSourceGraph(
        root: root,
        packages: [
            SwiftPackageSourceGraph.Package(
                identity: "workspace",
                root: root,
                dependencyRoots: [dependency],
                products: [
                    SwiftPackageSourceGraph.Product(
                        name: "App",
                        targets: ["App"]),
                    SwiftPackageSourceGraph.Product(
                        name: "Unrelated",
                        targets: ["Unrelated"]),
                ],
                targets: [
                    SwiftPackageSourceGraph.Target(
                        name: "App",
                        path: root.appending("domains/app"),
                        targetDependencies: ["Shared"],
                        productDependencies: ["Library"]),
                    SwiftPackageSourceGraph.Target(
                        name: "Shared",
                        path: root.appending("domains/shared")),
                    SwiftPackageSourceGraph.Target(
                        name: "Unrelated",
                        path: root.appending("domains/unrelated")),
                    SwiftPackageSourceGraph.Target(
                        name: "AppTests",
                        path: root.appending("tests/app"),
                        targetDependencies: ["App"],
                        isTest: true),
                ]),
            SwiftPackageSourceGraph.Package(
                identity: "dependency",
                root: dependency,
                products: [
                    SwiftPackageSourceGraph.Product(
                        name: "Library",
                        targets: ["Library"])
                ],
                targets: [
                    SwiftPackageSourceGraph.Target(
                        name: "Library",
                        path: dependency.appending("Sources/Library"))
                ]),
        ])
}
