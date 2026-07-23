import NucleusSkiaGraphiteBridge
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
        guard let instanceHandle = bootstrap.instanceLifetime.owner?.handle,
              let instanceDispatch = bootstrap.instanceLifetime.owner?.dispatch
        else { return nil }
        let requiredSurface: VkSurfaceKHR?
        let probe: ((VkInstance, VkPhysicalDevice, UInt32) -> Bool)?
        switch qualification {
        case .none:
            requiredSurface = nil; probe = nil
        case .platformProbe(let body):
            requiredSurface = nil
            probe = { instance, device, family in
                body(VulkanInstanceHandle(instance), VulkanPhysicalDeviceHandle(device), family)
            }
        case .surface(let surface):
            guard surface.instance == instanceHandle else { return nil }
            requiredSurface = surface.handle; probe = nil
        }
        guard let selection = DeviceOwner.selectPhysicalDevice(
            instance: instanceHandle, dispatch: instanceDispatch, contract: contract,
            requiredPresentationSurface: requiredSurface,
            queueFamilyPresentationSupport: probe
        ) else { return nil }
        guard let device = DeviceOwner.create(
            selection: selection, instanceDispatch: instanceDispatch,
            contract: contract
        ) else { return nil }
        guard let queue = device.queue(family: selection.graphicsQueueFamily) else {
            return nil
        }

        // Build the Graphite context. The device-extension pointer is only needed
        // for the make call, so create the context inside the cstring scope and
        // copy the (value-typed) context out.
        let context: nucleus.skia.GraphiteContext = withCStringArray(
            contract.deviceExtensions
        ) { extPtr, extCount in
            var ctxDesc = nucleus.skia.VulkanContextDescriptor()
            ctxDesc.instance = UnsafeMutableRawPointer(instanceHandle)
            ctxDesc.physicalDevice = UnsafeMutableRawPointer(selection.physicalDevice)
            ctxDesc.device = UnsafeMutableRawPointer(device.handle)
            ctxDesc.queue = UnsafeMutableRawPointer(queue)
            ctxDesc.graphicsQueueIndex = selection.graphicsQueueFamily
            ctxDesc.maxApiVersion = contract.minimumApiVersion.raw
            ctxDesc.deviceExtensions = extPtr
            ctxDesc.deviceExtensionCount = extCount
            return nucleus.skia.makeGraphiteVulkanContext(ctxDesc)
        }
        guard context.isValid() else { return nil }
        guard let driver = FrameDriver(
            context: context,
            resourceHost: resourceHost,
            wakeSink: asyncRenderWakeSink)
        else {
            return nil
        }
        bootstrap.finalized = true
        _ = queue  // consumed only to build the context above

        return RenderCore(
            instanceLifetime: bootstrap.instanceLifetime, device: consume device, queue: queue,
            physicalDevice: selection.physicalDevice, graphicsFamily: selection.graphicsQueueFamily,
            context: context, driver: driver, store: store,
            resourceHost: resourceHost)
    }

    public func createSurface(_ factory: VulkanSurfaceFactory) -> VulkanSurface? {
        guard let instanceLifetime,
              let token = factory(VulkanInstanceHandle(instanceHandle))
        else { return nil }
        return VulkanSurface(
            lifetime: instanceLifetime, instance: instanceHandle, dispatch: instanceDispatch,
            handle: token.vkSurface)
    }

    // MARK: - Output geometry

    /// Register (or replace) one output's presentation geometry — the agnostic
    /// `RenderTarget` the FramePlan walk is parameterized by. The presentation
    /// backend calls this when it attaches an output; `recordFrame` looks it up.
}
