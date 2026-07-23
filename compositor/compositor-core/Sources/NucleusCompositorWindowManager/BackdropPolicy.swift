public import NucleusTypes
import NucleusCompositorServerTypes
@_spi(NucleusCompositor) import NucleusLayers

/// Swift-owned policy that turns per-layer `BackdropMaterial` intent
/// plus current frame state into the per-frame `BackdropDraw` list consumed by
/// the render walker.
///
/// The end-state architecture moves all backdrop policy decisions
/// here so the render server only consumes resolved draws. See
/// `docs/backdrop-appkit-redesign.md` for the migration order.
///
/// The FFI seam (`nucleus_compositor_backdrop_policy_resolve`) and its call site
/// are added with the render-walker consumer.
@MainActor
public enum BackdropPolicy {

    /// Per-layer input to the policy. `frame` is in output-space
    /// pixels (the same coordinate space the policy returns clipped
    /// regions in).
    public struct LayerInput: Sendable, Equatable {
        public let layerID: UInt64
        public let frame: Rect
        public let material: BackdropMaterialKind
        public let blendingMode: BackdropBlendingMode
        public let requestedState: BackdropState
        public let appearance: BackdropAppearance
        public let isEmphasized: Bool
        public let producerGroupID: UInt64
        /// Window this layer belongs to (for `.followsWindowActiveState`
        /// resolution). `nil` for unowned layers (shell overlays).
        public let owningWindowID: UInt64?
        /// True when this layer is wholly opaque and contributes to
        /// occlusion of layers below it. Backdrop layers themselves are
        /// not opaque (the blur is sampled through them).
        public let isOpaqueOccluder: Bool

        public init(
            layerID: UInt64,
            frame: Rect,
            material: BackdropMaterialKind,
            blendingMode: BackdropBlendingMode = .behindWindow,
            requestedState: BackdropState = .active,
            appearance: BackdropAppearance = .auto,
            isEmphasized: Bool = false,
            producerGroupID: UInt64 = 0,
            owningWindowID: UInt64? = nil,
            isOpaqueOccluder: Bool = false
        ) {
            self.layerID = layerID
            self.frame = frame
            self.material = material
            self.blendingMode = blendingMode
            self.requestedState = requestedState
            self.appearance = appearance
            self.isEmphasized = isEmphasized
            self.producerGroupID = producerGroupID
            self.owningWindowID = owningWindowID
            self.isOpaqueOccluder = isOpaqueOccluder
        }
    }

    /// Resolved appearance — `auto` is collapsed by the policy. The
    /// renderer never sees `auto` in a draw so a mid-frame appearance
    /// change does not split a frame visually.
    public enum ResolvedAppearance: UInt8, Sendable, Equatable {
        case light = 1
        case dark = 2
    }

    /// Per-frame backdrop work for a single layer. Fully-occluded layers
    /// are omitted from the output list entirely; partially-occluded
    /// layers appear with a clipped `region`.
    ///
    /// The policy resolves only: clipped `region`, `groupID` assignment,
    /// `resolvedState` (collapses `.followsWindowActiveState`), and
    /// `resolvedAppearance` (collapses `.auto`). The pass-through fields
    /// the renderer needs (material role, emphasis, blending mode,
    /// shape, mask, tint, opacity) are spliced in from
    /// the originating `BackdropAttachment` keyed on `layerID`, so the
    /// Swift surface and the FFI buffer stay narrow.
    public struct Draw: Sendable, Equatable {
        public let layerID: UInt64
        public let region: Rect
        public let groupID: UInt64
        public let resolvedState: BackdropState
        public let resolvedAppearance: ResolvedAppearance

        public init(
            layerID: UInt64,
            region: Rect,
            groupID: UInt64,
            resolvedState: BackdropState,
            resolvedAppearance: ResolvedAppearance
        ) {
            self.layerID = layerID
            self.region = region
            self.groupID = groupID
            self.resolvedState = resolvedState
            self.resolvedAppearance = resolvedAppearance
        }
    }

