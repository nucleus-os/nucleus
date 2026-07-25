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
                try probeGraphite(
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
        guard base.vkCreateInstance != nil,
              base.vkEnumerateInstanceVersion != nil,
              base.vkEnumerateInstanceExtensionProperties != nil,
              base.vkEnumerateInstanceLayerProperties != nil
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
        let fd = renderNode.withCString { nucleus_drm_open_device($0) }
        guard fd >= 0 else {
            throw LaneProbeFailure.contract(
                "could not open DRM render node \(renderNode)")
        }
        defer { _ = close(fd) }
        guard let gbm = gbm_create_device(fd) else {
            throw LaneProbeFailure.contract(
                "GBM rejected DRM render node \(renderNode)")
        }
        defer { gbm_device_destroy(gbm) }

        let identity = try renderNodeIdentity(fd)
        try probeGraphite(
            presentation: .platformDefault,
            applicationName: "Nucleus gpu-drm preflight"
        ) { instance, physicalDevice, _ in
            Self.physicalDevice(
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
        guard let instance = InstanceOwner.create(
            base: VK.loadBaseDispatch(),
            applicationName: applicationName,
            contract: contract,
            enableValidation: false
        ) else {
            throw LaneProbeFailure.contract(
                "could not create the required \(presentation) Vulkan instance")
        }
        guard let selection = DeviceOwner.selectPhysicalDevice(
            instance: instance.handle,
            dispatch: instance.dispatch,
            contract: contract,
            queueFamilyPresentationSupport: queueFamilyQualification
        ) else {
            throw LaneProbeFailure.contract(
                "no physical device satisfies the required \(presentation) contract")
        }
        guard let device = DeviceOwner.create(
            selection: selection,
            instanceDispatch: instance.dispatch,
            contract: contract
        ) else {
            throw LaneProbeFailure.contract(
                "could not create the required \(presentation) logical device")
        }
        guard let queue = device.queue(
            family: selection.graphicsQueueFamily)
        else {
            throw LaneProbeFailure.contract(
                "the selected Vulkan graphics queue is unavailable")
        }

        var context = withCStringArray(
            contract.deviceExtensions
        ) { extensions, count in
            var descriptor = nucleus.skia.VulkanContextDescriptor()
            descriptor.instance = UnsafeMutableRawPointer(instance.handle)
            descriptor.physicalDevice =
                UnsafeMutableRawPointer(selection.physicalDevice)
            descriptor.device = UnsafeMutableRawPointer(device.handle)
            descriptor.queue = UnsafeMutableRawPointer(queue)
            descriptor.graphicsQueueIndex = selection.graphicsQueueFamily
            descriptor.maxApiVersion = contract.minimumApiVersion.raw
            descriptor.deviceExtensions = extensions
            descriptor.deviceExtensionCount = count
            return nucleus.skia.makeGraphiteVulkanContext(descriptor)
        }
        guard context.isValid() else {
            throw LaneProbeFailure.contract(
                "Skia Graphite rejected the required Vulkan device")
        }
        func validateRecorder(
            context: nucleus.skia.GraphiteContext
        ) throws {
            let recorder = context.makeRecorder()
            guard recorder.isValid() else {
                throw LaneProbeFailure.contract(
                    "Skia Graphite could not create a recorder")
            }
        }
        do {
            try validateRecorder(context: context)
        } catch {
            context.reset()
            throw error
        }
        context.reset()
    }

    private static func renderNodeIdentity(
        _ fd: Int32
    ) throws -> (major: Int64, minor: Int64) {
        var deviceStat = stat()
        guard fstat(fd, &deviceStat) == 0 else {
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
        guard let raw = vkGetInstanceProcAddr(
            instance, "vkGetPhysicalDeviceProperties2")
        else { return false }
        let getProperties = unsafeBitCast(
            raw, to: PFN_vkGetPhysicalDeviceProperties2.self)
        var drm = VkPhysicalDeviceDrmPropertiesEXT()
        drm.sType =
            VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRM_PROPERTIES_EXT
        var properties = VkPhysicalDeviceProperties2()
        properties.sType =
            VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2
        withUnsafeMutablePointer(to: &drm) { pointer in
            properties.pNext = UnsafeMutableRawPointer(pointer)
            getProperties(physicalDevice, &properties)
        }
        return drm.hasRender != 0
            && drm.renderMajor == identity.major
            && drm.renderMinor == identity.minor
    }
}
