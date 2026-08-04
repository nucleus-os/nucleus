import ColliderCore
import ColliderSwiftPM
import SystemPackage
import Testing

private let root = FilePath("/workspace")
private let invocation = SwiftPMInvocation(
    context: SwiftBuildContext(
        packageRoot: root,
        configuration: .debug,
        target: .host(identity: "arm64-macos"),
        toolchainIdentity: "fixture"),
    scratchPath: root.appending(".build"))

private let builder = SwiftPackageRequirementBuilder(
    component: ComponentID(rawValue: "core"),
    package: "core",
    packageRoot: root.appending("core"),
    sourceTrees: [root.appending("core/swift")],
    testTrees: [root.appending("core/Tests")],
    lock: .checkout("core"),
    invocation: invocation,
    environment: [:])

@Test func swiftPackageBuilderDeclaresBuildWithoutArgumentSentinels() {
    let task = builder.build(
        id: TaskID(rawValue: "core.build"),
        products: ["Nucleus"])

    #expect(task.swiftProducts.map(\.product) == ["Nucleus"])
    #expect(task.swiftTests.isEmpty)
    #expect(task.operation == .sequence([]))
    #expect(task.inputs.contains(.tree(root.appending("core/swift"))))
}

@Test func swiftPackageBuilderDeclaresTestAndExplicitSubsumption() {
    let buildID = TaskID(rawValue: "core.build")
    let task = builder.test(
        id: TaskID(rawValue: "core.test"),
        testProduct: "CorePackageTests",
        dependencies: [buildID],
        subsumedBuild: buildID,
        arguments: ["--filter", "smoke"])

    #expect(task.swiftProducts.isEmpty)
    #expect(task.swiftTests.map(\.testProduct) == ["CorePackageTests"])
    #expect(task.dependencies == [buildID])
    #expect(task.subsumedDependencies == [buildID])
    #expect(task.inputs.contains(.tree(root.appending("core/Tests"))))
}
