public import NucleusWindowClientContracts
package import WaylandClientDispatch

/// One independently backed child in a synchronized Wayland surface tree.
///
/// A new `wl_subsurface` starts synchronized. Child content and surface state
/// therefore remain cached until the root or nearest desynchronized ancestor
/// commits, providing the standard Wayland atomic subtree boundary.
@MainActor
public final class NucleusDesktopSubsurface {
    let surface: WaylandProxy<WlSurfaceClient>
    private let role: WaylandProxy<WlSubsurfaceClient>
    private var alpha: WaylandProxy<WpAlphaModifierSurfaceV1Client>?
    private var closed = false

    init(
        client: NucleusDesktopConnection,
        parentSurface: WaylandProxy<WlSurfaceClient>,
        configuration: NucleusDesktopSubsurfaceConfiguration
    ) throws(NucleusDesktopWindowError) {
        guard let subcompositor = client.subcompositor else {
            throw .capabilityUnavailable
        }
        do {
            let surface = try client.createSurface()
            let role = try subcompositor.getSubsurface(
                surface: surface,
                parent: parentSurface)
            self.surface = surface
            self.role = role
            try role.setPosition(
                x: configuration.x,
                y: configuration.y)
            if let alphaModifier = client.alphaModifier {
                alpha = try alphaModifier.getSurface(surface: surface)
            }
        } catch {
            throw .protocolFailure
        }
    }

    isolated deinit {}

    public func setPosition(
        x: Int32,
        y: Int32
    ) throws(NucleusDesktopWindowError) {
        do {
            try role.setPosition(x: x, y: y)
        } catch {
            throw .protocolFailure
        }
    }

    public func placeAbove(
        _ sibling: NucleusDesktopSubsurface
    ) throws(NucleusDesktopWindowError) {
        do {
            try role.placeAbove(sibling: sibling.surface)
        } catch {
            throw .protocolFailure
        }
    }

    public func placeBelow(
        _ sibling: NucleusDesktopSubsurface
    ) throws(NucleusDesktopWindowError) {
        do {
            try role.placeBelow(sibling: sibling.surface)
        } catch {
            throw .protocolFailure
        }
    }

    /// Queue a compositor-side alpha multiplier. It becomes current with this
    /// surface's next synchronized commit.
    public func setOpacity(
        _ value: Double
    ) throws(NucleusDesktopWindowError) {
        guard value.isFinite, value >= 0, value <= 1 else {
            throw .protocolFailure
        }
        guard let alpha else {
            throw .capabilityUnavailable
        }
        let factor =
            value == 1
            ? UInt32.max
            : UInt32(
                (value * Double(UInt32.max)).rounded())
        do {
            try alpha.setMultiplier(factor: factor)
        } catch {
            throw .protocolFailure
        }
    }

    /// Latch this child's pending buffer and adjacent state. Because the role is
    /// synchronized, nothing becomes visible until the parent subtree commits.
    public func commit()
        throws(NucleusDesktopWindowError)
    {
        do {
            try surface.commit()
        } catch {
            throw .protocolFailure
        }
    }

    public func close() {
        guard !closed else { return }
        closed = true
        if let alpha {
            try? alpha.destroy()
            self.alpha = nil
        }
        try? role.destroy()
        try? surface.destroy()
    }

    package func withUnsafeNativeSurface<Result>(
        _ body: (OpaquePointer) throws -> Result
    ) throws -> Result {
        try unsafe surface.withUnsafeNativeProxy(body)
    }
}
