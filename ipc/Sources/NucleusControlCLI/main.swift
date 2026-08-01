import ArgumentParser
import Foundation
import Glibc
import NucleusConfig
import NucleusControlClient
import NucleusControlProtocol

// The `nucleus` command: a thin client over the control protocol.
//
// It holds no policy of its own. Every subcommand maps to one ControlRequest,
// and every request names an operation the compositor already understands from
// its binding table — so a command and a keybinding cannot drift apart.

@main
struct NucleusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "nucleus",
        abstract: "Control a running Nucleus compositor.",
        subcommands: [Message.self])
}

struct Message: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "msg",
        abstract: "Send a request to the compositor.",
        subcommands: [
            Version.self, Configuration.self, Reload.self, Outputs.self,
            Binds.self, CloseWindow.self, Workspace.self,
            MoveToWorkspace.self, Tile.self,
        ],
        defaultSubcommand: Version.self)
}

// MARK: - shared plumbing

/// Send one request and render its response, or exit non-zero with a message
/// on stderr. Kept in one place so every subcommand reports failure the same
/// way — a CLI whose errors vary by subcommand is one nobody can script.
private func perform(
    _ request: ControlRequest,
    render: (ControlResponse) throws -> Void = { defaultRender($0) }
) throws {
    let client: ControlClient
    do {
        client = try ControlClient()
    } catch {
        throw ValidationError(error.message)
    }
    let response: ControlResponse
    do {
        response = try client.send(request)
    } catch {
        throw ValidationError(error.message)
    }
    if case .error(let failure) = response {
        throw ValidationError(
            "compositor [\(failure.code.rawValue)]: \(failure.message)")
    }
    try render(response)
}

private func defaultRender(_ response: ControlResponse) {
    switch response {
    case .accepted, .completed:
        // Silence on success is the scriptable default; the exit code carries
        // the outcome.
        break
    case .version(let value):
        let renderVersion = value.renderServer.version ?? "unavailable"
        print("control \(value.controlProtocolVersion); render \(renderVersion)")
    case .configuration(let configuration):
        print(configuration.canonicalSource)
    case .validation(let diagnostics):
        for diagnostic in diagnostics { print(diagnostic) }
    case .outputs(let snapshot):
        for output in snapshot.outputs { print(describe(output)) }
    case .binds(let snapshot):
        for bind in snapshot.binds {
            print("\(bind.keys.text)\t\(bind.action.name)")
        }
    case .error(let failure):
        // `perform` turns an error response into a thrown ValidationError
        // before reaching here, so this is only a backstop for other callers.
        writeStandardError(
            "error [\(failure.code.rawValue)]: \(failure.message)\n")
    }
}

/// Write to fd 2 directly. Glibc's `stderr` is a mutable global and so is not
/// concurrency-safe to reference under strict checking.
private func writeStandardError(_ text: String) {
    let bytes = Array(text.utf8)
    _ = bytes.withUnsafeBytes { buffer in
        unsafe write(2, buffer.baseAddress, buffer.count)
    }
}

private func describe(_ output: ControlOutput) -> String {
    // Millihertz keeps the interesting rates (59.94, 143.998) intact through
    // plain interpolation without locale-sensitive formatting.
    let refresh = Double(output.refreshMillihertz) / 1000
    let state = output.enabled ? "" : "\t(disabled)"
    return "\(output.name)\t\(output.width)x\(output.height)@\(refresh)Hz"
        + "\tscale \(output.scale)\tat \(output.x),\(output.y)\(state)"
}

// MARK: - queries

struct Version: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the running compositor's version.")

    func run() throws { try perform(.version) }
}

struct Configuration: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Print the configuration currently in force.")

    func run() throws { try perform(.configuration) }
}

struct Reload: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Re-read the configuration file now.")

    func run() throws { try perform(.reloadConfiguration) }
}

struct Outputs: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List the attached outputs.")

    func run() throws { try perform(.outputs) }
}

struct Binds: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List the active key bindings.")

    func run() throws { try perform(.binds) }
}

// MARK: - actions

struct CloseWindow: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "close-window",
        abstract: "Close the focused window.")

    func run() throws { try perform(.action(.closeWindow)) }
}

struct Workspace: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Switch the focused output to a workspace.")

    @Argument(help: "1-based workspace index.")
    var index: UInt32

    func validate() throws {
        guard index >= 1 else {
            throw ValidationError("workspace index is 1-based; got 0")
        }
    }

    func run() throws { try perform(.action(.activateWorkspace(index))) }
}

struct MoveToWorkspace: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "move-to-workspace",
        abstract: "Move the focused window to a workspace.")

    @Argument(help: "1-based workspace index.")
    var index: UInt32

    func validate() throws {
        guard index >= 1 else {
            throw ValidationError("workspace index is 1-based; got 0")
        }
    }

    func run() throws { try perform(.action(.moveWindowToWorkspace(index))) }
}

struct Tile: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Tile the focused window.")

    @Argument(help: "One of: \(TileDirection.allCases.map(\.rawValue).joined(separator: ", ")).")
    var direction: String

    func run() throws {
        guard let resolved = TileDirection(rawValue: direction) else {
            throw ValidationError(
                "unknown direction '\(direction)'; expected one of "
                    + TileDirection.allCases.map(\.rawValue)
                    .joined(separator: ", "))
        }
        try perform(.action(.tile(resolved)))
    }
}