    /// Output-space rectangle. Width/height are non-negative; an empty
    /// rect (any dimension <= 0) means "no area."
    public struct Rect: Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public var isEmpty: Bool { width <= 0 || height <= 0 }
        public var maxX: Double { x + width }
        public var maxY: Double { y + height }
    }

    /// Per-frame accessibility / appearance inputs. `reduceTransparency`
    /// short-circuits the policy entirely. `systemAppearance` is the
    /// resolved desktop appearance (from the org.freedesktop.appearance
    /// portal) used to collapse a layer's `.auto` request to a concrete
    /// `.light` / `.dark`.
    public struct Accessibility: Sendable {
        public let reduceTransparency: Bool
        public let systemAppearance: ResolvedAppearance
        public init(
            reduceTransparency: Bool = false,
            systemAppearance: ResolvedAppearance = .light
        ) {
            self.reduceTransparency = reduceTransparency
            self.systemAppearance = systemAppearance
        }
    }

    /// Compute the per-frame `Draw` list for one output.
    ///
    /// - Parameter layers: every layer that may contribute a backdrop,
    ///   in z-order back-to-front. Layers without a backdrop material
    ///   (material == .none) are still passed in so their opaque
    ///   contribution can occlude layers below them.
    /// - Parameter keyWindowID: the window currently holding focus, for
    ///   `.followsWindowActiveState` resolution. `nil` when no window
    ///   is key (e.g. all minimized).
    /// - Parameter accessibility: per-frame accessibility settings.
    /// - Returns: backdrop draws in the same z-order as the input.
    public static func resolve(
        layers: [LayerInput],
        keyWindowID: UInt64?,
        accessibility: Accessibility = .init(),
        resolvedMaterials: [UInt64: ResolvedBackdropMaterial] = [:]
    ) -> [Draw] {
        var draws: [Draw] = []
        draws.reserveCapacity(layers.count)

        // Reused across iterations so the occluder gather doesn't allocate a
        // fresh array per layer the way `slice.filter {}.map {}` did (O(n²)).
        var opaqueAbove: [Rect] = []
        let layerSpan = layers.span

        // Walk back-to-front; `i` is the candidate, `i+1...` are above.
        for i in layerSpan.indices {
            let candidate = layerSpan[i]
            guard candidate.material != .none else { continue }

            opaqueAbove.removeAll(keepingCapacity: true)
            for j in (i + 1)..<layerSpan.count where layerSpan[j].isOpaqueOccluder {
                opaqueAbove.append(layerSpan[j].frame)
            }
            guard let clipped = clip(frame: candidate.frame, subtracting: opaqueAbove) else {
                continue // fully occluded
            }

            let retained = resolvedMaterials[candidate.layerID]
            let resolvedState = retained?.resolvedState ?? resolveState(
                requested: candidate.requestedState, owningWindowID: candidate.owningWindowID,
                keyWindowID: keyWindowID)

            let groupID = resolveGroup(
                material: candidate.material,
                producerGroupID: candidate.producerGroupID,
                owningWindowID: candidate.owningWindowID,
                layerID: candidate.layerID
            )

            let resolvedAppearance = retained?.resolvedAppearance ?? resolveAppearance(
                requested: candidate.appearance, systemDefault: accessibility.systemAppearance)

            draws.append(.init(
                layerID: candidate.layerID,
                region: clipped,
                groupID: groupID,
                resolvedState: resolvedState,
                resolvedAppearance: resolvedAppearance
            ))
        }
        return draws
    }

    // MARK: - Building blocks (testable individually)

    /// Subtract every rect in `subtracting` from `frame` and return the
    /// axis-aligned bounding box of the remaining visible area. Returns
    /// `nil` when the candidate is fully occluded. The
    /// renderer doesn't need rectilinear pieces because the blur sample
    /// already covers the whole bounds.
    static func clip(frame: Rect, subtracting: [Rect]) -> Rect? {
        if frame.isEmpty { return nil }
        var visible: [Rect] = [frame]
        var scratch: [Rect] = []
        for occluder in subtracting {
            if occluder.isEmpty { continue }
            scratch.removeAll(keepingCapacity: true)
            for piece in visible {
                appendRectMinus(piece, occluder, into: &scratch)
            }
            visible = scratch
            if visible.isEmpty { return nil }
        }
        return boundingBox(of: visible)
    }

    /// Collapse `.auto` to the system's resolved appearance. Explicit
    /// `.light` / `.dark` pass through. The renderer never sees `.auto`.
    static func resolveAppearance(
        requested: BackdropAppearance,
        systemDefault: ResolvedAppearance
    ) -> ResolvedAppearance {
        switch requested {
        case .auto: return systemDefault
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// Resolve `.followsWindowActiveState` to `.active` / `.inactive`
    /// using the key window. Explicit `.active` / `.inactive` pass
    /// through unchanged.
    static func resolveState(
        requested: BackdropState,
        owningWindowID: UInt64?,
        keyWindowID: UInt64?
    ) -> BackdropState {
        switch requested {
        case .followsWindowActiveState:
            guard let owningWindowID, let keyWindowID else { return .inactive }
            return owningWindowID == keyWindowID ? .active : .inactive
        case .active, .inactive:
            return requested
        }
    }

    /// Group-assignment policy. Producers may set `producerGroupID`
    /// explicitly; the policy honors non-zero values. Zero means "let
    /// the policy decide":
    ///
    /// - Shell-overlay-class materials (titlebar, menu, hud) within the
    ///   same window share a group keyed on the window id.
    /// - Everything else gets its own group keyed on the layer id (so
    ///   captures aren't accidentally shared across unrelated layers).
    static func resolveGroup(
        material: BackdropMaterialKind,
        producerGroupID: UInt64,
        owningWindowID: UInt64?,
        layerID: UInt64
    ) -> UInt64 {
        if producerGroupID != 0 { return producerGroupID }
        switch material {
        case .titlebar, .menu, .hudWindow:
            if let owningWindowID, owningWindowID != 0 {
                // Stable but distinct from layer ids: high bit set.
                return owningWindowID | (UInt64(1) << 63)
            }
            return layerID
        default:
            return layerID
        }
    }
}

// MARK: - Geometry helpers

private extension BackdropPolicy {
    static func appendRectMinus(_ a: Rect, _ b: Rect, into out: inout [Rect]) {
        // Compute a - b (set difference) as up to four axis-aligned rects.
        let ix = max(a.x, b.x)
        let iy = max(a.y, b.y)
        let ixMax = min(a.maxX, b.maxX)
        let iyMax = min(a.maxY, b.maxY)
        if ix >= ixMax || iy >= iyMax {
            // No intersection: a is unchanged.
            out.append(a)
            return
        }
        // Left slab.
        if a.x < ix {
            out.append(.init(x: a.x, y: a.y, width: ix - a.x, height: a.height))
        }
        // Right slab.
        if ixMax < a.maxX {
            out.append(.init(x: ixMax, y: a.y, width: a.maxX - ixMax, height: a.height))
        }
        // Top slab (inside the x-overlap).
        if a.y < iy {
            out.append(.init(x: ix, y: a.y, width: ixMax - ix, height: iy - a.y))
        }
        // Bottom slab (inside the x-overlap).
        if iyMax < a.maxY {
            out.append(.init(x: ix, y: iyMax, width: ixMax - ix, height: a.maxY - iyMax))
        }
    }

    static func boundingBox(of rects: [Rect]) -> Rect? {
        guard let first = rects.first else { return nil }
        var minX = first.x
        var minY = first.y
        var maxX = first.maxX
        var maxY = first.maxY
        for r in rects.dropFirst() {
            minX = min(minX, r.x)
            minY = min(minY, r.y)
            maxX = max(maxX, r.maxX)
            maxY = max(maxY, r.maxY)
        }
        return .init(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
