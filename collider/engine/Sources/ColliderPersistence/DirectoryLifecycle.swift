import ColliderCore
import ColliderPlatformC
import Foundation
import SystemPackage

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public enum DirectoryLifecycle {
    public static func activate(target: String, link: FilePath) throws {
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
                throw PersistenceFailure.invalidPath(
                    "activation path is not a symbolic link: \(link)")
            }
            guard unsafe collider_replace(candidate.string, link.string) == 0 else {
                throw Errno(rawValue: errno)
            }
            try DurableFile.synchronizeDirectory(link.removingLastComponent())
        } catch {
            try? manager.removeItem(atPath: candidate.string)
            throw error
        }
    }

    public static func prune(_ plan: DirectoryRetentionPlan) throws {
        let safetyRoot = plan.safetyRoot.normalizedForComparison()
        guard safetyRoot != FilePath("/") else {
            throw PersistenceFailure.invalidPath(
                "retention safety root must not be the filesystem root")
        }
        for rule in plan.rules {
            let root = rule.root.normalizedForComparison()
            guard root.isContained(in: safetyRoot) else {
                throw PersistenceFailure.invalidPath(
                    "refusing to prune outside \(safetyRoot): \(root)")
            }
            try prune(rule, root: root)
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
            throw PersistenceFailure.invalidPath(
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
                    fileURLWithPath: link.removingLastComponent().string)
            )
            .standardizedFileURL.lastPathComponent
        }
        let expression = try NSRegularExpression(pattern: rule.naming.rawValue)
        let candidates = try manager.contentsOfDirectory(
            at: URL(fileURLWithPath: root.string),
            includingPropertiesForKeys: [
                .isDirectoryKey, .isSymbolicLinkKey,
                .contentModificationDateKey,
            ]
        )
        .filter { url in
            let name = url.lastPathComponent
            let range = NSRange(name.startIndex..., in: name)
            guard
                expression.firstMatch(
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
        let inactiveCandidates = candidates.filter {
            $0.lastPathComponent != protectedName
        }
        var retained = Set(
            inactiveCandidates.prefix(Int(rule.retain)).map(\.lastPathComponent))
        if let protectedName { retained.insert(protectedName) }
        for candidate in candidates
        where !retained.contains(candidate.lastPathComponent) {
            try manager.removeItem(at: candidate)
        }
    }

}
