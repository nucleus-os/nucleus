import ColliderCore
import Foundation
import NightlyReleaseContracts
import NightlyReleaseReservations
import Testing

@Test func reservationsSurviveReopeningAndRetryAcrossMidnight() throws {
    let root = temporaryAuthority()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NightlyReleaseReservationStore(root: root)
    try store.initialize()
    let request = UUID()
    let selection = try selection()
    let first = try store.reserve(
        requestID: request, selection: selection, now: instant("2026-09-05T23:59:59Z"))
    let reopened = NightlyReleaseReservationStore(root: root)
    let retry = try reopened.reserve(
        requestID: request, selection: selection, now: instant("2026-09-06T00:00:01Z"))
    #expect(first == retry)
    #expect(first.version.description == "2026.09.05.1")
    let next = try reopened.reserve(
        requestID: UUID(), selection: selection, now: instant("2026-09-06T00:00:01Z"))
    #expect(next.version.description == "2026.09.06.1")
    #expect(next.version > first.version)
}

@Test func abandonedReservationsAreNeverReused() throws {
    let root = temporaryAuthority()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NightlyReleaseReservationStore(root: root)
    try store.initialize()
    let selection = try selection()
    let now = instant("2026-09-05T12:00:00Z")
    _ = try store.reserve(requestID: UUID(), selection: selection, now: now)
    let next = try NightlyReleaseReservationStore(root: root).reserve(
        requestID: UUID(), selection: selection, now: now)
    #expect(next.version.description == "2026.09.05.2")
}

@Test func reservationRequestCannotChangeItsBinding() throws {
    let root = temporaryAuthority()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NightlyReleaseReservationStore(root: root)
    try store.initialize()
    let request = UUID()
    _ = try store.reserve(requestID: request, selection: selection())
    for changed in [
        try selection(commit: String(repeating: "b", count: 40)),
        try selection(run: 43),
        try selection(input: "other-input-manifest"),
    ] {
        #expect(throws: NightlyReleaseFailure.self) {
            try store.reserve(requestID: request, selection: changed)
        }
    }
}

@Test func concurrentReservationsAreUniqueAndRetriesConverge() async throws {
    let root = temporaryAuthority()
    defer { try? FileManager.default.removeItem(at: root) }
    try NightlyReleaseReservationStore(root: root).initialize()
    let selection = try selection()
    let now = instant("2026-09-05T12:00:00Z")
    let versions = try await withThrowingTaskGroup(of: NightlyReleaseVersion.self) { group in
        for _ in 0..<24 {
            group.addTask {
                try NightlyReleaseReservationStore(root: root).reserve(
                    requestID: UUID(), selection: selection, now: now
                ).version
            }
        }
        var values: [NightlyReleaseVersion] = []
        for try await version in group { values.append(version) }
        return values.sorted()
    }
    #expect(versions.map(\.sequence) == Array(UInt64(1)...UInt64(24)))
    let request = UUID()
    let retries = try await withThrowingTaskGroup(of: NightlyReleaseReservation.self) { group in
        for _ in 0..<12 {
            group.addTask {
                try NightlyReleaseReservationStore(root: root).reserve(
                    requestID: request, selection: selection, now: now)
            }
        }
        var values: [NightlyReleaseReservation] = []
        for try await value in group { values.append(value) }
        return values
    }
    #expect(retries.allSatisfy { $0 == retries.first })
    #expect(retries.first?.version.sequence == 25)
}

@Test func clockRollbackFailsWithoutConsumingASequence() throws {
    let root = temporaryAuthority()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NightlyReleaseReservationStore(root: root)
    try store.initialize()
    let selection = try selection()
    let now = instant("2026-09-05T12:00:00Z")
    _ = try store.reserve(requestID: UUID(), selection: selection, now: now)
    #expect(throws: NightlyReleaseFailure.self) {
        try store.reserve(
            requestID: UUID(), selection: selection, now: instant("2026-09-04T12:00:00Z"))
    }
    #expect(
        try store.reserve(requestID: UUID(), selection: selection, now: now).version.sequence == 2)
    #expect(NightlyReleaseVersion.utcDay(at: instant("2026-09-05T23:30:00-07:00")) == "2026.09.06")
}

@Test func missingAndCorruptAuthorityStateFailClosed() throws {
    let root = temporaryAuthority()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NightlyReleaseReservationStore(root: root)
    #expect(throws: (any Error).self) {
        try store.reserve(requestID: UUID(), selection: selection())
    }
    try store.initialize()
    #expect(throws: (any Error).self) { try store.initialize() }
    let ledger = root.appendingPathComponent("reservations.json")
    try FileManager.default.removeItem(at: ledger)
    #expect(throws: (any Error).self) {
        try store.reserve(requestID: UUID(), selection: selection())
    }
    #expect(throws: (any Error).self) { try store.initialize() }
    try Data("incomplete".utf8).write(to: ledger)
    #expect(throws: (any Error).self) {
        try store.reserve(requestID: UUID(), selection: selection())
    }
    #expect(try String(contentsOf: ledger, encoding: .utf8) == "incomplete")
}

