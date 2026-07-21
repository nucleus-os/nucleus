import Foundation

private let usage = """
Usage: tools/nucleus <command>

Commands:
  doctor       Validate the complete-checkout host and native SDK prerequisites
  bootstrap    Bootstrap all components, or one of tracy|vulkan|wayland|core|linux|rn|compositor|shell
  build        Build all runtime components, or one component
  test         Test all runtime components, or one component
  api          Emit and audit the public core Swift symbol graphs
  sanitize     Run focused address/leak, undefined-behavior, and thread sanitizers
  benchmark    Run deterministic release-built headless performance baselines
  toolchain    Rebuild and atomically activate the paired Swift toolchain and Android SDK
  android      Build or verify the Android host
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
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else { print(usage); return }
        switch command {
        case "doctor": try Doctor(context: context).run()
        case "bootstrap": try Orchestrator(context: context).bootstrap(arguments.dropFirst().first)
        case "build": try Orchestrator(context: context).build(arguments.dropFirst().first)
        case "test": try Orchestrator(context: context).test(arguments.dropFirst().first)
        case "api": try PublicAPIAudit(context: context).run()
        case "sanitize": try SanitizerCommand(context: context).run(arguments.dropFirst())
        case "benchmark": try BenchmarkCommand(context: context).run(arguments.dropFirst())
        case "toolchain": try ToolchainCommand(context: context).run(arguments.dropFirst())
        case "android": try AndroidCommand(context: context).run(arguments.dropFirst())
        case "profile": try ProfilingCommand(context: context).run(arguments.dropFirst())
        case "install": try InstallCommand(context: context).run(arguments.dropFirst())
        case "help", "--help", "-h": print(usage)
        default: throw WorkspaceFailure.message("unknown command '\(command)'\n\n\(usage)")
        }
    }
}
