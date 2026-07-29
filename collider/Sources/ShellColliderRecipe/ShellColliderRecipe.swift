import ColliderCore
import SystemPackage

public enum ShellColliderRecipe {
    public static func build(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) -> TaskDeclaration {
        let workspace = root.removingLastComponent()
        let shellKit = root.appending("shell-kit")
        let authWire = root.appending("auth-wire")
        let windowClient = workspace.appending("window-client")
        let desktop = workspace.appending("desktop")
        let validator = workspace.appending(
            "tools/validate-runtime-elf.sh")
        let manifest = swiftPM.configurationProducts.appending(
            "runtime-elf-ownership.tsv")
        return TaskDeclaration(
            id: TaskID(rawValue: "shell.build"),
            component: ComponentID(rawValue: "shell"),
            dependencies: [TaskID(rawValue: "compositor.build")],
            swiftProducts: [
                swiftPM.product(
                    package: "shell",
                    product: "NucleusShell",
                    packageRoot: root,
                    environment: environment,
                    expectedOutputs: [
                        PathPostcondition(
                            path: swiftPM.executable("NucleusShell"),
                            validation: .executableFile)
                    ]),
                swiftPM.product(
                    package: "shell",
                    product: "NucleusShellPamHelper",
                    packageRoot: root,
                    environment: environment,
                    expectedOutputs: [
                        PathPostcondition(
                            path: swiftPM.executable("NucleusShellPamHelper"),
                            validation: .executableFile)
                    ]),
            ],
            inputs: [
                .tree(root.appending("Sources")),
                .tree(shellKit.appending("Sources")),
                .tree(authWire.appending("Sources")),
                .tree(windowClient.appending("Sources")),
                .tree(desktop.appending("Sources")),
                .file(validator),
                .tool(.named("swift")),
                .tool(.named("readelf")),
                .tool(.named("ldd")),
                .tool(.named("sed")),
                .tool(.named("grep")),
                .tool(.named("awk")),
                .tool(.named("sort")),
                swiftPM.identityInput,
            ],
            postconditions: [
                swiftPM.postcondition,
                PathPostcondition(
                    path: manifest,
                    validation: .regularFile),
            ],
            locks: [.checkout("shell")],
            operation: .sequence(
                runtimeFinalizationOperations(
                    root: root,
                    workspace: workspace,
                    environment: environment,
                    swiftPM: swiftPM)))
    }

    public static func tests(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) -> [TaskDeclaration] {
        let workspace = root.removingLastComponent()
        let shellKit = root.appending("shell-kit")
        let authWire = root.appending("auth-wire")
        let integration = workspace.appending(
            "integration-tests/window-client-conformance")
        let manifest = swiftPM.configurationProducts.appending(
            "runtime-elf-ownership.tsv")
        let integrationRequirement = swiftPM.testProduct(
            package: "window-client-conformance",
            testProduct: "NucleusWindowClientIntegrationTestsPackageTests",
            packageRoot: integration,
            environment: environment)
        let authWireRequirement = swiftPM.testProduct(
            package: "auth-wire",
            testProduct: "NucleusShellAuthWirePackagePackageTests",
            packageRoot: authWire,
            environment: environment)
        let shellKitRequirement = swiftPM.testProduct(
            package: "shell-kit",
            testProduct: "NucleusShellKitPackagePackageTests",
            packageRoot: shellKit,
            environment: environment)
        return [
            TaskDeclaration(
                id: TaskID(rawValue: "shell.integration.test"),
                component: ComponentID(rawValue: "shell"),
                dependencies: [
                    TaskID(rawValue: "compositor-core.test")
                ],
                swiftTests: [integrationRequirement],
                locks: [.checkout("shell")],
                cachePolicy: .always,
                operation: .runSwiftTest(
                    SwiftTestExecution(
                        requirement: integrationRequirement))),
            TaskDeclaration(
                id: TaskID(rawValue: "shell.auth-wire.test"),
                component: ComponentID(rawValue: "shell"),
                dependencies: [
                    TaskID(rawValue: "shell.integration.test")
                ],
                swiftTests: [authWireRequirement],
                locks: [.checkout("shell")],
                cachePolicy: .always,
                operation: .runSwiftTest(
                    SwiftTestExecution(
                        requirement: authWireRequirement))),
            TaskDeclaration(
                id: TaskID(rawValue: "shell.test"),
                component: ComponentID(rawValue: "shell"),
                dependencies: [
                    TaskID(rawValue: "shell.auth-wire.test"),
                    TaskID(rawValue: "linux.desktop.test"),
                    TaskID(rawValue: "shell.build"),
                ],
                subsumedDependencies: [TaskID(rawValue: "shell.build")],
                swiftTests: [shellKitRequirement],
                postconditions: [
                    swiftPM.postcondition,
                    PathPostcondition(
                        path: manifest,
                        validation: .regularFile),
                ],
                locks: [.checkout("shell")],
                cachePolicy: .always,
                operation: .sequence(
                    [
                        .runSwiftTest(
                            SwiftTestExecution(
                                requirement: shellKitRequirement))
                    ]
                        + runtimeFinalizationOperations(
                            root: root,
                            workspace: workspace,
                            environment: environment,
                            swiftPM: swiftPM))),
        ]
    }
}

private func runtimeFinalizationOperations(
    root: FilePath,
    workspace: FilePath,
    environment: [String: String],
    swiftPM: SwiftPMInvocation
) -> [TaskOperation] {
    let validator = workspace.appending(
        "tools/validate-runtime-elf.sh")
    let manifest = swiftPM.configurationProducts.appending(
        "runtime-elf-ownership.tsv")
    return [
        .command(
            CommandSpec(
                executable: .path(validator),
                arguments: [
                    swiftPM.configurationProducts.string,
                    manifest.string,
                ],
                workingDirectory: workspace,
                environment: environment)),
    ]
}
