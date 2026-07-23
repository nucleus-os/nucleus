#if canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#elseif canImport(Darwin)
import Darwin
#endif
@_spi(NucleusCompositor) public import NucleusLayers
public import struct NucleusCompositorServerTypes.WireChromeInsets

public enum WindowSource: UInt32, Sendable {
    case xdg = 1
    case xwayland = 2
    case layerShell = 3
    /// An ext-session-lock surface: an output-sized, compositor-positioned
    /// surface shown only while the session is locked. Excluded from normal
    /// window management (not tiled, not in workspaces, not in the taskbar);
    /// the lock presentation/input gate composites and routes input to it.
    case lock = 4
}

public enum WindowMapState: Sendable {
    case unmapped
    case mapped
    case closing
}

public struct WindowRect: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: UInt32
    public var height: UInt32

    public init(x: Double = 0, y: Double = 0, width: UInt32 = 1, height: UInt32 = 1) {
        self.x = x
        self.y = y
        self.width = max(1, width)
        self.height = max(1, height)
    }
}

public enum FullscreenTarget: Sendable, Equatable {
    case automatic
    case output(DisplayID)
}

public struct WindowPendingConfigure: Sendable, Equatable {
    public var serial: UInt32
    public var rect: WindowRect
    public var activeMaximized: Bool
    public var activeFullscreen: Bool
    public var specialOutputID: DisplayID?
    public var layoutTransitionID: UInt64
    public var slotGeneration: UInt64

    public init(
        serial: UInt32,
        rect: WindowRect,
        activeMaximized: Bool,
        activeFullscreen: Bool,
        specialOutputID: DisplayID?,
        layoutTransitionID: UInt64,
        slotGeneration: UInt64
    ) {
        self.serial = serial
        self.rect = rect
        self.activeMaximized = activeMaximized
        self.activeFullscreen = activeFullscreen
        self.specialOutputID = specialOutputID
        self.layoutTransitionID = layoutTransitionID
        self.slotGeneration = slotGeneration
    }
}

public struct WindowProtocolState: Sendable {
    public private(set) var pendingConfigures: [WindowPendingConfigure] = []
    private var nextSlotGeneration: UInt64 = 1

    public init() {}

    public var latest: WindowPendingConfigure? { pendingConfigures.last }
    public var hasPending: Bool { !pendingConfigures.isEmpty }

    public mutating func allocateSlotGeneration() -> UInt64 {
        let generation = nextSlotGeneration
        nextSlotGeneration &+= 1
        if nextSlotGeneration == 0 { nextSlotGeneration = 1 }
        return generation
    }

    public mutating func queueConfigure(
        rect: WindowRect,
        activeMaximized: Bool,
        activeFullscreen: Bool,
        specialOutputID: DisplayID?,
        layoutTransitionID: UInt64,
        serial: UInt32
    ) -> UInt64 {
        let generation = allocateSlotGeneration()
        pendingConfigures.append(WindowPendingConfigure(
            serial: serial,
            rect: rect,
            activeMaximized: activeMaximized,
            activeFullscreen: activeFullscreen,
            specialOutputID: specialOutputID,
            layoutTransitionID: layoutTransitionID,
            slotGeneration: generation
        ))
        return generation
    }

    public func configure(forAckSerial ackedSerial: UInt32) -> WindowPendingConfigure? {
        pendingConfigures.last { ackedSerial >= $0.serial }
    }

    public mutating func consumeAcked(_ ackedSerial: UInt32) -> WindowPendingConfigure? {
        var latestIndex: Int?
        for (index, configure) in pendingConfigures.enumerated() {
            if ackedSerial >= configure.serial {
                latestIndex = index
            } else {
                break
            }
        }
        guard let index = latestIndex else { return nil }
        let applied = pendingConfigures[index]
        pendingConfigures.removeFirst(index + 1)
        return applied
    }

    public mutating func mutatePendingConfigures(_ body: (inout WindowPendingConfigure) -> Void) {
        for index in pendingConfigures.indices {
            body(&pendingConfigures[index])
        }
    }
}

public struct WindowPolicyState: Sendable, Equatable {
    public var x: Double = 0
    public var y: Double = 0
    public var layoutWidth: UInt32 = 0
    public var layoutHeight: UInt32 = 0

    public func currentRect(size: RenderSize) -> WindowRect {
        WindowRect(
            x: x,
            y: y,
            width: UInt32(max(1, size.w.rounded(.up))),
            height: UInt32(max(1, size.h.rounded(.up)))
        )
    }

    public mutating func setLayoutRect(_ rect: WindowRect) {
        x = rect.x
        y = rect.y
        layoutWidth = rect.width
        layoutHeight = rect.height
    }

    /// Update only the layout position, leaving the size to be set by the
    /// window's actual committed geometry. Used when accepting a configure: the
    /// compositor controls placement, but the client owns its size — a window
    /// that doesn't honor the configured size (e.g. a fixed-size dialog) must
    /// keep its real committed size, not the size we asked it to be.
    public mutating func setLayoutPosition(_ px: Double, _ py: Double) {
        x = px
        y = py
    }
}

