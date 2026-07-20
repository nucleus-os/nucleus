import NucleusTypes

/// Permanent role identity shared by every protocol capable of assigning a
/// `wl_surface` role.
enum SurfaceRoleIdentity: Equatable {
    case subsurface
    case xdg
    case layerShell
    case sessionLock
    case cursor
    case dragIcon
    case xwayland
}

/// Role-specific validation and applied-transaction hooks. The surface retains
/// only the typed identity; the wire resource remains the role object's owner.
protocol WlSurfaceRole: AnyObject {
    func validateSurfaceCommit(
        _ surface: WlSurface,
        context: SurfaceRoleCommitContext
    ) -> Bool
    func roleSurfaceCommit(_ surface: WlSurface, isInitial: Bool)
    func roleSurfaceDestroyed(_ surface: WlSurface)
}

extension WlSurfaceRole {
    func validateSurfaceCommit(
        _ surface: WlSurface,
        context: SurfaceRoleCommitContext
    ) -> Bool { true }
}

struct SurfaceRoleCommitContext {
    let bufferAttached: Bool
    let willHaveBuffer: Bool
    let bufferPixelSize: BufferPixelSize
    let bufferScale: Int32
}
