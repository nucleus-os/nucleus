import SystemPackage

/// A containment root prepared once for repeated tests against it.
///
/// `isContained(in:)` normalizes both sides on every call, which is right for a
/// single comparison and wasteful inside a scan: deciding which tasks write
/// under a storage root asks every task's every effect about one root, so that
/// root was normalized once per effect rather than once per scan.
public struct FilePathContainmentRoot: Sendable {
    private let normalized: FilePath
    private let components: [FilePath.Component]

    public init(_ root: FilePath) {
        let normalized = root.normalizedForComparison()
        self.normalized = normalized
        components = Array(normalized.components)
    }

    public func contains(_ path: FilePath) -> Bool {
        let path = path.normalizedForComparison()
        guard path.root == normalized.root else { return false }
        return path.components.starts(with: components)
    }
}

extension FilePath {
    public func normalizedForComparison() -> FilePath {
        lexicallyNormalized()
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
