import Foundation

/// Resolves the xdg-decoration mode per window. Nucleus is a server-chrome
/// (macOS-style) shell that owns every window's frame: the compositor always
/// advertises `server_side` and draws the titlebar/border itself, overriding a
/// client's `client_side` request (a well-behaved client then drops its own
/// decorations and lets us decorate; its in-window UI — e.g. a browser's tab
/// strip — simply sits below our titlebar, as on macOS). The `NUCLEUS_DECORATION`
/// env var pins a mode for development and overrides this.
@MainActor
public final class DecorationPolicy {
    public static let shared = DecorationPolicy()

    /// `zxdg_toplevel_decoration_v1.mode` wire values.
    public enum Mode: UInt8 {
        case clientSide = 1
        case serverSide = 2
    }

    /// Development override; when set it wins over the client's request.
    private let envPin: Mode?

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        switch environment["NUCLEUS_DECORATION"]?.lowercased() {
        case "csd", "client", "client_side":
            envPin = .clientSide
        case "ssd", "server", "server_side":
            envPin = .serverSide
        default:
            envPin = nil
        }
    }

    /// Resolve the effective decoration mode for a window. The env pin wins;
    /// otherwise the compositor always decorates server-side, overriding the
    /// client's request (`clientRequested` is tracked by the decoration object
    /// but does not change the outcome) so every window carries the system frame.
    public func resolveMode(windowID: UInt64, clientRequested: Mode?) -> Mode {
        _ = clientRequested
        if let envPin { return envPin }
        return .serverSide
    }

    /// The mode advertised before any client request — the compositor default.
    public func preferredMode(windowID: UInt64) -> UInt8 {
        resolveMode(windowID: windowID, clientRequested: nil).rawValue
    }
}
