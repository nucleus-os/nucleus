import VulkanC
import Vulkan
import NucleusDiagnostics
public import NucleusRenderModel
@_spi(NucleusPlatform) public import NucleusRenderer
import Glibc

public struct RendererOutputInfo:
    Sendable, Equatable
{
    public let topologyGeneration: UInt64
    public let id: UInt64
    public let pixelWidth: UInt32
    public let pixelHeight: UInt32
    public let refreshMhz: Int32
    public let physicalWidthMM: Int32
    public let physicalHeightMM: Int32
    public let crtcID: UInt32
    public let primaryPlaneID: UInt32
    public let cursorPlaneID: UInt32

    public init(
        topologyGeneration: UInt64,
        id: UInt64,
        pixelWidth: UInt32,
        pixelHeight: UInt32,
        refreshMhz: Int32,
        physicalWidthMM: Int32,
        physicalHeightMM: Int32,
        crtcID: UInt32,
        primaryPlaneID: UInt32,
        cursorPlaneID: UInt32
    ) {
        self.topologyGeneration = topologyGeneration
        self.id = id
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshMhz = refreshMhz
        self.physicalWidthMM = physicalWidthMM
        self.physicalHeightMM = physicalHeightMM
        self.crtcID = crtcID
        self.primaryPlaneID = primaryPlaneID
        self.cursorPlaneID = cursorPlaneID
    }
}

public struct RendererTopologyProposal:
    Sendable, Equatable
{
    public let generation: UInt64
    public let outputs: [RendererOutputInfo]
}

/// Result of a nonblocking KMS lifetime transition. Draining is not an error:
/// the compositor keeps the DRM fd in its reactor and retries after the kernel
/// retires the outstanding presentation state. This covers both an explicitly
/// tracked page flip and an atomic disable rejected with `EBUSY`.
public enum RendererRetirementResult: Sendable, Equatable {
    case complete
    case draining
    case failed
}

enum DrmBackendState {
    case resuming
    case active(OutputTopologySnapshot)
    case pausing
    case inactive
    case failed(String)

    var admitsPresentation: Bool {
        if case .active = self { return true }
        return false
    }
}

@_spi(NucleusPlatform)
public struct CompositeFenceTelemetry:
    Sendable, Equatable
{
    public var clientAcquireFenceCount: UInt64 = 0
    public var latestClientAcquireSignalNs: UInt64?
    public var renderCompleteNs: UInt64?
    public var gpuElapsedNs: UInt64?

    public init() {}
}

func logRendererDrm(_ message: String) {
    NucleusLogger(subsystem: "renderer-drm").error(message)
}

func rendererErrno() -> Int32 {
    unsafe __errno_location().pointee
}

func rendererMonotonicNowNs() -> UInt64 {
    var timestamp = timespec()
    unsafe clock_gettime(CLOCK_MONOTONIC, &timestamp)
    return UInt64(timestamp.tv_sec)
        &* 1_000_000_000
        &+ UInt64(timestamp.tv_nsec)
}

func logScanout(_ message: String) {
    NucleusLogger(subsystem: "scanout").debug(message)
}

@MainActor
extension DRMScanoutPresenter {
    public static func create(
        drmDeviceFd: Int32,
        enableValidation: Bool,
        presentPolicy: RendererPresentPolicy,
        store: RetainedTreeStore,
        resourceHost: SwiftResourceHost,
        asyncRenderWakeSink: any AsyncRenderWakeSink
    ) -> DRMScanoutPresenter? {
        var deviceStat = stat()
        guard unsafe fstat(drmDeviceFd, &deviceStat) == 0
        else { return nil }
        let deviceID = UInt64(deviceStat.st_rdev)
        let targetMajor = Int64(
            ((deviceID >> 8) & 0xfff)
                | ((deviceID >> 32) & ~0xfff))
        let targetMinor = Int64(
            (deviceID & 0xff)
                | ((deviceID >> 12) & ~0xff))
        logRendererDrm(
            "selecting Vulkan device matching DRM primary \(targetMajor):\(targetMinor) " +
            "validation=\(enableValidation)")
        guard let bootstrap = VulkanBootstrap.create(
            applicationName: "Nucleus Compositor",
            enableValidation: enableValidation)
        else {
            logRendererDrm(
                "Vulkan instance bootstrap failed validation=\(enableValidation)")
            return nil
        }
        guard let core = RenderCore.create(
            bootstrap: bootstrap,
            qualification: .platformProbe {
                instance, physicalDevice, _ in
                guard let raw = unsafe vkGetInstanceProcAddr(
                    instance.vkInstance,
                    "vkGetPhysicalDeviceProperties2")
                else { return false }
                let getProperties = unsafe unsafeBitCast(
                    raw,
                    to: PFN_vkGetPhysicalDeviceProperties2
                        .self)
                var drm =
                    unsafe VkPhysicalDeviceDrmPropertiesEXT()
                unsafe drm.sType =
                    VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRM_PROPERTIES_EXT
                var properties =
                    unsafe VkPhysicalDeviceProperties2()
                unsafe properties.sType =
                    VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2
                withUnsafeMutablePointer(to: &drm) {
                    drmPointer in
                    unsafe properties.pNext =
                        UnsafeMutableRawPointer(drmPointer)
                    unsafe getProperties(
                        physicalDevice.vkPhysicalDevice,
                        &properties)
                }
                let hasPrimary = unsafe drm.hasPrimary != 0
                let primaryMajor = unsafe drm.primaryMajor
                let primaryMinor = unsafe drm.primaryMinor
                let hasRender = unsafe drm.hasRender != 0
                let renderMajor = unsafe drm.renderMajor
                let renderMinor = unsafe drm.renderMinor
                let matches = hasPrimary
                    && primaryMajor == targetMajor
                    && primaryMinor == targetMinor
                logRendererDrm(
                    "Vulkan candidate primary=" +
                    "\(hasPrimary ? "\(primaryMajor):\(primaryMinor)" : "none") " +
                    "render=\(hasRender ? "\(renderMajor):\(renderMinor)" : "none") " +
                    "match=\(matches)")
                return matches
            },
            store: store,
            resourceHost: resourceHost,
            asyncRenderWakeSink: asyncRenderWakeSink)
        else {
            logRendererDrm(
                "no Vulkan device matched the selected DRM primary node")
            return nil
        }
        guard let gbm = GbmDevice(
            borrowingFd: drmDeviceFd),
            let gbmHandle = unsafe gbm.handle
        else {
            logRendererDrm(
                "gbm_create_device failed errno=\(rendererErrno())")
            return nil
        }
        let caps = DrmCapabilities.discover(
            fd: drmDeviceFd)
        logRendererDrm(
            "Vulkan and GBM initialized on selected DRM device " +
            "kernel_timestamp_monotonic=\(caps.timestampMonotonic)")
        let drmDevice = DrmDeviceLifetime(
            fileDescriptor: drmDeviceFd)
        return unsafe DRMScanoutPresenter(
            core: core,
            gbm: consume gbm,
            gbmHandle: gbmHandle,
            drmDevice: drmDevice,
            drmCaps: caps,
            presentPolicy: presentPolicy)
    }
}
