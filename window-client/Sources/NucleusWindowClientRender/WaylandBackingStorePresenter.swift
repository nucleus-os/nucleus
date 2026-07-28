@_spi(NucleusPlatform) import NucleusRenderer
@_spi(NucleusWindowClientImplementation)
import NucleusWindowClientWayland
import Vulkan
import VulkanC
import WaylandClientDispatch
import WaylandProtocolTypes

struct WaylandBackingStoreSlotLifecycle: Equatable {
    private(set) var releasePoint: UInt64 = 0
    private(set) var wlReleased = true
    private(set) var retired = false

    mutating func committed(releasePoint: UInt64) {
        precondition(releasePoint > self.releasePoint)
        self.releasePoint = releasePoint
        wlReleased = false
    }

    mutating func compositorReleased() {
        wlReleased = true
    }

    mutating func retire() {
        retired = true
    }

    func isReusable(timelineValue: UInt64) -> Bool {
        !retired && wlReleased && timelineValue >= releasePoint
    }

    func isReclaimable(timelineValue: UInt64) -> Bool {
        retired && wlReleased && timelineValue >= releasePoint
    }
}

struct WaylandBackingStorePacingState: Equatable {
    private(set) var paused = false
    private(set) var frameCallbackPending = false
    private(set) var removed = false

    mutating func committedFrame() {
        precondition(!paused && !removed && !frameCallbackPending)
        frameCallbackPending = true
    }

    mutating func frameCallbackCompleted() {
        frameCallbackPending = false
    }

    mutating func pause() {
        paused = true
    }

    mutating func resume() {
        guard !removed else { return }
        paused = false
    }

    mutating func remove() {
        removed = true
        paused = true
        frameCallbackPending = false
    }

    func canAcquire(hasReusableSlot: Bool) -> Bool {
        hasReusableSlot && !paused && !removed
            && !frameCallbackPending
    }
}

@MainActor
@safe final class WaylandBackingStoreSlot: WlBufferEvents {
    let image: ExportedDmaBufImage
    let buffer: WaylandProxy<WlBufferClient>
    var lifecycle = WaylandBackingStoreSlotLifecycle()
    var onRelease: (() -> Void)?

    init(
        image: ExportedDmaBufImage,
        buffer: WaylandProxy<WlBufferClient>
    ) throws {
        self.image = image
        self.buffer = buffer
        try buffer.installListener(self)
    }

    func release(
        _ proxy: WaylandBorrowedProxy<WlBufferClient>
    ) {
        lifecycle.compositorReleased()
        onRelease?()
    }

    func destroy() {
        try? buffer.destroy()
    }

    isolated deinit {}
}

@MainActor
@safe private final class WaylandFrameCallback: WlCallbackEvents {
    private let completion: () -> Void

    init(
        proxy: WaylandProxy<WlCallbackClient>,
        completion: @escaping () -> Void
    ) throws {
        self.completion = completion
        try proxy.installListener(self)
    }

    func done(
        _ proxy: WaylandBorrowedProxy<WlCallbackClient>,
        callback_data: UInt32
    ) {
        completion()
    }

    isolated deinit {}
}

@MainActor
@safe private final class WaylandPresentationReceipt:
    WpPresentationFeedbackEvents
{
    private let completion: () -> Void

    init(
        proxy: WaylandProxy<WpPresentationFeedbackClient>,
        completion: @escaping () -> Void
    ) throws {
        self.completion = completion
        try proxy.installListener(self)
    }

    func syncOutput(
        _ proxy:
            WaylandBorrowedProxy<WpPresentationFeedbackClient>,
        output: WaylandBorrowedProxy<WlOutputClient>
    ) {}

    func presented(
        _ proxy:
            WaylandBorrowedProxy<WpPresentationFeedbackClient>,
        tv_sec_hi: UInt32,
        tv_sec_lo: UInt32,
        tv_nsec: UInt32,
        refresh: UInt32,
        seq_hi: UInt32,
        seq_lo: UInt32,
        flags: WpPresentationFeedbackKind
    ) {
        completion()
    }

    func discarded(
        _ proxy:
            WaylandBorrowedProxy<WpPresentationFeedbackClient>
    ) {
        completion()
    }

    isolated deinit {}
}

/// The desktop client's sole presentation backend. Vulkan images and timeline
/// semaphores remain process-local; Wayland receives only DMA-BUF descriptors,
/// metadata, and monotonically increasing syncobj points.
@MainActor
@safe final class WaylandBackingStorePresenter: PresentationBackend {
    private static let backingStoreCount = 3

    private let core: RenderCore
    private let outputID: UInt64
    private let surface: WaylandProxy<WlSurfaceClient>
    private let dmaBuf: WaylandProxy<ZwpLinuxDmabufV1Client>
    private let syncSurface:
        WaylandProxy<WpLinuxDrmSyncobjSurfaceV1Client>
    private let syncTimeline:
        WaylandProxy<WpLinuxDrmSyncobjTimelineV1Client>
    private let presentation: WaylandProxy<WpPresentationClient>?
    private let timeline: ExportedTimelineSemaphore
    private let advertisedFormats: [NucleusDesktopDmaBufFormat]

