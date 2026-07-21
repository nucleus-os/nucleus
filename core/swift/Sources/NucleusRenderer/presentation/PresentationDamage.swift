// Per-frame damage collection plus the cross-frame
// damage cache: the damage-source taxonomy,
// the native-layer / remote-host change-detection that decides which prev/current
// rects a frame damages, stale-entry retirement, the source/remote-host counters,
// and the rect/region math (clamp, coverage, blur reconciliation).
//
// The walk's renderer reads (subtree-animation queries) are abstracted behind
// `DamageAnimationProbe`; accumulated coverage uses the shared canonical `Region`.

/// A damage rectangle in device-pixel space. Mirrors `damage.Rect`
/// (`cg_display.PhysicalRect`).
import NucleusRenderModel

typealias DamageRect = PhysicalRect

// MARK: - Source taxonomy

/// Why a frame's damage spans (or clears) the whole output. Mirrors
/// `DamageFullReason`.
enum DamageFullReason: UInt64 {
    case none = 0
    case fullRedraw = 1
    case backgroundAnimation = 2
    case damageCoversOutput = 3
}

/// What produced a damage rect. Mirrors `Source`.
enum DamageSource {
    case window
    case nativeLayer
    case nativeLayerStale
    case remoteHost
    case remoteHostStale
    case externalCommit
    case syntheticExternal
    case compositorExternal
}

/// Where a layer's external damage originates. Mirrors `ExternalDamageSource`.
enum ExternalDamageSource {
    case externalCommit
    case syntheticExternal
    case compositorExternal
}

func sourceForExternal(_ source: ExternalDamageSource) -> DamageSource {
    switch source {
    case .externalCommit: return .externalCommit
    case .syntheticExternal: return .syntheticExternal
    case .compositorExternal: return .compositorExternal
    }
}

/// Whether a source invalidates framebuffer effects (routes to the source sink).
/// Mirrors `sourceInvalidatesFramebufferEffects`.
func sourceInvalidatesFramebufferEffects(_ source: DamageSource) -> Bool {
    switch source {
    case .window, .externalCommit, .syntheticExternal, .compositorExternal:
        return true
    case .nativeLayer, .nativeLayerStale, .remoteHost, .remoteHostStale:
        return false
    }
}

// MARK: - Damage sinks

/// An accumulating damage region.
protocol DamageSink: AnyObject {
    func addRect(_ rect: DamageRect)
}

/// Canonical output-local damage coverage. The exact region is retained while
/// callers receive compositor damage rectangles in output-pixel coordinates.
final class DamageAccumulator: DamageSink {
    private var region = Region()
    var rects: [DamageRect] { region.rectangles.map(Self.damageRect) }

    func addRect(_ rect: DamageRect) {
        guard let rect = Self.regionRect(rect) else { return }
        region.formUnion(rect)
    }

    var isEmpty: Bool { region.isEmpty }

    /// Bounding box of all accumulated rects, or nil if empty.
    func bounds() -> DamageRect? {
        region.bounds.map(Self.damageRect)
    }

    func overlaps(_ rect: DamageRect) -> Bool {
        guard let rect = Self.regionRect(rect) else { return false }
        return !region.intersection(Region(rect)).isEmpty
    }

    private static func regionRect(_ rect: DamageRect) -> RegionRect? {
        guard rect.width > 0, rect.height > 0,
            rect.width <= UInt32(Int32.max), rect.height <= UInt32(Int32.max)
        else { return nil }
        return RegionRect(
            x: rect.x, y: rect.y,
            width: Int32(rect.width), height: Int32(rect.height))
    }

    private static func damageRect(_ rect: RegionRect) -> DamageRect {
        DamageRect(x: rect.x, y: rect.y, width: UInt32(rect.width), height: UInt32(rect.height))
    }
}

/// The set of sinks a frame's damage feeds. Mirrors `DamageSinks` (the blur-
/// region list is part of the deferred tree walk).
struct DamageSinks {
    var output: DamageSink
    var source: DamageSink? = nil
}

// MARK: - Cross-frame damage cache (RenderState.FrameDamageCache)

