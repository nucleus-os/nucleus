import Glibc
import NucleusShellLoop
import NucleusUI

/// A transient descriptor returned to the shell immediately before `poll`.
///
/// This value borrows the executor's descriptor. It must not be retained across
/// a call to `processPollResult`, which may complete and close the transfer.
public struct ShellDataTransferPollDescriptor: Sendable, Equatable {
    public let token: UInt64
    public let fileDescriptor: Int32
    public let events: Int16
}

enum DataTransferFailure: Error, Sendable, Equatable {
    case cancelled
    case transport(String)
}

/// Lexical ownership for descriptors received from `pipe2` or Wayland.
///
/// Stored transfer state cannot contain this value because it is move-only. It
/// must be consumed into `StoredTransferFileDescriptor`, the one reference owner
/// retained by a pending transfer.
struct TransferFileDescriptor: ~Copyable {
    private(set) var rawValue: Int32

    init(owning rawValue: Int32) {
        precondition(rawValue >= 0)
        self.rawValue = rawValue
    }

    consuming func release() -> Int32 {
        let result = rawValue
        discard self
        return result
    }

    deinit {
        if rawValue >= 0 {
            _ = Glibc.close(rawValue)
        }
    }
}

/// The single reference owner used by long-lived transfer state.
final class StoredTransferFileDescriptor {
    private var descriptor: Int32
    private(set) var closeCount = 0

    init(owning descriptor: consuming TransferFileDescriptor) {
        self.descriptor = descriptor.release()
    }

    var borrowedValue: Int32 {
        precondition(descriptor >= 0, "borrowing a closed transfer descriptor")
        return descriptor
    }

    var isOpen: Bool { descriptor >= 0 }

    func close() {
        guard descriptor >= 0 else { return }
        let closing = descriptor
        descriptor = -1
        closeCount += 1
        _ = Glibc.close(closing)
    }

    deinit {
        close()
    }
}

@MainActor
final class DataTransferExecutor {
    typealias ReadCompletion =
        @MainActor (Result<[UInt8], DataTransferFailure>) -> Void
    typealias FailureHandler =
        @MainActor (_ operation: String, _ failure: DataTransferFailure) -> Void

    private final class PendingRead {
        let descriptor: StoredTransferFileDescriptor
        let operation: String
        let byteLimit: Int
        let deadlineNanoseconds: UInt64
        let completion: ReadCompletion
        var bytes: [UInt8] = []

        init(
            descriptor: StoredTransferFileDescriptor,
            operation: String,
            byteLimit: Int,
            deadlineNanoseconds: UInt64,
            completion: @escaping ReadCompletion
        ) {
            self.descriptor = descriptor
            self.operation = operation
            self.byteLimit = byteLimit
            self.deadlineNanoseconds = deadlineNanoseconds
            self.completion = completion
        }
    }

    private final class PendingWrite {
        let descriptor: StoredTransferFileDescriptor
        let operation: String
        let payload: [UInt8]
        let deadlineNanoseconds: UInt64
        var offset = 0

        init(
            descriptor: StoredTransferFileDescriptor,
            operation: String,
            payload: [UInt8],
            deadlineNanoseconds: UInt64
        ) {
            self.descriptor = descriptor
            self.operation = operation
            self.payload = payload
            self.deadlineNanoseconds = deadlineNanoseconds
        }
    }

    private enum Transfer {
        case read(PendingRead)
        case write(PendingWrite)

        var descriptor: StoredTransferFileDescriptor {
            switch self {
            case .read(let read): read.descriptor
            case .write(let write): write.descriptor
            }
        }

        var deadlineNanoseconds: UInt64 {
            switch self {
            case .read(let read): read.deadlineNanoseconds
            case .write(let write): write.deadlineNanoseconds
            }
        }
    }

    private var nextToken: UInt64 = 1
    private var transfers: [UInt64: Transfer] = [:]
    private let failureHandler: FailureHandler
    private let pollSetDidChange: @MainActor () -> Void

