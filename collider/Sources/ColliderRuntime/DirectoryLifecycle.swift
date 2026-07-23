import ColliderCore
import ColliderPlatformC
import Foundation
import SystemPackage
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

enum DirectoryLifecycle {
    static func activate(target: String, link: FilePath) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            atPath: link.removingLastComponent().string,
            withIntermediateDirectories: true)
        let candidate = link.removingLastComponent().appending(
            ".\(link.lastComponent?.string ?? "current")."
                + "\(ProcessInfo.processInfo.processIdentifier).tmp")
        try? manager.removeItem(atPath: candidate.string)
        try manager.createSymbolicLink(
            atPath: candidate.string,
            withDestinationPath: target)
        do {
            if manager.fileExists(atPath: link.string),
               let metadata = try? link.stat(followTargetSymlink: false),
               metadata.type != .symbolicLink
            {
                throw RuntimeFailure.invalidOutput(
                    "activation path is not a symbolic link: \(link)")
            }
            guard collider_replace(candidate.string, link.string) == 0 else {
                throw Errno(rawValue: errno)
            }
            try DurableFile.synchronizeDirectory(link.removingLastComponent())
        } catch {
            try? manager.removeItem(atPath: candidate.string)
            throw error
        }
    }

    static func publish(_ publication: DirectoryPublication) throws {
        let prepared = publication.prepared
        let destination = publication.destination
        guard prepared != destination,
              prepared.removingLastComponent()
                == destination.removingLastComponent()
        else {
            throw RuntimeFailure.invalidOutput(
                "atomic directory publication requires distinct sibling paths")
        }
        let preparedMetadata = try prepared.stat(followTargetSymlink: false)
        guard preparedMetadata.type == .directory else {
            throw RuntimeFailure.invalidOutput(
                "prepared publication is not a real directory: \(prepared)")
        }
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.string) {
            let destinationMetadata = try destination.stat(
                followTargetSymlink: false)
            guard destinationMetadata.type == .directory else {
                throw RuntimeFailure.invalidOutput(
                    "publication destination is not a real directory: "
                        + destination.string)
            }
            guard collider_exchange(
                prepared.string, destination.string) == 0
            else {
                throw Errno(rawValue: errno)
            }
            try DurableFile.synchronizeDirectory(
                destination.removingLastComponent())
            try manager.removeItem(atPath: prepared.string)
        } else {
            guard collider_replace(
                prepared.string, destination.string) == 0
            else {
                throw Errno(rawValue: errno)
            }
            try DurableFile.synchronizeDirectory(
                destination.removingLastComponent())
        }
    }

    static func prune(_ plan: DirectoryRetentionPlan) throws {
        let safetyRoot = standardized(plan.safetyRoot)
        guard safetyRoot != "/" else {
            throw RuntimeFailure.invalidOutput(
                "retention safety root must not be the filesystem root")
        }
        for rule in plan.rules {
            let root = standardized(rule.root)
            guard isDescendant(root, of: safetyRoot) else {
                throw RuntimeFailure.invalidOutput(
                    "refusing to prune outside \(safetyRoot): \(root)")
            }
            try prune(rule, root: FilePath(root))
        }
    }

    private static func prune(
        _ rule: DirectoryRetentionRule,
        root: FilePath
    ) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.string) else { return }
        let metadata = try root.stat(followTargetSymlink: false)
        guard metadata.type == .directory else {
            throw RuntimeFailure.invalidOutput(
                "retention root is not a real directory: \(root)")
        }
        let protectedName = try rule.current.flatMap { link -> String? in
            guard let metadata = try? link.stat(followTargetSymlink: false),
                  metadata.type == .symbolicLink
            else { return nil }
            let target = try manager.destinationOfSymbolicLink(
                atPath: link.string)
            return URL(
                fileURLWithPath: target,
                relativeTo: URL(
                    fileURLWithPath: link.removingLastComponent().string))
                .standardizedFileURL.lastPathComponent
        }
        let pattern = switch rule.naming {
        case .contentIdentity: #"^[0-9a-f]{24}$"#
        case .colliderRun:
            #"^[0-9]{8}T[0-9]{6}\.[0-9]+Z-[0-9]+-(doctor|bootstrap|build|test|install)$"#
        }
        let expression = try NSRegularExpression(pattern: pattern)
        let candidates = try manager.contentsOfDirectory(
            at: URL(fileURLWithPath: root.string),
            includingPropertiesForKeys: [
                .isDirectoryKey, .isSymbolicLinkKey,
                .contentModificationDateKey,
            ])
            .filter { url in
                let name = url.lastPathComponent
                let range = NSRange(name.startIndex..., in: name)
                guard expression.firstMatch(
                    in: name, range: range) != nil,
                      let values = try? url.resourceValues(
                        forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                else { return false }
                return values.isDirectory == true
                    && values.isSymbolicLink != true
            }
            .sorted {
                let left = try? $0.resourceValues(
                    forKeys: [.contentModificationDateKey])
                    .contentModificationDate
                let right = try? $1.resourceValues(
                    forKeys: [.contentModificationDateKey])
                    .contentModificationDate
                return (left ?? .distantPast) > (right ?? .distantPast)
            }
        var retained = Set(
            candidates.prefix(Int(rule.retain)).map(\.lastPathComponent))
        if let protectedName { retained.insert(protectedName) }
        for candidate in candidates
            where !retained.contains(candidate.lastPathComponent)
        {
            try manager.removeItem(at: candidate)
        }
    }

    private static func standardized(_ path: FilePath) -> String {
        URL(fileURLWithPath: path.string).standardizedFileURL.path
    }

    private static func isDescendant(_ path: String, of root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