public struct RenderSize: Sendable, Equatable {
    public var w: Double
    public var h: Double

    public init(w: Double, h: Double) {
        self.w = w
        self.h = h
    }
}

public struct TileEdges: Sendable, Equatable {
    public var left: Bool = false
    public var right: Bool = false
    public var top: Bool = false
    public var bottom: Bool = false

    public init(left: Bool = false, right: Bool = false, top: Bool = false, bottom: Bool = false) {
        self.left = left
        self.right = right
        self.top = top
        self.bottom = bottom
    }
}

/// The client content's offset within the window slot — the negated xdg
/// window-geometry origin. GTK/Chrome wrap the visible window in invisible
/// buffer margins (even under server decorations); shifting the backing by this
/// aligns the visible geometry sub-rect with the content viewport. Zero when the
/// whole buffer is the content.
public struct WindowContentOffset: Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double = 0, y: Double = 0) {
        self.x = x
        self.y = y
    }
}

/// A presented-frame rectangle in logical coordinates. The compositor-owned
/// presentation animation (the tiling spring) eases this in continuous Doubles,
/// distinct from the integer-extent `WindowRect`.
public struct PresentationRect: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

/// Sub-pixel rect equality (logical px). The redundant-target guard for the
/// tiling spring.
public func renderRectsNearlyEqual(_ a: PresentationRect, _ b: PresentationRect) -> Bool {
    abs(a.x - b.x) < 0.01 && abs(a.y - b.y) < 0.01 && abs(a.w - b.w) < 0.01 && abs(a.h - b.h) < 0.01
}

/// Compositor-owned presentation timing for the tiling spring and closing fade.
public enum PresentationTiming {
    /// Angular frequency (rad/s) of the critically-damped tiling spring. Higher =
    /// snappier; ~26 settles a typical move in roughly a quarter second.
    public static let tileSpringOmega: Double = 26.0
    /// Motion is "done" once every edge is within this many logical px of the target.
    public static let tileMotionSettleEps: Double = 0.75
    /// Hard cap on the spring's motion phase (seconds).
    public static let tileMotionMaxSeconds: Double = 0.6
    /// How close (logical px) the client's committed size must be to the final tile
    /// to count as settled — else the published presented/base scale renders soft.
    public static let tileSettleEps: Double = 1.0
    /// After motion is done, how long (seconds) to wait for an unresponsive client's
    /// final buffer before settling on whatever size it last committed.
    public static let tileSettleGraceSeconds: Double = 0.5
    /// Presentation-clock duration of the compositor-owned closing fade.
    public static let closingFadeSeconds: Double = 0.18
}

/// Closed-form critically-damped spring: position and velocity at `t` seconds since
/// the segment began, for initial position `x0`, initial velocity `v0`, and `target`,
/// at angular frequency `omega`. Stateless in `t` — sampled fresh each frame (and
/// multiple times per frame for multi-output) with no integration state to advance.
/// Critical damping gives a monotonic, overshoot-free approach; carrying `v0` from
/// the prior segment on a re-tile makes interrupted motion C¹-continuous.
private func springSample(x0: Double, v0: Double, target: Double, omega: Double, t: Double) -> (pos: Double, vel: Double) {
    let disp = x0 - target
    let c = v0 + omega * disp
    let decay = exp(-omega * t)
    return (pos: target + (disp + c * t) * decay,
            vel: (v0 - omega * c * t) * decay)
}

/// One tiling action's motion. The compositor owns the whole thing: a critically-
/// damped spring eases the *presented* frame (position AND size) toward the final
/// tile at the display rate, and a published transform scales the client's buffer
/// onto it. A mid-flight re-tile carries the current velocity into the new segment
/// (see `WindowPresentationActor.beginTileAnimation`), so interruptions stay
/// continuous.
public struct TileAnimation: Sendable, Equatable {
    /// Spring initial condition: the presented frame at `startTimeSeconds` (per edge).
    public var startRect: PresentationRect
    /// Spring initial velocity, carried from the prior segment on a re-tile.
    public var startVel: PresentationRect = .init()
    /// Spring target (the final tile).
    public var finalRect: PresentationRect
    /// Velocity at the most recent sample, captured so the next re-tile can carry it.
    public var currentVel: PresentationRect = .init()
    /// Absolute present time the segment started; 0 = unseeded (seeded on first
    /// sample, so multiple per-output renders in one frame share one clock).
    public var startTimeSeconds: Double = 0
    /// Absolute time motion first finished, for the settle grace backstop.
    public var endTimeSeconds: Double = 0
    /// The slot generation when the segment began. The slot advances when the client
    /// commits an acked configure, so `currentSlotGeneration` moving past this means
    /// the client has committed a buffer in response to the tile.
    public var startSlotGeneration: UInt64 = 0

