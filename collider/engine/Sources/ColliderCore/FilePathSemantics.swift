import Foundation
import SystemPackage

extension FilePath {
    public func normalizedForComparison() -> FilePath {
        let path = lexicallyNormalized()
        guard path.isAbsolute else { return path }
        return FilePath(
            URL(fileURLWithPath: path.string).standardizedFileURL.path
        ).lexicallyNormalized()
    }

    /// Returns whether this path is equal to or lexically contained by `root`.
    ///
    /// Both paths are normalized and compared as path components, so sibling
    /// names that merely share a string prefix never overlap.
    public func isContained(in root: FilePath) -> Bool {
        let path = normalizedForComparison()
        let root = root.normalizedForComparison()
        guard path.root == root.root else { return false }
        return path.components.starts(with: root.components)
    }

    public func overlaps(_ other: FilePath) -> Bool {
        isContained(in: other) || other.isContained(in: self)
    }

    public func relativeSubpath(from root: FilePath) -> FilePath? {
        let path = normalizedForComparison()
        let root = root.normalizedForComparison()
        guard path.isContained(in: root) else { return nil }
        return FilePath(
            root: nil,
            path.components.dropFirst(root.components.count))
    }
}

public func elapsedNanoseconds(
    since start: ContinuousClock.Instant
) -> UInt64 {
    let components = start.duration(to: ContinuousClock().now).components
    let seconds = UInt64(max(0, components.seconds))
    let nanoseconds = UInt64(max(0, components.attoseconds / 1_000_000_000))
    return seconds &* 1_000_000_000 &+ nanoseconds
}
