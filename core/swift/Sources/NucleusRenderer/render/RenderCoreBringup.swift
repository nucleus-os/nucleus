import NucleusSkiaGraphiteBridge
import NucleusDiagnostics
import VulkanC
import Vulkan
import Tracy
public import NucleusRenderModel
#if canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif
@MainActor
extension RenderCore {
    /// Bring up the agnostic render core: the Vulkan instance/device, the Graphite
    /// context + frame driver, and the shared retained tree. No platform fd — the
    /// presentation backend owns the display device. Returns nil when the GPU stack
    /// is unavailable.
    public static func create(
        applicationName: String,
        presentation: VkRequirements.PresentationMode = .platformDefault,
        store: RetainedTreeStore,
        resourceHost: SwiftResourceHost,
        asyncRenderWakeSink: any AsyncRenderWakeSink
    ) -> RenderCore? {
        guard let bootstrap = VulkanBootstrap.create(
            applicationName: applicationName, presentation: presentation)
        else { return nil }
        return create(
            bootstrap: bootstrap, qualification: .none,
            store: store, resourceHost: resourceHost,
            asyncRenderWakeSink: asyncRenderWakeSink)
    }

    public static func create(
        bootstrap: VulkanBootstrap,
        qualification: VulkanPresentationQualification,
        store: RetainedTreeStore,
        resourceHost: SwiftResourceHost,
        asyncRenderWakeSink: any AsyncRenderWakeSink
    ) -> RenderCore? {
        guard !bootstrap.finalized else { return nil }
        let contract = bootstrap.contract
        guard let instanceHandle = unsafe bootstrap.instanceLifetime.owner?.handle,
              let instanceDispatch = bootstrap.instanceLifetime.owner?.dispatch
        else { return nil }
        let requiredSurface: VkSurfaceKHR?
        let probe: ((VkInstance, VkPhysicalDevice, UInt32) -> Bool)?
        switch qualification {
        case .none:
            unsafe requiredSurface = nil
            unsafe probe = nil
        case .platformProbe(let body):
            unsafe requiredSurface = nil
            unsafe probe = { instance, device, family in
                unsafe body(VulkanInstanceHandle(instance), VulkanPhysicalDeviceHandle(device), family)
            }
        case .surface(let surface):
            guard unsafe surface.instance == instanceHandle else { return nil }
            unsafe requiredSurface = surface.handle
            unsafe probe = nil
        }
        guard let selection = unsafe DeviceOwner.selectPhysicalDevice(
            instance: instanceHandle, dispatch: instanceDispatch, contract: contract,
            requiredPresentationSurface: requiredSurface,
            queueFamilyPresentationSupport: probe
        ) else { return nil }
        guard let device = unsafe DeviceOwner.create(
            selection: selection, instanceDispatch: instanceDispatch,
            contract: contract
        ) else { return nil }
        guard let queue = unsafe device.queue(family: selection.graphicsQueueFamily) else {
            return nil
        }

        // Build the Graphite context. The device-extension pointer is only needed
        // for the make call, so create the context inside the cstring scope and
        // copy the (value-typed) context out.
        let context: nucleus.skia.GraphiteContext = unsafe withCStringArray(
            contract.deviceExtensions
        ) { extPtr, extCount in
            var ctxDesc = unsafe nucleus.skia.VulkanContextDescriptor()
            unsafe ctxDesc.instance = UnsafeMutableRawPointer(instanceHandle)
            unsafe ctxDesc.physicalDevice = UnsafeMutableRawPointer(selection.physicalDevice)
            unsafe ctxDesc.device = UnsafeMutableRawPointer(device.handle)
            unsafe ctxDesc.queue = UnsafeMutableRawPointer(queue)
            unsafe ctxDesc.graphicsQueueIndex = selection.graphicsQueueFamily
            unsafe ctxDesc.maxApiVersion = contract.minimumApiVersion.raw
            unsafe ctxDesc.deviceExtensions = extPtr
            unsafe ctxDesc.deviceExtensionCount = extCount
            return unsafe nucleus.skia.makeGraphiteVulkanContext(ctxDesc)
        }
        guard unsafe context.isValid() else { return nil }
        guard let driver = unsafe FrameDriver(
            context: context,
            resourceHost: resourceHost,
            wakeSink: asyncRenderWakeSink)
        else {
            return nil
        }
        bootstrap.finalized = true
        _ = unsafe queue  // consumed only to build the context above

        return unsafe RenderCore(
            instanceLifetime: bootstrap.instanceLifetime, device: consume device, queue: queue,
            physicalDevice: selection.physicalDevice, graphicsFamily: selection.graphicsQueueFamily,
            context: context, driver: driver, store: store,
            resourceHost: resourceHost,
            vulkanContract: contract,
            asyncRenderWakeSink: asyncRenderWakeSink)
    }