struct RemoteHostKey: Hashable {
    var outputId: DisplayID
    var hostLayerId: UInt64
}

struct RemoteHostSnapshot {
    var targetContextId: ContextID
    var rootLayerId: UInt64
    var contextRevision: UInt64
    var sourceRect: Rect
    var visibleRect: DamageRect
    var hostSignature: UInt64
}

struct NativeLayerKey: Hashable {
    var outputId: DisplayID
    var layerId: UInt64
}

struct NativeLayerSnapshot {
    var visibleRect: DamageRect
    var visualSignature: UInt64
}

/// Cross-frame damage cache: committed per-key snapshots plus the pending set
/// accumulated during a frame and the retired keys to drop at commit. Mirrors
/// `RenderState.FrameDamageCache`.
final class FrameDamageCache {
    var remoteHosts: [RemoteHostKey: RemoteHostSnapshot] = [:]
    var nativeLayers: [NativeLayerKey: NativeLayerSnapshot] = [:]
    var remoteHostPending: [RemoteHostKey: RemoteHostSnapshot] = [:]
    var nativeLayerPending: [NativeLayerKey: NativeLayerSnapshot] = [:]
    var remoteHostRetired: [RemoteHostKey] = []
    var nativeLayerRetired: [NativeLayerKey] = []

    func beginFrame() {
        remoteHostPending.removeAll(keepingCapacity: true)
        nativeLayerPending.removeAll(keepingCapacity: true)
        remoteHostRetired.removeAll(keepingCapacity: true)
        nativeLayerRetired.removeAll(keepingCapacity: true)
    }

    /// Apply this frame's pending snapshots: drop the retired keys, then fold in
    /// the pending set. Mirrors `commitFrame`.
    func commitFrame() {
        for key in remoteHostRetired { remoteHosts.removeValue(forKey: key) }
        for (key, value) in remoteHostPending { remoteHosts[key] = value }
        for key in nativeLayerRetired { nativeLayers.removeValue(forKey: key) }
        for (key, value) in nativeLayerPending { nativeLayers[key] = value }
    }
}

// MARK: - Damage facts (produced by the scene lowering, consumed here)

struct NativeLayerDamageFact {
    var outputId: DisplayID
    var layerId: UInt64
    var visibleRect: DamageRect
    var visualSignature: UInt64
}

struct RemoteHostDamageFact {
    var outputId: DisplayID
    var hostLayerId: UInt64
    var targetContextId: ContextID
    var rootLayerId: UInt64
    var contextRevision: UInt64
    var sourceRect: Rect
    var visibleRect: DamageRect
    var hostSignature: UInt64
}

struct ExternalDamageFact {
    var source: ExternalDamageSource
    var visibleRect: DamageRect
}

/// The damage-relevant facts a scene layer contributes. Mirrors
/// `LayerDamageFacts`.
struct LayerDamageFacts {
    var remoteHost: RemoteHostDamageFact?
    var nativeLayer: NativeLayerDamageFact?
    var external: ExternalDamageFact?
    var descendChildren: Bool = true
}

/// Renderer subtree-animation query, abstracted from the damage walk. Mirrors
/// `composition.render_server.subtreeHasActiveAnimations`.
protocol DamageAnimationProbe {
    func subtreeHasActiveAnimations(_ layerId: UInt64) -> Bool
}

// MARK: - Counters

struct SourceStats: Equatable {
    var windowRects: UInt64 = 0
    var windowAreaPx: UInt64 = 0
    var nativeLayerRects: UInt64 = 0
    var nativeLayerAreaPx: UInt64 = 0
    var nativeLayerStaleRects: UInt64 = 0
    var nativeLayerStaleAreaPx: UInt64 = 0
    var remoteHostRects: UInt64 = 0
    var remoteHostAreaPx: UInt64 = 0
    var remoteHostStaleRects: UInt64 = 0
    var remoteHostStaleAreaPx: UInt64 = 0
    var externalCommitRects: UInt64 = 0
    var externalCommitAreaPx: UInt64 = 0
    var syntheticExternalRects: UInt64 = 0
    var syntheticExternalAreaPx: UInt64 = 0
    var compositorExternalRects: UInt64 = 0
    var compositorExternalAreaPx: UInt64 = 0

