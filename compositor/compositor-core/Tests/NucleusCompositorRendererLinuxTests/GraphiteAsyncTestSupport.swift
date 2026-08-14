import Glibc
import NucleusSkiaGraphiteBridge

/// Hardware-gated tests use the production asynchronous submission API and poll
/// its serial completion. This keeps CPU-synchronous Graphite compatibility
/// entry points out of the shipped façade while still making borrowed Vulkan
/// device teardown deterministic in tests.
func submitGraphiteAndWait(
    context: nucleus.skia.GraphiteContext,
    recording: nucleus.skia.Recording,
    serial: UInt64
) -> Bool {
    guard unsafe recording.isValid(),
        unsafe context.submitAsync(recording, serial).isOk()
    else { return false }
    return unsafe waitForGraphiteSerial(context: context, serial: serial)
}

func readGraphiteSurfaceRGBA(
    context: nucleus.skia.GraphiteContext,
    surface: nucleus.skia.Surface
) -> [UInt8]? {
    let width = unsafe Int(surface.width())
    let height = unsafe Int(surface.height())
    guard width > 0, height > 0,
        width <= Int.max / 4,
        height <= Int.max / (width * 4)
    else { return nil }
    let rowBytes = width * 4
    let readback = unsafe context.beginSurfaceReadbackRGBA(surface)
    guard unsafe readback.isValid() else { return nil }
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while unsafe !readback.isComplete() {
        _ = unsafe context.pollCompletedSubmissionSerial()
        guard ContinuousClock.now < deadline else { return nil }
        sched_yield()
    }
    var pixels = [UInt8](repeating: 0, count: rowBytes * height)
    var pixelSpan = pixels.mutableSpan
    let status = unsafe readback.copyPixels(&pixelSpan, Int32(rowBytes))
    return status == nucleus.skia.Status.ok ? pixels : nil
}

func waitForGraphiteSerial(
    context: nucleus.skia.GraphiteContext,
    serial: UInt64
) -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while unsafe context.pollCompletedSubmissionSerial() < serial {
        guard ContinuousClock.now < deadline else { return false }
        sched_yield()
    }
    return true
}
