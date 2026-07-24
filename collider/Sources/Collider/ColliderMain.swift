import ColliderCommands

@main
struct ColliderMain {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            if let mode = colliderPrivilegedMode(for: arguments) {
                try runColliderPrivilegedMode(
                    mode,
                    arguments: Array(arguments.dropFirst()))
                return
            }
            try await ColliderCommand.execute(arguments: arguments)
        } catch {
            ColliderCommand.exit(withError: error)
        }
    }
}
