// The boundary between the Swift-authored retained tree and concrete plan
// emission: the per-layer geometric lowering (world matrix / clip / visible
// rect / combined opacity), remote-host inline resolution, the damage-fact
// lowering family that feeds the 9.6 tracker, and the visual-state signatures.
//
// Hashing: the visual-state signatures are an internal frame-to-frame change-
// detection key that never crosses a language boundary, so `SceneHasher` is a
// deterministic FNV-1a-64 fed in a fixed field order — contract-parity (stable
// per visual state, distinguishes changes).

// MARK: - Hosted-context value inputs

/// The hosted-context geometry the scene lowering reads. Mirrors the
/// `root_layer_id` + `source_rect` of `rs.HostedContextGeometry`.
internal import NucleusRenderModel
internal import struct NucleusTypes.OutputPixelSize
internal import struct NucleusTypes.Rect

struct HostedContextGeometry {
    var rootLayerId: UInt64
    var sourceRect: NucleusRenderModel.Rect
}

/// Inputs for lowering a remote-host layer's damage. Mirrors
/// `RemoteHostDamageInput` (the host is the kind's target context id).
struct RemoteHostDamageInput {
    var hostContextId: ContextID
    var geometry: HostedContextGeometry
    var contextRevision: UInt64
}

// MARK: - Per-layer geometric lowering

/// The resolved per-layer geometry the rest of lowering consumes. Mirrors
/// `LayerInput`.
struct LayerInput {
    var layerId: UInt64
    var layer: Layer
    var bounds: Bounds
    var parentMatrix: M44
    var worldMatrix: M44
    var clip: ClipState
    var layerRect: LogicalRect
    var visibleRect: LogicalRect?
    var combinedOpacity: Float
}

/// Resolve a layer's world matrix, accumulated clip, mapped rect, visible rect,
/// and combined opacity. Nil when the layer is fully clipped. Mirrors
/// `lowerLayerInput`.
func lowerLayerInput(
    layerId: UInt64,
    layer: Layer,
    parentMatrix: M44,
    parentOpacity: Float,
    parentClip: ClipState,
    layerOpacity: Float
) -> LayerInput? {
    let bounds = layer.effectiveBounds()
    let worldMatrix = parentMatrix.concat(layerLocalMatrix(layer))
    let clip = accumulateClip(parentClip, layer, worldMatrix)
    if case .empty = clip { return nil }
    let layerRect = mappedLogicalRect(worldMatrix, bounds)
    return LayerInput(
        layerId: layerId, layer: layer, bounds: bounds,
        parentMatrix: parentMatrix, worldMatrix: worldMatrix, clip: clip,
        layerRect: layerRect, visibleRect: clipLayerRect(clip, layerRect),
        combinedOpacity: parentOpacity * layerOpacity)
}

// MARK: - Remote-host resolution

/// World geometry of a hosted context within its host layer. Mirrors
/// `RemoteHostGeometry`.
private struct RemoteHostGeometry {
    var hostMatrix: M44
    var hostRect: LogicalRect
    var visibleRect: LogicalRect
    var opacity: Float
}

/// One inline-subtree remote-host presentation. Mirrors `RemoteHostInline`.
struct RemoteHostInline {
    var rootLayerId: UInt64
    var hostMatrix: M44
    var opacity: Float
    var clip: ClipState
    var destinationPassRequired: Bool
}

/// How a remote host presents. Mirrors `RemoteHostPresentation`.
enum RemoteHostPresentation {
    case inlineSubtree(RemoteHostInline)
}

private func lowerRemoteHostGeometry(_ input: LayerInput, _ geometry: HostedContextGeometry) -> RemoteHostGeometry? {
    let hostMatrix = input.worldMatrix
    let hostRect = mappedLayerRect(hostMatrix, geometry.sourceRect)
    guard let visible = clipLayerRect(input.clip, hostRect) else { return nil }
    return RemoteHostGeometry(hostMatrix: hostMatrix, hostRect: hostRect,
                              visibleRect: visible, opacity: input.combinedOpacity)
}

/// Resolve a remote host into an inline-subtree presentation. Mirrors
/// `lowerRemoteHost`.
func lowerRemoteHost(_ input: LayerInput, _ geometry: HostedContextGeometry,
                     destinationPassRequired: Bool) -> RemoteHostPresentation? {
    guard let resolved = lowerRemoteHostGeometry(input, geometry) else { return nil }
    return .inlineSubtree(RemoteHostInline(
        rootLayerId: geometry.rootLayerId,
        hostMatrix: resolved.hostMatrix,
        opacity: resolved.opacity,
        clip: .rect(RoundedClip(rect: resolved.visibleRect)),
        destinationPassRequired: destinationPassRequired))
}

