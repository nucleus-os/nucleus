import Foundation

func resolveXwaylandExecutable(
    environment: [String: String],
    fileManager: FileManager = .default
) throws -> String {
    guard let path = environment["PATH"] else {
        throw WorkspaceFailure.message(
            "Xwayland is required but PATH is unavailable")
    }
    for directory in path.split(
        separator: ":", omittingEmptySubsequences: false
    ) {
        let base = directory.isEmpty ? "." : String(directory)
        let candidate = URL(
            fileURLWithPath: base,
            isDirectory: true
        ).appendingPathComponent("Xwayland")
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard candidate.path.hasPrefix("/"),
              fileManager.isExecutableFile(atPath: candidate.path),
              let attributes = try? fileManager.attributesOfItem(
                atPath: candidate.path),
              attributes[.type] as? FileAttributeType == .typeRegular
        else {
            continue
        }
        return candidate.path
    }
    throw WorkspaceFailure.message(
        "Xwayland is required; install an executable regular file named "
            + "Xwayland on PATH")
}
