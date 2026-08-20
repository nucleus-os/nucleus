import SystemPackage

public struct IdentityPathRoot: Hashable, Sendable {
    public let name: String
    public let path: FilePath

    public init(name: String, path: FilePath) {
        precondition(!name.isEmpty)
        precondition(path.isAbsolute && path.isLexicallyNormal)
        precondition(path.string != "/")
        self.name = name
        self.path = path
    }
}

public struct IdentityPathMap: Hashable, Sendable {
    public static let empty = IdentityPathMap(roots: [])

    public let roots: [IdentityPathRoot]

    public init(roots: [IdentityPathRoot]) {
        precondition(Set(roots.map(\.name)).count == roots.count)
        precondition(Set(roots.map(\.path)).count == roots.count)
        self.roots = roots.sorted {
            if $0.path.string.count != $1.path.string.count {
                return $0.path.string.count > $1.path.string.count
            }
            return $0.name < $1.name
        }
    }

    public func canonicalize(_ value: String) -> String {
        roots.reduce(value) { result, root in
            replacingPathRoot(
                root.path.string,
                with: "${\(root.name)}",
                in: result)
        }
    }

    /// Replaces declared placement-only roots and rejects a remaining absolute
    /// macOS or Linux user/temporary path. Portable artifact identity must not
    /// silently retain a path that another builder cannot reproduce.
    public func canonicalizePortable(_ value: String) throws -> String {
        let canonical = canonicalize(value)
        guard !containsAbsoluteHostPath(canonical) else {
            throw PortableIdentityPathFailure.unrecognizedAbsoluteHostPath(value)
        }
        return canonical
    }
}

extension IdentityPathMap {
    /// Where a declared root appears inside an execution environment.
    ///
    /// One declaration of placement serves identity and execution alike: the
    /// same root resolves to `${name}` in an identity and to `/nucleus-name`
    /// in a container, so the two cannot disagree about which prefix is
    /// placement. A path under no declared root is not placement and is
    /// returned unchanged.
    ///
    /// The name is a single root-level component because a container image's
    /// root filesystem is read only: the runtime binds onto a target it can
    /// reach, and a nested target would require creating its parent there.
    /// Every other mount this build system declares is root-level for the same
    /// reason.
    public func executionPath(_ path: FilePath) -> String {
        for root in roots {
            let prefix = root.path.string
            guard path.string == prefix || path.string.hasPrefix(prefix + "/")
            else { continue }
            return "/nucleus-\(root.name)" + path.string.dropFirst(prefix.count)
        }
        return path.string
    }

    /// Whether a declared root appears literally in already-encoded bytes.
    ///
    /// Identity bytes computed elsewhere may have resolved through a different
    /// map, or none. A declared root surviving into them is placement leaking
    /// into identity: the same source at another location hashes differently
    /// and shares nothing with it, which is the whole cost these roots exist to
    /// remove.
    public func containsDeclaredRoot(inEncoded bytes: [UInt8]) -> Bool {
        guard !roots.isEmpty else { return false }
        // Identity payloads are mostly digests, so the scan looks for the roots
        // rather than decoding the bytes as text.
        return roots.contains { root in
            bytes.containsSubsequence(Array(root.path.string.utf8))
        }
    }
}

extension [UInt8] {
    fileprivate func containsSubsequence(_ pattern: [UInt8]) -> Bool {
        guard !pattern.isEmpty, count >= pattern.count else { return false }
        for start in 0...(count - pattern.count)
        where Array(self[start..<(start + pattern.count)]) == pattern {
            return true
        }
        return false
    }
}

public enum PortableIdentityPathFailure: Error, CustomStringConvertible, Sendable {
    case unrecognizedAbsoluteHostPath(String)

    public var description: String {
        switch self {
        case .unrecognizedAbsoluteHostPath(let value):
            "portable identity contains an unrecognized absolute host path: \(value)"
        }
    }
}

private func replacingPathRoot(
    _ root: String,
    with replacement: String,
    in value: String
) -> String {
    var result = ""
    var cursor = value.startIndex
    while let range = value.range(of: root, range: cursor..<value.endIndex) {
        let suffixIsBoundary =
            range.upperBound == value.endIndex
            || value[range.upperBound] == "/"
            || value[range.upperBound] == "="
        guard suffixIsBoundary else {
            result += value[cursor..<range.upperBound]
            cursor = range.upperBound
            continue
        }
        result += value[cursor..<range.lowerBound]
        result += replacement
        cursor = range.upperBound
    }
    result += value[cursor...]
    return result
}

private func containsAbsoluteHostPath(_ value: String) -> Bool {
    if value.contains("file://") { return true }
    for index in value.indices where value[index] == "/" {
        let next = value.index(after: index)
        if next < value.endIndex, value[next] == "/" {
            continue
        }
        if index == value.startIndex { return true }
        let previous = value[value.index(before: index)]
        if previous.isWhitespace || "=,:;\"'([{".contains(previous) {
            return true
        }
        let tokenStart =
            value[..<index].lastIndex(where: { $0.isWhitespace })
            .map { value.index(after: $0) } ?? value.startIndex
        let tokenPrefix = value[tokenStart..<index]
        if tokenPrefix == "-I" || tokenPrefix == "-L" || tokenPrefix == "-F" {
            return true
        }
    }
    return false
}
