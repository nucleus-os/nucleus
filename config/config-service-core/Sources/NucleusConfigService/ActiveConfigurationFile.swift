import Foundation
import Glibc
import NucleusConfigIO
import NucleusSessionProtocol

package enum ActiveConfigurationFileFailure:
    Error, CustomStringConvertible, Sendable
{
    case unavailable
    case invalidSource([ConfigurationDiagnosticPublication])
    case system(operation: String, error: Int32)

    package var description: String {
        switch self {
        case .unavailable:
            "no active configuration path is available"
        case .invalidSource:
            "replacement configuration is invalid"
        case .system(let operation, let error):
            "\(operation) failed: errno \(error)"
        }
    }
}

/// The service's sole filesystem authority over the active configuration.
package struct ActiveConfigurationFile: Sendable {
    package let path: String

    package init?(path: String? = ConfigFile.defaultPath()) {
        guard let path else { return nil }
        self.path = path
    }

    package func load() -> ConfigLoadOutcome {
        ConfigFile.load(path: path)
    }

    /// Validate, durably replace, then return the already-resolved snapshot.
    ///
    /// The caller publishes this result directly. The resulting watcher event
    /// is a semantic duplicate and therefore cannot advance the generation.
    package func replace(source: String) throws -> ConfigLoadOutcome {
        let result = ConfigLoader.load(text: source)
        if case .failed(let diagnostics) = result {
            throw ActiveConfigurationFileFailure.invalidSource(
                diagnostics.publications)
        }
        try persist(Array(source.utf8))
        return result
    }

    private func persist(_ bytes: [UInt8]) throws {
        guard let separator = path.lastIndex(of: "/"),
            separator != path.startIndex
        else {
            throw ActiveConfigurationFileFailure.unavailable
        }
        let directory = String(path[..<separator])
        do {
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch {
            throw ActiveConfigurationFileFailure.system(
                operation: "create configuration directory",
                error: errno)
        }
        let temporary = path + ".tmp.\(getpid()).\(monotonicNanoseconds())"
        let descriptor = unsafe open(
            temporary,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else {
            throw ActiveConfigurationFileFailure.system(
                operation: "open temporary configuration",
                error: errno)
        }
        var published = false
        defer {
            _ = close(descriptor)
            if !published { _ = unsafe unlink(temporary) }
        }

        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw in
                unsafe write(
                    descriptor,
                    raw.baseAddress!.advanced(by: offset),
                    bytes.count - offset)
            }
            guard written > 0 else {
                throw ActiveConfigurationFileFailure.system(
                    operation: "write temporary configuration",
                    error: errno)
            }
            offset += written
        }
        guard fsync(descriptor) == 0 else {
            throw ActiveConfigurationFileFailure.system(
                operation: "flush temporary configuration",
                error: errno)
        }
        guard unsafe rename(temporary, path) == 0 else {
            throw ActiveConfigurationFileFailure.system(
                operation: "replace active configuration",
                error: errno)
        }
        published = true

        let directoryDescriptor = unsafe open(
            directory, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directoryDescriptor >= 0 else {
            throw ActiveConfigurationFileFailure.system(
                operation: "open configuration directory",
                error: errno)
        }
        defer { _ = close(directoryDescriptor) }
        guard fsync(directoryDescriptor) == 0 else {
            throw ActiveConfigurationFileFailure.system(
                operation: "flush configuration directory",
                error: errno)
        }
    }

    private func monotonicNanoseconds() -> UInt64 {
        var time = timespec()
        unsafe clock_gettime(CLOCK_MONOTONIC, &time)
        return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
    }
}
