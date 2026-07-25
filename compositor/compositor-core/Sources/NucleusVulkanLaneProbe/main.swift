import Foundation
import Glibc
import NucleusCompositorDrmC
import NucleusRenderer
import NucleusSkiaGraphiteBridge
import Vulkan
import VulkanC

enum LaneProbeFailure: Error, CustomStringConvertible {
    case usage
    case contract(String)

    var description: String {
        switch self {
        case .usage:
            "expected one lane: loader, gpu-headless, or gpu-drm"
        case .contract(let detail):
            detail
        }
    }
}

@main
enum NucleusVulkanLaneProbe {
    static func main() {
        do {
            guard CommandLine.arguments.count == 2 else {
                throw LaneProbeFailure.usage
            }
            let lane = CommandLine.arguments[1]
            switch lane {
            case "loader":
                try probeLoader()
            case "gpu-headless":
                try unsafe probeGraphite(
                    presentation: .headless,
                    applicationName: "Nucleus gpu-headless preflight")
            case "gpu-drm":
                try probeDRM()
            default:
                throw LaneProbeFailure.usage
            }
            print("Vulkan lane preflight satisfied: \(lane)")
        } catch {
            print("Vulkan lane preflight failed: \(error)")
            exit(1)
        }
    }

    private static func probeLoader() throws {
        let base = VK.loadBaseDispatch()
        guard unsafe base.vkCreateInstance != nil,
              unsafe base.vkEnumerateInstanceVersion != nil,
              unsafe base.vkEnumerateInstanceExtensionProperties != nil,
              unsafe base.vkEnumerateInstanceLayerProperties != nil
        else {
            throw LaneProbeFailure.contract(
                "the Vulkan loader does not expose the required global dispatch")
        }
    }

    private static func probeDRM() throws {
        guard let renderNode =
                ProcessInfo.processInfo.environment[
                    "NUCLEUS_TEST_DRM_RENDER_NODE"],
              !renderNode.isEmpty
        else {
            throw LaneProbeFailure.contract(
                "NUCLEUS_TEST_DRM_RENDER_NODE was not provided")
        }
        let fd = renderNode.withCString {
            unsafe nucleus_drm_open_device($0)
        }
        guard fd >= 0 else {
            throw LaneProbeFailure.contract(
                "could not open DRM render node \(renderNode)")
        }
        defer { _ = close(fd) }
        guard let gbm = unsafe gbm_create_device(fd) else {
            throw LaneProbeFailure.contract(
                "GBM rejected DRM render node \(renderNode)")
        }
        defer { unsafe gbm_device_destroy(gbm) }

        let identity = try renderNodeIdentity(fd)
        try unsafe probeGraphite(
            presentation: .platformDefault,
            applicationName: "Nucleus gpu-drm preflight"
        ) { instance, physicalDevice, _ in
            unsafe Self.physicalDevice(
                physicalDevice,
                belongsToRenderNode: identity,
                instance: instance)
        }
    }

    private static func probeGraphite(
        presentation: VkRequirements.PresentationMode,
        applicationName: String,
        queueFamilyQualification: ((
            VkInstance, VkPhysicalDevice, UInt32
        ) -> Bool)? = nil
    ) throws {
        let contract = VkRequirements.contract(for: presentation)
        guard let instance = unsafe InstanceOwner.create(
            base: VK.loadBaseDispatch(),
            applicationName: applicationName,
            contract: contract,
            enableValidation: false
        ) else {
            throw LaneProbeFailure.contract(
                "could not create the required \(presentation) Vulkan instance")
        }
        guard let selection = unsafe DeviceOwner.selectPhysicalDevice(
            instance: instance.handle,
            dispatch: instance.dispatch,
            contract: contract,
            queueFamilyPresentationSupport: queueFamilyQualification
        ) else {
            throw LaneProbeFailure.contract(
                "no physical device satisfies the required \(presentation) contract")
        }
        guard let device = unsafe DeviceOwner.create(
            selection: selection,
            instanceDispatch: instance.dispatch,
            contract: contract
        ) else {
            throw LaneProbeFailure.contract(
                "could not create the required \(presentation) logical device")
        }
        guard let queue = unsafe device.queue(
            family: selection.graphicsQueueFamily)
        else {
            throw LaneProbeFailure.contract(
                "the selected Vulkan graphics queue is unavailable")
        }

        var context = unsafe withCStringArray(
            contract.deviceExtensions
        ) { extensions, count in
            var descriptor = unsafe nucleus.skia.VulkanContextDescriptor()
            unsafe descriptor.instance = UnsafeMutableRawPointer(instance.handle)
            unsafe descriptor.physicalDevice =
                UnsafeMutableRawPointer(selection.physicalDevice)
            unsafe descriptor.device = UnsafeMutableRawPointer(device.handle)
            unsafe descriptor.queue = UnsafeMutableRawPointer(queue)
            unsafe descriptor.graphicsQueueIndex = selection.graphicsQueueFamily
            unsafe descriptor.maxApiVersion = contract.minimumApiVersion.raw
            unsafe descriptor.deviceExtensions = extensions
            unsafe descriptor.deviceExtensionCount = count
            return unsafe nucleus.skia.makeGraphiteVulkanContext(descriptor)
        }
        guard unsafe context.isValid() else {
            throw LaneProbeFailure.contract(
                "Skia Graphite rejected the required Vulkan device")
        }
        func validateRecorder(
            context: nucleus.skia.GraphiteContext
        ) throws {
            let recorder = unsafe context.makeRecorder()
            guard unsafe recorder.isValid() else {
                throw LaneProbeFailure.contract(
                    "Skia Graphite could not create a recorder")
            }
        }
        do {
            try unsafe validateRecorder(context: context)
        } catch {
            unsafe context.reset()
            throw error
        }
        unsafe context.reset()
    }

    private static func renderNodeIdentity(
        _ fd: Int32
    ) throws -> (major: Int64, minor: Int64) {
        var deviceStat = stat()
        guard unsafe fstat(fd, &deviceStat) == 0 else {
            throw LaneProbeFailure.contract(
                "fstat failed for the required DRM render node")
        }
        let deviceID = UInt64(deviceStat.st_rdev)
        return (
            Int64(((deviceID >> 8) & 0xfff)
                | ((deviceID >> 32) & ~0xfff)),
            Int64((deviceID & 0xff)
                | ((deviceID >> 12) & ~0xff)))
    }

    private static func physicalDevice(
        _ physicalDevice: VkPhysicalDevice,
        belongsToRenderNode identity: (major: Int64, minor: Int64),
        instance: VkInstance
    ) -> Bool {
        guard let raw = unsafe vkGetInstanceProcAddr(
            instance, "vkGetPhysicalDeviceProperties2")
        else { return false }
        let getProperties = unsafe unsafeBitCast(
            raw, to: PFN_vkGetPhysicalDeviceProperties2.self)
        var drm = unsafe VkPhysicalDeviceDrmPropertiesEXT()
        unsafe drm.sType =
            VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRM_PROPERTIES_EXT
        var properties = unsafe VkPhysicalDeviceProperties2()
        unsafe properties.sType =
            VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2
        withUnsafeMutablePointer(to: &drm) { pointer in
            unsafe properties.pNext = UnsafeMutableRawPointer(pointer)
            unsafe getProperties(physicalDevice, &properties)
        }
        return unsafe drm.hasRender != 0
            && drm.renderMajor == identity.major
            && drm.renderMinor == identity.minor
    }
}