/// Lower a remote host's damage fact. Mirrors `lowerRemoteHostDamageFact`.
func lowerRemoteHostDamageFact(
    _ target: RenderTarget, _ input: LayerInput, hostContextId: ContextID,
    _ geometry: HostedContextGeometry, contextRevision: UInt64
) -> RemoteHostDamageFact? {
    guard let resolved = lowerRemoteHostGeometry(input, geometry) else { return nil }
    guard let visibleRect = physicalDamageRectFromLogicalRect(target, resolved.visibleRect) else { return nil }
    return RemoteHostDamageFact(
        outputId: target.outputId,
        hostLayerId: input.layerId,
        targetContextId: hostContextId,
        rootLayerId: geometry.rootLayerId,
        contextRevision: contextRevision,
        sourceRect: geometry.sourceRect,
        visibleRect: visibleRect,
        hostSignature: remoteHostSignature(hostContextId, resolved.hostMatrix, resolved.opacity))
}

// MARK: - Damage-fact lowering

/// Lower a layer's damage-relevant facts. Mirrors `lowerLayerDamageFacts`.
func lowerLayerDamageFacts(_ target: RenderTarget, _ input: LayerInput,
                           remoteHost: RemoteHostDamageInput?) -> LayerDamageFacts {
    if case .remoteHost = input.layer.kind {
        let fact: RemoteHostDamageFact?
        if let hosted = remoteHost {
            fact = lowerRemoteHostDamageFact(target, input, hostContextId: hosted.hostContextId,
                                             hosted.geometry, contextRevision: hosted.contextRevision)
        } else {
            fact = nil
        }
        return LayerDamageFacts(remoteHost: fact, descendChildren: false)
    }
    return LayerDamageFacts(
        nativeLayer: lowerNativeLayerDamageFact(target, input),
        external: lowerExternalDamageFact(target, input))
}

/// Lower a native (compositor-tracked) layer's damage fact. Mirrors
/// `lowerNativeLayerDamageFact` (drops the renderer-only `diagnostic`).
func lowerNativeLayerDamageFact(_ target: RenderTarget, _ input: LayerInput) -> NativeLayerDamageFact? {
    if !shouldTrackNativeLayerDamage(input.layer) { return nil }
    let footprint = computeLayerFootprint(LayerFootprintInput(
        layer: input.layer, bounds: input.bounds, layerRect: input.layerRect, clip: input.clip))
    guard let currentVisible = footprint.physicalDamageRect(target) else { return nil }
    return NativeLayerDamageFact(
        outputId: target.outputId,
        layerId: input.layerId,
        visibleRect: currentVisible,
        visualSignature: nativeLayerVisualSignature(input.layer, input.combinedOpacity))
}

/// Lower a layer's external-content damage fact. Mirrors
/// `lowerExternalDamageFact`.
func lowerExternalDamageFact(_ target: RenderTarget, _ input: LayerInput) -> ExternalDamageFact? {
    guard case .external = input.layer.presentedContent() else { return nil }
    guard let visible = input.visibleRect else { return nil }
    guard let visibleRect = physicalDamageRectFromLogicalRect(target, visible) else { return nil }
    return ExternalDamageFact(source: .compositorExternal, visibleRect: visibleRect)
}

/// Whether a layer participates in native-layer damage tracking (notification /
/// hotkey-overlay / dock roles). Mirrors `shouldTrackNativeLayerDamage`.
func shouldTrackNativeLayerDamage(_ layer: Layer) -> Bool {
    switch layer.role {
    case .notification, .hotkeyOverlay, .dock: return true
    default: return false
    }
}

private func mappedLayerRect(
    _ matrix: M44,
    _ rect: NucleusRenderModel.Rect
) -> LogicalRect {
    let mapped = matrix.mapRect(rect.x, rect.y, rect.w, rect.h)
    return LogicalRect(x: Double(mapped.x), y: Double(mapped.y),
                       width: Double(mapped.w), height: Double(mapped.h))
}

// MARK: - Visual-state signatures

/// Visual-state signature for a native-tracked layer. Same visual state → same
/// value; a change to geometry/content/kind changes it. Mirrors
/// `nativeLayerVisualSignature` (contract-parity, see file header).
func nativeLayerVisualSignature(_ layer: Layer, _ combinedOpacity: Float) -> UInt64 {
    nativeLayerSignature(
        layer,
        combinedOpacity,
        revision: layer.model.visualRevision,
        includesContent: true)
}

/// Visual signature excluding sampled content identity. A localized paint
/// replacement can use its projected damage only when this signature and the
/// old footprint are unchanged.
func nativeLayerCompositeSignature(
    _ layer: Layer,
    _ combinedOpacity: Float
) -> UInt64 {
    nativeLayerSignature(
        layer,
        combinedOpacity,
        revision: layer.model.compositeRevision,
        includesContent: false)
}

