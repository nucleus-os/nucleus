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
package enum CapturedChildProcess {
    package struct Capture: Sendable {
        package let status: Int32
        package let standardOutput: [UInt8]
        package let standardError: [UInt8]

        package var standardOutputText: String {
            String(decoding: standardOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        package var standardErrorText: String {
            String(decoding: standardError, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    package enum Failure: Error, CustomStringConvertible {
        case invalidEnvironmentName(String)
        case invalidEnvironmentValue(name: String)

        package var description: String {
            switch self {
            case .invalidEnvironmentName(let name):
                "child process environment name is not usable: \(name)"
            case .invalidEnvironmentValue(let name):
                "child process environment value is not usable: \(name)"
            }
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
    package static let captureLimit = 1024 * 1_024 * 1_024

    package static func capture(
        executable: FilePath,
        arguments: [String],
        workingDirectory: FilePath,
        environment: [String: String]
    ) async throws -> Capture {
        // `Environment.Key(rawValue:)` accepts anything, so a name carrying a
        // NUL or an `=` would reach the child as a corrupted environment entry
        // rather than as an error. These are the same checks the runtime makes
        // before building its own environment.
        var keyed: [Subprocess.Environment.Key: String] = [:]
        for (name, value) in environment {
            guard !name.utf8.contains(0), !name.contains("="),
                name.utf8.first.map({ !(48...57).contains($0) }) ?? true,
                let key = Subprocess.Environment.Key(rawValue: name)
            else {
                throw Failure.invalidEnvironmentName(name)
            }
            guard !value.utf8.contains(0) else {
                throw Failure.invalidEnvironmentValue(name: name)
            }
            keyed[key] = value
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