    /// Seconds since the segment started, seeding `startTimeSeconds` on the first sample.
    public mutating func elapsed(_ nowSeconds: Double) -> Double {
        if startTimeSeconds == 0 { startTimeSeconds = nowSeconds }
        return nowSeconds - startTimeSeconds
    }

    /// The eased presented frame (position + size) at `nowSeconds`, also recording
    /// the instantaneous velocity so a re-tile can carry it.
    public mutating func sampleFrame(_ nowSeconds: Double) -> PresentationRect {
        let t = elapsed(nowSeconds)
        let omega = PresentationTiming.tileSpringOmega
        let x = springSample(x0: startRect.x, v0: startVel.x, target: finalRect.x, omega: omega, t: t)
        let y = springSample(x0: startRect.y, v0: startVel.y, target: finalRect.y, omega: omega, t: t)
        let w = springSample(x0: startRect.w, v0: startVel.w, target: finalRect.w, omega: omega, t: t)
        let h = springSample(x0: startRect.h, v0: startVel.h, target: finalRect.h, omega: omega, t: t)
        currentVel = PresentationRect(x: x.vel, y: y.vel, w: w.vel, h: h.vel)
        return PresentationRect(x: x.pos, y: y.pos, w: w.pos, h: h.pos)
    }

    /// Whether the spring has effectively reached its target: every edge within the
    /// settle epsilon, or the motion backstop has elapsed. Read after `sampleFrame`
    /// has seeded `startTimeSeconds` for the segment.
    public func motionDone(frame: PresentationRect, nowSeconds: Double) -> Bool {
        if nowSeconds - startTimeSeconds > PresentationTiming.tileMotionMaxSeconds { return true }
        let eps = PresentationTiming.tileMotionSettleEps
        return abs(frame.x - finalRect.x) < eps && abs(frame.y - finalRect.y) < eps
            && abs(frame.w - finalRect.w) < eps && abs(frame.h - finalRect.h) < eps
    }
}

public struct WindowTileCrossfade: Sendable, Equatable {
    public let generation: UInt64
    public let snapshotHandle: UInt64

    public init(generation: UInt64, snapshotHandle: UInt64) {
        self.generation = generation
        self.snapshotHandle = snapshotHandle
    }
}

public struct WindowClosingFade: Sendable, Equatable {
    public let generation: UInt64
    public let snapshotHandle: UInt64
    public let frozenRect: PresentationRect
    public var startTimeSeconds: Double?
    public var opacity: Double
    public var destroyWindowOnCompletion: Bool

    public init(
        generation: UInt64,
        snapshotHandle: UInt64,
        frozenRect: PresentationRect,
        startTimeSeconds: Double? = nil,
        opacity: Double = 1,
        destroyWindowOnCompletion: Bool = false
    ) {
        self.generation = generation
        self.snapshotHandle = snapshotHandle
        self.frozenRect = frozenRect
        self.startTimeSeconds = startTimeSeconds
        self.opacity = opacity
        self.destroyWindowOnCompletion = destroyWindowOnCompletion
    }
}

public enum WindowPresentationTransition: Sendable, Equatable {
    case tile(WindowTileCrossfade)
    case closing(WindowClosingFade)

    public var generation: UInt64 {
        switch self {
        case .tile(let state): state.generation
        case .closing(let state): state.generation
        }
    }

    public var snapshotHandle: UInt64 {
        switch self {
        case .tile(let state): state.snapshotHandle
        case .closing(let state): state.snapshotHandle
        }
    }
}

/// The resource obligation returned exactly once when a presentation transition
/// is replaced, cancelled, or completed.
public struct WindowTransitionRetirement: Sendable, Equatable {
    public let generation: UInt64
    public let snapshotHandle: UInt64
    public let wasClosing: Bool
    public let destroyWindow: Bool

    public init(
        generation: UInt64,
        snapshotHandle: UInt64,
        wasClosing: Bool,
        destroyWindow: Bool
    ) {
        self.generation = generation
        self.snapshotHandle = snapshotHandle
        self.wasClosing = wasClosing
        self.destroyWindow = destroyWindow
    }
}

/// The compositor-owned presentation state for one window: the PRESENTED frame
/// (what is actually drawn, eased by the tiling spring independent of the client's
/// commit cadence) plus the active tile animation. Authoritative for render, damage,
/// and hit-testing.
public struct WindowPresentationActor: Sendable {
    public var initialized: Bool = false
    public var mapState: WindowMapState = .unmapped
    public var presentedRect: PresentationRect = .init()
    /// Active tiling animation (the compositor-owned size curve + placement), or nil
    /// when settled/snapped.
    public var tileAnimation: TileAnimation?
    /// Last configure slot that reached the latch/ack path.
    public var latestLatchedSlotGeneration: UInt64 = 0
    /// Current presentation target slot; may lead the latched slot.
    public var currentSlotGeneration: UInt64 = 0
    /// The single snapshot-backed transition. Tile crossfade and closing fade are
    /// mutually exclusive, so supersession has one generation and one retirement
    /// obligation.
    public private(set) var transition: WindowPresentationTransition?
    private var nextTransitionGeneration: UInt64 = 1

