// compositor-owned framebuffer that persists across output frames: scene
// composition draws into it, the backdrop path samples its prefix snapshot at
// the z-order checkpoint, screenshots/captures copy from it, and the present
// pass samples it into the current scanout image.
//
// The invalidation/resize bookkeeping (`AccumulatorState`) is a pure value
// type, tested hardware-independently. The GPU-backed `OutputAccumulator`
// (persistent Graphite surface + prefix snapshot + present copy) runs
// best-effort where a Graphite context exists.

import NucleusSkiaGraphiteBridge

/// Pure resize + invalidation bookkeeping, mirroring `PersistentOutput`'s
/// `redrawn_gen` discipline: a freshly allocated accumulator (or one whose
/// dimensions changed, or one explicitly invalidated) needs a full redraw before
/// its prior contents can be trusted. The store bumps `invalidationGen`; the
/// accumulator records the generation it last fully redrew at.
struct AccumulatorState: Equatable {
    private(set) var width: Int32
    private(set) var height: Int32
    /// Bumped on resize or explicit invalidation. Starts at 1 so a fresh
    /// accumulator (redrawnGen 0) is below it and needs a full redraw.
    private(set) var invalidationGen: UInt64
    /// The generation this accumulator was last fully redrawn at.
    private(set) var redrawnGen: UInt64

    init(width: Int32, height: Int32) {
        self.width = width
        self.height = height
        self.invalidationGen = 1
        self.redrawnGen = 0
    }

    /// Prior contents cannot be trusted until a full redraw catches up.
    var needsFullRedraw: Bool { redrawnGen < invalidationGen }

    /// Record that the whole accumulator was redrawn this frame.
    mutating func markRedrawn() { redrawnGen = invalidationGen }

    /// Discard prior contents (e.g. scale change, output reconfiguration).
    mutating func invalidate() { invalidationGen += 1 }

    /// Reconcile to a new size. Returns true when the dimensions changed and the
    /// backing must be reallocated (which also invalidates prior contents).
    mutating func resize(width: Int32, height: Int32) -> Bool {
        if width == self.width && height == self.height { return false }
        self.width = width
        self.height = height
        invalidationGen += 1
        return true
    }
}

/// The GPU-backed accumulator: a persistent Graphite `Surface` plus the prefix
/// snapshot the backdrop path samples. Reference type (one per output, held for
/// the output's lifetime). The accumulator surface and prefix image are tied to
/// the recorder passed in; the compositor drives one persistent recorder, so the
/// surface validly persists across frames and recordings.
final class OutputAccumulator {
    let outputId: UInt64
    private(set) var state: AccumulatorState
    private(set) var surface: nucleus.skia.Surface
    /// The accumulator content snapshotted before the first backdrop effect runs
    /// this frame; the `.behind_window` capture samples this instead of the live
    /// accumulator, decoupling capture correctness from per-frame damage.
    private(set) var prefix: nucleus.skia.Image?

    private init(outputId: UInt64, state: AccumulatorState, surface: nucleus.skia.Surface) {
        self.outputId = outputId
        self.state = state
        self.surface = surface
    }

    /// Allocate the persistent accumulator surface for `outputId`. Returns nil if
    /// the recorder cannot make the render target (no GPU / unsupported size).
    static func create(
        recorder: nucleus.skia.Recorder, outputId: UInt64, width: Int32, height: Int32
    ) -> OutputAccumulator? {
        let surface = recorder.makeOffscreenSurface(width, height)
        guard surface.isValid() else { return nil }
        return OutputAccumulator(
            outputId: outputId, state: AccumulatorState(width: width, height: height),
            surface: surface)
    }

    /// Reconcile the accumulator to `width`×`height`, reallocating the surface on
    /// a dimension change. Returns false if a needed reallocation failed.
    func ensure(recorder: nucleus.skia.Recorder, width: Int32, height: Int32) -> Bool {
        guard state.resize(width: width, height: height) else { return true }
        let resized = recorder.makeOffscreenSurface(width, height)
        guard resized.isValid() else { return false }
        surface = resized
        prefix = nil
        return true
    }

    /// The accumulator's canvas — scene composition draws here.
    var canvas: nucleus.skia.Canvas { surface.getCanvas() }

    /// Snapshot the live accumulator into the prefix buffer (taken once per frame
    /// before the first backdrop effect). Mirrors `snapshotPrefix`.
    func snapshotPrefix() {
        prefix = surface.snapshotImage()
    }

    /// The current accumulator content as an image (the present + capture source).
    func snapshotImage() -> nucleus.skia.Image {
        surface.snapshotImage()
    }

    /// Present: sample the composited accumulator into `target`, stretching it to
    /// fill. Returns false if either side is unusable.
    func present(onto target: nucleus.skia.Surface, alpha: Float = 1) -> Bool {
        present(onto: target, source: nil, alpha: alpha)
    }

    func present(
        onto target: nucleus.skia.Surface, source: nucleus.skia.RectF?, alpha: Float = 1
    ) -> Bool {
        guard target.isValid() else { return false }
        let image = surface.snapshotImage()
        guard image.isValid() else { return false }
        let canvas = target.getCanvas()
        guard canvas.isValid() else { return false }
        var dst = nucleus.skia.RectF()
        dst.x = 0; dst.y = 0
        dst.width = Float(target.width()); dst.height = Float(target.height())
        var paint = nucleus.skia.Paint()
        paint.alpha = alpha
        paint.blend = nucleus.skia.BlendMode.src
        canvas.drawImageRect(image, source ?? nucleus.skia.RectF(), dst, paint)
        return true
    }

    /// Convenience pass-throughs to the resize/invalidation state.
    var needsFullRedraw: Bool { state.needsFullRedraw }
    func markRedrawn() { state.markRedrawn() }
    func invalidate() { state.invalidate() }
}
