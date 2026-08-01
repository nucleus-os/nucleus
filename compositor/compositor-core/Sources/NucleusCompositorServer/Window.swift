package import NucleusLayers

package import struct NucleusCompositorServerTypes.WireChromeInsets

#if canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#elseif canImport(Darwin)
import Darwin
#endif

package enum WindowSource: UInt32, Sendable {
    case xdg = 1
    case xwayland = 2
    case layerShell = 3
    /// An ext-session-lock surface: an output-sized, compositor-positioned
    /// surface shown only while the session is locked. Excluded from normal
    /// window management (not tiled, not in workspaces, not in the taskbar);
    /// the lock presentation/input gate composites and routes input to it.
    case lock = 4
}

package enum WindowMapState: Sendable {
    case unmapped
    case mapped
    case closing
}

package struct WindowRect: Sendable, Equatable {
    package var x: Double
    package var y: Double
    package var width: UInt32
    package var height: UInt32

    package init(x: Double = 0, y: Double = 0, width: UInt32 = 1, height: UInt32 = 1) {
        self.x = x
        self.y = y
        self.width = max(1, width)
        self.height = max(1, height)
    }
}

package enum FullscreenTarget: Sendable, Equatable {
    case automatic
    case output(DisplayID)
}

package struct WindowPendingConfigure: Sendable, Equatable {
    package var serial: UInt32
    package var rect: WindowRect
    package var activeMaximized: Bool
    package var activeFullscreen: Bool
    package var resizing: Bool
    package var specialOutputID: DisplayID?
    package var layoutTransitionID: UInt64
    package var slotGeneration: UInt64

    package init(
        serial: UInt32,
        rect: WindowRect,
        activeMaximized: Bool,
        activeFullscreen: Bool,
        resizing: Bool,
        specialOutputID: DisplayID?,
        layoutTransitionID: UInt64,
        slotGeneration: UInt64
    ) {
        self.serial = serial
        self.rect = rect
        self.activeMaximized = activeMaximized
        self.activeFullscreen = activeFullscreen
        self.resizing = resizing
        self.specialOutputID = specialOutputID
        self.layoutTransitionID = layoutTransitionID
        self.slotGeneration = slotGeneration
    }
}