private func nativeLayerSignature(
    _ layer: Layer,
    _ combinedOpacity: Float,
    revision: UInt64,
    includesContent: Bool
) -> UInt64 {
    var h = SceneHasher(seed: 0x9ea3_7281_71fd_4c5b)
    h.u64(UInt64(layer.role.rawValue))
    h.u64(revision)
    h.f32(combinedOpacity)
    h.f32(layer.effectiveOpacity())

    let bounds = layer.effectiveBounds()
    h.f32(bounds.w); h.f32(bounds.h)
    let position = layer.effectivePosition()
    h.f32(position.x); h.f32(position.y)

    switch layer.kind {
    case .container:
        h.byte(0)
    case .backdrop(let bd):
        h.byte(1)
        h.byte(bd.materialRole.rawValue)
        h.byte(bd.appearance.rawValue)
        h.byte(bd.state.rawValue)
        h.byte(bd.emphasized ? 1 : 0)
        switch bd.mask {
        case .none: h.byte(0)
        case .roundedRect(let radius): h.byte(1); h.f32(radius)
        case .image(let handle): h.byte(2); h.u64(handle.raw)
        }
        switch bd.shape {
        case .rect(let rect):
            h.byte(0)
            h.f32(rect.0); h.f32(rect.1); h.f32(rect.2); h.f32(rect.3)
        case .rrect(let rect, let radii):
            h.byte(1)
            h.f32(rect.0); h.f32(rect.1); h.f32(rect.2); h.f32(rect.3)
            h.f32(radii.0); h.f32(radii.1); h.f32(radii.2); h.f32(radii.3)
        }
    case .remoteHost:
        h.byte(2)
    }

    if includesContent {
        switch layer.presentedContent() {
        case .none: h.byte(0)
        case .paint(let handle): h.byte(1); h.u64(handle.raw)
        case .external(let surfaceId): h.byte(2); h.u64(UInt64(surfaceId.raw))
        case .snapshot(let snapshot): h.byte(3); h.u64(snapshot.raw)
        }
    }

    return h.final()
}

/// Signature of a remote host's identity + placement. Mirrors
/// `remoteHostSignature`.
func remoteHostSignature(_ hostContextId: ContextID, _ hostMatrix: M44, _ effectiveOpacity: Float) -> UInt64 {
    var h = SceneHasher(seed: 0x25b0_f4d3_c17a_8d91)
    h.u64(UInt64(hostContextId.raw))
    for value in hostMatrix.m { h.f32(value) }
    h.f32(effectiveOpacity)
    return h.final()
}

/// Output scale generation: changes when the target's pixel size or scale
/// changes. Mirrors `outputScaleGeneration`.
func outputScaleGeneration(_ target: RenderTarget) -> UInt64 {
    var h = SceneHasher(seed: 0x8f17_2cae_5160_9d03)
    h.u64(UInt64(target.pixelSize.width))
    h.u64(UInt64(target.pixelSize.height))
    h.f32(target.scale)
    h.f64(target.fractionalScale)
    return h.final()
}

/// Wayland-surface backdrop source kinds with distinct synthetic ids. Mirrors
/// `SurfaceBackdropKind`.
enum SurfaceBackdropKind: UInt32 {
    case waylandSurface = 0
    case kdeSurface = 1
    case popup = 2
}

/// Distinct nonzero synthetic layer id per (layer, kind, region). Mirrors
/// `surfaceBackdropLayerId`.
func surfaceBackdropLayerId(_ layerId: UInt64, _ kind: SurfaceBackdropKind, _ regionIndex: UInt32) -> UInt64 {
    var h = SceneHasher(seed: 0x6616_2c4b_0e1f_91a7)
    h.u64(layerId)
    h.u64(UInt64(kind.rawValue))
    h.u64(UInt64(regionIndex))
    let id = h.final()
    return id == 0 ? 1 : id
}

// MARK: - Deterministic signature hasher (FNV-1a-64, contract-parity)

/// A deterministic byte hasher used only for internal visual-state signatures.
/// FNV-1a-64 seeded per call site; the float/int updates feed a fixed field
/// order so the *contract* (stable per state) holds.
struct SceneHasher {
    private var state: UInt64
    private static let prime: UInt64 = 0x0000_0100_0000_01b3

    init(seed: UInt64) { state = seed }

    mutating func byte(_ b: UInt8) {
        state = (state ^ UInt64(b)) &* SceneHasher.prime
    }
    mutating func u64(_ v: UInt64) {
        var x = v
        for _ in 0..<8 { byte(UInt8(x & 0xff)); x >>= 8 }
    }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
    mutating func f64(_ v: Double) { u64(v.bitPattern) }
    private mutating func u32(_ v: UInt32) {
        var x = v
        for _ in 0..<4 { byte(UInt8(x & 0xff)); x >>= 8 }
    }
    func final() -> UInt64 { state }
}
