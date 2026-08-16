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
