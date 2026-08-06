import ColliderCLI

@main
struct ColliderMain {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            try await ColliderCommand.execute(arguments: arguments)
        } catch {
            ColliderCommand.exit(withError: error)
        }
    }
}
