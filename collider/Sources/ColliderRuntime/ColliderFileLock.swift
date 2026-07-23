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

public final class ColliderFileLock: @unchecked Sendable {
    private let descriptor: FileDescriptor
    private let ownerRecord: FilePath

    public init(
        path: FilePath,
        purpose: String,
        waitForExistingOwner: Bool = true,
        owner: LockOwner = LockOwner()
    ) throws {
        try FileManager.default.createDirectory(
            atPath: path.removingLastComponent().string,
            withIntermediateDirectories: true)
        let descriptor = try FileDescriptor.open(
            path,
            .readWrite,
            options: .create,
            permissions: [.ownerReadWrite, .groupRead, .otherRead])
        guard collider_lock_exclusive(
            descriptor.rawValue,
            waitForExistingOwner ? 1 : 0) == 0
        else {
            let code = errno
            try? descriptor.close()
            if !waitForExistingOwner && (code == EWOULDBLOCK || code == EAGAIN) {
                throw RuntimeLockFailure.alreadyOwned(purpose)
            }
            throw RuntimeLockFailure.system(purpose: purpose, code: code)
        }
        let record = [
            "pid=\(getpid())",
            "run=\(owner.run ?? "unknown")",
            "task=\(owner.task ?? "unknown")",
            "started=\(ISO8601DateFormatter().string(from: Date()))",
        ].joined(separator: "\n") + "\n"
        let ownerRecord = FilePath(path.string + ".owner")
        do {
            try DurableFile.write(Data(record.utf8), to: ownerRecord)
        } catch {
            _ = collider_unlock(descriptor.rawValue)
            try? descriptor.close()
            throw error
        }
        self.descriptor = descriptor
        self.ownerRecord = ownerRecord
    }

    deinit {
        try? FileManager.default.removeItem(atPath: ownerRecord.string)
        _ = collider_unlock(descriptor.rawValue)
        try? descriptor.close()
    }
}

public enum RuntimeLockFailure: Error, CustomStringConvertible, Sendable {
    case alreadyOwned(String)
    case system(purpose: String, code: Int32)

    public var description: String {
        switch self {
        case .alreadyOwned(let purpose): "\(purpose) is already running"
        case .system(let purpose, let code):
            "could not acquire \(purpose) lock: errno \(code)"
        }
    }
}
