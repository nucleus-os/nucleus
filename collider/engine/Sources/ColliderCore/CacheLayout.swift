import SystemPackage

public struct ColliderCacheLayout: Hashable, Sendable {
    public let root: FilePath
    public let downloadNamespace: FilePath

    public init(root: FilePath, downloadNamespace: FilePath) {
        precondition(root.isAbsolute && root.isLexicallyNormal)
        precondition(!downloadNamespace.isAbsolute)
        precondition(downloadNamespace.isLexicallyNormal)
        self.root = root
        self.downloadNamespace = downloadNamespace
    }

    public var downloads: FilePath {
        root.appending(downloadNamespace.components)
    }
}
