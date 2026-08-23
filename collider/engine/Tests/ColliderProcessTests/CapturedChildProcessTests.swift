import ColliderProcess
import Foundation
import SystemPackage
import Testing

/// Larger than any pipe buffer a supported platform gives a child: Linux
/// allocates 64 KiB and Darwin grows to 64 KiB, so a child writing this much
/// to one stream blocks on the write unless the parent is draining that stream
/// while it reads the other.
private let volumeExceedingAPipeBuffer = 512 * 1024

private func shell(_ script: String) async throws -> CapturedChildProcess.Capture {
    try await CapturedChildProcess.capture(
        executable: FilePath("/bin/sh"),
        arguments: ["-c", script],
        workingDirectory: FilePath(FileManager.default.currentDirectoryPath),
        environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C"])
}

@Test func captureDrainsBothStreamsWhenEitherWouldFillItsPipe() async throws {
    // Standard error is filled first and standard output stays open behind it.
    // Reading standard output to end of file before touching standard error
    // deadlocks here: the child blocks writing to a full standard error while
    // the parent blocks reading a standard output the child has not finished.
    let capture = try await shell(
        """
        yes e | head -c \(volumeExceedingAPipeBuffer) >&2
        yes o | head -c \(volumeExceedingAPipeBuffer)
        """)

    #expect(capture.status == 0)
    #expect(capture.standardOutput.count == volumeExceedingAPipeBuffer)
    #expect(capture.standardError.count == volumeExceedingAPipeBuffer)
    #expect(capture.standardOutput.allSatisfy { $0 == UInt8(ascii: "o") || $0 == 0x0a })
    #expect(capture.standardError.allSatisfy { $0 == UInt8(ascii: "e") || $0 == 0x0a })
}

@Test func captureInterleavesBothStreamsToCompletion() async throws {
    let capture = try await shell(
        """
        yes o | head -c \(volumeExceedingAPipeBuffer) &
        yes e | head -c \(volumeExceedingAPipeBuffer) >&2
        wait
        """)

    #expect(capture.status == 0)
    #expect(capture.standardOutput.count == volumeExceedingAPipeBuffer)
    #expect(capture.standardError.count == volumeExceedingAPipeBuffer)
}

@Test func captureReportsTheChildStatusWithoutTreatingItAsAFailure() async throws {
    let capture = try await shell("printf out; printf err >&2; exit 3")

    #expect(capture.status == 3)
    #expect(capture.standardOutputText == "out")
    #expect(capture.standardErrorText == "err")
}

@Test func captureRejectsAnUnusableEnvironmentName() async throws {
    await #expect(throws: CapturedChildProcess.Failure.self) {
        _ = try await CapturedChildProcess.capture(
            executable: FilePath("/bin/sh"),
            arguments: ["-c", "true"],
            workingDirectory: FilePath(FileManager.default.currentDirectoryPath),
            environment: ["NAME=WITH=EQUALS": "value"])
    }
}

/// Counts this process's open descriptors. `/dev/fd` lists one entry per open
/// descriptor on both supported platforms.
private func openDescriptorCount() throws -> Int {
    try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
}

@Test func repeatedCapturesDoNotLeakDescriptors() async throws {
    // Source capture runs Git once per checkout across hundreds in a closure.
    // The mechanism this replaced leaked four descriptors per invocation and
    // exhausted the process limit before a closure finished hashing, so the
    // count after many captures is the contract rather than an incidental
    // property.
    _ = try await shell("true")
    let before = try openDescriptorCount()
    for _ in 0..<64 {
        _ = try await shell("printf out; printf err >&2")
    }
    let after = try openDescriptorCount()
    #expect(after <= before)
}
