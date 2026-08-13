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
        abstract: "Maintain repository-scoped agent skills.",
        subcommands: [GenerateSkill.self, SyncSkill.self, VerifySkill.self])

    package init() {}
}

private struct GenerateSkill: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "generate",
        abstract: "Generate a skill entirely from local repository state.")

    @Argument(help: "The locally generated skill to update.")
    var skill: GeneratedSkill

    mutating func run() throws {
        let root = try resolveWorkspaceRoot(
            environment: ProcessInfo.processInfo.environment)
        switch skill {
        case .collider:
            try ColliderSkillDocumentation.write(to: root)
        }
        throw CleanExit.message(
            "generated .agents/skills/collider from the current Collider grammar")
    }
}

private struct SyncSkill: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Synchronize a skill from its canonical upstream source.")

    @Argument(help: "The upstream-backed skill to synchronize.")
    var skill: SynchronizedSkill

    mutating func run() throws {
        let root = try resolveWorkspaceRoot(
            environment: ProcessInfo.processInfo.environment)
        switch skill {
        case .swiftCxxInterop:
            throw CleanExit.message(
                try SwiftCxxInteropSkillDocumentation.sync(to: root))
        }
    }
}

private struct VerifySkill: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Verify managed skills against their authoritative sources.")

    @Argument(help: "The skill to verify; omit to verify every managed skill.")
    var skill: ManagedSkill?

    mutating func run() throws {
        let root = try resolveWorkspaceRoot(
            environment: ProcessInfo.processInfo.environment)
        if let skill {
            throw CleanExit.message(
                try ManagedSkillDocumentation.verify(skill, at: root))
        }
        throw CleanExit.message(
            try ManagedSkillDocumentation.verifyAll(at: root)
                .joined(separator: "\n"))
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