    mutating func note(_ source: DamageSource, _ rect: DamageRect) {
        let area = rectArea(rect)
        switch source {
        case .window: windowRects += 1; windowAreaPx += area
        case .nativeLayer: nativeLayerRects += 1; nativeLayerAreaPx += area
        case .nativeLayerStale: nativeLayerStaleRects += 1; nativeLayerStaleAreaPx += area
        case .remoteHost: remoteHostRects += 1; remoteHostAreaPx += area
        case .remoteHostStale: remoteHostStaleRects += 1; remoteHostStaleAreaPx += area
        case .externalCommit: externalCommitRects += 1; externalCommitAreaPx += area
        case .syntheticExternal: syntheticExternalRects += 1; syntheticExternalAreaPx += area
        case .compositorExternal: compositorExternalRects += 1; compositorExternalAreaPx += area
        }
    }
}

struct RemoteHostStats: Equatable {
    var seen: UInt64 = 0
    var initial: UInt64 = 0
    var unchanged: UInt64 = 0
    var changed: UInt64 = 0
    var stale: UInt64 = 0
    var contextChanged: UInt64 = 0
    var rootChanged: UInt64 = 0
    var sourceRectChanged: UInt64 = 0
    var visibleRectChanged: UInt64 = 0
    var appearanceChanged: UInt64 = 0
    var activeSubtreeAnimation: UInt64 = 0
}

// MARK: - Tracker

/// Per-frame damage tracker: the change-detection + stale-retirement engine.
/// Mirrors `Tracker`.
final class DamageTracker {
    var sourceStats = SourceStats()
    var remoteHostStats = RemoteHostStats()
    var remoteHostFrameActive = false
    var nativeLayerFrameActive = false
    var frameSerial: UInt64 = 0

    init(frameSerial: UInt64 = 0) { self.frameSerial = frameSerial }

    func beginFrame(_ state: FrameDamageCache) {
        sourceStats = SourceStats()
        remoteHostStats = RemoteHostStats()
        state.beginFrame()
        remoteHostFrameActive = true
        nativeLayerFrameActive = true
    }

    func deinitFrame() {
        remoteHostFrameActive = false
        nativeLayerFrameActive = false
    }

    func noteWindowDamage(_ area: UInt64) {
        sourceStats.windowRects += 1
        sourceStats.windowAreaPx += area
    }

    func addRect(_ sinks: DamageSinks, _ source: DamageSource, _ rect: DamageRect) {
        sinks.output.addRect(rect)
        if sourceInvalidatesFramebufferEffects(source) {
            sinks.source?.addRect(rect)
        }
        sourceStats.note(source, rect)
    }

    /// Retire native-layer entries not seen this frame, damaging their last rect.
    /// Mirrors `addStaleNativeLayerDamage`.
    func addStaleNativeLayerDamage(_ state: FrameDamageCache, _ outputId: DisplayID, _ out: DamageSink) {
        if !nativeLayerFrameActive { return }
        let sinks = DamageSinks(output: out)
        for (key, snapshot) in state.nativeLayers {
            if key.outputId != outputId { continue }
            if state.nativeLayerPending[key] != nil { continue }
            addRect(sinks, .nativeLayerStale, snapshot.visibleRect)
            state.nativeLayerRetired.append(key)
        }
    }

    /// Retire remote-host entries not seen this frame. Mirrors
    /// `addStaleRemoteHostDamage`.
    func addStaleRemoteHostDamage(_ state: FrameDamageCache, _ outputId: DisplayID, _ out: DamageSink) {
        if !remoteHostFrameActive { return }
        let sinks = DamageSinks(output: out)
        for (key, snapshot) in state.remoteHosts {
            if key.outputId != outputId { continue }
            if state.remoteHostPending[key] != nil { continue }
            addRect(sinks, .remoteHostStale, snapshot.visibleRect)
            remoteHostStats.stale += 1
            state.remoteHostRetired.append(key)
        }
    }

