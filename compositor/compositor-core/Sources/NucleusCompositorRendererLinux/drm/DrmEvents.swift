// Phase 10a.5 — Swift DRM page-flip / vblank event drain over real libdrm.
//
// The reactor registers the DRM device fd for readability; on readiness Swift
// drains the fd through libdrm's `drmHandleEvent` via the NucleusCompositorDrmC façade and
// applies each page-flip completion synchronously.
//
// libdrm's `drmEventContext` callbacks are bare C function pointers that can't
// capture context, so the per-output context travels as the atomic commit's
// `user_data`: a `DrmPageFlipToken` whose opaque pointer is set on the commit
// and recovered here. The façade routes every completion to one
// `@convention(c)` trampoline; the trampoline decodes the token and invokes its
// handler with (timestamp, sequence, crtc_id). Nothing imports it yet.

import NucleusCompositorDrmC

/// A page-flip / vblank completion drained from the DRM fd.
struct DrmPageFlipEvent: Sendable, Equatable {
    var timestampNs: UInt64
    var sequence: UInt32
    var crtcId: UInt32
}

/// Per-output context carried as an atomic commit's `user_data` and recovered on
/// flip completion. Ownership is a retained handoff: arming a page-flip retains the
/// token into the kernel's `user_data` as a borrowed pointer. The owning output
/// retains it for its lifetime; the runtime retains tokens from replaced bindings
/// until device teardown, so late completions remain safe without leaking one ARC
/// retain for every VT switch whose completion is discarded by the driver.
final class DrmPageFlipToken: Sendable {
    let onFlip: @MainActor @Sendable (DrmPageFlipEvent) -> Void

    init(onFlip: @escaping @MainActor @Sendable (DrmPageFlipEvent) -> Void) {
        self.onFlip = onFlip
    }

    func commitUserData() -> UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }
}

/// The `@convention(c)` trampoline libdrm calls for each completion. Decodes the
/// commit's `user_data` back into the runtime-owned `DrmPageFlipToken` and
/// dispatches. A nil `user_data`
/// (commit without a token) is ignored. Top-level + non-capturing so it is usable
/// as a C function pointer.
func drmPageFlipTrampoline(
    _ userData: UnsafeMutableRawPointer?,
    _ timestampNs: UInt64,
    _ sequence: UInt32,
    _ crtcId: UInt32
) {
    guard let userData else { return }
    let token = Unmanaged<DrmPageFlipToken>.fromOpaque(userData).takeUnretainedValue()
    let event = DrmPageFlipEvent(timestampNs: timestampNs, sequence: sequence, crtcId: crtcId)
    MainActor.assumeIsolated { token.onFlip(event) }
}

/// Drains DRM events from the device fd through libdrm. Single-threaded: drive
/// it from the reactor on DRM-fd readability.
@MainActor enum DrmEventPump {
    /// True when the DRM fd has events to drain (a non-blocking readability
    /// probe). `drmHandleEvent` reads the fd, so callers must gate on this to
    /// avoid blocking on an empty fd.
    static func isReadable(fd: Int32) -> Bool {
        nucleus_drm_fd_poll_readable(fd) == 1
    }

    /// Drain and dispatch all pending page-flip completions. Returns false if
    /// libdrm reported an error. Each completion routes through the commit's
    /// `DrmPageFlipToken`.
    @discardableResult
    static func dispatch(fd: Int32) -> Bool {
        nucleus_drm_handle_event(fd, drmPageFlipTrampoline) == 0
    }

    /// Drain only when the fd is readable (the reactor-readiness path); a no-op
    /// when nothing is pending. Returns true when a drain ran successfully.
    @discardableResult
    static func dispatchIfReady(fd: Int32) -> Bool {
        guard isReadable(fd: fd) else { return false }
        return dispatch(fd: fd)
    }
}
