import Foundation

public struct AndroidRuntimeHostConfiguration: Equatable, Sendable {
    public let userID: UInt32
    public let groupID: UInt32
    public let kernelConfiguration: URL
    public let subordinateUID: UInt32
    public let subordinateGID: UInt32
    public let subordinateUIDCount: UInt32
    public let subordinateGIDCount: UInt32

    public init(
        userID: UInt32,
        groupID: UInt32,
        kernelConfiguration: URL,
        subordinateUID: UInt32,
        subordinateGID: UInt32,
        subordinateUIDCount: UInt32,
        subordinateGIDCount: UInt32
    ) {
        self.userID = userID
        self.groupID = groupID
        self.kernelConfiguration = kernelConfiguration
        self.subordinateUID = subordinateUID
        self.subordinateGID = subordinateGID
        self.subordinateUIDCount = subordinateUIDCount
        self.subordinateGIDCount = subordinateGIDCount
    }
}

public struct AndroidSwiftRuntime: Equatable, Sendable {
    public let libraryRoot: URL
    public let loaderSearchDirectory: URL
    public let loaderSearchPath: String

    public init(
        libraryRoot: URL,
        loaderSearchDirectory: URL
    ) throws {
        let root = libraryRoot.standardizedFileURL.path
        let loader = loaderSearchDirectory.standardizedFileURL.path
        guard root != "/",
            loader.hasPrefix(root + "/")
        else {
            throw AndroidRuntimeFailure(
                "Swift loader directory is outside its runtime root")
        }
        self.libraryRoot = libraryRoot
        self.loaderSearchDirectory = loaderSearchDirectory
        loaderSearchPath = String(loader.dropFirst(root.count + 1))
    }
}
