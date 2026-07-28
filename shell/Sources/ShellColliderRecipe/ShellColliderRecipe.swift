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
        let normalizer = workspace.appending(
            "tools/normalize-runtime-elf.sh")
        let manifest = swiftPM.configurationProducts.appending(
            "runtime-elf-ownership.tsv")
        return TaskDeclaration(
            id: TaskID(rawValue: "shell.build"),
            component: ComponentID(rawValue: "shell"),
            dependencies: [TaskID(rawValue: "compositor.build")],
            inputs: [
                .file(root.appending("Package.swift")),
                .tree(root.appending("Sources")),
                .file(shellKit.appending("Package.swift")),
                .tree(shellKit.appending("Sources")),
                .file(authWire.appending("Package.swift")),
                .tree(authWire.appending("Sources")),
                .file(windowClient.appending("Package.swift")),
                .tree(windowClient.appending("Sources")),
                .file(desktop.appending("Package.swift")),
                .tree(desktop.appending("Sources")),
                .file(validator),
                .file(normalizer),
                .tool(.named("swift")),
                .tool(.named("readelf")),
                .tool(.named("nm")),
                .tool(.named("sed")),
                .tool(.named("grep")),
                .tool(.named("awk")),
                .tool(.named("sort")),
                .tool(.named("cut")),
                .tool(.named("uniq")),
                .tool(.named("patchelf")),
                swiftPM.identityInput,
            ],
            postconditions: [
                swiftPM.postcondition,
                PathPostcondition(
                    path: manifest,
                    validation: .regularFile),
            ],
            locks: [.checkout("shell"), swiftPM.lock],
            operation: .sequence([
                .command(swiftPM.command(
                    arguments: [
                        "build", "--product", "NucleusWindowClient",
                    ],
                    workingDirectory: windowClient,
                    environment: environment)),
                .command(swiftPM.command(
                    arguments: [
                        "build", "--product", "NucleusDesktop",
                    ],
                    workingDirectory: desktop,
                    environment: environment)),
                .command(swiftPM.command(
                    arguments: [
                        "build", "--product", "NucleusShellKit",
                    ],
                    workingDirectory: shellKit,
                    environment: environment)),
                .command(swiftPM.command(
                    arguments: ["build"],
                    workingDirectory: root,
                    environment: environment)),
                .command(CommandSpec(
                    executable: .path(normalizer),
                    arguments: [swiftPM.configurationProducts.string],
                    workingDirectory: workspace,
                    environment: environment)),
                .command(CommandSpec(
                    executable: .path(validator),
                    arguments: [
                        swiftPM.configurationProducts.string,
                        manifest.string,
                    ],
                    workingDirectory: workspace,
                    environment: environment)),
            ]))
    }

    public static func test(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) -> TaskDeclaration {
        let workspace = root.removingLastComponent()
        let shellKit = root.appending("shell-kit")
        let authWire = root.appending("auth-wire")
        let integration = workspace.appending(
            "integration-tests/window-client-conformance")
        let desktop = workspace.appending("desktop")
        return TaskDeclaration(
            id: TaskID(rawValue: "shell.test"),
            component: ComponentID(rawValue: "shell"),
            dependencies: [TaskID(rawValue: "shell.build")],
            inputs: [
                .file(root.appending("Package.swift")),
                .tree(root.appending("Sources")),
                .file(shellKit.appending("Package.swift")),
                .tree(shellKit.appending("Sources")),
                .tree(shellKit.appending("Tests")),
                .file(authWire.appending("Package.swift")),
                .tree(authWire.appending("Sources")),
                .tree(authWire.appending("Tests")),
                .file(integration.appending("Package.swift")),
                .tree(integration.appending("Tests")),
                .file(desktop.appending("Package.swift")),
                .tree(desktop.appending("Sources")),
                .tree(desktop.appending("Tests")),
                swiftPM.identityInput,
                .tool(.named("swift")),
            ],
            postconditions: [swiftPM.postcondition],
            locks: [.checkout("shell"), swiftPM.lock],
            operation: .sequence([
                .command(swiftPM.command(
                    arguments: ["test"],
                    workingDirectory: desktop,
                    environment: environment)),
                .command(swiftPM.command(
                    arguments: ["test"],
                    workingDirectory: integration,
                    environment: environment)),
                .command(swiftPM.command(
                    arguments: ["test"],
                    workingDirectory: authWire,
                    environment: environment)),
                .command(swiftPM.command(
                    arguments: ["test"],
                    workingDirectory: shellKit,
                    environment: environment)),
            ]))
    }
}
