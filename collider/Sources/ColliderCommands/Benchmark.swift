import ColliderCore
import Foundation
import SystemPackage

struct BenchmarkCommand {
    private struct Suite {
        let package: String
        let product: String
        let outputDirectory: String
    }

    let context: WorkspaceContext

    func run(controls: TaskControls) async throws {
        let registry = ComponentRegistry(context: context)
        let swiftPM = try registry.linuxSwiftPMInvocation(configuration: .release)
        let environment = context.taskEnvironment.merging([
            "NUCLEUS_BENCHMARK_SWIFT_VERSION": swiftPM.context.toolchainIdentity
        ]) { _, configured in configured }
        let suites = [
            Suite(
                package: "core",
                product: "NucleusHeadlessBenchmarks",
                outputDirectory: "core"),
            Suite(
                package: "platform-linux/desktop",
                product: "NucleusLinuxBenchmarks",
                outputDirectory: "linux"),
            Suite(
                package: "react-native",
                product: "NucleusReactBenchmarks",
                outputDirectory: "react-native"),
        ]
        let tasks = try registry.linuxArchitectureTasks()
        let benchmarkTasks = suites.map { suite in
            let executable = swiftPM.executable(suite.product)
            let output = FilePath(context.layout.benchmarkBuilds.path).appending(
                suite.outputDirectory)
            return TaskDeclaration(
                id: TaskID(rawValue: "benchmark.\(suite.outputDirectory)"),
                component: ComponentID(rawValue: "benchmark"),
                dependencies: [
                    TaskID(rawValue: "native.builder"),
                    TaskID(rawValue: "android-runtime.gfxstream.linux-arm64"),
                ],
                swiftProducts: [
                    swiftPM.product(
                        package: suite.package,
                        product: suite.product,
                        packageRoot: context.layout.rootPath,
                        environment: environment,
                        expectedOutputs: [
                            PathPostcondition(
                                path: executable,
                                validation: .executableFile)
                        ])
                ],
                inputs: [swiftPM.identityInput],
                outputs: [
                    OutputDeclaration(path: output, validation: .nonEmptyDirectory)
                ],
                locks: [.checkout("benchmark-\(suite.outputDirectory)")],
                cachePolicy: .always,
                operation: .sequence([
                    .removePath(output),
                    swiftPM.operation(
                        executable: executable,
                        arguments: [
                            "--output", output.string, "--iterations", "3",
                        ],
                        workingDirectory: context.layout.rootPath,
                        environment: environment),
                ]))
        }
        try await context.execute(
            tasks: tasks + benchmarkTasks,
            selected: benchmarkTasks.map(\.id),
            controls: controls)
    }
}