    private var slots: [WaylandBackingStoreSlot] = []
    private var retiredSlots: [WaylandBackingStoreSlot] = []
    private var acquiredSlot: WaylandBackingStoreSlot?
    private var submittedAcquirePoint: UInt64?
    private var nextTimelinePoint: UInt64 = 1
    private var frameCallback: WaylandFrameCallback?
    private var presentationReceipts:
        [UInt64: WaylandPresentationReceipt] = [:]
    private var nextPresentationReceiptID: UInt64 = 1
    private var pacing = WaylandBackingStorePacingState()

    private(set) var lastExtentWidth: Int32 = 0
    private(set) var lastExtentHeight: Int32 = 0
    var deviceLost: Bool { timeline.deviceLost }

    init?(
        core: RenderCore,
        outputID: UInt64,
        surface: WaylandProxy<WlSurfaceClient>,
        connection: NucleusDesktopConnection
    ) {
        guard let dmaBuf = connection.dmaBuf,
              let syncManager = connection.drmSyncobj,
              !connection.dmaBufFormats.isEmpty,
              let timeline = unsafe ExportedTimelineSemaphore(
                device: core.deviceHandle,
                dispatch: core.deviceDispatch,
                queue: core.graphicsQueue),
              let descriptor = timeline.takeFileDescriptor()
        else { return nil }
        do {
            let syncTimeline = try syncManager.importTimeline(
                fd: WaylandClientOwnedFileDescriptor(descriptor))
            let syncSurface = try syncManager.getSurface(
                surface: surface)
            self.core = core
            self.outputID = outputID
            self.surface = surface
            self.dmaBuf = dmaBuf
            self.syncSurface = syncSurface
            self.syncTimeline = syncTimeline
            self.presentation = connection.presentation
            self.timeline = timeline
            self.advertisedFormats = connection.dmaBufFormats
        } catch {
            return nil
        }
    }

    var defersGpuResourceRetirement: Bool { false }

    func configure(
        width: Int32,
        height: Int32
    ) -> Bool {
        guard width > 0, height > 0 else { return false }
        if width == lastExtentWidth,
           height == lastExtentHeight,
           !slots.isEmpty
        {
            return true
        }
        guard let replacement = makeBackingStores(
            width: UInt32(width),
            height: UInt32(height))
        else { return false }
        for slot in slots {
            slot.lifecycle.retire()
            retiredSlots.append(slot)
        }
        slots = replacement
        lastExtentWidth = width
        lastExtentHeight = height
        collectRetiredSlots()
        return true
    }

    func presentableOutputIDs() -> [UInt64] {
        pacing.paused || pacing.removed || slots.isEmpty
            ? [] : [outputID]
    }

    func isReadyToPresent(_ outputID: UInt64) -> Bool {
        guard outputID == self.outputID,
              !pacing.paused,
              !pacing.removed,
              !pacing.frameCallbackPending,
              acquiredSlot == nil
        else { return false }
        collectRetiredSlots()
        guard let current = timeline.currentValue() else {
            return false
        }
        return slots.contains {
            $0.lifecycle.isReusable(timelineValue: current)
        }
    }

    func acquireTarget(
        _ outputID: UInt64
    ) -> AcquiredFrameTarget? {
        guard isReadyToPresent(outputID),
              let current = timeline.currentValue(),
              let slot = slots.first(where: {
                  $0.lifecycle.isReusable(timelineValue: current)
              })
        else { return nil }
        acquiredSlot = slot
        return unsafe AcquiredFrameTarget(
            image: slot.image.imageHandle,
            width: lastExtentWidth,
            height: lastExtentHeight,
            format: vulkanFormatForDrm(slot.image.drmFormat),
            tiling: VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT,
            initialLayout: VK_IMAGE_LAYOUT_UNDEFINED,
            usageFlags: DmaBufImageDescriptor.scanoutUsage,
            queueFamily: core.graphicsFamily,
            hasAlpha: slot.image.drmFormat == DrmFourcc.argb8888
                || slot.image.drmFormat == DrmFourcc.abgr8888,
            kind: .clientBackingStore)
    }

    func didSubmitTarget(_ outputID: UInt64) -> Bool {
        guard outputID == self.outputID,
              acquiredSlot != nil,
              submittedAcquirePoint == nil,
              nextTimelinePoint <= UInt64.max - 2
        else { return false }
        let acquirePoint = nextTimelinePoint
        nextTimelinePoint += 2
        guard timeline.signal(acquirePoint) else { return false }
        submittedAcquirePoint = acquirePoint
        return true
    }

