@_spi(NucleusCompositor) public import NucleusLayers
public import enum NucleusTypes.BackdropMaterialKind

/// Single Swift authority for backdrop dynamics, material identity, state,
/// appearance, accessibility, visibility, occlusion, and grouping. The caller
/// gathers identities and geometry, then executes the returned specifications.
@MainActor
public final class BackdropResolver {
    public struct Identity: Sendable, Equatable {
        public var layerID: UInt64
        public var material: BackdropMaterialKind
        public var requestedState: BackdropState
        public var appearance: BackdropAppearance
        public var isEmphasized: Bool
        public var owningWindowID: UInt64?
        public var tint: SIMD4<Float>
        public var opacity: Float
    }

    public struct GeometryInput: Sendable, Equatable {
        public var layerID: UInt64
        public var frame: BackdropPolicy.Rect
        public var isOpaqueOccluder: Bool
        public var producerGroupID: UInt64
    }

    public private(set) var materials: [UInt64: ResolvedBackdropMaterial] = [:]
    private var identities: [UInt64: Identity] = [:]
    public var dynamics = BackdropDynamics()

    public init() {}

    /// Frame-start half of `resolveBackdrops`. Advances presentation dynamics
    /// once, then resolves every identity into the retained frame snapshot.
    public func resolveBackdrops(
        identities: [Identity],
        keyWindowID: UInt64?,
        accessibility: BackdropPolicy.Accessibility,
        increaseContrast: Bool,
        frameTime: Double
    ) -> [ResolvedBackdropMaterialRecord] {
        let producers = dynamics.resolve(frameTime: frameTime)
        materials.removeAll(keepingCapacity: true)
        self.identities.removeAll(keepingCapacity: true)
        var records: [ResolvedBackdropMaterialRecord] = []
        records.reserveCapacity(identities.count)
        for identity in identities {
            self.identities[identity.layerID] = identity
            let state = BackdropPolicy.resolveState(
                requested: identity.requestedState,
                owningWindowID: identity.owningWindowID,
                keyWindowID: keyWindowID
            )
            let appearance = BackdropPolicy.resolveAppearance(
                requested: identity.appearance,
                systemDefault: accessibility.systemAppearance
            )
            var resolved = BackdropCatalog.resolve(
                key: .init(
                    role: identity.material,
                    appearance: appearance,
                    reduceTransparency: accessibility.reduceTransparency,
                    increaseContrast: increaseContrast,
                    state: state,
                    emphasized: identity.isEmphasized
                ),
                producers: producers
            )
            if identity.tint.w > 0 {
                resolved.tint = identity.tint
                resolved.tintBlend = min(max(identity.tint.w, 0), 1)
            }
            resolved.alpha *= min(max(identity.opacity, 0), 1)
            resolved.enabled = resolved.enabled && resolved.alpha > 0.0001
            materials[identity.layerID] = resolved
            records.append(.init(layerID: identity.layerID, material: resolved, needsFrame: dynamics.hasActiveAnimation))
        }
        return records
    }

    /// Post-walk half of `resolveBackdrops`. Geometry policy consumes the
    /// retained frame-start state/appearance snapshot and never re-resolves it.
    public func resolveSpatial(
        geometries: [GeometryInput]
    ) -> [BackdropPolicy.Draw] {
        let fallbackIdentity = identities[UInt64.max]
        let layers = geometries.map { geometry in
            let identity = identities[geometry.layerID] ?? fallbackIdentity
            return BackdropPolicy.LayerInput(
                layerID: geometry.layerID,
                frame: geometry.frame,
                material: identity?.material ?? .contentBackground,
                requestedState: identity?.requestedState ?? .active,
                appearance: identity?.appearance ?? .auto,
                isEmphasized: identity?.isEmphasized ?? false,
                producerGroupID: geometry.producerGroupID,
                owningWindowID: identity?.owningWindowID,
                isOpaqueOccluder: geometry.isOpaqueOccluder
            )
        }
        var spatialMaterials = materials
        if let fallback = materials[UInt64.max] {
            for geometry in geometries where spatialMaterials[geometry.layerID] == nil {
                spatialMaterials[geometry.layerID] = fallback
            }
        }
        return BackdropPolicy.resolve(
            layers: layers,
            keyWindowID: nil,
            resolvedMaterials: spatialMaterials
        )
    }
}

public struct ResolvedBackdropMaterialRecord: Sendable, Equatable {
    public var layerID: UInt64
    public var material: ResolvedBackdropMaterial
    public var needsFrame: Bool
}
