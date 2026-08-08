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

    #expect(inputs.contains(.file(root.appending("Package.swift"))))
    #expect(sourcePaths.contains(root.appending("domains/app")))
    #expect(sourcePaths.contains(root.appending("domains/shared")))
    #expect(inputs.contains(.file(dependency.appending("Package.swift"))))
    #expect(sourcePaths.contains(dependency.appending("Sources/Library")))
    #expect(!sourcePaths.contains(root.appending("domains/unrelated")))
    #expect(!sourcePaths.contains(root.appending("tests/app")))
    #expect(!sourcePaths.contains(root))
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
