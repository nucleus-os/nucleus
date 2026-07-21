import Foundation

struct BenchmarkCommand {
    let context: WorkspaceContext

    func run(_ arguments: ArraySlice<String>) throws {
        guard arguments.isEmpty else {
            throw WorkspaceFailure.message("usage: tools/nucleus benchmark")
        }
        let package = context.repository("core")
        let product = "NucleusHeadlessBenchmarks"
        print(
            "==> benchmark package=core product=\(product) "
                + "configuration=release schema=nucleus.headless.v1")
        try context.run(
            "swift",
            [
                "build", "-c", "release",
                "--product", product,
            ],
            directory: package)
        let binaryDirectory = try context.run(
            "swift",
            ["build", "-c", "release", "--show-bin-path"],
            directory: package,
            capture: true)
        let executable = URL(fileURLWithPath: binaryDirectory)
            .appendingPathComponent(product)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw WorkspaceFailure.message(
                "release benchmark product is not executable: \(executable.path)")
        }

        let toolchain = try context.run(
            "swift", ["--version"], capture: true)
            .split(whereSeparator: \Character.isNewline)
            .joined(separator: " | ")
        var environment = context.environment
        environment["NUCLEUS_SWIFT_TOOLCHAIN"] = toolchain
        let benchmarkContext = WorkspaceContext(
            root: context.root,
            environment: environment)
        let output = package.appendingPathComponent(
            ".build/nucleus-benchmarks",
            isDirectory: true)
        try benchmarkContext.run(
            executable.path,
            ["--output", output.path, "--iterations", "3"],
            directory: package)
    }
}
