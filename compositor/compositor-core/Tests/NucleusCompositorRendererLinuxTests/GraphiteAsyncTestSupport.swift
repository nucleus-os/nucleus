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
    guard recording.isValid(),
          context.submitAsync(recording, serial) == nucleus.skia.Status.ok
    else { return false }
    return waitForGraphiteSerial(context: context, serial: serial)
}

func submitGraphiteWithUploadAndWait(
    context: nucleus.skia.GraphiteContext,
    upload: nucleus.skia.Recording,
    frame: nucleus.skia.Recording,
    serial: UInt64
) -> Bool {
    guard upload.isValid(), frame.isValid(),
          context.submitWithUploadAndSemaphores(
              upload, frame, nil, 0, nil, serial) == nucleus.skia.Status.ok
    else { return false }
    return waitForGraphiteSerial(context: context, serial: serial)
}

func readGraphiteSurfaceRGBA(
    context: nucleus.skia.GraphiteContext,
    surface: nucleus.skia.Surface
) -> [UInt8]? {
    let width = Int(surface.width())
    let height = Int(surface.height())
    guard width > 0, height > 0,
          width <= Int.max / 4,
          height <= Int.max / (width * 4)
    else { return nil }
    let rowBytes = width * 4
    let readback = context.beginSurfaceReadbackRGBA(surface)
    guard readback.isValid() else { return nil }
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while !readback.isComplete() {
        _ = context.pollCompletedSubmissionSerial()
        guard ContinuousClock.now < deadline else { return nil }
        sched_yield()
    }
    var pixels = [UInt8](repeating: 0, count: rowBytes * height)
    let status = pixels.withUnsafeMutableBufferPointer {
        readback.copyPixels($0.baseAddress, $0.count, Int32(rowBytes))
    }
    return status == nucleus.skia.Status.ok ? pixels : nil
}

private func waitForGraphiteSerial(
    context: nucleus.skia.GraphiteContext,
    serial: UInt64
) -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while context.pollCompletedSubmissionSerial() < serial {
        guard ContinuousClock.now < deadline else { return false }
        sched_yield()
    }
    return true
}
