import Foundation

struct BenchmarkSample: Equatable {
    var metrics: [String: UInt64]
    var semanticChecksum: UInt64
    var phaseNanoseconds: [String: UInt64] = [:]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.metrics == rhs.metrics
            && lhs.semanticChecksum == rhs.semanticChecksum
    }
}

struct MetricBudget: Codable, Equatable {
    enum Kind: String, Codable {
        case exact
        case maximum
    }

    var metric: String
    var kind: Kind
    var value: UInt64

    static func exact(_ metric: String, _ value: UInt64) -> Self {
        Self(metric: metric, kind: .exact, value: value)
    }

    static func maximum(_ metric: String, _ value: UInt64) -> Self {
        Self(metric: metric, kind: .maximum, value: value)
    }
}

struct BenchmarkWorkload {
    var category: String
    var name: String
    var inputSize: UInt64
    var seed: UInt64
    var budgets: [MetricBudget]
    var body: @MainActor () async throws -> BenchmarkSample
}

struct BenchmarkTiming: Codable {
    var samplesNanoseconds: [UInt64]
    var medianNanoseconds: UInt64
    var tailNanoseconds: UInt64
    var totalNanoseconds: UInt64
}

struct BenchmarkResult: Codable {
    var category: String
    var name: String
    var inputSize: UInt64
    var seed: UInt64
    var iterations: Int
    var semanticChecksum: UInt64
    var structuralMetrics: [String: UInt64]
    var budgets: [MetricBudget]
    var timing: BenchmarkTiming
    var phaseTimings: [String: BenchmarkTiming]
}

struct BenchmarkReport: Codable {
    struct Environment: Codable {
        var architecture: String
        var buildConfiguration: String
        var swiftToolchain: String
    }

    struct MetricSemantics: Codable {
        var allocationUnits: String
        var copiedBytes: String
        var timing: String
    }

    var metricSchema: String
    var deterministicSeedPolicy: String
    var environment: Environment
    var metricSemantics: MetricSemantics
    var workloads: [BenchmarkResult]
}

enum BenchmarkFailure: Error, CustomStringConvertible {
    case argument(String)
    case semantic(String)
    case nondeterministic(
        workload: String,
        iteration: Int,
        expected: BenchmarkSample,
        actual: BenchmarkSample)
    case missingMetric(workload: String, metric: String)
    case phaseSchema(
        workload: String,
        iteration: Int,
        expected: [String],
        actual: [String])
    case budget(
        workload: String,
        metric: String,
        kind: MetricBudget.Kind,
        expected: UInt64,
        actual: UInt64)

    var description: String {
        switch self {
        case .argument(let message), .semantic(let message):
            message
        case .nondeterministic(
            let workload, let iteration, let expected, let actual):
            "\(workload) produced nondeterministic structure at iteration "
                + "\(iteration): expected \(expected), actual \(actual)"
        case .missingMetric(let workload, let metric):
            "\(workload) did not publish budgeted metric '\(metric)'"
        case .phaseSchema(
            let workload, let iteration, let expected, let actual):
            "\(workload) changed phase schema at iteration \(iteration): "
                + "expected \(expected), actual \(actual)"
        case .budget(
            let workload, let metric, let kind, let expected, let actual):
            "\(workload) exceeded its \(kind.rawValue) budget for \(metric): "
                + "expected \(expected), actual \(actual)"
        }
    }
}

@MainActor
struct BenchmarkRunner {
    var iterations: Int

    func run(_ workloads: [BenchmarkWorkload]) async throws -> [BenchmarkResult] {
        var results: [BenchmarkResult] = []
        results.reserveCapacity(workloads.count)
        for workload in workloads {
            results.append(try await run(workload))
        }
        return results
    }

    private func run(_ workload: BenchmarkWorkload) async throws -> BenchmarkResult {
        let clock = ContinuousClock()
        var baseline: BenchmarkSample?
        var elapsed: [UInt64] = []
        elapsed.reserveCapacity(iterations)
        var phaseSamples: [String: [UInt64]] = [:]

        for iteration in 0..<iterations {
            let start = clock.now
            let sample = try await workload.body()
            let duration = start.duration(to: clock.now)
            elapsed.append(Self.nanoseconds(duration))
            if let baseline {
                let expected = baseline.phaseNanoseconds.keys.sorted()
                let actual = sample.phaseNanoseconds.keys.sorted()
                guard expected == actual else {
                    throw BenchmarkFailure.phaseSchema(
                        workload: workload.name,
                        iteration: iteration,
                        expected: expected,
                        actual: actual)
                }
            }
            for (phase, nanoseconds) in sample.phaseNanoseconds {
                phaseSamples[phase, default: []].append(nanoseconds)
            }
            if let baseline, baseline != sample {
                throw BenchmarkFailure.nondeterministic(
                    workload: workload.name,
                    iteration: iteration,
                    expected: baseline,
                    actual: sample)
            }
            baseline = sample
        }

        guard let baseline else {
            throw BenchmarkFailure.argument("benchmark iteration count must be positive")
        }
        try validate(workload.budgets, sample: baseline, workload: workload.name)
        return BenchmarkResult(
            category: workload.category,
            name: workload.name,
            inputSize: workload.inputSize,
            seed: workload.seed,
            iterations: iterations,
            semanticChecksum: baseline.semanticChecksum,
            structuralMetrics: baseline.metrics,
            budgets: workload.budgets,
            timing: Self.timing(for: elapsed),
            phaseTimings: phaseSamples.mapValues(Self.timing(for:)))
    }