    init(
        pollSetDidChange: @escaping @MainActor () -> Void = {},
        failureHandler: @escaping FailureHandler
    ) {
        self.pollSetDidChange = pollSetDidChange
        self.failureHandler = failureHandler
    }

    var activeTransferCount: Int { transfers.count }

    var pollDescriptors: [ShellDataTransferPollDescriptor] {
        transfers.compactMap { token, transfer in
            guard transfer.descriptor.isOpen else { return nil }
            let events: Int16
            switch transfer {
            case .read:
                events = Int16(POLLIN)
            case .write:
                events = Int16(POLLOUT)
            }
            return ShellDataTransferPollDescriptor(
                token: token,
                fileDescriptor: transfer.descriptor.borrowedValue,
                events: events)
        }
    }

    func installRead(
        owning descriptor: consuming TransferFileDescriptor,
        operation: String,
        byteLimit: Int,
        deadlineNanoseconds: UInt64,
        completion: @escaping ReadCompletion
    ) -> UInt64 {
        precondition(byteLimit >= 0)
        let token = allocateToken()
        transfers[token] = .read(PendingRead(
            descriptor: StoredTransferFileDescriptor(owning: descriptor),
            operation: operation,
            byteLimit: byteLimit,
            deadlineNanoseconds: deadlineNanoseconds,
            completion: completion))
        pollSetDidChange()
        return token
    }

    func installWrite(
        owning descriptor: consuming TransferFileDescriptor,
        operation: String,
        payload: [UInt8],
        deadlineNanoseconds: UInt64
    ) -> UInt64? {
        installWrite(
            owning: StoredTransferFileDescriptor(owning: descriptor),
            operation: operation,
            payload: payload,
            deadlineNanoseconds: deadlineNanoseconds)
    }

    func installWrite(
        owning descriptor: StoredTransferFileDescriptor,
        operation: String,
        payload: [UInt8],
        deadlineNanoseconds: UInt64
    ) -> UInt64? {
        let stored = descriptor
        guard !payload.isEmpty else {
            stored.close()
            return nil
        }
        let token = allocateToken()
        transfers[token] = .write(PendingWrite(
            descriptor: stored,
            operation: operation,
            payload: payload,
            deadlineNanoseconds: deadlineNanoseconds))
        pollSetDidChange()
        return token
    }

    func processPollResult(
        token: UInt64,
        result: ShellPollResult,
        nowNanoseconds: UInt64
    ) {
        guard let transfer = transfers[token] else { return }
        if result.isInvalid {
            fail(
                token: token,
                operation: operation(for: transfer),
                failure: .transport("poll reported an invalid descriptor"))
            return
        }

        switch transfer {
        case .read(let pending):
            if result.isReadable || result.isHungUp {
                drainRead(token: token, pending: pending)
            } else if result.hasError {
                fail(
                    token: token,
                    operation: pending.operation,
                    failure: .transport("read descriptor failed"))
            }
        case .write(let pending):
            if result.isWritable {
                drainWrite(token: token, pending: pending)
            } else if result.isTerminal {
                fail(
                    token: token,
                    operation: pending.operation,
                    failure: .transport("write peer closed"))
            }
        }

        expireTransfers(nowNanoseconds: nowNanoseconds)
    }

    func nanosecondsUntilDeadline(nowNanoseconds: UInt64) -> UInt64? {
        transfers.values.reduce(nil as UInt64?) { earliest, transfer in
            let remaining = transfer.deadlineNanoseconds > nowNanoseconds
                ? transfer.deadlineNanoseconds - nowNanoseconds
                : 0
            return min(earliest ?? remaining, remaining)
        }
    }

    func expireTransfers(nowNanoseconds: UInt64) {
        let expired = transfers.compactMap { token, transfer in
            transfer.deadlineNanoseconds <= nowNanoseconds ? token : nil
        }
        for token in expired {
            guard let transfer = transfers[token] else { continue }
            fail(
                token: token,
                operation: operation(for: transfer),
                failure: .transport("transfer timed out"))
        }
    }

