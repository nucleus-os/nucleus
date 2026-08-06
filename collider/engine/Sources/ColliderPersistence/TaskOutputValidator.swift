import ColliderCore
import Foundation
import SystemPackage

public struct TaskOutputValidator: Sendable {
    private let fileSystem: ActionFileSystem

    public init(fileSystem: ActionFileSystem) {
        self.fileSystem = fileSystem
    }

    public func validate(_ task: TaskDeclaration) throws {
        try validate(task.outputs.map { ($0.path, $0.validation) })
        try validate(task.postconditions.map { ($0.path, $0.validation) })
        if let action = task.action {
            try action.validateOutputs(
                using: fileSystem.scoped(to: action.requirements.effects))
        }
    }

    private func validate(
        _ paths: [(path: FilePath, validation: PathValidation)]
    ) throws {
        for path in paths {
            switch path.validation {
            case .exists:
                _ = try path.path.stat(followTargetSymlink: false)
            case .symlinkTarget:
                let metadata = try path.path.stat(followTargetSymlink: false)
                guard metadata.type == .symbolicLink else {
                    throw PersistenceFailure.invalidPath(
                        "task produced an invalid output at \(path.path)")
                }
                _ = try path.path.stat(followTargetSymlink: true)
            case .regularFile, .json:
                let metadata = try path.path.stat()
                guard metadata.type == .regular else {
                    throw PersistenceFailure.invalidPath(
                        "task produced an invalid output at \(path.path)")
                }
                if path.validation == .json {
                    _ = try JSONSerialization.jsonObject(
                        with: Data(
                            contentsOf: URL(fileURLWithPath: path.path.string)))
                }
            case .executableFile:
                let metadata = try path.path.stat()
                guard metadata.type == .regular,
                    metadata.permissions.contains(.ownerExecute)
                else {
                    throw PersistenceFailure.invalidPath(
                        "task produced an invalid output at \(path.path)")
                }
            case .nonEmptyDirectory:
                let metadata = try path.path.stat()
                guard metadata.type == .directory,
                    !(try FileManager.default.contentsOfDirectory(
                        atPath: path.path.string)).isEmpty
                else {
                    throw PersistenceFailure.invalidPath(
                        "task produced an invalid output at \(path.path)")
                }
            }
        }
    }
}