    public init() {}

    /// The rect the actor is heading toward: the tile's final rect while a segment is
    /// in flight, else the settled presented rect.
    public func targetRect() -> PresentationRect {
        if let anim = tileAnimation { return anim.finalRect }
        return presentedRect
    }

    public mutating func ensureInitialized(fallback: PresentationRect) {
        if initialized { return }
        initialized = true
        presentedRect = fallback
    }

    public mutating func snapTo(_ rect: PresentationRect, slotGeneration: UInt64) {
        initialized = true
        presentedRect = rect
        currentSlotGeneration = slotGeneration
        tileAnimation = nil
    }

    /// Begin a tiling spring toward `finalRect`, starting from `startRect` (the live
    /// presented rect). If a segment is already in flight (a mid-flight re-tile), its
    /// current velocity is carried into the new segment so motion is C¹-continuous.
    public mutating func beginTileAnimation(startRect: PresentationRect, finalRect: PresentationRect, slotGeneration: UInt64) {
        let carriedVel = tileAnimation?.currentVel ?? PresentationRect()
        ensureInitialized(fallback: finalRect)
        currentSlotGeneration = slotGeneration
        tileAnimation = TileAnimation(
            startRect: startRect,
            startVel: carriedVel,
            finalRect: finalRect,
            startSlotGeneration: slotGeneration
        )
    }

    /// Set the presented rect only (not the slot). The per-frame advance uses this.
    public mutating func setPresented(_ rect: PresentationRect) {
        initialized = true
        presentedRect = rect
    }

    /// Finish a tile animation, landing the presented frame on `settleRect`.
    public mutating func settleTileAnimation(_ settleRect: PresentationRect) {
        if tileAnimation != nil {
            presentedRect = settleRect
            tileAnimation = nil
        }
    }

    /// Drop an in-flight tile animation, freezing the presented frame where it is.
    /// Used on unmap/close so a closing window does not keep easing its frame.
    public mutating func cancelTileAnimation() {
        tileAnimation = nil
    }

    public func hasActiveTileAnimation() -> Bool { tileAnimation != nil }

    /// Whether a tile animation is already in flight toward (approximately) `rect`.
    /// A redundant re-present for the same target must NOT rebuild the animation.
    public func tileAnimationTargetsRect(_ rect: PresentationRect) -> Bool {
        guard let anim = tileAnimation else { return false }
        return renderRectsNearlyEqual(anim.finalRect, rect)
    }

    public func targetMatches(_ rect: PresentationRect) -> Bool {
        renderRectsNearlyEqual(targetRect(), rect)
    }

    @discardableResult
    public mutating func installTileCrossfade(
        snapshotHandle: UInt64
    ) -> (generation: UInt64, replaced: WindowTransitionRetirement?) {
        let replaced = takeTransition()
        let generation = allocateTransitionGeneration()
        transition = .tile(WindowTileCrossfade(
            generation: generation,
            snapshotHandle: snapshotHandle))
        mapState = .mapped
        return (generation, replaced)
    }

    @discardableResult
    public mutating func installClosingFade(
        snapshotHandle: UInt64,
        frozenRect: PresentationRect,
        destroyWindowOnCompletion: Bool
    ) -> (generation: UInt64, replaced: WindowTransitionRetirement?) {
        let replaced = takeTransition()
        let generation = allocateTransitionGeneration()
        transition = .closing(WindowClosingFade(
            generation: generation,
            snapshotHandle: snapshotHandle,
            frozenRect: frozenRect,
            destroyWindowOnCompletion: destroyWindowOnCompletion))
        presentedRect = frozenRect
        initialized = true
        tileAnimation = nil
        mapState = .closing
        return (generation, replaced)
    }

    /// Preserve an already-captured close while upgrading an unmap into permanent
    /// window destruction. No new generation or capture is needed.
    public mutating func requireWindowDestructionAfterClosing() {
        guard case .closing(var state) = transition else { return }
        state.destroyWindowOnCompletion = true
        transition = .closing(state)
    }

    /// Sample closing opacity from the presentation clock. Returns true while a
    /// future sample can change the value.
    public mutating func advanceClosingFade(
        presentTimeSeconds: Double
    ) -> Bool {
        guard case .closing(var state) = transition else { return false }
        if state.startTimeSeconds == nil {
            state.startTimeSeconds = presentTimeSeconds
        }
        let elapsed = max(0, presentTimeSeconds - (state.startTimeSeconds ?? presentTimeSeconds))
        let progress = min(1, elapsed / PresentationTiming.closingFadeSeconds)
        // Smoothstep keeps both ends stationary without introducing a second
        // animation system.
        let eased = progress * progress * (3 - 2 * progress)
        state.opacity = 1 - eased
        transition = .closing(state)
        return state.opacity > 0
    }