    func cancelRead(token: UInt64) {
        guard case .read? = transfers[token] else { return }
        finishRead(token: token, result: .failure(.cancelled))
    }

    func cancel(token: UInt64) {
        guard let transfer = transfers[token] else { return }
        switch transfer {
        case .read:
            finishRead(token: token, result: .failure(.cancelled))
        case .write:
            transfers.removeValue(forKey: token)?.descriptor.close()
            pollSetDidChange()
        }
    }

    func failRead(token: UInt64, failure: DataTransferFailure) {
        guard case .read? = transfers[token] else { return }
        finishRead(token: token, result: .failure(failure))
    }

    func shutdown() {
        let tokens = Array(transfers.keys)
        for token in tokens {
            guard let transfer = transfers[token] else { continue }
            switch transfer {
            case .read:
                finishRead(token: token, result: .failure(.cancelled))
            case .write:
                transfers.removeValue(forKey: token)?.descriptor.close()
                pollSetDidChange()
            }
        }
    }

    private func drainRead(token: UInt64, pending: PendingRead) {
        withUnsafeTemporaryAllocation(
            of: UInt8.self,
            capacity: 16 * 1024
        ) { scratch in
            while transfers[token] != nil {
                let count = Glibc.read(
                    pending.descriptor.borrowedValue,
                    scratch.baseAddress,
                    scratch.count)
                if count > 0 {
                    let byteCount = Int(count)
                    guard byteCount <= pending.byteLimit - pending.bytes.count else {
                        fail(
                            token: token,
                            operation: pending.operation,
                            failure: .transport(
                                "transfer exceeded \(pending.byteLimit) byte limit"))
                        return
                    }
                    pending.bytes.append(
                        contentsOf: UnsafeBufferPointer(
                            start: scratch.baseAddress,
                            count: byteCount))
                    continue
                }
                if count == 0 {
                    finishRead(token: token, result: .success(pending.bytes))
                    return
                }
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                fail(
                    token: token,
                    operation: pending.operation,
                    failure: .transport(
                        "transfer read failed: "
                            + String(cString: strerror(errno))))
                return
            }
        }
    }

    private func drainWrite(token: UInt64, pending: PendingWrite) {
        while pending.offset < pending.payload.count {
            let count = pending.payload.withUnsafeBytes { bytes in
                Glibc.write(
                    pending.descriptor.borrowedValue,
                    bytes.baseAddress?.advanced(by: pending.offset),
                    pending.payload.count - pending.offset)
            }
            if count > 0 {
                pending.offset += Int(count)
                continue
            }
            if count == 0 {
                fail(
                    token: token,
                    operation: pending.operation,
                    failure: .transport("write made no progress"))
                return
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            fail(
                token: token,
                operation: pending.operation,
                failure: .transport(
                    "transfer write failed: "
                        + String(cString: strerror(errno))))
            return
        }
        transfers.removeValue(forKey: token)?.descriptor.close()
        pollSetDidChange()
    }

    private func finishRead(
        token: UInt64,
        result: Result<[UInt8], DataTransferFailure>
    ) {
        guard case .read(let pending)? = transfers.removeValue(forKey: token)
        else { return }
        pending.descriptor.close()
        pollSetDidChange()
        pending.completion(result)
    }

    private func fail(
        token: UInt64,
        operation: String,
        failure: DataTransferFailure
    ) {
        guard let transfer = transfers[token] else { return }
        switch transfer {
        case .read:
            finishRead(token: token, result: .failure(failure))
        case .write:
            transfers.removeValue(forKey: token)?.descriptor.close()
            pollSetDidChange()
            failureHandler(operation, failure)
        }
    }

    private func operation(for transfer: Transfer) -> String {
        switch transfer {
        case .read(let read): read.operation
        case .write(let write): write.operation
        }
    }

    private func allocateToken() -> UInt64 {
        let token = nextToken
        nextToken &+= 1
        precondition(nextToken != 0, "data-transfer token space exhausted")
        return token
    }
}
