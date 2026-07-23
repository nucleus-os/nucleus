import Testing
@testable import ColliderCommands

@Test func numericPlotSummaryReportsNearestRankPercentiles() {
    let header = "name,a,b,c,d,e,value"
    let samples = (1...100).map { "frame,a,b,c,d,e,\($0)" }
    let fixture = ([header] + samples + [
        "other,a,b,c,d,e,-2.5",
        "other,a,b,c,d,e,7.5",
        "ignored,a,b,c,d,e,not-a-number",
    ]).joined(separator: "\n")

    let summaries = summarizeNumericPlots(fixture)

    #expect(summaries["frame"] == NumericPlotSummary(
        count: 100, p50: 50, p90: 90, p99: 99, maximum: 100))
    #expect(summaries["other"] == NumericPlotSummary(
        count: 2, p50: -2.5, p90: 7.5, p99: 7.5, maximum: 7.5))
    #expect(summaries["ignored"] == nil)
}
