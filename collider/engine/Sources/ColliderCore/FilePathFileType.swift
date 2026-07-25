import SystemPackage

// File-type predicates over `stat(2)`, matching the streaming hasher's use of
// `FilePath.stat(followTargetSymlink:)`. One `stat` beats constructing a `URL`
// and driving Foundation's resource-value machinery for a single mode bit, and
// the failure mode is a typed `Errno` rather than an untyped nil.
extension FilePath {
    /// True when this path resolves to a directory. Symbolic links are followed,
    /// so a link to a directory reports `true`; a broken link reports `false`.
    public var isDirectory: Bool {
        (try? stat().type) == .directory
    }

    /// True when this path resolves to a regular file. Symbolic links are
    /// followed, so a link to a file reports `true`; a broken link reports
    /// `false`.
    public var isRegularFile: Bool {
        (try? stat().type) == .regular
    }
}
