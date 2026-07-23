import ColliderPlatformC
import Foundation
import SystemPackage
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum GenerationPublisher {
    public static func publish(
        candidate: FilePath,
        generation: FilePath,
        active: FilePath
    ) throws {
        try publish(
            candidate: candidate,
            generation: generation,
            active: active,
            after: { _ in })
    }

    static func publish(
        candidate: FilePath,
        generation: FilePath,
        active: FilePath,
        after boundary: (GenerationPublicationBoundary) throws -> Void
    ) throws {
        guard candidate.removingLastComponent() == generation.removingLastComponent() else {
            throw GenerationPublicationFailure.differentFilesystems
        }
        let metadata = try candidate.stat(followTargetSymlink: false)
        guard metadata.type == .directory else {
            throw GenerationPublicationFailure.invalidCandidate(candidate)
        }

        if FileManager.default.fileExists(atPath: generation.string) {
            guard try ArtifactHasher.digest(tree: candidate)
                    == ArtifactHasher.digest(tree: generation)
            else {
                throw GenerationPublicationFailure.generationConflict(generation)
            }
            try FileManager.default.removeItem(atPath: candidate.string)
            try activate(
                generation: generation, active: active, after: boundary)
            return
        }

        try synchronizeTree(candidate)
        try boundary(.candidateSynchronized)
        try rename(candidate, generation)
        try boundary(.generationRenamed)
        try synchronizeDirectory(generation.removingLastComponent())
        try boundary(.generationDirectorySynchronized)
        try activate(
            generation: generation, active: active, after: boundary)
    }

    private static func activate(
        generation: FilePath,
        active: FilePath,
        after boundary: (GenerationPublicationBoundary) throws -> Void = { _ in }
    ) throws {
        try FileManager.default.createDirectory(
            atPath: active.removingLastComponent().string,
            withIntermediateDirectories: true)
        let linkCandidate = active.removingLastComponent().appending(
            ".\(active.lastComponent?.string ?? "active").candidate-\(getpid())")
        try? FileManager.default.removeItem(atPath: linkCandidate.string)
        let target = relativeTarget(for: generation, from: active.removingLastComponent())
        guard collider_symlink(target, linkCandidate.string) == 0 else {
            throw Errno(rawValue: errno)
        }
        do {
            try boundary(.activeCandidateCreated)
            if FileManager.default.fileExists(atPath: active.string),
               let activeMetadata = try? active.stat(
                followTargetSymlink: false),
               activeMetadata.type != .symbolicLink
            {
                try FileManager.default.removeItem(atPath: active.string)
            }
            try rename(linkCandidate, active)
            try boundary(.activePointerReplaced)
            try synchronizeDirectory(active.removingLastComponent())
            try boundary(.activeDirectorySynchronized)
        } catch {
            try? FileManager.default.removeItem(atPath: linkCandidate.string)
            throw error
        }
    }

    private static func synchronizeTree(_ path: FilePath) throws {
        let entries = try FileManager.default.contentsOfDirectory(atPath: path.string).sorted()
        for entry in entries {
            let child = path.appending(entry)
            let metadata = try child.stat(followTargetSymlink: false)
            switch metadata.type {
            case .regular:
                let descriptor = try FileDescriptor.open(child, .readOnly)
                defer { try? descriptor.close() }
                guard collider_sync_file(descriptor.rawValue) == 0 else {
                    throw Errno(rawValue: errno)
                }
            case .directory:
                try synchronizeTree(child)
            default:
                break
            }
        }
        try synchronizeDirectory(path)
    }

    private static func synchronizeDirectory(_ path: FilePath) throws {
        let descriptor = try FileDescriptor.open(path, .readOnly)
        defer { try? descriptor.close() }
        guard collider_sync_directory(descriptor.rawValue) == 0 else {
            throw Errno(rawValue: errno)
        }
    }

    private static func rename(_ source: FilePath, _ destination: FilePath) throws {
        guard collider_replace(source.string, destination.string) == 0 else {
            throw Errno(rawValue: errno)
        }
    }

    private static func relativeTarget(for generation: FilePath, from parent: FilePath) -> String {
        if generation.removingLastComponent() == parent,
           let component = generation.lastComponent
        {
            return component.string
        }
        let prefix = parent.string.hasSuffix("/")
            ? parent.string : parent.string + "/"
        if generation.string.hasPrefix(prefix) {
            return String(generation.string.dropFirst(prefix.count))
        }
        return generation.string
    }
}

enum GenerationPublicationBoundary: CaseIterable {
    case candidateSynchronized
    case generationRenamed
    case generationDirectorySynchronized
    case activeCandidateCreated
    case activePointerReplaced
    case activeDirectorySynchronized
}

public enum GenerationPublicationFailure: Error, CustomStringConvertible {
    case differentFilesystems
    case generationConflict(FilePath)
    case invalidCandidate(FilePath)

    public var description: String {
        switch self {
        case .differentFilesystems:
            "generation candidates must be assembled beside the immutable generation"
        case .generationConflict(let path):
            "immutable generation already exists with different contents at \(path)"
        case .invalidCandidate(let path):
            "generation candidate is not a directory at \(path)"
        }
    }
}