    func present(_ outputID: UInt64) -> Bool {
        guard outputID == self.outputID,
              let slot = acquiredSlot,
              let acquirePoint = submittedAcquirePoint
        else { return false }
        let releasePoint = acquirePoint + 1
        do {
            try syncSurface.setAcquirePoint(
                timeline: syncTimeline,
                point_hi: UInt32(acquirePoint >> 32),
                point_lo: UInt32(truncatingIfNeeded: acquirePoint))
            try syncSurface.setReleasePoint(
                timeline: syncTimeline,
                point_hi: UInt32(releasePoint >> 32),
                point_lo: UInt32(truncatingIfNeeded: releasePoint))
            try surface.attach(buffer: slot.buffer, x: 0, y: 0)
            try surface.damageBuffer(
                x: 0, y: 0,
                width: lastExtentWidth,
                height: lastExtentHeight)
            let callbackProxy = try surface.frame()
            frameCallback = try WaylandFrameCallback(
                proxy: callbackProxy,
                completion: { [weak self] in
                    self?.frameCallback = nil
                    self?.pacing.frameCallbackCompleted()
                })
            installPresentationReceipt()
            try surface.commit()
        } catch {
            frameCallback = nil
            return false
        }
        slot.lifecycle.committed(releasePoint: releasePoint)
        pacing.committedFrame()
        acquiredSlot = nil
        submittedAcquirePoint = nil
        return true
    }

    func discardAcquiredTarget(_ outputID: UInt64) {
        guard outputID == self.outputID else { return }
        acquiredSlot = nil
        submittedAcquirePoint = nil
    }

    func didPresentFrame() {}

    func pauseSession() {
        pacing.pause()
    }

    func resumeSession() {
        pacing.resume()
    }

    func teardown() {
        acquiredSlot = nil
        submittedAcquirePoint = nil
        frameCallback = nil
        presentationReceipts.removeAll()
        pacing.remove()
        for slot in slots + retiredSlots {
            slot.destroy()
        }
        slots.removeAll()
        retiredSlots.removeAll()
        try? syncSurface.destroy()
        try? syncTimeline.destroy()
    }

    private func makeBackingStores(
        width: UInt32,
        height: UInt32
    ) -> [WaylandBackingStoreSlot]? {
        let preferred = advertisedFormats.sorted {
            let lhsAlpha = $0.format == DrmFourcc.argb8888
                || $0.format == DrmFourcc.abgr8888
            let rhsAlpha = $1.format == DrmFourcc.argb8888
                || $1.format == DrmFourcc.abgr8888
            if lhsAlpha != rhsAlpha { return lhsAlpha }
            return ($0.format, $0.modifier)
                < ($1.format, $1.modifier)
        }
        for candidate in preferred {
            var candidateSlots: [WaylandBackingStoreSlot] = []
            for _ in 0..<Self.backingStoreCount {
                guard let slot = makeBackingStore(
                    width: width,
                    height: height,
                    format: candidate.format,
                    modifier: candidate.modifier)
                else {
                    for slot in candidateSlots { slot.destroy() }
                    candidateSlots.removeAll()
                    break
                }
                candidateSlots.append(slot)
            }
            if candidateSlots.count == Self.backingStoreCount {
                return candidateSlots
            }
        }
        return nil
    }

    private func makeBackingStore(
        width: UInt32,
        height: UInt32,
        format: UInt32,
        modifier: UInt64
    ) -> WaylandBackingStoreSlot? {
        guard let image = unsafe allocateExportedDmaBufImage(
            physicalDevice: core.physicalDevice,
            instanceDispatch: core.instanceDispatch,
            device: core.deviceHandle,
            deviceDispatch: core.deviceDispatch,
            width: width,
            height: height,
            drmFormat: format,
            modifier: modifier),
              let descriptor = image.takeFileDescriptor()
        else { return nil }
        do {
            let ownedDescriptor =
                WaylandClientOwnedFileDescriptor(descriptor)
            let params = try dmaBuf.createParams()
            try params.add(
                fd: consume ownedDescriptor,
                plane_idx: 0,
                offset: image.offset,
                stride: image.rowPitch,
                modifier_hi: UInt32(image.modifier >> 32),
                modifier_lo: UInt32(
                    truncatingIfNeeded: image.modifier))
            let buffer = try params.createImmed(
                width: Int32(width),
                height: Int32(height),
                format: image.drmFormat,
                flags: [])
            try params.destroy()
            let slot = try WaylandBackingStoreSlot(
                image: image, buffer: buffer)
            slot.onRelease = { [weak self] in
                self?.collectRetiredSlots()
            }
            return slot
        } catch {
            return nil
        }
    }

    private func collectRetiredSlots() {
        guard let current = timeline.currentValue() else { return }
        var retained: [WaylandBackingStoreSlot] = []
        for slot in retiredSlots {
            if slot.lifecycle.isReclaimable(
                timelineValue: current)
            {
                slot.destroy()
            } else {
                retained.append(slot)
            }
        }
        retiredSlots = retained
    }

    private func installPresentationReceipt() {
        guard let presentation,
              let proxy = try? presentation.feedback(surface: surface)
        else { return }
        let id = nextPresentationReceiptID
        nextPresentationReceiptID &+= 1
        guard let receipt = try? WaylandPresentationReceipt(
            proxy: proxy,
            completion: { [weak self] in
                self?.presentationReceipts[id] = nil
            })
        else { return }
        presentationReceipts[id] = receipt
    }

    isolated deinit {}
}