    func makeReplacementGraphiteContext() -> nucleus.skia.GraphiteContext {
        unsafe withCStringArray(vulkanContract.deviceExtensions) { extPtr, extCount in
            var descriptor = unsafe nucleus.skia.VulkanContextDescriptor()
            unsafe descriptor.instance = UnsafeMutableRawPointer(instanceHandle)
            unsafe descriptor.physicalDevice = UnsafeMutableRawPointer(physicalDevice)
            unsafe descriptor.device = UnsafeMutableRawPointer(deviceHandle)
            unsafe descriptor.queue = UnsafeMutableRawPointer(graphicsQueue)
            unsafe descriptor.graphicsQueueIndex = graphicsFamily
            unsafe descriptor.maxApiVersion = vulkanContract.minimumApiVersion.raw
            unsafe descriptor.deviceExtensions = extPtr
            unsafe descriptor.deviceExtensionCount = extCount
            return unsafe nucleus.skia.makeGraphiteVulkanContext(descriptor)
        }
    }

    @discardableResult
    func recreateGraphiteRenderer() -> Bool {
        // A failed insertion never makes staged uploads resident. Return their
        // owned CPU payloads to the coalescing queue before destroying the failed
        // recorder so the replacement renderer can retry them.
        rollbackStagedShmUploads()
        frameDriver?.abandonSubmissionScope()
        waitForGpuIdle()
        frameDriver?.shutdown()
        frameDriver = nil
        snapshots.releaseAll { _ in }
        unsafe clientUploadTextures.removeAll()
        unsafe retiredClientUploadTextures.removeAll()
        pendingClientAcquireSemaphores.removeAll()
        retiredClientAcquireSemaphores.removeAll()
        for box in importedSurfaceImages.values {
            box.release()
        }
        importedSurfaceImages.removeAll()
        for index in retiredSurfaceImages.indices {
            onSurfaceReleaseSync?(retiredSurfaceImages[index].releaseID)
        }
        retiredSurfaceImages.removeAll()
        unsafe context.reset()

        var replacement = unsafe makeReplacementGraphiteContext()
        guard unsafe replacement.isValid(),
              let driver = unsafe FrameDriver(
                context: replacement,
                resourceHost: resourceHost,
                wakeSink: asyncRenderWakeSink)
        else {
            unsafe replacement.reset()
            return false
        }
        unsafe context = replacement
        frameDriver = driver
        outputsNeedingInitialFrame.formUnion(outputTargets.keys)
        return true
    }

    func acceptGraphiteSubmission(
        _ result: nucleus.skia.SubmissionResult
    ) -> Bool {
        guard !result.isOk() else { return true }
        #if canImport(Glibc)
        let line =
            "graphite-submit: status=\(result.status.rawValue) "
            + "insert=\(result.insertStatus.rawValue) "
            + "context_usable=\(result.contextUsable) "
            + "diagnostic=\(String(result.diagnostic))"
        NucleusLogger(subsystem: "render-bringup").info(line)
        #endif
        if !result.contextUsable {
            _ = recreateGraphiteRenderer()
        }
        return false
    }

    public func createSurface(_ factory: VulkanSurfaceFactory) -> VulkanSurface? {
        guard let instanceLifetime,
              let token = unsafe factory(VulkanInstanceHandle(instanceHandle))
        else { return nil }
        return unsafe VulkanSurface(
            lifetime: instanceLifetime, instance: instanceHandle, dispatch: instanceDispatch,
            handle: token.vkSurface)
    }

    // MARK: - Output geometry

    /// Register (or replace) one output's presentation geometry — the agnostic
    /// `RenderTarget` the FramePlan walk is parameterized by. The presentation
    /// backend calls this when it attaches an output; `recordFrame` looks it up.
}
