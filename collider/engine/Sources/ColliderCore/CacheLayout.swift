import Foundation
import SystemPackage

public struct ColliderCacheLayout: Hashable, Sendable {
    public let root: FilePath

    public init(environment: [String: String]) {
        if let value = environment["XDG_CACHE_HOME"], !value.isEmpty {
            root = FilePath(value)
        } else if let home = environment["HOME"], !home.isEmpty {
            root = FilePath(home).appending(".cache")
        } else {
            root = FilePath(
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".cache", isDirectory: true).path)
        }
    }

    public var downloads: FilePath {
        root.appending("nucleus/downloads")
    }
}
