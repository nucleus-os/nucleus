import Foundation

package struct NumericPlotSummary: Equatable {
    package let count: Int
    package let p50: Double
    package let p90: Double
    package let p99: Double
    package let maximum: Double

    package init(
        count: Int,
        p50: Double,
        p90: Double,
        p99: Double,
        maximum: Double
    ) {
        self.count = count
        self.p50 = p50
        self.p90 = p90
        self.p99 = p99
        self.maximum = maximum
    }
}

package func summarizeNumericPlots(_ csv: String) -> [String: NumericPlotSummary] {
    var samples: [String: [Double]] = [:]
    for row in csv.split(separator: "\n").dropFirst() {
        let fields = row.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count > 6, let value = Double(fields[6]), value.isFinite else { continue }
        samples[String(fields[0]), default: []].append(value)
    }

    func percentile(_ fraction: Double, in sorted: [Double]) -> Double {
        let rank = max(1, Int(ceil(fraction * Double(sorted.count))))
        return sorted[rank - 1]
    }

    return samples.mapValues { values in
        let sorted = values.sorted()
        return NumericPlotSummary(
            count: sorted.count,
            p50: percentile(0.50, in: sorted),
            p90: percentile(0.90, in: sorted),
            p99: percentile(0.99, in: sorted),
            maximum: sorted[sorted.count - 1])
    }
}
