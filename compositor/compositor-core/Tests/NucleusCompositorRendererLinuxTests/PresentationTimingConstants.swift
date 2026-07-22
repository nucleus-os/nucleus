//
// The single place for the tiling spring and the window lifecycle-fade
// constants the compositor itself drives. Render-layer animation defaults (the
// content-reveal duration, implicit opacity/spring) live with the dynamics
// engine, not here. Mirrors the pre-Swift (Zig) presentation timing constants
// exactly; pure constants, nothing imports it yet.

enum PresentationTimingConstants {
    /// Angular frequency (rad/s) of the critically-damped tiling spring. Higher
    /// = snappier. Velocity-preserving on a mid-flight re-tile, never overshoots.
    static let tileSpringOmega: Double = 26.0

    /// Motion is "done" once every edge is within this many logical px of the
    /// target. Backstopped by `tileMotionMaxS`.
    static let tileMotionSettleEps: Double = 0.75

    /// Hard cap on the spring's motion phase (seconds).
    static let tileMotionMaxS: Double = 0.6

    /// How close (logical px) the client's committed size must be to the final
    /// tile to count as settled.
    static let tileSettleEps: Double = 1.0

    /// After motion is done, how long (seconds) to wait for an unresponsive
    /// client's final buffer before settling on its last committed size.
    static let tileSettleGraceS: Double = 0.5

    /// Window open / close opacity-fade durations (seconds), ease-out authored.
    static let lifecycleOpenDurationS: Double = 0.18
    static let lifecycleCloseDurationS: Double = 0.16

    /// Whether the snapshot→final tiling content crossfade is active (a
    /// two-layer dissolve authored at the same eased frame as the backing).
    static let tileContentCrossfadeEnabled: Bool = true
}
