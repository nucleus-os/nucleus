import ArgumentParser
import ColliderWorkspaceCommands
import Foundation

#if os(Linux)
import ColliderLinuxOperations
#endif

func colliderCommandSubcommands() -> [ParsableCommand.Type] {
    var commands = WorkspaceCommandSet.rootPrefix
    #if os(Linux)
    commands.append(contentsOf: LinuxOperationCommandSet.root)
    #endif
    commands.append(Install.self)
    commands.append(Skill.self)
    #if os(Linux)
    commands.append(AndroidRuntime.self)
    #endif
    commands.append(contentsOf: WorkspaceCommandSet.rootSuffix)
    return commands
}

package struct Skill: ParsableCommand {
    package static let configuration = CommandConfiguration(
        abstract: "Maintain the repository-scoped Collider agent skill.",
        subcommands: [GenerateColliderSkill.self])

    package init() {}
}

private struct GenerateColliderSkill: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "generate",
        abstract: "Regenerate the Collider agent skill from the current CLI grammar.")

    mutating func run() throws {
        let root = try resolveWorkspaceRoot(
            environment: ProcessInfo.processInfo.environment)
        try ColliderSkillDocumentation.write(to: root)
        throw CleanExit.message(
            "generated .agents/skills/collider from the current Collider grammar")
    }
}

package struct Install: AsyncParsableCommand {
    package static let configuration = CommandConfiguration(
        abstract: "Install Nucleus runtime and browser products.",
        subcommands: installSubcommands())

    private static func installSubcommands() -> [ParsableCommand.Type] {
        var commands = WorkspaceCommandSet.install
        #if os(Linux)
        commands.insert(contentsOf: LinuxOperationCommandSet.install, at: 0)
        #endif
        return commands
    }

    package init() {}
}

package struct AndroidRuntime: AsyncParsableCommand {
    package static let configuration = CommandConfiguration(
        commandName: "android-runtime",
        abstract: "Build and operate the contained Android runtime.",
        subcommands: androidRuntimeSubcommands())

    private static func androidRuntimeSubcommands() -> [ParsableCommand.Type] {
        var commands: [ParsableCommand.Type] = []
        #if os(Linux)
        commands.append(contentsOf: LinuxOperationCommandSet.androidRuntime)
        #endif
        return commands
    }

    package init() {}
}
