import Foundation

struct BenchmarkCommand {
    private struct Suite {
        var package: String
        var product: String
        var outputDirectory: String
    }

    let context: WorkspaceContext

    func run(_ arguments: ArraySlice<String>) throws {
        guard arguments.isEmpty else {
            throw WorkspaceFailure.message("usage: tools/nucleus benchmark")
        }

        let toolchain = try context.run(
            "swift", ["--version"], capture: true)
            .split(whereSeparator: \Character.isNewline)
            .joined(separator: " | ")
        var environment = context.environment
        environment["NUCLEUS_BENCHMARK_SWIFT_VERSION"] = toolchain
        let benchmarkContext = WorkspaceContext(
            root: context.root,
            environment: environment)
        let outputRoot = context.root
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("nucleus-benchmarks", isDirectory: true)
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
            try run(
                suite,
                outputRoot: outputRoot,
                context: benchmarkContext)
        }
    }

    private func run(
        _ suite: Suite,
        outputRoot: URL,
        context: WorkspaceContext
    ) throws {
        let package = context.repository(suite.package)
        print(
            "==> benchmark package=\(suite.package) product=\(suite.product) "
                + "configuration=release schema=nucleus.headless.v2")
        try context.run(
            "swift",
            [
                "build", "-c", "release",
                "--product", suite.product,
            ],
            directory: package)
        let binaryDirectory = try context.run(
            "swift", ["build", "-c", "release", "--show-bin-path"],
            directory: package,
            capture: true)
        let executable = URL(fileURLWithPath: binaryDirectory)
            .appendingPathComponent(suite.product)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw WorkspaceFailure.message(
                "release benchmark product is not executable: \(executable.path)")
        }

        let output = outputRoot.appendingPathComponent(
            suite.outputDirectory,
            isDirectory: true)
        try context.run(
            executable.path,
            ["--output", output.path, "--iterations", "3"],
            directory: package)
    }
}
