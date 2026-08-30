import ColliderPlatformC
import Foundation
import SystemPackage

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Why removing a directory tree was refused.
///
/// `FileManager.removeItem` reports the path it was handed, so a denial
/// anywhere beneath a tree of thousands of entries names only the root and
/// leaves nothing to act on. The kernel checks an unlink against the containing
/// directory rather than the entry, so the first directory the process cannot
/// write is the denial; a `chflags` immutability bit refuses it instead, on a
/// path whose mode looks fine. Both are properties of the tree. The effective
/// identity is the remaining alternative, and it is the one thing inspecting the
/// tree afterwards cannot establish.
package enum RemovalDenial {
    package struct Failure: Error, CustomStringConvertible {
        package let path: FilePath
        package let reason: String
        package let diagnosis: String

        package var description: String {
            "\(reason) [\(diagnosis)]"
        }
    }

    /// Remove a tree, naming the entry and syscall that refused.
    ///
    /// `FileManager.removeItem` reports only the path it was handed, and its
    /// recursive delete has been observed refusing a tree whose every entry the
    /// process can unlink -- with the containing directory writable, no
    /// immutability flag anywhere, and a create-and-unlink probe in that same
    /// directory succeeding in the same instant. Walking the tree here removes
    /// exactly what the kernel is asked about, and turns any refusal into the
    /// one path and errno worth acting on.
    package static func removeTree(_ root: FilePath) throws {
        guard let metadata = try? root.stat(followTargetSymlink: false) else {
            return
        }
        if metadata.type == .directory {
            let names =
                (try? FileManager.default.contentsOfDirectory(atPath: root.string)) ?? []
            for name in names {
                try removeTree(root.appending(name))
            }
            guard removed(root, by: { unsafe rmdir($0) }) else {
                throw Failure(
                    path: root,
                    reason: "rmdir failed: \(Errno(rawValue: errno))",
                    diagnosis: diagnose(root))
            }
            return
        }
        guard removed(root, by: { unsafe unlink($0) }) else {
            throw Failure(
                path: root,
                reason: "unlink failed: \(Errno(rawValue: errno))",
                diagnosis: diagnose(root))
        }
    }

    /// Remove one entry, clearing an access-control entry that refuses it.
    ///
    /// A store holds reconstructible state its owner must always be able to
    /// collect, and an entry copied in from a source tree can deny exactly that
    /// -- to the identity the entry names, and to everyone else by ownership,
    /// which strands the content permanently. Staging no longer carries such an
    /// entry in, so this is what releases the copies made before it stopped.
    /// Clearing happens only on the entry being deleted and only after the
    /// kernel has refused, so it narrows nothing a caller had not already
    /// decided to remove.
    private static func removed(
        _ path: FilePath,
        by remove: (String) -> Int32
    ) -> Bool {
        if remove(path.string) == 0 { return true }
        guard errno == EACCES || errno == EPERM else { return false }
        guard unsafe collider_clear_acl(path.string) == 0 else { return false }
        return remove(path.string) == 0
    }

    package static func diagnose(_ root: FilePath) -> String {
        let parent = root.removingLastComponent()
        var notes = [
            "running as uid \(getuid()) euid \(geteuid()) "
                + "gid \(getgid()) egid \(getegid())"
        ]
        notes.append("target \(describe(root))")
        notes.append("parent \(describe(parent))")
        // Unlinking an entry is checked against the containing directory, so
        // the parent is the permission that matters and the only one a walk of
        // the tree never visits. `access` answers for the real identity and the
        // probe answers for the effective one; a disagreement between them is
        // itself the finding.
        notes.append(
            unsafe access(parent.string, W_OK | X_OK) == 0
                ? "parent passes access(W_OK|X_OK)"
                : "parent fails access(W_OK|X_OK): \(Errno(rawValue: errno))")
        notes.append("parent write probe: \(probeWrite(in: parent))")

        var scanned = 0
        var blocked: String?
        var flagged: String?
        let enumerator = FileManager.default.enumerator(atPath: root.string)
        while let relative = enumerator?.nextObject() as? String {
            scanned += 1
            let entry = root.appending(relative)
            if blocked == nil, entry.isDirectory,
                unsafe access(entry.string, W_OK | X_OK) != 0
            {
                blocked = "first unwritable directory \(describe(entry))"
            }
            if flagged == nil, immutabilityFlags(of: entry) != 0 {
                flagged = "first flagged entry \(describe(entry))"
            }
            if blocked != nil, flagged != nil { break }
        }
        notes.append("scanned \(scanned) entries")
        notes.append(blocked ?? "every directory is writable by this process")
        notes.append(flagged ?? "no entry carries an immutability flag")
        return notes.joined(separator: "; ")
    }

    /// Whether this process can actually create and unlink in a directory.
    ///
    /// `access` reports for the real identity while the kernel enforces the
    /// effective one, so the syscalls the removal itself uses are the only
    /// honest answer.
    private static func probeWrite(in directory: FilePath) -> String {
        let probe = directory.appending(".collider-removal-probe-\(getpid())")
        guard
            let descriptor = try? FileDescriptor.open(
                probe, .writeOnly, options: [.create, .exclusiveCreate],
                permissions: .ownerReadWrite)
        else {
            return "create failed: \(Errno(rawValue: errno))"
        }
        try? descriptor.close()
        guard unsafe unlink(probe.string) == 0 else {
            let failure = Errno(rawValue: errno)
            return "created but unlink failed: \(failure)"
        }
        return "created and unlinked"
    }

    private static func describe(_ path: FilePath) -> String {
        var info = stat()
        guard unsafe lstat(path.string, &info) == 0 else {
            return "\(path) (unreadable: \(Errno(rawValue: errno)))"
        }
        let mode = String(UInt32(info.st_mode) & 0o7777, radix: 8)
        return "\(path) uid=\(info.st_uid) gid=\(info.st_gid) mode=\(mode)"
    }

    /// Darwin's per-file immutability bits. Linux carries no `st_flags`, and its
    /// equivalent lives behind an ioctl this diagnosis does not need.
    private static func immutabilityFlags(of path: FilePath) -> UInt32 {
        #if canImport(Darwin)
        var info = stat()
        guard unsafe lstat(path.string, &info) == 0 else { return 0 }
        return info.st_flags
            & UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND)
        #else
        return 0
        #endif
    }
}