    func applyLayerFacts(_ state: FrameDamageCache, _ facts: LayerDamageFacts, _ sinks: DamageSinks,
                         _ probe: DamageAnimationProbe) {
        if let fact = facts.remoteHost { trackRemoteHostDamage(state, fact, sinks, probe) }
        if let fact = facts.nativeLayer { trackNativeLayerDamage(state, fact, sinks, probe) }
        if let fact = facts.external {
            addRect(sinks, sourceForExternal(fact.source), fact.visibleRect)
        }
    }

    func trackNativeLayerDamage(_ state: FrameDamageCache, _ fact: NativeLayerDamageFact,
                                _ sinks: DamageSinks, _ probe: DamageAnimationProbe) {
        if !nativeLayerFrameActive { return }
        let key = NativeLayerKey(outputId: fact.outputId, layerId: fact.layerId)
        let current = NativeLayerSnapshot(visibleRect: fact.visibleRect, visualSignature: fact.visualSignature)

        var currentAdded = false
        var changed = false
        if let previous = state.nativeLayers[key] {
            if !rectsEqual(previous.visibleRect, current.visibleRect) {
                addRect(sinks, .nativeLayer, previous.visibleRect)
                addRect(sinks, .nativeLayer, current.visibleRect)
                currentAdded = true
                changed = true
            }
            if previous.visualSignature != current.visualSignature { changed = true }
        } else {
            changed = true
        }

        if probe.subtreeHasActiveAnimations(fact.layerId) { changed = true }

        if changed && !currentAdded {
            addRect(sinks, .nativeLayer, current.visibleRect)
        }
        state.nativeLayerPending[key] = current
    }

    func trackRemoteHostDamage(_ state: FrameDamageCache, _ fact: RemoteHostDamageFact,
                               _ sinks: DamageSinks, _ probe: DamageAnimationProbe) {
        if !remoteHostFrameActive { return }
        remoteHostStats.seen += 1
        let key = RemoteHostKey(outputId: fact.outputId, hostLayerId: fact.hostLayerId)
        let current = RemoteHostSnapshot(
            targetContextId: fact.targetContextId, rootLayerId: fact.rootLayerId,
            contextRevision: fact.contextRevision, sourceRect: fact.sourceRect,
            visibleRect: fact.visibleRect, hostSignature: fact.hostSignature)

        var currentAdded = false
        var changed = false
        if let previous = state.remoteHosts[key] {
            if previous.targetContextId != current.targetContextId ||
                previous.contextRevision != current.contextRevision {
                remoteHostStats.contextChanged += 1
                if previous.targetContextId != current.targetContextId { changed = true }
            }
            if previous.rootLayerId != current.rootLayerId {
                remoteHostStats.rootChanged += 1
                changed = true
            }
            if !layerRectsNearlyEqual(previous.sourceRect, current.sourceRect) {
                remoteHostStats.sourceRectChanged += 1
                changed = true
            }
            if !rectsEqual(previous.visibleRect, current.visibleRect) {
                remoteHostStats.visibleRectChanged += 1
                addRect(sinks, .remoteHost, previous.visibleRect)
                addRect(sinks, .remoteHost, current.visibleRect)
                currentAdded = true
                changed = true
            }
            if previous.hostSignature != current.hostSignature {
                remoteHostStats.appearanceChanged += 1
                changed = true
            }
        } else {
            remoteHostStats.initial += 1
            changed = true
        }

        if probe.subtreeHasActiveAnimations(current.rootLayerId) {
            remoteHostStats.activeSubtreeAnimation += 1
        }

        if changed {
            remoteHostStats.changed += 1
            if !currentAdded { addRect(sinks, .remoteHost, current.visibleRect) }
        } else {
            remoteHostStats.unchanged += 1
        }

        state.remoteHostPending[key] = current
    }
}

// MARK: - Rect / region math

func rectsEqual(_ a: DamageRect, _ b: DamageRect) -> Bool {
    a.x == b.x && a.y == b.y && a.width == b.width && a.height == b.height
}

func layerRectsNearlyEqual(_ a: Rect, _ b: Rect) -> Bool {
    abs(a.x - b.x) < 0.01 && abs(a.y - b.y) < 0.01 &&
        abs(a.w - b.w) < 0.01 && abs(a.h - b.h) < 0.01
}

