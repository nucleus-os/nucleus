import Foundation
import SystemPackage

extension FilePath {
    package init(_ url: URL) {
        self.init(url.path)
    }
}

extension URL {
    package init(_ path: FilePath, isDirectory: Bool = false) {
        self.init(fileURLWithPath: path.string, isDirectory: isDirectory)
    }
}