    public func transitionGeneration() -> UInt64? {
        transition?.generation
    }

    public func closingOpacity() -> Double {
        guard case .closing(let state) = transition else { return 1 }
        return state.opacity
    }

    public func hasClosingFade() -> Bool {
        if case .closing = transition { return true }
        return false
    }

    /// Take only the expected generation. A late completion from a superseded
    /// transition therefore cannot retire the replacement's resource.
    public mutating func takeTransition(
        generation expectedGeneration: UInt64? = nil
    ) -> WindowTransitionRetirement? {
        guard let transition else { return nil }
        if let expectedGeneration, transition.generation != expectedGeneration {
            return nil
        }
        self.transition = nil
        switch transition {
        case .tile(let state):
            return WindowTransitionRetirement(
                generation: state.generation,
                snapshotHandle: state.snapshotHandle,
                wasClosing: false,
                destroyWindow: false)
        case .closing(let state):
            mapState = .unmapped
            return WindowTransitionRetirement(
                generation: state.generation,
                snapshotHandle: state.snapshotHandle,
                wasClosing: true,
                destroyWindow: state.destroyWindowOnCompletion)
        }
    }

    private mutating func allocateTransitionGeneration() -> UInt64 {
        let generation = nextTransitionGeneration
        nextTransitionGeneration &+= 1
        if nextTransitionGeneration == 0 {
            nextTransitionGeneration = 1
        }
        return generation
    }
}

@MainActor
public final class Window {
    public let id: WindowID
    public var source: WindowSource
    /// The compositor-stable identity of the window's backing `wl_surface` on the
    /// live Wayland router (0 when unlinked). Wire object ids are client-scoped;
    /// `WlCompositor` resolves collisions before this value reaches the model. This
    /// is the single home for surface→window identity: the router driver sets it
    /// when the role is created, and focus/scene/activation resolve a `Window` back
    /// to its surface through it.
    public var surfaceObjectId: UInt32 = 0 {
        didSet {
            if surfaceObjectId != oldValue { onSurfaceObjectIdChange?(self, oldValue) }
        }
    }
    /// Installed by `WindowList` when the window is added, so the list's
    /// `surfaceObjectId -> Window` index self-maintains when the id is (re)assigned
    /// after creation. `(window, oldValue)`. Nil for a detached window.
    public var onSurfaceObjectIdChange: ((Window, UInt32) -> Void)?
    /// Records a coarse `windowChanged` for the observation stream when a
    /// projected-relevant field changes. Installed by the model at creation; nil
    /// for a detached window. The model coalesces and dispatches per iteration.
    public var changeRecorder: ((DesktopChange) -> Void)?
    /// Human-readable title and application identity, normalized across sources:
    /// an xdg toplevel's `set_title`/`set_app_id`, or an Xwayland window's
    /// `_NET_WM_NAME` / `WM_CLASS` class. The single home for window metadata —
    /// the foreign-toplevel projection and native-command identity matching read
    /// these, not the per-source role objects.
    public var title: String = "" { didSet { if title != oldValue { changeRecorder?(.windowChanged(id)) } } }
    public var appId: String = "" { didSet { if appId != oldValue { changeRecorder?(.windowChanged(id)) } } }
    public var mapped: Bool = false {
        didSet {
            guard mapped != oldValue else { return }
            if mapped {
                presentationActor.mapState = .mapped
            } else if !presentationActor.hasClosingFade() {
                presentationActor.mapState = .unmapped
            }
            changeRecorder?(.windowChanged(id))
        }
    }
    public var protocolState: WindowProtocolState = .init()
    public var policyState: WindowPolicyState = .init()
    /// Geometry the compositor has requested but the client may not have committed.
    public private(set) var requestedFrame: WindowRect?
    /// Geometry backed by the latest acknowledged client content.
    public private(set) var committedFrame: WindowRect?
    public var requestedMaximized: Bool = false
    public var requestedFullscreen: Bool = false
    public var fullscreenTarget: FullscreenTarget = .automatic
    public var preferredOutputID: DisplayID?
    public var currentOutputID: DisplayID? { didSet { if currentOutputID != oldValue { changeRecorder?(.windowChanged(id)) } } }
    public var specialOutputID: DisplayID?
    public var activeMaximized: Bool = false { didSet { if activeMaximized != oldValue { changeRecorder?(.windowChanged(id)) } } }
    public var activeFullscreen: Bool = false { didSet { if activeFullscreen != oldValue { changeRecorder?(.windowChanged(id)) } } }
    public var managedAppWindow: Bool = true
    // Window visibility. `minimized` is driven by an explicit minimize request;
    // `spaceHidden` by workspace (space) activation. Both default to visible.
    public var minimized: Bool = false { didSet { if minimized != oldValue { changeRecorder?(.windowChanged(id)) } } }
    public var spaceHidden: Bool = false { didSet { if spaceHidden != oldValue { changeRecorder?(.windowChanged(id)) } } }
    public var wantsKeyboardFocus: Bool = true
    public var committedLogicalSize: RenderSize = RenderSize(w: 1, h: 1)
    /// The committed buffer's pixel extent (the full `wl_surface` buffer size,
    /// including any CSD margins) — the backing layer's source size before the
    /// presented/base scale. Set by the render driver on each commit.
    public var committedBufferSize: RenderSize = RenderSize(w: 0, h: 0)
    /// The client content's offset within the slot (negated xdg geometry origin),
    /// set by the render driver from the committed window geometry.
    public var contentOffsetInSlot: WindowContentOffset = .init()
    public var tileEdges: TileEdges = .init()
    /// Window decoration intent (the `NSWindow.StyleMask` analog). The frame
    /// view derives the titlebar, border, and standard buttons — and thus the
    /// chrome geometry — from this. `.borderless` (the default) draws no server
    /// chrome; managed xdg toplevels are seeded `.titledResizable`. Owned by the
    /// decoration-resolution policy.
    public var styleMask: WindowStyleMask = .borderless
    public var restoreRect: WindowRect?
    public var restoreOutputID: DisplayID?
    public var layerHost: LayerHost?
    /// Stacking band (0 normal, +1 above, -1 below). `WindowList.items` is kept
    /// level-sorted by `insertionIndex`, so a level change must re-position the
    /// window into its new band — the list wires `onLevelChange` to do that.
    public var level: Int32 = 0 {
        didSet { if level != oldValue { onLevelChange?(self) } }
    }
    /// Set by `WindowList.add` to restack this window when its `level` changes; nil
    /// before the window is added (add() does the initial band-correct placement).
    public var onLevelChange: ((Window) -> Void)?
    /// The window this one is a child of (xdg set_parent / X11 transient-for).
    /// Drives parent-child stacking: a child is kept above its parent and the
    /// family travels together on raise. `nil` for ordinary top-level windows.
    public var parentWindowID: WindowID?
    /// Compositor-owned presentation state: the eased PRESENTED frame + the active
    /// tiling spring. The scene feeder samples it per frame (`currentAnimatedRect`,
    /// `tileCrossfadeOpacity`) to author the eased layout; the configure path seeds
    /// it (`seedPresentationActorToRect`) and begins springs
    /// (`beginPresentationTileAnimation`). Distinct from `policyState` (the
    /// authorized slot) and `committedLogicalSize` (the client's committed extent).
    public var presentationActor = WindowPresentationActor()

