import Foundation
import Testing

@testable import ColliderCore

@Test func runEventReducerReconstructsTerminalTaskState() throws {
    let runID = RunID(rawValue: "fixture")
    let clean = TaskID(rawValue: "fixture.clean")
    let failed = TaskID(rawValue: "fixture.failed")
    let failure = ExecutionFailure(
        task: failed,
        operation: "swift build",
        command: ["swift", "build"],
        status: 1,
        invocation: "swift build",
        workingDirectory: "/workspace",
        logPath: "/runs/fixture/stages/fixture-failed.log",
        reason: "child command failed")
    let events = [
        RunEvent(
            sequence: 0,
            timestamp: "2026-08-08T00:00:00Z",
            runID: runID,
            payload: .runStarted(resumed: false)),
        RunEvent(
            sequence: 1,
            timestamp: "2026-08-08T00:00:01Z",
            runID: runID,
            payload: .task(.skipped(task: clean, explanation: "inputs unchanged"))),
        RunEvent(
            sequence: 2,
            timestamp: "2026-08-08T00:00:02Z",
            runID: runID,
            payload: .task(.started(failed))),
        RunEvent(
            sequence: 3,
            timestamp: "2026-08-08T00:00:03Z",
            runID: runID,
            payload: .task(.failed(task: failed, failure: failure))),
        RunEvent(
            sequence: 4,
            timestamp: "2026-08-08T00:00:04Z",
            runID: runID,
            payload: .terminal(
                TerminalRunEvent(status: .failed, failedTask: failed))),
    ]

    let state = try RunEventReducer.reduce(events)

    #expect(state.runID == runID)
    #expect(state.status == .failed)
    #expect(state.tasks[clean] == .skipped(explanation: "inputs unchanged"))
    #expect(state.tasks[failed] == .failed(failure))
    #expect(state.failedTask == failed)
}

@Test func runEventReducerRejectsSequenceGaps() {
    let event = RunEvent(
        sequence: 1,
        timestamp: "2026-08-08T00:00:00Z",
        runID: RunID(rawValue: "fixture"),
        payload: .runStarted(resumed: false))

    #expect(throws: RunEventReductionFailure.self) {
        try RunEventReducer.reduce([event])
    }
}

@Test func artifactDigestHasAnAlgorithmLabel() {
    #expect(
        ArtifactDigest(bytes: [0, 1, 254, 255]).description
            == "sha256:0001feff")
}

@Test func artifactDigestParsesOnlyCompleteLowercaseSHA256() {
    let value = String(repeating: "0a", count: 32)
    #expect(ArtifactDigest(sha256Hex: value)?.description == "sha256:" + value)
    #expect(ArtifactDigest(sha256Hex: String(repeating: "0A", count: 32)) == nil)
    #expect(ArtifactDigest(sha256Hex: "00") == nil)
}

@Test func downloadSpecificationsRejectUnboundedOrUnverifiedInputs() throws {
    let digest = ArtifactDigest(bytes: [UInt8](repeating: 0, count: 32))
    #expect(throws: DownloadSpecFailure.self) {
        try DownloadSpec(
            url: URL(string: "http://example.invalid/archive")!,
            permittedRedirectOrigins: [],
            expectedDigest: digest,
            maximumResponseSize: 1,
            acceptedMediaTypes: ["application/octet-stream"])
    }
    #expect(throws: DownloadSpecFailure.self) {
        try DownloadSpec(
            url: URL(string: "https://user:secret@example.invalid/archive")!,
            permittedRedirectOrigins: [],
            expectedDigest: digest,
            maximumResponseSize: 1,
            acceptedMediaTypes: ["application/octet-stream"])
    }
    #expect(throws: DownloadSpecFailure.self) {
        try DownloadSpec(
            url: URL(string: "https://example.invalid/archive")!,
            permittedRedirectOrigins: [],
            expectedDigest: ArtifactDigest(bytes: [0]),
            maximumResponseSize: 1,
            acceptedMediaTypes: ["application/octet-stream"])
    }
    #expect(throws: DownloadSpecFailure.self) {
        try DownloadSpec(
            url: URL(string: "https://example.invalid/archive")!,
            permittedRedirectOrigins: [],
            expectedDigest: digest,
            maximumResponseSize: 0,
            acceptedMediaTypes: ["application/octet-stream"])
    }
}
