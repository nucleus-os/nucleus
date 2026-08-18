import Foundation
import Glibc
import NucleusSkiaGraphiteBridge
import Synchronization
import Testing
import Vulkan
import VulkanC

@testable import NucleusRenderer

/// The process Vulkan loader and installed ICDs are shared by every suite in this
/// test product. Swift Testing runs suites concurrently, but concurrent loader
/// initialization has crashed inside `vkGetInstanceProcAddr`/ICD discovery on the
/// mandatory Linux lane. Keep each complete instance → device → Graphite lifetime
/// exclusive so teardown finishes before another suite initializes the loader.
private let requiredVulkanGraphiteGate = VulkanGraphiteTestGate()

private final class VulkanGraphiteTestGate: Sendable {
    /// The gate carries no state; it serializes the lifetimes themselves.
    private let mutex = Mutex<Void>(())

    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        try mutex.withLock { _ in try body() }
    }
}

enum VulkanLaneTestFailure: Error, CustomStringConvertible {
    case instance(VkRequirements.PresentationMode)
    case physicalDevice(VkRequirements.PresentationMode)
    case logicalDevice(VkRequirements.PresentationMode)
    case graphicsQueue
    case graphiteContext
    case graphiteRecorder
    case requirement(String)

    var description: String {
        switch self {
        case .instance(let mode):
            "could not create the required \(mode) Vulkan instance"
        case .physicalDevice(let mode):
            "no physical device satisfies the required \(mode) Vulkan contract"
        case .logicalDevice(let mode):
            "could not create the required \(mode) Vulkan device"
        case .graphicsQueue:
            "the selected Vulkan graphics queue is unavailable"
        case .graphiteContext:
            "Skia Graphite rejected the required Vulkan device"
        case .graphiteRecorder:
            "Skia Graphite could not create a recorder"
        case .requirement(let message):
            message
        }
    }
}

/// The DRM render node Collider provisions for the mandatory GPU+GBM lane.
///
/// An absent variable means this run is not the provisioned lane — the case is
/// cancelled rather than recorded as a failure. Everything downstream of this gate
/// stays a hard requirement: once Collider names a node, the lane must work.
func requireProvisionedDrmRenderNode() throws -> String {
    guard
        let path = ProcessInfo.processInfo.environment[
            "NUCLEUS_TEST_DRM_RENDER_NODE"],
        !path.isEmpty
    else {
        try Test.cancel(
            "NUCLEUS_TEST_DRM_RENDER_NODE is not provisioned; the DRM lane runs only under Collider on a machine with a render node"
        )
    }
    return path
}

func requireValue<T>(
    _ value: @autoclosure () -> T?,
    _ message: @autoclosure () -> String
) throws -> T {
    guard let value = value() else {
        throw VulkanLaneTestFailure.requirement(message())
    }
    return value
}

func requireTrue(
    _ condition: @autoclosure () -> Bool,
    _ message: @autoclosure () -> String
) throws {
    guard condition() else {
        throw VulkanLaneTestFailure.requirement(message())
    }
}

func keepAlive<T: ~Copyable>(_ value: borrowing T) {}

func withRequiredVulkanGraphite<Result>(
    presentation: VkRequirements.PresentationMode,
    applicationName: String,
    queueFamilyQualification: (
        (
            VkInstance, VkPhysicalDevice, UInt32
        ) -> Bool
    )? = nil,
    _ body: (
        borrowing DeviceOwner,
        DeviceOwner.PhysicalSelection,
        nucleus.skia.GraphiteContext,
        nucleus.skia.Recorder
    ) throws -> Result
) throws -> Result {
    try requiredVulkanGraphiteGate.withLock {
        try unsafe withExclusiveRequiredVulkanGraphite(
            presentation: presentation,
            applicationName: applicationName,
            queueFamilyQualification: queueFamilyQualification,
            body)
    }
}

private func withExclusiveRequiredVulkanGraphite<Result>(
    presentation: VkRequirements.PresentationMode,
    applicationName: String,
    queueFamilyQualification: (
        (
            VkInstance, VkPhysicalDevice, UInt32
        ) -> Bool
    )?,
    _ body: (
        borrowing DeviceOwner,
        DeviceOwner.PhysicalSelection,
        nucleus.skia.GraphiteContext,
        nucleus.skia.Recorder
    ) throws -> Result
) throws -> Result {
    let contract = VkRequirements.contract(for: presentation)
    guard
        let instance = unsafe InstanceOwner.create(
            base: VK.loadBaseDispatch(),
            applicationName: applicationName,
            contract: contract,
            enableValidation: false
        )
    else {
        throw VulkanLaneTestFailure.instance(presentation)
    }
    guard
        let selection = unsafe DeviceOwner.selectPhysicalDevice(
            instance: instance.handle,
            dispatch: instance.dispatch,
            contract: contract,
            queueFamilyPresentationSupport: queueFamilyQualification
        )
    else {
        throw VulkanLaneTestFailure.physicalDevice(presentation)
    }
    guard
        let device = unsafe DeviceOwner.create(
            selection: selection,
            instanceDispatch: instance.dispatch,
            contract: contract
        )
    else {
        throw VulkanLaneTestFailure.logicalDevice(presentation)
    }
    guard let queue = unsafe device.queue(family: selection.graphicsQueueFamily) else {
        throw VulkanLaneTestFailure.graphicsQueue
    }

    var context = unsafe withCStringArray(contract.deviceExtensions) { extensions, count in
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
        throw VulkanLaneTestFailure.graphiteContext
    }

    func useRecorder(
        _ body: (
            borrowing DeviceOwner,
            DeviceOwner.PhysicalSelection,
            nucleus.skia.GraphiteContext,
            nucleus.skia.Recorder
        ) throws -> Result
    ) throws -> Result {
        let recorder = unsafe context.makeRecorder()
        guard unsafe recorder.isValid() else {
            throw VulkanLaneTestFailure.graphiteRecorder
        }
        return try unsafe body(device, selection, context, recorder)
    }

    do {
        let result = try unsafe useRecorder(body)
        unsafe context.reset()
        return result
    } catch {
        unsafe context.reset()
        throw error
    }
}
