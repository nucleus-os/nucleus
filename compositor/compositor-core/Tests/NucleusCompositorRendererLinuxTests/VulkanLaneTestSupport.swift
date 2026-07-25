import Glibc
import NucleusSkiaGraphiteBridge
@testable import NucleusRenderer
import Vulkan
import VulkanC

/// The process Vulkan loader and installed ICDs are shared by every suite in this
/// test product. Swift Testing runs suites concurrently, but concurrent loader
/// initialization has crashed inside `vkGetInstanceProcAddr`/ICD discovery on the
/// mandatory Linux lane. Keep each complete instance → device → Graphite lifetime
/// exclusive so teardown finishes before another suite initializes the loader.
private let requiredVulkanGraphiteGate = VulkanGraphiteTestGate()

private final class VulkanGraphiteTestGate: @unchecked Sendable {
    private var mutex = pthread_mutex_t()

    init() {
        precondition(pthread_mutex_init(&mutex, nil) == 0)
    }

    deinit {
        precondition(pthread_mutex_destroy(&mutex) == 0)
    }

    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        precondition(pthread_mutex_lock(&mutex) == 0)
        defer { precondition(pthread_mutex_unlock(&mutex) == 0) }
        return try body()
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
    queueFamilyQualification: ((
        VkInstance, VkPhysicalDevice, UInt32
    ) -> Bool)? = nil,
    _ body: (
        borrowing DeviceOwner,
        DeviceOwner.PhysicalSelection,
        nucleus.skia.GraphiteContext,
        nucleus.skia.Recorder
    ) throws -> Result
) throws -> Result {
    try requiredVulkanGraphiteGate.withLock {
        try withExclusiveRequiredVulkanGraphite(
            presentation: presentation,
            applicationName: applicationName,
            queueFamilyQualification: queueFamilyQualification,
            body)
    }
}

private func withExclusiveRequiredVulkanGraphite<Result>(
    presentation: VkRequirements.PresentationMode,
    applicationName: String,
    queueFamilyQualification: ((
        VkInstance, VkPhysicalDevice, UInt32
    ) -> Bool)?,
    _ body: (
        borrowing DeviceOwner,
        DeviceOwner.PhysicalSelection,
        nucleus.skia.GraphiteContext,
        nucleus.skia.Recorder
    ) throws -> Result
) throws -> Result {
    let contract = VkRequirements.contract(for: presentation)
    guard let instance = InstanceOwner.create(
        base: VK.loadBaseDispatch(),
        applicationName: applicationName,
        contract: contract,
        enableValidation: false
    ) else {
        throw VulkanLaneTestFailure.instance(presentation)
    }
    guard let selection = DeviceOwner.selectPhysicalDevice(
        instance: instance.handle,
        dispatch: instance.dispatch,
        contract: contract,
        queueFamilyPresentationSupport: queueFamilyQualification
    ) else {
        throw VulkanLaneTestFailure.physicalDevice(presentation)
    }
    guard let device = DeviceOwner.create(
        selection: selection,
        instanceDispatch: instance.dispatch,
        contract: contract
    ) else {
        throw VulkanLaneTestFailure.logicalDevice(presentation)
    }
    guard let queue = device.queue(family: selection.graphicsQueueFamily) else {
        throw VulkanLaneTestFailure.graphicsQueue
    }

    var context = withCStringArray(contract.deviceExtensions) { extensions, count in
        var descriptor = nucleus.skia.VulkanContextDescriptor()
        descriptor.instance = UnsafeMutableRawPointer(instance.handle)
        descriptor.physicalDevice = UnsafeMutableRawPointer(selection.physicalDevice)
        descriptor.device = UnsafeMutableRawPointer(device.handle)
        descriptor.queue = UnsafeMutableRawPointer(queue)
        descriptor.graphicsQueueIndex = selection.graphicsQueueFamily
        descriptor.maxApiVersion = contract.minimumApiVersion.raw
        descriptor.deviceExtensions = extensions
        descriptor.deviceExtensionCount = count
        return nucleus.skia.makeGraphiteVulkanContext(descriptor)
    }
    guard context.isValid() else {
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
        let recorder = context.makeRecorder()
        guard recorder.isValid() else {
            throw VulkanLaneTestFailure.graphiteRecorder
        }
        return try body(device, selection, context, recorder)
    }

    do {
        let result = try useRecorder(body)
        context.reset()
        return result
    } catch {
        context.reset()
        throw error
    }
}
