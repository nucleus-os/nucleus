import Glibc
import NucleusLinuxPrimitivesC

/// The process-wide Linux monotonic clock, expressed as saturating nanoseconds.
package enum LinuxMonotonicClock {
    package static func nowNanoseconds() -> UInt64 {
        var value = timespec()
        guard unsafe clock_gettime(CLOCK_MONOTONIC, &value) == 0,
            value.tv_sec >= 0,
            value.tv_nsec >= 0
        else { return 0 }
        let seconds = UInt64(value.tv_sec)
        let nanoseconds = UInt64(value.tv_nsec)
        let scaled = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !scaled.overflow else { return .max }
        let result = scaled.partialValue.addingReportingOverflow(nanoseconds)
        return result.overflow ? .max : result.partialValue
    }
}

/// A lifetime-scoped borrowed Linux file descriptor.
///
/// The value cannot escape the borrow supplied by
/// `LinuxOwnedFileDescriptor.withBorrowedDescriptor`. It never closes the
/// underlying descriptor and never implies ownership.
@safe package struct LinuxBorrowedFileDescriptor: ~Escapable, Sendable {
    package let rawValue: Int32

    init(_ rawValue: Int32) {
        self.rawValue = rawValue
    }
}

/// Unique ownership of one Linux file descriptor.
///
/// This value is move-only: ownership cannot be accidentally aliased. Use
/// `duplicate()` when the kernel object needs a second independently owned
/// descriptor, or `withBorrowedDescriptor` for a scoped syscall borrow.
@safe package struct LinuxOwnedFileDescriptor: ~Copyable, Sendable {
    private var descriptor: Int32

    package init(adopting descriptor: Int32) {
        precondition(descriptor >= 0, "cannot own an invalid file descriptor")
        self.descriptor = descriptor
    }

    private borrowing func validDescriptor() -> Int32 {
        precondition(descriptor >= 0, "file descriptor ownership was transferred")
        return descriptor
    }

    package borrowing func withBorrowedDescriptor<
        Result: ~Copyable, Failure: Error
    >(
        _ body: (borrowing LinuxBorrowedFileDescriptor) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        try body(LinuxBorrowedFileDescriptor(validDescriptor()))
    }

    package borrowing func duplicate() -> LinuxOwnedFileDescriptor? {
        let copy = dup(validDescriptor())
        guard copy >= 0 else { return nil }
        return LinuxOwnedFileDescriptor(adopting: copy)
    }

    package consuming func take() -> Int32 {
        let result = validDescriptor()
        descriptor = -1
        return result
    }

    deinit {
        if descriptor >= 0 {
            _ = close(descriptor)
        }
    }
}

/// Shared lifetime ownership of one immutable descriptor handle.
///
/// Use this only when value copies must intentionally keep the same descriptor
/// alive. The handle itself is never exposed as owned: callers receive a lexical
/// borrow, or explicitly duplicate it into unique ownership.
@safe package final class LinuxSharedFileDescriptor: Sendable {
    private let descriptor: LinuxOwnedFileDescriptor

    package init(adopting descriptor: Int32) {
        self.descriptor = LinuxOwnedFileDescriptor(adopting: descriptor)
    }

    package init(adopting descriptor: consuming LinuxOwnedFileDescriptor) {
        self.descriptor = consume descriptor
    }

    package func withBorrowedDescriptor<
        Result: ~Copyable, Failure: Error
    >(
        _ body: (borrowing LinuxBorrowedFileDescriptor) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        try descriptor.withBorrowedDescriptor(body)
    }

    package func duplicate() -> LinuxOwnedFileDescriptor? {
        descriptor.duplicate()
    }
}

package struct LinuxFileError: Error, Equatable, Sendable {
    package let operation: String
    package let code: Int32

    package init(operation: String, code: Int32) {
        self.operation = operation
        self.code = code
    }
}

/// An immutable, sealed memfd containing one stable byte payload.
///
/// Creation is transactional: a partially written or unsealed descriptor never
/// escapes. Successful values forbid writes, growth, shrinking, and additional
/// seal changes before they can be shared with another process.
@safe package struct LinuxSealedFile: ~Copyable, Sendable {
    private var descriptor: LinuxOwnedFileDescriptor
    package let size: Int

    package init(name: String, bytes: borrowing [UInt8]) throws(LinuxFileError) {
        let raw = name.withCString { namePointer in
            unsafe nucleus_linux_create_sealable_memfd(namePointer)
        }
        guard raw >= 0 else {
            throw LinuxFileError(operation: "memfd_create", code: errno)
        }
        let owned = LinuxOwnedFileDescriptor(adopting: raw)

        guard ftruncate(raw, off_t(bytes.count)) == 0 else {
            throw LinuxFileError(operation: "ftruncate", code: errno)
        }
        if !bytes.isEmpty {
            let writeError = bytes.withUnsafeBytes { buffer -> Int32? in
                guard let base = buffer.baseAddress else { return EFAULT }
                var written = 0
                while written < buffer.count {
                    let result = unsafe Glibc.write(
                        raw,
                        base.advanced(by: written),
                        buffer.count - written)
                    if result > 0 {
                        written += result
                    } else if result < 0, errno == EINTR {
                        continue
                    } else {
                        return errno
                    }
                }
                return nil
            }
            if let writeError {
                throw LinuxFileError(operation: "write", code: writeError)
            }
        }
        guard nucleus_linux_seal_memfd_immutable(raw) == 0
        else {
            throw LinuxFileError(
                operation: "fcntl(F_ADD_SEALS)",
                code: errno)
        }

        self.descriptor = consume owned
        self.size = bytes.count
    }

    package borrowing func withBorrowedDescriptor<
        Result: ~Copyable, Failure: Error
    >(
        _ body: (borrowing LinuxBorrowedFileDescriptor) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        try descriptor.withBorrowedDescriptor(body)
    }

    package borrowing func duplicateDescriptor() -> LinuxOwnedFileDescriptor? {
        descriptor.duplicate()
    }

    package consuming func takeDescriptor() -> LinuxOwnedFileDescriptor {
        consume descriptor
    }
}