    private func validate(
        _ budgets: [MetricBudget],
        sample: BenchmarkSample,
        workload: String
    ) throws {
        for budget in budgets {
            guard let actual = sample.metrics[budget.metric] else {
                throw BenchmarkFailure.missingMetric(
                    workload: workload,
                    metric: budget.metric)
            }
            switch budget.kind {
            case .exact where actual != budget.value:
                throw BenchmarkFailure.budget(
                    workload: workload,
                    metric: budget.metric,
                    kind: budget.kind,
                    expected: budget.value,
                    actual: actual)
            case .maximum where actual > budget.value:
                throw BenchmarkFailure.budget(
                    workload: workload,
                    metric: budget.metric,
                    kind: budget.kind,
                    expected: budget.value,
                    actual: actual)
            default:
                break
            }
        }
    }

    private static func nanoseconds(_ duration: Duration) -> UInt64 {
        let components = duration.components
        let seconds = UInt64(max(0, components.seconds))
        let attoseconds = UInt64(max(0, components.attoseconds))
        let secondsNanoseconds = seconds.multipliedReportingOverflow(
            by: 1_000_000_000)
        if secondsNanoseconds.overflow { return .max }
        let subsecondNanoseconds = attoseconds / 1_000_000_000
        let total = secondsNanoseconds.partialValue.addingReportingOverflow(
            subsecondNanoseconds)
        return total.overflow ? .max : total.partialValue
    }

    private static func timing(for samples: [UInt64]) -> BenchmarkTiming {
        precondition(!samples.isEmpty)
        let sorted = samples.sorted()
        let tailIndex = min(
            sorted.count - 1,
            Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)
        return BenchmarkTiming(
            samplesNanoseconds: samples,
            medianNanoseconds: sorted[sorted.count / 2],
            tailNanoseconds: sorted[max(0, tailIndex)],
            totalNanoseconds: samples.reduce(into: 0) { total, sample in
                let sum = total.addingReportingOverflow(sample)
                total = sum.overflow ? .max : sum.partialValue
            })
    }
}

enum BenchmarkReportWriter {
    static func write(
        _ report: BenchmarkReport,
        to outputDirectory: URL
    ) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = try encoder.encode(report)
        try atomicWrite(
            json + Data("\n".utf8),
            to: outputDirectory.appendingPathComponent("report.json"))

        let summary = humanSummary(report)
        try atomicWrite(
            Data(summary.utf8),
            to: outputDirectory.appendingPathComponent("summary.txt"))
        print(summary, terminator: "")
        print("JSON: \(outputDirectory.appendingPathComponent("report.json").path)")
    }

    private static func atomicWrite(_ data: Data, to destination: URL) throws {
        let temporary = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).tmp")
        try data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    private static func humanSummary(_ report: BenchmarkReport) -> String {
        var lines = [
            "Nucleus headless benchmarks",
            "schema=\(report.metricSchema) architecture=\(report.environment.architecture) "
                + "configuration=\(report.environment.buildConfiguration)",
        ]
        for result in report.workloads {
            let milliseconds = Double(result.timing.medianNanoseconds) / 1_000_000
            lines.append(
                "\(result.category)/\(result.name): input=\(result.inputSize) "
                    + "iterations=\(result.iterations) median_ms="
                    + String(format: "%.3f", milliseconds)
                    + " structural=pass"
                    + phaseSummary(result.phaseTimings))
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func phaseSummary(
        _ timings: [String: BenchmarkTiming]
    ) -> String {
        guard !timings.isEmpty else { return "" }
        return " phases_ms=" + timings.keys.sorted().map { phase in
            let milliseconds = Double(
                timings[phase]?.medianNanoseconds ?? 0) / 1_000_000
            return "\(phase):" + String(format: "%.3f", milliseconds)
        }.joined(separator: ",")
    }
}

struct BenchmarkPhaseRecorder {
    private let clock = ContinuousClock()
    private(set) var phaseNanoseconds: [String: UInt64] = [:]

    mutating func measure<T>(
        _ phase: String,
        _ body: () throws -> T
    ) rethrows -> T {
        precondition(phaseNanoseconds[phase] == nil, "benchmark phase recorded twice")
        let start = clock.now
        defer {
            phaseNanoseconds[phase] = durationNanoseconds(
                start.duration(to: clock.now))
        }
        return try body()
    }
}

private func durationNanoseconds(_ duration: Duration) -> UInt64 {
    let components = duration.components
    let seconds = UInt64(max(0, components.seconds))
    let attoseconds = UInt64(max(0, components.attoseconds))
    let secondsNanoseconds = seconds.multipliedReportingOverflow(
        by: 1_000_000_000)
    guard !secondsNanoseconds.overflow else { return .max }
    let subsecondNanoseconds = attoseconds / 1_000_000_000
    let total = secondsNanoseconds.partialValue.addingReportingOverflow(
        subsecondNanoseconds)
    return total.overflow ? .max : total.partialValue
}

extension UInt64 {
    mutating func mix(_ value: UInt64) {
        self ^= value &+ 0x9e37_79b9_7f4a_7c15 &+ (self << 6) &+ (self >> 2)
    }
}

@inline(never)
func consume<T>(_ value: T) {
    withExtendedLifetime(value) {}
}
