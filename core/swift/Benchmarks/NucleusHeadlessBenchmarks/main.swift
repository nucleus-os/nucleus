import Foundation

@main
struct NucleusHeadlessBenchmarks {
    @MainActor
    static func main() async {
        do {
            let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
            let workloads = publicationBenchmarks()
                + textAndCollectionBenchmarks()
                + resourceBenchmarks()
                + renderModelBenchmarks()
            let results = try await BenchmarkRunner(iterations: options.iterations)
                .run(workloads)
            let report = BenchmarkReport(
                metricSchema: "nucleus.headless.v2",
                deterministicSeedPolicy:
                    "Every workload uses the recorded fixed seed; repeated structural "
                        + "samples must be byte-for-byte equivalent.",
                environment: .init(
                    architecture: architecture,
                    buildConfiguration: buildConfiguration,
                    swiftToolchain: ProcessInfo.processInfo.environment[
                        "NUCLEUS_SWIFT_TOOLCHAIN"] ?? "unknown"),
                metricSemantics: .init(
                    allocationUnits:
                        "Deterministic first-party objects, entries, or buffers retained "
                            + "by the workload; this is a structural allocation proxy, "
                            + "not allocator implementation metadata.",
                    copiedBytes:
                        "Payload bytes deliberately materialized or copied by the "
                            + "workload's first-party algorithm.",
                    timing:
                        "ContinuousClock diagnostics only; wall-clock values never fail "
                            + "a benchmark budget."),
                workloads: results)
            try BenchmarkReportWriter.write(report, to: options.outputDirectory)
        } catch {
            FileHandle.standardError.write(Data("benchmark error: \(error)\n".utf8))
            exit(1)
        }
    }

    private static var architecture: String {
        #if arch(x86_64)
        "x86_64"
        #elseif arch(arm64)
        "arm64"
        #else
        "unknown"
        #endif
    }

    private static var buildConfiguration: String {
        #if DEBUG
        "debug"
        #else
        "release"
        #endif
    }
}

private struct Options {
    var outputDirectory: URL
    var iterations: Int

    static func parse(_ arguments: [String]) throws -> Self {
        var output = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/nucleus-benchmarks", isDirectory: true)
        var iterations = 3
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--output":
                index += 1
                guard index < arguments.count else {
                    throw BenchmarkFailure.argument("--output requires a path")
                }
                output = URL(fileURLWithPath: arguments[index], isDirectory: true)
            case "--iterations":
                index += 1
                guard index < arguments.count,
                      let value = Int(arguments[index]),
                      value > 1
                else {
                    throw BenchmarkFailure.argument(
                        "--iterations requires an integer greater than one")
                }
                iterations = value
            default:
                throw BenchmarkFailure.argument(
                    "usage: NucleusHeadlessBenchmarks "
                        + "[--output <directory>] [--iterations <count>]")
            }
            index += 1
        }
        return Self(outputDirectory: output, iterations: iterations)
    }
}
