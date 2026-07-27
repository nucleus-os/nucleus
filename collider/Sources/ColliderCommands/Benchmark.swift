import ColliderCore
import FoundationEssentials

struct BenchmarkCommand {
    private struct Suite {
        var package: String
        var product: String
        var outputDirectory: String
    }

    let context: WorkspaceContext

    func run() async throws {
        let swiftPM = try context.swiftPMInvocation(configuration: .release)
        let toolchain = try await context.run(
            "swift", ["--version"], capture: true)
            .split(whereSeparator: \Character.isNewline)
            .joined(separator: " | ")
        var environment = context.environment
        environment["NUCLEUS_BENCHMARK_SWIFT_VERSION"] = toolchain
        let benchmarkContext = WorkspaceContext(
            root: context.root,
            environment: environment)
        let outputRoot = context.layout.benchmarkBuilds
        let suites = [
            Suite(
                package: "core",
                product: "NucleusHeadlessBenchmarks",
                outputDirectory: "core"),
            Suite(
                package: "platform-linux",
                product: "NucleusLinuxBenchmarks",
                outputDirectory: "linux"),
            Suite(
                package: "react-native",
                product: "NucleusReactBenchmarks",
                outputDirectory: "react-native"),
        ]

        for suite in suites {
            try await run(
                suite,
                outputRoot: outputRoot,
                context: benchmarkContext,
                swiftPM: swiftPM)
        }
    }

    private func run(
        _ suite: Suite,
        outputRoot: URL,
        context: WorkspaceContext,
        swiftPM: SwiftPMInvocation
    ) async throws {
        let package = context.repository(suite.package)
        print(
            "==> benchmark package=\(suite.package) product=\(suite.product) "
                + "configuration=release schema=nucleus.headless.v3")
        try await context.run(
            "swift",
            swiftPM.commandArguments([
                "build", "--product", suite.product,
            ]),
            directory: package,
            environmentOverrides: swiftPM.commandEnvironment(
                context.taskEnvironment))
        let executable = URL(
            fileURLWithPath: swiftPM.executable(suite.product).string)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw WorkspaceFailure.message(
                "release benchmark product is not executable: \(executable.path)")
        }

        let output = outputRoot.appendingPathComponent(
            suite.outputDirectory,
            isDirectory: true)
        try await context.run(
            executable.path,
            ["--output", output.path, "--iterations", "3"],
            directory: package)
    }
}