@Test func incompleteCandidateDoesNotReplaceCommittedReservations() throws {
    let root = temporaryAuthority()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NightlyReleaseReservationStore(root: root)
    try store.initialize()
    let selection = try selection()
    let request = UUID()
    let first = try store.reserve(requestID: request, selection: selection)
    try Data("partial candidate from a terminated process".utf8)
        .write(to: root.appendingPathComponent(".reservation-interrupted.json"))
    let retry = try NightlyReleaseReservationStore(root: root).reserve(
        requestID: request, selection: selection)
    #expect(first == retry)
}

@Test(arguments: [
    "2026.02.29.1", "2026.9.05.1", "2026.09.05.0", "2026.09.05.01", "2026.09.05.-1", "0000.01.01.1",
])
func malformedNightlyVersionsAreRejected(value: String) throws {
    let bytes = try JSONEncoder().encode(value)
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(NightlyReleaseVersion.self, from: bytes)
    }
}

@Test func nightlyVersionsOrderNumericallyAndRoundTrip() throws {
    let versions = try [
        NightlyReleaseVersion(day: "2026.09.05", sequence: 2),
        NightlyReleaseVersion(day: "2026.09.05", sequence: 10),
        NightlyReleaseVersion(day: "2026.09.06", sequence: 1),
        NightlyReleaseVersion(day: "2028.02.29", sequence: 1),
    ]
    #expect(versions.sorted() == versions)
    for version in versions {
        #expect(
            try JSONDecoder().decode(
                NightlyReleaseVersion.self, from: JSONEncoder().encode(version)) == version)
    }
}

@Test func separateAuthorityProcessesSerializeReservations() throws {
    let root = temporaryAuthority()
    defer { try? FileManager.default.removeItem(at: root) }
    try NightlyReleaseReservationStore(root: root).initialize()
    let input = root.appendingPathComponent("selection.json")
    try JSONEncoder().encode(selection()).write(to: input)
    let executable = try reservationExecutable()
    var children: [(Process, Pipe)] = []
    defer {
        for (process, _) in children where process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }
    for _ in 0..<8 {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["reserve", root.path, UUID().uuidString, input.path]
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        children.append((process, output))
    }
    var versions: [NightlyReleaseVersion] = []
    for (process, output) in children {
        let data = try output.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        versions.append(
            try JSONDecoder().decode(NightlyReleaseReservation.self, from: data).version)
    }
    #expect(Set(versions).count == 8)
    // This also holds if the test crosses UTC midnight.
    #expect(versions.sorted().first?.sequence == 1)
}

@Test func inconsistentLedgerBindingsAreRejected() throws {
    let root = temporaryAuthority()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NightlyReleaseReservationStore(root: root)
    try store.initialize()
    let first = try store.reserve(
        requestID: UUID(), selection: selection(), now: instant("2026-09-05T12:00:00Z"))
    let gap = NightlyReleaseReservation(
        requestID: UUID(), selection: first.selection,
        version: try NightlyReleaseVersion(day: "2026.09.05", sequence: 3))
    for records in [[first, first], [first, gap]] {
        let data = try JSONEncoder().encode(records)
        let ledger = root.appendingPathComponent("reservations.json")
        try data.write(to: ledger)
        #expect(throws: NightlyReleaseFailure.self) {
            try store.reserve(requestID: UUID(), selection: selection())
        }
        #expect(try Data(contentsOf: ledger) == data)
    }
}

@Test func decodedSelectionMustStillPassAdmissionShapeValidation() throws {
    let root = temporaryAuthority()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = NightlyReleaseReservationStore(root: root)
    try store.initialize()
    let valid = try JSONEncoder().encode(selection())
    var object = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
    object["sourceCommit"] = "main"
    let invalid = try JSONDecoder().decode(
        NightlyReleaseSelection.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(throws: NightlyReleaseFailure.self) {
        try store.reserve(requestID: UUID(), selection: invalid)
    }
    #expect(try store.reserve(requestID: UUID(), selection: selection()).version.sequence == 1)
}

private final class ReservationTestBundle: NSObject {}

private func reservationExecutable() throws -> URL {
    var directory = Bundle(for: ReservationTestBundle.self).bundleURL
    for _ in 0..<5 {
        let candidate = directory.appendingPathComponent("nucleus-nightly-reservation")
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        directory.deleteLastPathComponent()
    }
    throw NightlyReleaseFailure("SwiftPM test products are missing nucleus-nightly-reservation")
}

private func temporaryAuthority() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
        "nightly-reservations-\(UUID().uuidString)")
}

private func selection(
    commit: String = String(repeating: "a", count: 40),
    run: UInt64 = 42,
    input: String = "input-manifest"
) throws -> NightlyReleaseSelection {
    try NightlyReleaseSelection(
        sourceCommit: commit, verificationRunID: run,
        inputManifestDigest: .sha256(Array(input.utf8)))
}

private func instant(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
}
