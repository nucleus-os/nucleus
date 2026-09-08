import ColliderCore
import Testing

@testable import ColliderWorkspaceCommands

private func encodedIdentity(_ build: (inout IdentityEncoder) -> Void) -> [UInt8] {
    var encoder = IdentityEncoder()
    build(&encoder)
    return encoder.bytes
}

@Test func explainingATaskReportsWhereItLeftTheRecordedIdentity() throws {
    let collector = IdentityExplanationCollector(selection: "fixture.explained")
    let task = TaskID(rawValue: "fixture.explained")
    let planned = try #require(collector.observer)
    let recorded = try #require(collector.recordedObserver)

    planned(task, encodedIdentity { $0.appendSequence(["a", "planned"]) { $0.append($1) } })
    recorded(task, encodedIdentity { $0.appendSequence(["a", "recorded"]) { $0.append($1) } })

    let report = collector.report().joined(separator: "\n")

    #expect(report.contains("identity  fixture.explained"))
    #expect(report.contains("diverged from the recorded identity at"))
    #expect(report.contains("\"recorded\""))
    #expect(report.contains("\"planned\""))
}

@Test func aTaskThatMatchesItsRecordIsExplainedWithoutADifference() throws {
    let collector = IdentityExplanationCollector(selection: "fixture")
    let task = TaskID(rawValue: "fixture.clean")
    let planned = try #require(collector.observer)

    // Nothing observes a recorded identity for a task planning did not
    // reject, so an explanation of one is its components and no comparison.
    planned(task, encodedIdentity { $0.append("only") })

    let report = collector.report().joined(separator: "\n")

    #expect(report.contains("string \"only\""))
    #expect(!report.contains("diverged"))
}

@Test func aDivergenceAgainstARecordWithoutComponentsSaysSoRatherThanNothing()
    throws
{
    let collector = IdentityExplanationCollector(selection: "fixture")
    let task = TaskID(rawValue: "fixture.inherited")
    let planned = try #require(collector.observer)
    let recorded = try #require(collector.recordedObserver)

    planned(task, encodedIdentity { $0.append("planned") })
    // What every record written before components were kept looks like.
    // Silence here reads as agreement, which is the opposite of the truth.
    recorded(task, [])

    let report = collector.report().joined(separator: "\n")

    #expect(report.contains("kept no components"))
    #expect(report.contains("locatable once it next executes"))
}

@Test func explanationIsScopedToTheSelectedTasks() throws {
    let collector = IdentityExplanationCollector(selection: "wanted")
    let planned = try #require(collector.observer)

    planned(TaskID(rawValue: "fixture.wanted"), encodedIdentity { $0.append("kept") })
    planned(TaskID(rawValue: "fixture.other"), encodedIdentity { $0.append("dropped") })

    let report = collector.report().joined(separator: "\n")

    #expect(report.contains("fixture.wanted"))
    #expect(!report.contains("fixture.other"))
    #expect(!report.contains("dropped"))
}
