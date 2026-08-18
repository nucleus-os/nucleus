import ColliderCore
import ColliderPersistence
import ColliderPlatformC
import Foundation
import SystemPackage

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public struct LockOwner: Sendable {
    public let run: String?
    public let task: String?

    public init(run: String? = nil, task: String? = nil) {
        self.run = run
        self.task = task
    }
}

/// One kernel-backed exclusive lock whose holder is recorded inside the locked
/// file.
///
/// The record lives in the lock file rather than beside it so that a lock may
/// live in a directory nobody is allowed to write. The machine-wide execution
/// lease depends on exactly that: provisioning creates one root-owned lock file
/// that every account may open and write, inside a directory writable by none,
/// so an account can hold and describe the lease but can never replace, unlink,
/// or substitute the inode that enforces it.
public final class ColliderFileLock: @unchecked Sendable {
    private let descriptor: FileDescriptor

    public init(
        path: FilePath,
        purpose: String,
        waitForExistingOwner: Bool = true,
        owner: LockOwner = LockOwner()
    ) throws {
        try FileManager.default.createDirectory(
            atPath: path.removingLastComponent().string,
            withIntermediateDirectories: true)
        let descriptor: FileDescriptor
        do {
            descriptor = try FileDescriptor.open(
                path,
                .readWrite,
                options: .create,
                permissions: [.ownerReadWrite, .groupRead, .otherRead])
        } catch let error as Errno {
            throw RuntimeLockFailure.system(
                purpose: purpose,
                path: path,
                code: error.rawValue)
        }
        guard
            collider_lock_exclusive(
                descriptor.rawValue,
                waitForExistingOwner ? 1 : 0) == 0
        else {
            let code = errno
            try? descriptor.close()
            if !waitForExistingOwner && (code == EWOULDBLOCK || code == EAGAIN) {
                throw RuntimeLockFailure.alreadyOwned(purpose)
            }
            throw RuntimeLockFailure.system(purpose: purpose, path: path, code: code)
        }
        self.descriptor = descriptor
        record(owner: owner)
    }

    deinit {
        // A clean release leaves no record, so a record found without a holder
        // is evidence that its process died rather than a current claim.
        _ = ftruncate(descriptor.rawValue, 0)
        _ = collider_unlock(descriptor.rawValue)
        try? descriptor.close()
    }

    /// The holder recorded in the lock file at `path`.
    ///
    /// This is meaningful only to a caller that has just failed to acquire the
    /// lock. The kernel lock is the sole authority on whether work may proceed;
    /// the record only explains an observed wait, so a caller that races a
    /// release may read the departing holder once and then acquire.
    public static func holder(at path: FilePath) -> String? {
        guard let data = FileManager.default.contents(atPath: path.string),
            let text = String(data: data, encoding: .utf8),
            let line = text.split(separator: "\n", maxSplits: 1).first,
            !line.isEmpty
        else { return nil }
        return String(line)
    }

    /// Writes the holder record as one line, then trims the file to it, so a
    /// concurrent reader observes either the previous complete line or this one.
    private func record(owner: LockOwner) {
        let line =
            [
                "pid=\(getpid())",
                "user=\(NSUserName())",
                "run=\(owner.run ?? "unknown")",
                "task=\(owner.task ?? "unknown")",
                "started=\(ISO8601DateFormatter().string(from: Date()))",
            ].joined(separator: " ") + "\n"
        let bytes = Array(line.utf8)
        guard (try? descriptor.writeAll(toAbsoluteOffset: 0, bytes)) != nil else { return }
        _ = ftruncate(descriptor.rawValue, off_t(bytes.count))
    }
}

public enum RuntimeLockFailure: Error, CustomStringConvertible, Sendable {
    case alreadyOwned(String)
    case system(purpose: String, path: FilePath, code: Int32)

    public var description: String {
        switch self {
        case .alreadyOwned(let purpose): "\(purpose) is already running"
        case .system(let purpose, let path, let code):
            "could not acquire \(purpose) lock at \(path): \(Errno(rawValue: code))"
        }
    }
}

/// Acquires one kernel-backed lock without blocking the Swift executor. A run
/// records the interval only when contention actually occurs, and the recorded
/// resource names the holder it is waiting behind, so a wait on a lease shared
/// with another account reads as contention rather than as a stalled command.
public func acquireColliderFileLock(
    path: FilePath,
    purpose: String,
    resource: String,
    run: RunHandle? = nil,
    registry: RunRegistry? = nil,
    task: TaskID? = nil,
    cancellation: RuntimeCancellation
) async throws -> ColliderFileLock {
    var recordedWait = false
    // Both records use one string: the reduction that renders a wait removes it
    // by resource equality.
    var recordedResource = resource
    while true {
        try Task.checkCancellation()
        if await cancellation.wasInterrupted() { throw CancellationError() }
        do {
            let lock = try ColliderFileLock(
                path: path,
                purpose: purpose,
                waitForExistingOwner: false,
                owner: LockOwner(
                    run: run?.id.rawValue,
                    task: task?.rawValue))
            if recordedWait, let run, let registry {
                try? await registry.record(
                    .wait(.finished(task: task, resource: recordedResource)),
                    in: run)
            }
            return lock
        } catch RuntimeLockFailure.alreadyOwned {
            if !recordedWait {
                recordedWait = true
                if let holder = ColliderFileLock.holder(at: path) {
                    recordedResource = "\(resource) held by \(holder)"
                }
                if let run, let registry {
                    try? await registry.record(
                        .wait(.started(task: task, resource: recordedResource)),
                        in: run)
                }
            }
            try await ContinuousClock().sleep(for: .milliseconds(100))
        }
    }
}
