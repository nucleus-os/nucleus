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
        let manifest = swiftPM.configurationProducts.appending(
            "runtime-elf-report.json")
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
                .tool(.named("swift")),
                .tool(.named("readelf")),
                .tool(.named("ldd")),
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
            "runtime-elf-report.json")
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
                operation: .sequence([])),
            TaskDeclaration(
                id: TaskID(rawValue: "shell.auth-wire.test"),
                component: ComponentID(rawValue: "shell"),
                dependencies: [
                    TaskID(rawValue: "shell.integration.test")
                ],
                swiftTests: [authWireRequirement],
                locks: [.checkout("shell")],
                cachePolicy: .always,
                operation: .sequence([])),
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
                    runtimeFinalizationOperations(
                        environment: environment,
                        swiftPM: swiftPM))),
        ]
    }
}

private func runtimeFinalizationOperations(
    environment: [String: String],
    swiftPM: SwiftPMInvocation
) -> [TaskOperation] {
    let manifest = swiftPM.configurationProducts.appending(
        "runtime-elf-report.json")
    return [
        .action(
            AnyColliderAction(
                ValidateRuntimeELFAction(
                    root: swiftPM.configurationProducts,
                    report: manifest,
                    environment: environment)))
    ]
}
