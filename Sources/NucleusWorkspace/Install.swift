import Foundation

struct InstallCommand {
    let context: WorkspaceContext

    func run(_ arguments: ArraySlice<String>) throws {
        guard arguments.first == "compositor" else {
            throw WorkspaceFailure.message("Usage: tools/nucleus install compositor [--prefix DIR]")
        }
        let options = Array(arguments.dropFirst())
        var command = ["package", "--package-path", "compositor", "install-compositor", "--allow-writing-to-package-directory"]
        if let index = options.firstIndex(of: "--prefix") {
            guard options.indices.contains(index + 1) else { throw WorkspaceFailure.message("missing value for --prefix") }
            let prefix = URL(fileURLWithPath: options[index + 1], relativeTo: context.root).standardizedFileURL.path
            command += ["--prefix", prefix, "--allow-writing-to-directory", prefix]
        } else if !options.isEmpty {
            throw WorkspaceFailure.message("unknown install option '\(options[0])'")
        }
        try context.run("swift", command, directory: context.root.appendingPathComponent("compositor"))
    }
}