package struct WindowProtocolState: Sendable {
    package private(set) var pendingConfigures: [WindowPendingConfigure] = []
    private var nextSlotGeneration: UInt64 = 1

    package init() {}

    package var latest: WindowPendingConfigure? { pendingConfigures.last }
    package var hasPending: Bool { !pendingConfigures.isEmpty }

    package mutating func allocateSlotGeneration() -> UInt64 {
        let generation = nextSlotGeneration
        nextSlotGeneration &+= 1
        if nextSlotGeneration == 0 { nextSlotGeneration = 1 }
        return generation
    }

    package mutating func queueConfigure(
        rect: WindowRect,
        activeMaximized: Bool,
        activeFullscreen: Bool,
        resizing: Bool,
        specialOutputID: DisplayID?,
        layoutTransitionID: UInt64,
        serial: UInt32
    ) -> UInt64 {
        let generation = allocateSlotGeneration()
        pendingConfigures.append(
            WindowPendingConfigure(
                serial: serial,
                rect: rect,
                activeMaximized: activeMaximized,
                activeFullscreen: activeFullscreen,
                resizing: resizing,
                specialOutputID: specialOutputID,
                layoutTransitionID: layoutTransitionID,
                slotGeneration: generation
            ))
        return generation
    }

    package func configure(forAckSerial ackedSerial: UInt32) -> WindowPendingConfigure? {
        pendingConfigures.last { ackedSerial >= $0.serial }
    }

    package mutating func consumeAcked(_ ackedSerial: UInt32) -> WindowPendingConfigure? {
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

    package mutating func mutatePendingConfigures(_ body: (inout WindowPendingConfigure) -> Void) {
        for index in pendingConfigures.indices {
            body(&pendingConfigures[index])
        }
    }
}

package struct WindowPolicyState: Sendable, Equatable {
    package var x: Double = 0
    package var y: Double = 0
    package var layoutWidth: UInt32 = 0
    package var layoutHeight: UInt32 = 0

    package func currentRect(size: RenderSize) -> WindowRect {
        WindowRect(
            x: x,
            y: y,
            width: UInt32(max(1, size.w.rounded(.up))),
            height: UInt32(max(1, size.h.rounded(.up)))
        )
    }

    package mutating func setLayoutRect(_ rect: WindowRect) {
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
    package mutating func setLayoutPosition(_ px: Double, _ py: Double) {
        x = px
        y = py
    }
}

package struct RenderSize: Sendable, Equatable {
    package var w: Double
    package var h: Double

    package init(w: Double, h: Double) {
        self.w = w
        self.h = h
    }
}

package struct TileEdges: Sendable, Equatable {
    package var left: Bool = false
    package var right: Bool = false
    package var top: Bool = false
    package var bottom: Bool = false

    package init(left: Bool = false, right: Bool = false, top: Bool = false, bottom: Bool = false) {
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
package struct WindowContentOffset: Sendable, Equatable {
    package var x: Double
    package var y: Double

    package init(x: Double = 0, y: Double = 0) {
        self.x = x
        self.y = y
    }
}

/// A presented-frame rectangle in logical coordinates. The compositor-owned
/// presentation animation (the tiling spring) eases this in continuous Doubles,
/// distinct from the integer-extent `WindowRect`.
package struct PresentationRect: Sendable, Equatable {
    package var x: Double
    package var y: Double
    package var w: Double
    package var h: Double

    package init(x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

/// Sub-pixel rect equality (logical px). The redundant-target guard for the
/// tiling spring.
package func renderRectsNearlyEqual(_ a: PresentationRect, _ b: PresentationRect) -> Bool {
    abs(a.x - b.x) < 0.01 && abs(a.y - b.y) < 0.01 && abs(a.w - b.w) < 0.01 && abs(a.h - b.h) < 0.01
}

/// Compositor-owned presentation timing for the tiling spring and closing fade.
package enum PresentationTiming {
    /// Angular frequency (rad/s) of the critically-damped tiling spring. Higher =
    /// snappier; ~26 settles a typical move in roughly a quarter second.
    package static let tileSpringOmega: Double = 26.0
    /// Motion is "done" once every edge is within this many logical px of the target.
    package static let tileMotionSettleEps: Double = 0.75
    /// Hard cap on the spring's motion phase (seconds).
    package static let tileMotionMaxSeconds: Double = 0.6
    /// How close (logical px) the client's committed size must be to the final tile
    /// to count as settled — else the published presented/base scale renders soft.
    package static let tileSettleEps: Double = 1.0
    /// After motion is done, how long (seconds) to wait for an unresponsive client's
    /// final buffer before settling on whatever size it last committed.
    package static let tileSettleGraceSeconds: Double = 0.5
    /// Presentation-clock duration of the compositor-owned closing fade.
    package static let closingFadeSeconds: Double = 0.18
}

/// Closed-form critically-damped spring: position and velocity at `t` seconds since
/// the segment began, for initial position `x0`, initial velocity `v0`, and `target`,
/// at angular frequency `omega`. Stateless in `t` — sampled fresh each frame (and
/// multiple times per frame for multi-output) with no integration state to advance.
/// Critical damping gives a monotonic, overshoot-free approach; carrying `v0` from
/// the prior segment on a re-tile makes interrupted motion C¹-continuous.
private func springSample(x0: Double, v0: Double, target: Double, omega: Double, t: Double) -> (
    pos: Double, vel: Double
) {
    let disp = x0 - target
    let c = v0 + omega * disp
    let decay = exp(-omega * t)
    return (
        pos: target + (disp + c * t) * decay,
        vel: (v0 - omega * c * t) * decay
    )
}

/// One tiling action's motion. The compositor owns the whole thing: a critically-
/// damped spring eases the *presented* frame (position AND size) toward the final
/// tile at the display rate, and a published transform scales the client's buffer
/// onto it. A mid-flight re-tile carries the current velocity into the new segment
/// (see `WindowPresentationActor.beginTileAnimation`), so interruptions stay
/// continuous.
package struct TileAnimation: Sendable, Equatable {
    /// Spring initial condition: the presented frame at `startTimeSeconds` (per edge).
    package var startRect: PresentationRect
    /// Spring initial velocity, carried from the prior segment on a re-tile.
    package var startVel: PresentationRect = .init()
    /// Spring target (the final tile).
    package var finalRect: PresentationRect
    /// Velocity at the most recent sample, captured so the next re-tile can carry it.
    package var currentVel: PresentationRect = .init()
    /// Absolute present time the segment started; 0 = unseeded (seeded on first
    /// sample, so multiple per-output renders in one frame share one clock).
    package var startTimeSeconds: Double = 0
    /// Absolute time motion first finished, for the settle grace backstop.
    package var endTimeSeconds: Double = 0
    /// The slot generation when the segment began. The slot advances when the client
    /// commits an acked configure, so `currentSlotGeneration` moving past this means
    /// the client has committed a buffer in response to the tile.
    package var startSlotGeneration: UInt64 = 0

    /// Seconds since the segment started, seeding `startTimeSeconds` on the first sample.
    package mutating func elapsed(_ nowSeconds: Double) -> Double {
        if startTimeSeconds == 0 { startTimeSeconds = nowSeconds }
        return nowSeconds - startTimeSeconds
    }

    /// The eased presented frame (position + size) at `nowSeconds`, also recording
    /// the instantaneous velocity so a re-tile can carry it.
    package mutating func sampleFrame(_ nowSeconds: Double) -> PresentationRect {
        let t = elapsed(nowSeconds)
        let omega = PresentationTiming.tileSpringOmega
        let x = springSample(
            x0: startRect.x, v0: startVel.x, target: finalRect.x, omega: omega, t: t)
        let y = springSample(
            x0: startRect.y, v0: startVel.y, target: finalRect.y, omega: omega, t: t)
        let w = springSample(
            x0: startRect.w, v0: startVel.w, target: finalRect.w, omega: omega, t: t)
        let h = springSample(
            x0: startRect.h, v0: startVel.h, target: finalRect.h, omega: omega, t: t)
        currentVel = PresentationRect(x: x.vel, y: y.vel, w: w.vel, h: h.vel)
        return PresentationRect(x: x.pos, y: y.pos, w: w.pos, h: h.pos)
    }

    /// Whether the spring has effectively reached its target: every edge within the
    /// settle epsilon, or the motion backstop has elapsed. Read after `sampleFrame`
    /// has seeded `startTimeSeconds` for the segment.
    package func motionDone(frame: PresentationRect, nowSeconds: Double) -> Bool {
        if nowSeconds - startTimeSeconds > PresentationTiming.tileMotionMaxSeconds { return true }
        let eps = PresentationTiming.tileMotionSettleEps
        return abs(frame.x - finalRect.x) < eps && abs(frame.y - finalRect.y) < eps
            && abs(frame.w - finalRect.w) < eps && abs(frame.h - finalRect.h) < eps
    }
}

package struct WindowTileCrossfade: Sendable, Equatable {
    package let generation: UInt64
    package let snapshotHandle: UInt64

    package init(generation: UInt64, snapshotHandle: UInt64) {
        self.generation = generation
        self.snapshotHandle = snapshotHandle
    }
}

package struct WindowClosingFade: Sendable, Equatable {
    package let generation: UInt64
    package let snapshotHandle: UInt64
    package let frozenRect: PresentationRect
    package var startTimeSeconds: Double?
    package var opacity: Double
    package var destroyWindowOnCompletion: Bool

    package init(
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

package enum WindowPresentationTransition: Sendable, Equatable {
    case tile(WindowTileCrossfade)
    case closing(WindowClosingFade)

    package var generation: UInt64 {
        switch self {
        case .tile(let state): state.generation
        case .closing(let state): state.generation
        }
    }

    package var snapshotHandle: UInt64 {
        switch self {
        case .tile(let state): state.snapshotHandle
        case .closing(let state): state.snapshotHandle
        }
    }
}

/// The resource obligation returned exactly once when a presentation transition
/// is replaced, cancelled, or completed.
package struct WindowTransitionRetirement: Sendable, Equatable {
    package let generation: UInt64
    package let snapshotHandle: UInt64
    package let wasClosing: Bool
    package let destroyWindow: Bool

    package init(
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
package struct WindowPresentationActor: Sendable {
    package var initialized: Bool = false
    package var mapState: WindowMapState = .unmapped
    package var presentedRect: PresentationRect = .init()
    /// Active tiling animation (the compositor-owned size curve + placement), or nil
    /// when settled/snapped.
    package var tileAnimation: TileAnimation?
    /// Last configure slot that reached the latch/ack path.
    package var latestLatchedSlotGeneration: UInt64 = 0
    /// Current presentation target slot; may lead the latched slot.
    package var currentSlotGeneration: UInt64 = 0
    /// The single snapshot-backed transition. Tile crossfade and closing fade are
    /// mutually exclusive, so supersession has one generation and one retirement
    /// obligation.
    package private(set) var transition: WindowPresentationTransition?
    private var nextTransitionGeneration: UInt64 = 1

    package init() {}

    /// The rect the actor is heading toward: the tile's final rect while a segment is
    /// in flight, else the settled presented rect.
    package func targetRect() -> PresentationRect {
        if let anim = tileAnimation { return anim.finalRect }
        return presentedRect
    }

    package mutating func ensureInitialized(fallback: PresentationRect) {
        if initialized { return }
        initialized = true
        presentedRect = fallback
    }

    package mutating func snapTo(_ rect: PresentationRect, slotGeneration: UInt64) {
        initialized = true
        presentedRect = rect
        currentSlotGeneration = slotGeneration
        tileAnimation = nil
    }

    /// Begin a tiling spring toward `finalRect`, starting from `startRect` (the live
    /// presented rect). If a segment is already in flight (a mid-flight re-tile), its
    /// current velocity is carried into the new segment so motion is C¹-continuous.
    package mutating func beginTileAnimation(
        startRect: PresentationRect, finalRect: PresentationRect, slotGeneration: UInt64
    ) {
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
    package mutating func setPresented(_ rect: PresentationRect) {
        initialized = true
        presentedRect = rect
    }

    /// Finish a tile animation, landing the presented frame on `settleRect`.
    package mutating func settleTileAnimation(_ settleRect: PresentationRect) {
        if tileAnimation != nil {
            presentedRect = settleRect
            tileAnimation = nil
        }
    }

    /// Drop an in-flight tile animation, freezing the presented frame where it is.
    /// Used on unmap/close so a closing window does not keep easing its frame.
    package mutating func cancelTileAnimation() {
        tileAnimation = nil
    }

    package func hasActiveTileAnimation() -> Bool { tileAnimation != nil }

    /// Whether a tile animation is already in flight toward (approximately) `rect`.
    /// A redundant re-present for the same target must NOT rebuild the animation.
    package func tileAnimationTargetsRect(_ rect: PresentationRect) -> Bool {
        guard let anim = tileAnimation else { return false }
        return renderRectsNearlyEqual(anim.finalRect, rect)
    }

    package func targetMatches(_ rect: PresentationRect) -> Bool {
        renderRectsNearlyEqual(targetRect(), rect)
    }

    @discardableResult
    package mutating func installTileCrossfade(
        snapshotHandle: UInt64
    ) -> (generation: UInt64, replaced: WindowTransitionRetirement?) {
        let replaced = takeTransition()
        let generation = allocateTransitionGeneration()
        transition = .tile(
            WindowTileCrossfade(
                generation: generation,
                snapshotHandle: snapshotHandle))
        mapState = .mapped
        return (generation, replaced)
    }

    @discardableResult
    package mutating func installClosingFade(
        snapshotHandle: UInt64,
        frozenRect: PresentationRect,
        destroyWindowOnCompletion: Bool
    ) -> (generation: UInt64, replaced: WindowTransitionRetirement?) {
        let replaced = takeTransition()
        let generation = allocateTransitionGeneration()
        transition = .closing(
            WindowClosingFade(
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
    package mutating func requireWindowDestructionAfterClosing() {
        guard case .closing(var state) = transition else { return }
        state.destroyWindowOnCompletion = true
        transition = .closing(state)
    }

    /// Sample closing opacity from the presentation clock. Returns true while a
    /// future sample can change the value.
    package mutating func advanceClosingFade(
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

    package func transitionGeneration() -> UInt64? {
        transition?.generation
    }

    package func closingOpacity() -> Double {
        guard case .closing(let state) = transition else { return 1 }
        return state.opacity
    }

    package func hasClosingFade() -> Bool {
        if case .closing = transition { return true }
        return false
    }

    /// Take only the expected generation. A late completion from a superseded
    /// transition therefore cannot retire the replacement's resource.
    package mutating func takeTransition(
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
package final class Window {
    package let id: WindowID
    package var source: WindowSource
    /// The compositor-stable identity of the window's backing `wl_surface` on the
    /// live Wayland router (0 when unlinked). Wire object ids are client-scoped;
    /// `WlCompositor` resolves collisions before this value reaches the model. This
    /// is the single home for surface→window identity: the router driver sets it
    /// when the role is created, and focus/scene/activation resolve a `Window` back
    /// to its surface through it.
    package var surfaceObjectId: UInt32 = 0 {
        didSet {
            if surfaceObjectId != oldValue { onSurfaceObjectIdChange?(self, oldValue) }
        }
    }
    /// Installed by `WindowList` when the window is added, so the list's
    /// `surfaceObjectId -> Window` index self-maintains when the id is (re)assigned
    /// after creation. `(window, oldValue)`. Nil for a detached window.
    package var onSurfaceObjectIdChange: ((Window, UInt32) -> Void)?
    /// Records a coarse `windowChanged` for the observation stream when a
    /// projected-relevant field changes. Installed by the model at creation; nil
    /// for a detached window. The model coalesces and dispatches per iteration.
    package var changeRecorder: ((DesktopChange) -> Void)?
    /// Human-readable title and application identity, normalized across sources:
    /// an xdg toplevel's `set_title`/`set_app_id`, or an Xwayland window's
    /// `_NET_WM_NAME` / `WM_CLASS` class. The single home for window metadata —
    /// the foreign-toplevel projection and native-command identity matching read
    /// these, not the per-source role objects.
    package var title: String = "" {
        didSet { if title != oldValue { changeRecorder?(.windowChanged(id)) } }
    }
    package var appId: String = "" {
        didSet { if appId != oldValue { changeRecorder?(.windowChanged(id)) } }
    }
    package var mapped: Bool = false {
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
    package var protocolState: WindowProtocolState = .init()
    package var policyState: WindowPolicyState = .init()
    /// Geometry the compositor has requested but the client may not have committed.
    package private(set) var requestedFrame: WindowRect?
    /// Geometry backed by the latest acknowledged client content.
    package private(set) var committedFrame: WindowRect?
    package var requestedMaximized: Bool = false
    package var requestedFullscreen: Bool = false
    package var fullscreenTarget: FullscreenTarget = .automatic
    package var preferredOutputID: DisplayID?
    package var currentOutputID: DisplayID? {
        didSet { if currentOutputID != oldValue { changeRecorder?(.windowChanged(id)) } }
    }
    package var specialOutputID: DisplayID?
    package var activeMaximized: Bool = false {
        didSet { if activeMaximized != oldValue { changeRecorder?(.windowChanged(id)) } }
    }
    package var activeFullscreen: Bool = false {
        didSet { if activeFullscreen != oldValue { changeRecorder?(.windowChanged(id)) } }
    }
    package var managedAppWindow: Bool = true
    // Window visibility. `minimized` is driven by an explicit minimize request;
    // `spaceHidden` by workspace (space) activation. Both default to visible.
    package var minimized: Bool = false {
        didSet { if minimized != oldValue { changeRecorder?(.windowChanged(id)) } }
    }
    package var spaceHidden: Bool = false {
        didSet { if spaceHidden != oldValue { changeRecorder?(.windowChanged(id)) } }
    }
    package var wantsKeyboardFocus: Bool = true
    package var committedLogicalSize: RenderSize = RenderSize(w: 1, h: 1)
    /// The committed buffer's pixel extent (the full `wl_surface` buffer size,
    /// including any CSD margins) — the backing layer's source size before the
    /// presented/base scale. Set by the render driver on each commit.
    package var committedBufferSize: RenderSize = RenderSize(w: 0, h: 0)
    /// The client content's offset within the slot (negated xdg geometry origin),
    /// set by the render driver from the committed window geometry.
    package var contentOffsetInSlot: WindowContentOffset = .init()
    package var tileEdges: TileEdges = .init()
    /// Window decoration intent (the `NSWindow.StyleMask` analog). The frame
    /// view derives the titlebar, border, and standard buttons — and thus the
    /// chrome geometry — from this. `.borderless` (the default) draws no server
    /// chrome; managed xdg toplevels are seeded `.titledResizable`. Owned by the
    /// decoration-resolution policy.
    package var styleMask: WindowStyleMask = .borderless
    package var restoreRect: WindowRect?
    package var restoreOutputID: DisplayID?
    package var layerHost: LayerHost?
    /// Stacking band (0 normal, +1 above, -1 below). `WindowList.items` is kept
    /// level-sorted by `insertionIndex`, so a level change must re-position the
    /// window into its new band — the list wires `onLevelChange` to do that.
    package var level: Int32 = 0 {
        didSet { if level != oldValue { onLevelChange?(self) } }
    }
    /// Set by `WindowList.add` to restack this window when its `level` changes; nil
    /// before the window is added (add() does the initial band-correct placement).
    package var onLevelChange: ((Window) -> Void)?
    /// The window this one is a child of (xdg set_parent / X11 transient-for).
    /// Drives parent-child stacking: a child is kept above its parent and the
    /// family travels together on raise. `nil` for ordinary top-level windows.
    package var parentWindowID: WindowID?
    /// Compositor-owned presentation state: the eased PRESENTED frame + the active
    /// tiling spring. The scene feeder samples it per frame (`currentAnimatedRect`,
    /// `tileCrossfadeOpacity`) to author the eased layout; the configure path seeds
    /// it (`seedPresentationActorToRect`) and begins springs
    /// (`beginPresentationTileAnimation`). Distinct from `policyState` (the
    /// authorized slot) and `committedLogicalSize` (the client's committed extent).
    package var presentationActor = WindowPresentationActor()

    package init(id: WindowID, source: WindowSource) {
        self.id = id
        self.source = source
    }

    package func logicalSize() -> RenderSize { committedLogicalSize }
    package func layoutSize() -> RenderSize {
        if policyState.layoutWidth == 0 || policyState.layoutHeight == 0 {
            return logicalSize()
        }
        return RenderSize(w: Double(policyState.layoutWidth), h: Double(policyState.layoutHeight))
    }
    /// The window's frame rect — the outer rectangle the user sees and
    /// manipulates, including server-drawn chrome. Authoritative for layout,
    /// stacking, placement, and hit-testing. The client content occupies
    /// `contentRect()`, inset by `chromeInsets`.
    package func currentRect() -> WindowRect {
        requestedFrame ?? policyState.currentRect(size: layoutSize())
    }

    package func currentCommittedRect() -> WindowRect {
        committedFrame ?? policyState.currentRect(size: logicalSize())
    }

    /// The window's frame view (the `NSThemeFrame` analog): owns the titlebar,
    /// border, and standard window buttons derived from the style mask, with
    /// fullscreen suppression applied. Drives the chrome geometry and rendering.
    package var frameView: WindowFrameView {
        WindowFrameView(styleMask: styleMask, fullscreen: activeFullscreen)
    }

    /// The chrome reservation between the frame rect and the content rect, after
    /// fullscreen suppression. Zero for borderless / fullscreen windows.
    package var chromeInsets: WindowEdgeInsets { frameView.contentInsets }

    /// The content rect for a given frame rect, removing the chrome insets.
    /// Mirrors `NSWindow.contentRect(forFrameRect:)`.
    package func contentRect(forFrameRect frame: WindowRect) -> WindowRect {
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
    package func frameRect(forContentRect content: WindowRect) -> WindowRect {
        let insets = chromeInsets
        return WindowRect(
            x: content.x - insets.left,
            y: content.y - insets.top,
            width: UInt32(max(1, Double(content.width) + insets.horizontal)),
            height: UInt32(max(1, Double(content.height) + insets.vertical))
        )
    }

    /// The client content rect for this window's current frame rect.
    package func contentRect() -> WindowRect { contentRect(forFrameRect: currentRect()) }

    // MARK: - Compositor-owned presentation (the tiling spring)

    /// The model frame rect (the authorized outer rect) as a continuous
    /// `PresentationRect`. The spring's fallback target before the actor is seeded.
    private func modelPresentationRect() -> PresentationRect {
        let rect = currentRect()
        return PresentationRect(x: rect.x, y: rect.y, w: Double(rect.width), h: Double(rect.height))
    }

    /// The rect the actor is heading toward: the in-flight tile's final rect, the
    /// settled presented rect, or — before the actor is seeded — the model rect.
    package func targetRenderRect() -> PresentationRect {
        if presentationActor.initialized { return presentationActor.targetRect() }
        return modelPresentationRect()
    }

    /// The current compositor-owned presentation rect — what is actually drawn. May
    /// lead the client's committed content size while configure/ack catches up.
    package func currentAnimatedRect() -> PresentationRect {
        if presentationActor.initialized { return presentationActor.presentedRect }
        return targetRenderRect()
    }

    /// Snap the presentation actor to `rect` with no animation (first map / a hard
    /// placement). Mirrors `Window.seedPresentationActorToRect`.
    package func seedPresentationActorToRect(_ rect: PresentationRect, slotGeneration: UInt64) {
        presentationActor.snapTo(rect, slotGeneration: slotGeneration)
    }

    /// Begin a tiling spring from the live presented rect to `finalRect`. The
    /// compositor owns the motion; the client is asked for the final size and its
    /// buffer is scaled onto the eased frame. A redundant re-present for the same
    /// target leaves the in-flight curve untouched.
    package func beginPresentationTileAnimation(finalRect: PresentationRect, slotGeneration: UInt64)
    {
        if presentationActor.tileAnimationTargetsRect(finalRect) { return }
        presentationActor.beginTileAnimation(
            startRect: currentAnimatedRect(),
            finalRect: finalRect,
            slotGeneration: slotGeneration
        )
    }

    package func hasActiveTileAnimation() -> Bool { presentationActor.hasActiveTileAnimation() }

    package func hasActiveClosingFade() -> Bool {
        presentationActor.hasClosingFade()
    }

    package func activeTransitionGeneration() -> UInt64? {
        presentationActor.transitionGeneration()
    }

    @discardableResult
    package func installTileCrossfade(
        snapshotHandle: UInt64
    ) -> (generation: UInt64, replaced: WindowTransitionRetirement?) {
        presentationActor.installTileCrossfade(snapshotHandle: snapshotHandle)
    }

    @discardableResult
    package func installClosingFade(
        snapshotHandle: UInt64,
        destroyWindowOnCompletion: Bool
    ) -> (generation: UInt64, replaced: WindowTransitionRetirement?) {
        presentationActor.installClosingFade(
            snapshotHandle: snapshotHandle,
            frozenRect: currentAnimatedRect(),
            destroyWindowOnCompletion: destroyWindowOnCompletion)
    }

    package func requireWindowDestructionAfterClosing() {
        presentationActor.requireWindowDestructionAfterClosing()
    }

    @discardableResult
    package func advanceClosingFade(presentTimeSeconds: Double) -> Bool {
        presentationActor.advanceClosingFade(
            presentTimeSeconds: presentTimeSeconds)
    }

    package func windowPresentationOpacity() -> Double {
        presentationActor.closingOpacity()
    }

    /// Opacity of the transient snapshot overlay. A close fades the entire root,
    /// so its frozen overlay stays opaque within that root; a tile dissolves only
    /// the snapshot over live client content.
    package func transitionOverlayOpacity() -> Double {
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
    package func takePresentationTransition(
        generation: UInt64? = nil
    ) -> WindowTransitionRetirement? {
        presentationActor.takeTransition(generation: generation)
    }

    /// Advance the tiling animation once for the frame predicted to present at
    /// `presentTimeSeconds`: ease the presented rect toward the final tile, settling
    /// once the client's buffer lands (transform on identity) or after the grace
    /// backstop. Returns whether the animation is still in flight.
    @discardableResult
    package func advanceTileAnimation(presentTimeSeconds: Double) -> Bool {
        guard var anim = presentationActor.tileAnimation else { return false }
        let frame = anim.sampleFrame(presentTimeSeconds)
        presentationActor.setPresented(frame)

        if anim.motionDone(frame: frame, nowSeconds: presentTimeSeconds) {
            if anim.endTimeSeconds == 0 { anim.endTimeSeconds = presentTimeSeconds }
            // The client was asked for the final size at tile start; settle once its
            // crisp native buffer has committed (committed ≈ final, transform on
            // identity) or after a grace period for an unresponsive client.
            let committed = logicalSize()
            let reachedFinal =
                abs(committed.w - anim.finalRect.w) < PresentationTiming.tileSettleEps
                && abs(committed.h - anim.finalRect.h) < PresentationTiming.tileSettleEps
            let graceExpired =
                presentTimeSeconds - anim.endTimeSeconds > PresentationTiming.tileSettleGraceSeconds
            // Whether the client has committed a buffer in response to the tile
            // configure. Until it has, `committed` is the stale PRE-tile extent.
            let clientResponded =
                presentationActor.currentSlotGeneration != anim.startSlotGeneration
            if reachedFinal || (clientResponded && graceExpired) {
                // Land on the client's ACTUAL committed size at the final tile origin
                // (not the requested tile size) so the published presented/base scale
                // lands on identity — a client that quantizes or ignores the resize
                // would otherwise render soft forever.
                presentationActor.settleTileAnimation(
                    PresentationRect(
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
    package func tileCrossfadeOpacity() -> Double {
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
    package func visibleInScene() -> Bool {
        (mapped || presentationActor.hasClosingFade()) && !minimized && !spaceHidden
    }
    /// Eligible to receive pointer/keyboard input: mapped, not minimized, not
    /// space-hidden.
    package func eligibleForInput() -> Bool {
        mapped && !minimized && !spaceHidden
    }
    package func isManagedAppWindow() -> Bool { managedAppWindow }

    /// Cross-level fullscreen-occlusion decision against `owner`: `false` if this
    /// window sits above the owner's level, `true` if below, `nil` if same level
    /// (the caller breaks the tie by back-to-front z-order).
    package func occludedByFullscreen(at owner: Window) -> Bool? {
        if owner === self { return false }
        if level > owner.level { return false }
        if level < owner.level { return true }
        return nil
    }

    package func consumeAckedConfigure(serial: UInt32) -> WindowPendingConfigure? {
        guard let configure = protocolState.consumeAcked(serial) else { return nil }
        applyAcceptedConfigure(configure)
        return configure
    }

    package func setGeometry(_ rect: WindowRect) {
        setRequestedFrame(rect)
        acceptCommittedFrame(rect)
    }

    package func setRequestedFrame(_ rect: WindowRect) {
        requestedFrame = rect
        policyState.setLayoutRect(rect)
    }

    package func acceptCommittedFrame(_ rect: WindowRect) {
        committedFrame = rect
        policyState.setLayoutPosition(rect.x, rect.y)
    }

    /// Move compositor-owned placement during a direct manipulation without
    /// pretending that the client committed a new buffer extent.
    package func moveRequestedAndCommittedFrame(to rect: WindowRect) {
        setRequestedFrame(rect)
        let committed = currentCommittedRect()
        acceptCommittedFrame(
            WindowRect(
                x: rect.x, y: rect.y,
                width: committed.width, height: committed.height))
    }

    package func applyAcceptedConfigure(_ configure: WindowPendingConfigure) {
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