    public init(id: WindowID, source: WindowSource) {
        self.id = id
        self.source = source
    }

    public func logicalSize() -> RenderSize { committedLogicalSize }
    public func layoutSize() -> RenderSize {
        if policyState.layoutWidth == 0 || policyState.layoutHeight == 0 {
            return logicalSize()
        }
        return RenderSize(w: Double(policyState.layoutWidth), h: Double(policyState.layoutHeight))
    }
    /// The window's frame rect — the outer rectangle the user sees and
    /// manipulates, including server-drawn chrome. Authoritative for layout,
    /// stacking, placement, and hit-testing. The client content occupies
    /// `contentRect()`, inset by `chromeInsets`.
    public func currentRect() -> WindowRect {
        requestedFrame ?? policyState.currentRect(size: layoutSize())
    }

    public func currentCommittedRect() -> WindowRect {
        committedFrame ?? policyState.currentRect(size: logicalSize())
    }

    /// The window's frame view (the `NSThemeFrame` analog): owns the titlebar,
    /// border, and standard window buttons derived from the style mask, with
    /// fullscreen suppression applied. Drives the chrome geometry and rendering.
    public var frameView: WindowFrameView {
        WindowFrameView(styleMask: styleMask, fullscreen: activeFullscreen)
    }

    /// The chrome reservation between the frame rect and the content rect, after
    /// fullscreen suppression. Zero for borderless / fullscreen windows.
    public var chromeInsets: WindowEdgeInsets { frameView.contentInsets }

    /// The content rect for a given frame rect, removing the chrome insets.
    /// Mirrors `NSWindow.contentRect(forFrameRect:)`.
    public func contentRect(forFrameRect frame: WindowRect) -> WindowRect {
        let insets = chromeInsets
        return WindowRect(
            x: frame.x + insets.left,
            y: frame.y + insets.top,
            width: UInt32(max(1, Double(frame.width) - insets.horizontal)),
            height: UInt32(max(1, Double(frame.height) - insets.vertical))
        )
    }

    /// The frame rect for a given content rect, adding the chrome insets.
    /// Mirrors `NSWindow.frameRect(forContentRect:)`.
    public func frameRect(forContentRect content: WindowRect) -> WindowRect {
        let insets = chromeInsets
        return WindowRect(
            x: content.x - insets.left,
            y: content.y - insets.top,
            width: UInt32(max(1, Double(content.width) + insets.horizontal)),
            height: UInt32(max(1, Double(content.height) + insets.vertical))
        )
    }

