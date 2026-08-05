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
