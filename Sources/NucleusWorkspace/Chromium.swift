import FoundationEssentials

enum ChromiumOperation: String, CaseIterable {
    case doctor
    case bootstrap
    case build
    case test
    case install
}

struct ChromiumCommand {
    let context: WorkspaceContext

    static let usage = """
    Usage: tools/nucleus chromium doctor|bootstrap|build|test|install

    The Chromium workflow has one production configuration. `build` prepares
    the pinned source generation, builds CEF and Nucleus Browser sequentially,
    validates both products, and atomically publishes their artifacts.
    """

    static func parse(_ arguments: [String]) throws -> ChromiumOperation {
        guard arguments.count == 1,
              let operation = ChromiumOperation(rawValue: arguments[0])
        else {
            throw WorkspaceFailure.message(usage)
        }
        return operation
    }

    func run(_ arguments: ArraySlice<String>) throws {
        let operation = try Self.parse(Array(arguments))
        try context.run(
            context.root.appendingPathComponent("chromium/build.sh").path,
            [operation.rawValue],
            environmentOverrides: ["NUCLEUS_CHROMIUM_CLI": "1"])
    }
}
