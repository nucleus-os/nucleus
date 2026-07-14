// Tracks which client surface each output is scanning out.
//
// A client buffer is unsafe to release while the kernel scans it, which is true from
// the moment its commit is *submitted* (pending) until the flip that *replaces* it
// completes. The buffer is on the plane for that whole window — NOT just while it is
// the latched front. So the "is this surface scanned out" question must consider both
// the latched front and the in-flight pending commit, and the front only changes at
// flip-completion, never at submit time.
//
// Tracking the submitted surface as "scanned" immediately (the earlier bug) lies about
// the plane during the in-flight window: at a scanout→composite or surface→surface
// transition the old buffer is still latched while a new commit is submitted, so a
// client commit in that window would see "not scanned" and release a buffer the kernel
// is still scanning → tearing. This value type fixes that by rotating pending→front
// only on flip-completion, mirroring DrmOutput's frontScanout/pendingScanout.

struct ScanoutSurfaceTracker: Equatable {
    /// Per output, the IOSurface id of the buffer currently latched on the plane
    /// (absent when the output last flipped a composite frame).
    private var front: [UInt64: UInt64] = [:]
    /// Per output, the IOSurface id of the in-flight submitted commit awaiting its flip
    /// (absent when the in-flight commit is a composite frame or none is pending).
    private var pending: [UInt64: UInt64] = [:]

    /// Whether `iosurfaceID` is latched on, or in-flight to, any output's plane — i.e.
    /// the kernel is or is about to scan it, so its buffer must not be released.
    func isScannedOut(_ iosurfaceID: UInt64) -> Bool {
        front.values.contains(iosurfaceID) || pending.values.contains(iosurfaceID)
    }

    /// A direct-scanout commit for `iosurfaceID` was submitted on `output`.
    mutating func submitScanout(output: UInt64, iosurfaceID: UInt64) {
        pending[output] = iosurfaceID
    }

    /// A composite commit was submitted on `output` (no client surface in-flight).
    mutating func submitComposite(output: UInt64) {
        pending[output] = nil
    }

    /// `output`'s page flip completed: the pending commit is now latched (front), and
    /// nothing is in-flight until the next submit.
    mutating func flipCompleted(output: UInt64) {
        front[output] = pending[output]
        pending[output] = nil
    }

    /// Forget an output entirely (removed / re-enumerated).
    mutating func removeOutput(_ output: UInt64) {
        front[output] = nil
        pending[output] = nil
    }

    mutating func reset() {
        front.removeAll()
        pending.removeAll()
    }
}
