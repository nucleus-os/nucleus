import ColliderPlatformC
import Foundation
import SystemPackage
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

enum DurableFile {
    static func copy(from source: FilePath, to path: FilePath) throws {
        try FileManager.default.createDirectory(
            atPath: path.removingLastComponent().string,
            withIntermediateDirectories: true)
        let candidate = FilePath(path.string + ".candidate-\(getpid())")
        try? FileManager.default.removeItem(atPath: candidate.string)
        do {
            try FileManager.default.copyItem(
                atPath: source.string,
                toPath: candidate.string)
            let descriptor = try FileDescriptor.open(candidate, .readOnly)
            do {
                guard collider_sync_file(descriptor.rawValue) == 0 else {
                    throw Errno(rawValue: errno)
                }
                try descriptor.close()
            } catch {
                try? descriptor.close()
                throw error
            }
            guard collider_replace(candidate.string, path.string) == 0 else {
                throw Errno(rawValue: errno)
            }
            try synchronizeDirectory(path.removingLastComponent())
        } catch {
            try? FileManager.default.removeItem(atPath: candidate.string)
            throw error
        }
    }

    static func writeJSON<T: Encodable>(_ value: T, to path: FilePath) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0a)
        try write(data, to: path)
    }

    static func write(_ data: Data, to path: FilePath) throws {
        try FileManager.default.createDirectory(
            atPath: path.removingLastComponent().string,
            withIntermediateDirectories: true)
        let candidate = FilePath(path.string + ".candidate-\(getpid())")
        let descriptor = try FileDescriptor.open(
            candidate,
            .writeOnly,
            options: [.create, .truncate],
            permissions: .ownerReadWrite)
        do {
            try descriptor.writeAll(data)
            guard collider_sync_file(descriptor.rawValue) == 0 else {
                throw Errno(rawValue: errno)
            }
            try descriptor.close()
            guard collider_replace(candidate.string, path.string) == 0 else {
                throw Errno(rawValue: errno)
            }
            try synchronizeDirectory(path.removingLastComponent())
        } catch {
            try? descriptor.close()
            try? FileManager.default.removeItem(atPath: candidate.string)
            throw error
        }
    }

    static func synchronizeDirectory(_ path: FilePath) throws {
        let descriptor = try FileDescriptor.open(path, .readOnly)
        defer { try? descriptor.close() }
        guard collider_sync_directory(descriptor.rawValue) == 0 else {
            throw Errno(rawValue: errno)
        }
    }
}
