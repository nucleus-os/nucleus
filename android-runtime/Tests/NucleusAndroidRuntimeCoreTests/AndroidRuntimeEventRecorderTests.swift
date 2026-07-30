import Foundation
import NucleusAndroidRuntimeCore
import Testing

@Test
func runtimeEventRecorderPreservesEarlierAttempts() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appendingPathComponent("progress.jsonl")
    try Data("{\"stage\":\"earlier.attempt\"}\n".utf8).write(to: output)

    let recorder = try AndroidRuntimeEventRecorder(output: output)
    try recorder.record("current.attempt")

    let contents = try String(contentsOf: output, encoding: .utf8)
    #expect(contents.contains("\"stage\":\"earlier.attempt\""))
    #expect(contents.contains("\"stage\":\"current.attempt\""))
}
