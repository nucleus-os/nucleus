// LinuxFileWatcher — an inotify reactor source for one file.
//
// It watches the file's *parent directory*, filtered by name, rather than the
// file itself. That is the whole design: editors overwhelmingly save by writing
// a temporary file and renaming it into place, which replaces the inode. A
// watch on the file would survive exactly one save and then silently observe
// nothing forever — the failure mode where reload appears to work once and then
// stops, which is worse than not reloading at all.

import Glibc

/// Watches a single path for content changes and disappearance.
///
/// Single-threaded on the owner's actor. Holds an owned inotify descriptor and
/// a raw read buffer, so it is a reference type with explicit teardown.
@MainActor
@safe package final class LinuxFileWatcher: LinuxReactorSource {
    /// What the watcher observed since the last drain.
    package struct Change: Equatable, Sendable {
        /// The file was created, replaced, or written in place.
        package var contentChanged = false
        /// The file was removed or renamed away.
        package var removed = false
        /// The watched directory itself moved or disappeared. The owner must
        /// discard this source and periodically attempt to create a new one.
        package var watchInvalidated = false

        package var isEmpty: Bool {
            !contentChanged && !removed && !watchInvalidated
        }
    }

    /// inotify's header is fixed-size; the name follows it inline.
    private static let headerSize = MemoryLayout<inotify_event>.size
    /// Enough for a burst of saves without a second read in the common case.
    private static let bufferCapacity = 8 * 1024

    private let descriptor: Int32
    private let watch: Int32
    private let fileName: String
    private let buffer: UnsafeMutableRawPointer
    /// Fired on the owner's actor when a drain observed something relevant.
    package var onChange: (@MainActor (Change) -> Void)?

    /// Watch `path`. Returns nil when inotify is unavailable or the parent
    /// directory does not exist.
    ///
    /// A missing parent directory is deliberately not an error worth
    /// synthesizing around: it means the user has never written a
    /// configuration, so there is nothing to reload yet, and creating one is
    /// already a deliberate act they can follow with a restart.
    package init?(path: String) {
        let separator = path.lastIndex(of: "/")
        guard let separator, separator != path.startIndex else { return nil }
        let directory = String(path[path.startIndex..<separator])
        let name = String(path[path.index(after: separator)...])
        guard !name.isEmpty else { return nil }

        let fd = inotify_init1(Int32(IN_NONBLOCK) | Int32(IN_CLOEXEC))
        guard fd >= 0 else { return nil }
        // CLOSE_WRITE catches an in-place save; MOVED_TO catches the atomic
        // rename; CREATE catches a fresh file; DELETE and MOVED_FROM catch
        // removal, which must fall back to defaults rather than keep stale
        // settings that no file supports any more.
        let mask =
            UInt32(IN_CLOSE_WRITE) | UInt32(IN_MOVED_TO)
            | UInt32(IN_CREATE) | UInt32(IN_DELETE) | UInt32(IN_MOVED_FROM)
            | UInt32(IN_DELETE_SELF) | UInt32(IN_MOVE_SELF)
        // The String → const char* bridge is the unsafe part, not the call.
        let wd = unsafe inotify_add_watch(fd, directory, mask)
        guard wd >= 0 else {
            close(fd)
            return nil
        }
        descriptor = fd
        watch = wd
        fileName = name
        unsafe buffer = .allocate(
            byteCount: Self.bufferCapacity,
            alignment: MemoryLayout<inotify_event>.alignment)
    }

    isolated deinit {
        unsafe buffer.deallocate()
        close(descriptor)
    }

    // MARK: LinuxReactorSource

    package var fileDescriptor: Int32 { descriptor }
    package var pollEvents: Int16 { Int16(POLLIN) }
    /// Purely descriptor-driven; it never needs a timeout wake.
    package func timeoutMicroseconds() -> UInt64? { nil }

    @discardableResult
    package func process() -> Bool {
        let change = drain()
        guard !change.isEmpty else { return false }
        onChange?(change)
        return true
    }

    package func transportDidFail(operation: String) {
        // A dead inotify descriptor costs reload, not the session. The owner
        // logs; there is nothing to repair here without re-creating the
        // watcher, which the owner decides.
    }

    // MARK: draining

    /// Read every queued event, coalescing them into one `Change`.
    ///
    /// Coalescing matters because a single save commonly produces several
    /// events — a create followed by a close-write, or a rename preceded by a
    /// temporary file's own events. One reload per drain is both correct and
    /// idempotent.
    func drain() -> Change {
        var change = Change()
        while true {
            let count = unsafe read(
                descriptor, buffer, Self.bufferCapacity)
            if count <= 0 { break }
            accumulate(byteCount: count, into: &change)
        }
        return change
    }

    private func accumulate(byteCount: Int, into change: inout Change) {
        var offset = 0
        while offset + Self.headerSize <= byteCount {
            let raw = unsafe UnsafeRawBufferPointer(
                start: buffer, count: byteCount)
            let mask = unsafe raw.loadUnaligned(
                fromByteOffset: offset + 4, as: UInt32.self)
            let nameLength = Int(
                unsafe raw.loadUnaligned(
                    fromByteOffset: offset + 12, as: UInt32.self))
            let nameStart = offset + Self.headerSize
            guard nameStart + nameLength <= byteCount else { break }

            if mask
                & (UInt32(IN_DELETE_SELF) | UInt32(IN_MOVE_SELF)
                    | UInt32(IN_IGNORED)) != 0
            {
                change.watchInvalidated = true
                change.removed = true
                change.contentChanged = false
            }
            if unsafe matchesFileName(
                in: raw, start: nameStart, length: nameLength)
            {
                if mask & (UInt32(IN_DELETE) | UInt32(IN_MOVED_FROM)) != 0 {
                    change.removed = true
                    change.contentChanged = false
                } else {
                    change.contentChanged = true
                    change.removed = false
                }
            }
            offset = nameStart + nameLength
        }
    }

    /// inotify pads the name with NULs to an alignment boundary, so compare
    /// against the first NUL rather than the padded length.
    private func matchesFileName(
        in raw: UnsafeRawBufferPointer, start: Int, length: Int
    ) -> Bool {
        var end = start
        while end < start + length, unsafe raw[end] != 0 { end += 1 }
        let candidate = unsafe String(
            decoding: raw[start..<end], as: UTF8.self)
        return candidate == fileName
    }
}