    /// The client content rect for this window's current frame rect.
    public func contentRect() -> WindowRect { contentRect(forFrameRect: currentRect()) }

    // MARK: - Compositor-owned presentation (the tiling spring)

    /// The model frame rect (the authorized outer rect) as a continuous
    /// `PresentationRect`. The spring's fallback target before the actor is seeded.
    private func modelPresentationRect() -> PresentationRect {
        let rect = currentRect()
        return PresentationRect(x: rect.x, y: rect.y, w: Double(rect.width), h: Double(rect.height))
    }

    /// The rect the actor is heading toward: the in-flight tile's final rect, the
    /// settled presented rect, or — before the actor is seeded — the model rect.
    public func targetRenderRect() -> PresentationRect {
        if presentationActor.initialized { return presentationActor.targetRect() }
        return modelPresentationRect()
    }

    /// The current compositor-owned presentation rect — what is actually drawn. May
    /// lead the client's committed content size while configure/ack catches up.
    public func currentAnimatedRect() -> PresentationRect {
        if presentationActor.initialized { return presentationActor.presentedRect }
        return targetRenderRect()
    }

    /// Snap the presentation actor to `rect` with no animation (first map / a hard
    /// placement). Mirrors `Window.seedPresentationActorToRect`.
    public func seedPresentationActorToRect(_ rect: PresentationRect, slotGeneration: UInt64) {
        presentationActor.snapTo(rect, slotGeneration: slotGeneration)
    }

    /// Begin a tiling spring from the live presented rect to `finalRect`. The
    /// compositor owns the motion; the client is asked for the final size and its
    /// buffer is scaled onto the eased frame. A redundant re-present for the same
    /// target leaves the in-flight curve untouched.
    public func beginPresentationTileAnimation(finalRect: PresentationRect, slotGeneration: UInt64) {
        if presentationActor.tileAnimationTargetsRect(finalRect) { return }
        presentationActor.beginTileAnimation(
            startRect: currentAnimatedRect(),
            finalRect: finalRect,
            slotGeneration: slotGeneration
        )
    }

    public func hasActiveTileAnimation() -> Bool { presentationActor.hasActiveTileAnimation() }

    public func hasActiveClosingFade() -> Bool {
        presentationActor.hasClosingFade()
    }

    public func activeTransitionGeneration() -> UInt64? {
        presentationActor.transitionGeneration()
    }

    @discardableResult
    public func installTileCrossfade(
        snapshotHandle: UInt64
    ) -> (generation: UInt64, replaced: WindowTransitionRetirement?) {
        presentationActor.installTileCrossfade(snapshotHandle: snapshotHandle)
    }

    @discardableResult
    public func installClosingFade(
        snapshotHandle: UInt64,
        destroyWindowOnCompletion: Bool
    ) -> (generation: UInt64, replaced: WindowTransitionRetirement?) {
        presentationActor.installClosingFade(
            snapshotHandle: snapshotHandle,
            frozenRect: currentAnimatedRect(),
            destroyWindowOnCompletion: destroyWindowOnCompletion)
    }

    public func requireWindowDestructionAfterClosing() {
        presentationActor.requireWindowDestructionAfterClosing()
    }

    @discardableResult
    public func advanceClosingFade(presentTimeSeconds: Double) -> Bool {
        presentationActor.advanceClosingFade(
            presentTimeSeconds: presentTimeSeconds)
    }

    public func windowPresentationOpacity() -> Double {
        presentationActor.closingOpacity()
    }

    /// Opacity of the transient snapshot overlay. A close fades the entire root,
    /// so its frozen overlay stays opaque within that root; a tile dissolves only
    /// the snapshot over live client content.
    public func transitionOverlayOpacity() -> Double {
        switch presentationActor.transition {
        case .tile:
            return presentationActor.tileAnimation == nil
                ? 0
                : tileCrossfadeOpacity()
        case .closing:
            return 1
        case nil:
            return 1
        }
    }

    @discardableResult
    public func takePresentationTransition(
        generation: UInt64? = nil
    ) -> WindowTransitionRetirement? {
        presentationActor.takeTransition(generation: generation)
    }

