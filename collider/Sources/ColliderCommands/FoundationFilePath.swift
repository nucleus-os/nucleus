import Foundation
import SystemPackage

extension FilePath {
    init(_ url: URL) {
        self.init(url.path)
    }
}

extension URL {
    init(_ path: FilePath, isDirectory: Bool = false) {
        self.init(fileURLWithPath: path.string, isDirectory: isDirectory)
    }
}
