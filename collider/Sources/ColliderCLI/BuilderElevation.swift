import ColliderWorkspaceCommands
import Foundation
import SystemPackage

#if canImport(Darwin)
import Darwin
#endif

/// Re-runs this invocation as the identity permitted to execute builds.
///
/// A provisioned host has one store and one identity that may write it, so a
/// command that executes a task graph has to run as that identity. Which
/// commands those are is Collider's own knowledge, not the operator's, so
/// Collider crosses the boundary rather than refusing and naming a second
/// command for a person to retype. The alternative left the privileged
/// launcher's grammar as a parallel command surface that had to grow every
/// time this one did, and silently put operations out of reach whenever it
/// did not.
///
/// What crosses stays typed. The launcher admits command words and a closed
/// list of options, never this process's argument vector, so a password-free
/// grant cannot become a way to run something else as another identity.
enum BuilderElevation {
    /// Options the launcher admits, and whether each carries a value.
    ///
    /// An option outside this list is not silently dropped: the invocation is
    /// refused, because running a build that quietly ignored `--rebuild` would
    /// answer a question the operator did not ask.
    private static let admittedOptions: [String: Bool] = [
        "--rebuild": false,
        "--dry-run": false,
        "--as-builder": false,
        "--explain-identity": true,
        "--verify-reproduction": false,
        "--storage": true,
        "--verbose": false,
        "--quiet": false,
        "--measure-allocations": false,
        "--format": true,
        "--color": true,
        "--progress": true,
        "--progress-format": true,
        "--run-id": true,
    ]

    /// Whether this account executes builds directly.
    ///
    /// A host with no machine build store runs Collider from one account, which
    /// is therefore that identity. A host with one has exactly one identity
    /// that may write it.
    static func executesDirectly() -> Bool {
        #if os(macOS)
        guard MacOSMachineStorageLayout.buildStoreIsInstalled() else { return true }
        return FileManager.default.isWritableFile(
            atPath: MacOSMachineStorageLayout.buildStore.string)
        #else
        return true
        #endif
    }

    #if os(macOS)
    /// Replaces this process with the same command run as the builder.
    ///
    /// Replacing rather than supervising: the launcher inherits this process's
    /// standard streams, terminal, and signal disposition, so output streams as
    /// it is produced, an interrupt reaches the run that is actually executing,
    /// and the exit status is the run's own rather than a relayed copy.
    static func reexecuteAsBuilder(
        arguments: [String],
        workspaceRoot: FilePath
    ) throws -> Never {
        let launcher = MacOSMachineStorageLayout.builderLauncher
        guard FileManager.default.isExecutableFile(atPath: launcher.string) else {
            throw WorkspaceFailure.message(
                "this account cannot write the machine build store at "
                    + "\(MacOSMachineStorageLayout.buildStore), and the builder "
                    + "launcher is not installed at \(launcher); run "
                    + "'sudo tools/macos-builder/finalize-nucleus-builder.sh'")
        }
        let admitted = try admittedArguments(arguments)
        let command =
            ["/usr/bin/sudo", "-n", launcher.string, workspaceRoot.string] + admitted

        // Announced on standard error, so a machine-readable result on standard
        // output stays parseable, and never silently: an identity change the
        // operator cannot see is worse than one they have to type.
        FileHandle.standardError.write(
            Data("running as nucleus-builder: \(admitted.joined(separator: " "))\n".utf8))

        // The C entry point takes a null-terminated vector of C strings, which
        // has no safe Swift spelling. Every pointer here is owned by this
        // process and outlives the call, which either replaces the process or
        // returns having done nothing.
        var pointers = unsafe command.map { unsafe strdup($0) }
        unsafe pointers.append(nil)
        unsafe execv(command[0], &pointers)
        // execv returns only on failure; the process is otherwise gone.
        let reason = unsafe String(cString: strerror(errno))
        throw WorkspaceFailure.message(
            "could not run \(launcher) as the builder: " + reason)
    }

    /// The command words and options the launcher admits, in that order.
    private static func admittedArguments(_ arguments: [String]) throws -> [String] {
        var words: [String] = []
        var options: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            guard argument.hasPrefix("-") else {
                words.append(argument)
                index = arguments.index(after: index)
                continue
            }
            // `--option=value` and `--option value` reach the launcher in its
            // one accepted shape.
            let name = argument.prefix(while: { $0 != "=" })
            guard let carriesValue = admittedOptions[String(name)] else {
                throw WorkspaceFailure.message(
                    "'\(argument)' cannot be passed to a build that must run as "
                        + "another identity; run it from an account that writes "
                        + "the machine build store")
            }
            if let separator = argument.firstIndex(of: "=") {
                options.append(String(name))
                options.append(String(argument[argument.index(after: separator)...]))
                index = arguments.index(after: index)
                continue
            }
            options.append(argument)
            index = arguments.index(after: index)
            if carriesValue {
                guard index < arguments.endIndex else {
                    throw WorkspaceFailure.message("'\(argument)' requires a value")
                }
                options.append(arguments[index])
                index = arguments.index(after: index)
            }
        }
        return words + options
    }
    #endif
}
