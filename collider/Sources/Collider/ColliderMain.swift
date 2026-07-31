import ColliderCommands

@main
struct ColliderMain {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            if try ToolchainSystemEntryPoint.executeIfRequested(arguments: arguments) {
                return
            }
            try await ColliderCommand.execute(arguments: arguments)
        } catch {
            ColliderCommand.exit(withError: error)
        }
    }
}
