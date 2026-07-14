import Foundation

private let usage = """
Usage: tools/nucleus <command>

Commands:
  doctor       Validate the versioned host build contract
  bootstrap    Bootstrap all components, or one of tracy|vulkan|wayland|core|rn|compositor|shell
  build        Build all runtime components, or one component
  test         Test all runtime components, or one component
  sdk          Build, verify, or fetch native SDK artifacts
  android      Build, verify, or provision the Android host and Swift SDK
  profile      Capture a compositor Tracy profile (`profile receivers` builds tools)
  install      Assemble an installable runtime prefix
  help         Show this help
"""

@main
struct NucleusWorkspaceCommand {
    static func main() {
        do { try execute() }
        catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(2)
        }
    }

    private static func execute() throws {
        let context = try WorkspaceContext.load()
        let contract = try BuildContract.load(from: context.root)
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else { print(usage); return }
        switch command {
        case "doctor": try Doctor(context: context, contract: contract).run()
        case "bootstrap": try Doctor(context: context, contract: contract).run(); try Orchestrator(context: context).bootstrap(arguments.dropFirst().first)
        case "build": try Doctor(context: context, contract: contract).run(); try Orchestrator(context: context).build(arguments.dropFirst().first)
        case "test": try Doctor(context: context, contract: contract).run(); try Orchestrator(context: context).test(arguments.dropFirst().first)
        case "sdk": try SDKArtifacts(context: context).run(arguments.dropFirst())
        case "android": try AndroidCommand(context: context).run(arguments.dropFirst())
        case "profile": try ProfilingCommand(context: context).run(arguments.dropFirst())
        case "install": try InstallCommand(context: context).run(arguments.dropFirst())
        case "help", "--help", "-h": print(usage)
        default: throw WorkspaceFailure.message("unknown command '\(command)'\n\n\(usage)")
        }
    }
}
