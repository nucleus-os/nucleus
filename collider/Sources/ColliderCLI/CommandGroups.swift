import ArgumentParser
import ColliderWorkspaceCommands

#if os(Linux)
import ColliderLinuxOperations
#endif

func colliderCommandSubcommands() -> [ParsableCommand.Type] {
    var commands = WorkspaceCommandSet.rootPrefix
    #if os(Linux)
    commands.append(contentsOf: LinuxOperationCommandSet.root)
    #endif
    commands.append(Install.self)
    commands.append(contentsOf: WorkspaceCommandSet.rootBetweenGroups)
    commands.append(AndroidRuntime.self)
    commands.append(contentsOf: WorkspaceCommandSet.rootSuffix)
    return commands
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
        var commands = WorkspaceCommandSet.androidRuntime
        #if os(Linux)
        commands.append(contentsOf: LinuxOperationCommandSet.androidRuntime)
        #endif
        return commands
    }

    package init() {}
}
