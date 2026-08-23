import ColliderCore
import Subprocess
import SystemPackage

/// The persistence layer's execution entry point.
///
/// `ColliderRuntime` depends on this module, so a persistence-layer site
/// cannot reach the runtime's execution path and would otherwise construct a
/// process by hand. Both mechanisms drain concurrently, and neither reads one
/// stream to end of file before starting the other, which is the property that
/// keeps a child from blocking on a full pipe while the parent waits on a
/// different one.
public enum CapturedChildProcess {
    public struct Capture: Sendable {
        public let status: Int32
        public let standardOutput: [UInt8]
        public let standardError: [UInt8]

        init(status: Int32, standardOutput: [UInt8], standardError: [UInt8]) {
            self.status = status
            self.standardOutput = standardOutput
            self.standardError = standardError
        }

        public var standardOutputText: String {
            String(decoding: standardOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        public var standardErrorText: String {
            String(decoding: standardError, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Bounds a runaway child rather than a legitimate one.
    ///
    /// A Git listing grows with the number of tracked paths, and the largest
    /// tree in the source closure is `llvm-project`: 165k paths, whose
    /// `ls-files -s -z` output is just under 17 MB. This limit is roughly
    /// sixty times that, which no real repository listing reaches, so hitting
    /// it means a runaway child or a wrong command rather than a large
    /// checkout. Exceeding it fails rather than truncates, because a silently
    /// truncated capture would feed source provenance and change task
    /// identity.
    public static let captureLimit = 1024 * 1_024 * 1_024

    /// Runs a child only for its exit status, discarding both streams.
    ///
    /// A caller that inspects neither stream has nothing to drain and is not
    /// in the deadlock class. This exists so such a caller still has an
    /// execution path available to it rather than a reason to build a process
    /// by hand.
    public static func status(
        executable: FilePath,
        arguments: [String]
    ) async throws -> Int32 {
        let result = try await Subprocess.run(
            .path(.init(executable.string)),
            arguments: Arguments(arguments),
            output: .discarded,
            error: .discarded)
        return statusCode(result.terminationStatus)
    }

    public static func capture(
        executable: FilePath,
        arguments: [String],
        workingDirectory: FilePath,
        environment: [String: String],
        combiningStandardError: Bool = false
    ) async throws -> Capture {
        let keyed = try ChildProcessEnvironment.validated(environment)
        // Combining shares one descriptor between the streams, so what the
        // child interleaved is what the caller reads. Concatenating two
        // separate captures would not preserve that.
        guard !combiningStandardError else {
            let result = try await Subprocess.run(
                .path(.init(executable.string)),
                arguments: Arguments(arguments),
                environment: .custom(keyed),
                workingDirectory: .init(workingDirectory.string),
                output: .bytes(limit: captureLimit),
                error: .combinedWithOutput)
            return Capture(
                status: statusCode(result.terminationStatus),
                standardOutput: result.standardOutput,
                standardError: [])
        }
        let result = try await Subprocess.run(
            .path(.init(executable.string)),
            arguments: Arguments(arguments),
            environment: .custom(keyed),
            workingDirectory: .init(workingDirectory.string),
            output: .bytes(limit: captureLimit),
            error: .bytes(limit: captureLimit))
        return Capture(
            status: statusCode(result.terminationStatus),
            standardOutput: result.standardOutput,
            standardError: result.standardError)
    }

    private static func statusCode(_ status: TerminationStatus) -> Int32 {
        switch status {
        case .exited(let code): Int32(code)
        case .signaled(let signal): 128 &+ Int32(signal)
        }
    }
}