    /// Advance the tiling animation once for the frame predicted to present at
    /// `presentTimeSeconds`: ease the presented rect toward the final tile, settling
    /// once the client's buffer lands (transform on identity) or after the grace
    /// backstop. Returns whether the animation is still in flight.
    @discardableResult
    public func advanceTileAnimation(presentTimeSeconds: Double) -> Bool {
        guard var anim = presentationActor.tileAnimation else { return false }
        let frame = anim.sampleFrame(presentTimeSeconds)
        presentationActor.setPresented(frame)

        if anim.motionDone(frame: frame, nowSeconds: presentTimeSeconds) {
            if anim.endTimeSeconds == 0 { anim.endTimeSeconds = presentTimeSeconds }
            // The client was asked for the final size at tile start; settle once its
            // crisp native buffer has committed (committed ≈ final, transform on
            // identity) or after a grace period for an unresponsive client.
            let committed = logicalSize()
            let reachedFinal = abs(committed.w - anim.finalRect.w) < PresentationTiming.tileSettleEps
                && abs(committed.h - anim.finalRect.h) < PresentationTiming.tileSettleEps
            let graceExpired = presentTimeSeconds - anim.endTimeSeconds > PresentationTiming.tileSettleGraceSeconds
            // Whether the client has committed a buffer in response to the tile
            // configure. Until it has, `committed` is the stale PRE-tile extent.
            let clientResponded = presentationActor.currentSlotGeneration != anim.startSlotGeneration
            if reachedFinal || (clientResponded && graceExpired) {
                // Land on the client's ACTUAL committed size at the final tile origin
                // (not the requested tile size) so the published presented/base scale
                // lands on identity — a client that quantizes or ignores the resize
                // would otherwise render soft forever.
                presentationActor.settleTileAnimation(PresentationRect(
                    x: anim.finalRect.x, y: anim.finalRect.y, w: committed.w, h: committed.h))
                return false
            }
            if graceExpired {
                // The client never committed a tile-response buffer within the grace
                // window; land on the requested tile size and let the post-settle
                // presented frame track the client's buffer (crisp) when it commits.
                presentationActor.settleTileAnimation(anim.finalRect)
                return false
            }
            presentationActor.tileAnimation = anim
            return true
        }
        presentationActor.tileAnimation = anim
        return true
    }

    /// The snapshot-overlay opacity for the in-flight tile crossfade: the fraction of
    /// the spring's size displacement that remains, so the frozen pre-tile snapshot is
    /// fully opaque at the start shape and dissolves to zero exactly as the frame
    /// reaches its final shape. Returns 1 when no tile is animating.
    public func tileCrossfadeOpacity() -> Double {
        guard let anim = presentationActor.tileAnimation else { return 1 }
        let presented = currentAnimatedRect()
        let dw0 = abs(anim.startRect.w - anim.finalRect.w)
        let dh0 = abs(anim.startRect.h - anim.finalRect.h)
        var frac: Double = 0
        if dw0 > 0.5 { frac = max(frac, abs(presented.w - anim.finalRect.w) / dw0) }
        if dh0 > 0.5 { frac = max(frac, abs(presented.h - anim.finalRect.h) / dh0) }
        return min(max(frac, 0), 1)
    }

    /// Eligible to appear in the rendered scene: mapped (or animating closed) and
    /// not hidden by minimize or an inactive space.
    public func visibleInScene() -> Bool {
        (mapped || presentationActor.hasClosingFade()) && !minimized && !spaceHidden
    }
    /// Eligible to receive pointer/keyboard input: mapped, not minimized, not
    /// space-hidden.
    public func eligibleForInput() -> Bool {
        mapped && !minimized && !spaceHidden
    }
    public func isManagedAppWindow() -> Bool { managedAppWindow }

    /// Cross-level fullscreen-occlusion decision against `owner`: `false` if this
    /// window sits above the owner's level, `true` if below, `nil` if same level
    /// (the caller breaks the tie by back-to-front z-order).
    public func occludedByFullscreen(at owner: Window) -> Bool? {
        if owner === self { return false }
        if level > owner.level { return false }
        if level < owner.level { return true }
        return nil
    }

    public func consumeAckedConfigure(serial: UInt32) -> WindowPendingConfigure? {
        guard let configure = protocolState.consumeAcked(serial) else { return nil }
        applyAcceptedConfigure(configure)
        return configure
    }

    public func setGeometry(_ rect: WindowRect) {
        setRequestedFrame(rect)
        acceptCommittedFrame(rect)
    }

    public func setRequestedFrame(_ rect: WindowRect) {
        requestedFrame = rect
        policyState.setLayoutRect(rect)
    }

    public func acceptCommittedFrame(_ rect: WindowRect) {
        committedFrame = rect
        policyState.setLayoutPosition(rect.x, rect.y)
    }

    /// Move compositor-owned placement during a direct manipulation without
    /// pretending that the client committed a new buffer extent.
    public func moveRequestedAndCommittedFrame(to rect: WindowRect) {
        setRequestedFrame(rect)
        let committed = currentCommittedRect()
        acceptCommittedFrame(WindowRect(
            x: rect.x, y: rect.y,
            width: committed.width, height: committed.height))
    }

    public func applyAcceptedConfigure(_ configure: WindowPendingConfigure) {
        // Accept the placement, but not the size: the window's real size comes
        // from its committed geometry (`setGeometry`, driven by the client's
        // buffer). A fixed-size window acks a configure it won't honor and never
        // re-commits, so trusting the configured size left the manager believing
        // it was e.g. 800x600 and re-imposing that on every focus/tile configure.
        policyState.setLayoutPosition(configure.rect.x, configure.rect.y)
        activeMaximized = configure.activeMaximized
        activeFullscreen = configure.activeFullscreen
        specialOutputID = configure.specialOutputID
    }
}