func rectArea(_ rect: DamageRect) -> UInt64 {
    UInt64(rect.width) * UInt64(rect.height)
}

func intersectDamageRects(_ a: DamageRect, _ b: DamageRect) -> DamageRect? {
    let left = max(Int64(a.x), Int64(b.x))
    let top = max(Int64(a.y), Int64(b.y))
    let right = min(Int64(a.x) + Int64(a.width), Int64(b.x) + Int64(b.width))
    let bottom = min(Int64(a.y) + Int64(a.height), Int64(b.y) + Int64(b.height))
    if right <= left || bottom <= top { return nil }
    return DamageRect(x: Int32(left), y: Int32(top),
                      width: UInt32(right - left), height: UInt32(bottom - top))
}

func clampDamageRectToTarget(_ rect: DamageRect, _ width: UInt32, _ height: UInt32) -> DamageRect? {
    if width == 0 || height == 0 || rect.width == 0 || rect.height == 0 { return nil }
    let left = max(Int64(rect.x), 0)
    let top = max(Int64(rect.y), 0)
    let right = min(Int64(rect.x) + Int64(rect.width), Int64(width))
    let bottom = min(Int64(rect.y) + Int64(rect.height), Int64(height))
    if right <= left || bottom <= top { return nil }
    return DamageRect(x: Int32(left), y: Int32(top),
                      width: UInt32(right - left), height: UInt32(bottom - top))
}

func damageBoundsCoverTarget(_ bounds: DamageRect, _ width: UInt32, _ height: UInt32) -> Bool {
    if width == 0 || height == 0 { return false }
    if bounds.x > 0 || bounds.y > 0 { return false }
    let right = bounds.x + Int32(bounds.width)
    let bottom = bounds.y + Int32(bounds.height)
    return right >= Int32(width) && bottom >= Int32(height)
}

func damageBoundsFraction(_ bounds: DamageRect?, _ width: UInt32, _ height: UInt32) -> Double {
    guard let rect = bounds else { return 0 }
    let targetArea = UInt64(width) * UInt64(height)
    if targetArea == 0 { return 0 }
    let rectArea = UInt64(rect.width) * UInt64(rect.height)
    return Double(rectArea) / Double(targetArea)
}

func planRectFromDamageRect(_ rect: DamageRect) -> PlanRect {
    PlanRect(x: Float(rect.x), y: Float(rect.y), w: Float(rect.width), h: Float(rect.height))
}

func planRectsIntersect(_ a: PlanRect, _ b: PlanRect) -> Bool {
    a.x < b.x + b.w && a.x + a.w > b.x && a.y < b.y + b.h && a.y + a.h > b.y
}

/// True if any rect in `region` overlaps `rect`. Mirrors `regionOverlapsRect`.
func regionOverlapsRect(_ region: [DamageRect], _ rect: DamageRect) -> Bool {
    let rx2 = rect.x &+ Int32(rect.width)
    let ry2 = rect.y &+ Int32(rect.height)
    for box in region {
        let bx2 = box.x &+ Int32(box.width)
        let by2 = box.y &+ Int32(box.height)
        if box.x < rx2 && rect.x < bx2 && box.y < ry2 && rect.y < by2 { return true }
    }
    return false
}

/// Force every backdrop-blurred layer whose region overlaps the accumulated
/// damage to re-composite its whole region. Overlap is tested against the
/// pre-expansion damage so neighbouring blurred layers don't cascade. Mirrors
/// `reconcileBackdropBlurDamage`. Returns the count redrawn.
@discardableResult
func reconcileBackdropBlurDamage(_ frameDamage: DamageAccumulator, _ blurRegions: [DamageRect]) -> UInt64 {
    if blurRegions.isEmpty || frameDamage.isEmpty { return 0 }
    let limit = min(blurRegions.count, 64)
    var overlaps = [Bool](repeating: false, count: limit)
    for i in 0..<limit { overlaps[i] = frameDamage.overlaps(blurRegions[i]) }
    var redrawn: UInt64 = 0
    for i in 0..<limit where overlaps[i] {
        frameDamage.addRect(blurRegions[i])
        redrawn += 1
    }
    return redrawn
}
