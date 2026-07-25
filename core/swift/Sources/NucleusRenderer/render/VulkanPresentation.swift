import Vulkan
public import VulkanC

/// Opaque, non-owning Vulkan tokens passed across the renderer's platform-host
/// boundary. The unchecked sendability covers only immutable pointer bits:
/// construction and dereference remain platform SPI operations, and the
/// originating `VulkanBootstrap`/`VulkanSurface` lifetime must encompass every
/// use. No mutable Vulkan state is accessed through these values directly.
@safe public struct VulkanInstanceHandle: @unchecked Sendable {
    private let raw: UnsafeRawPointer
    @_spi(NucleusPlatform) public init(_ value: VkInstance) {
        unsafe raw = UnsafeRawPointer(value)
    }
    @_spi(NucleusPlatform) public var vkInstance: VkInstance {
        unsafe OpaquePointer(raw)
    }
}

@safe public struct VulkanPhysicalDeviceHandle: @unchecked Sendable {
    private let raw: UnsafeRawPointer
    @_spi(NucleusPlatform) public init(_ value: VkPhysicalDevice) {
        unsafe raw = UnsafeRawPointer(value)
    }
    @_spi(NucleusPlatform) public var vkPhysicalDevice: VkPhysicalDevice {
        unsafe OpaquePointer(raw)
    }
}

@safe public struct VulkanSurfaceHandle: @unchecked Sendable {
    private let raw: UnsafeRawPointer
    @_spi(NucleusPlatform) public init(_ value: VkSurfaceKHR) {
        unsafe raw = UnsafeRawPointer(value)
    }
    @_spi(NucleusPlatform) public var vkSurface: VkSurfaceKHR {
        unsafe OpaquePointer(raw)
    }
}

public typealias VulkanSurfaceFactory = (VulkanInstanceHandle) -> VulkanSurfaceHandle?
public typealias VulkanQueuePresentationProbe = (
    VulkanInstanceHandle, VulkanPhysicalDeviceHandle, UInt32
) -> Bool

/// The platform-specific evidence required while selecting the graphics queue.
public enum VulkanPresentationQualification {
    case none
    case platformProbe(VulkanQueuePresentationProbe)
    case surface(VulkanSurface)
}

final class VulkanInstanceLifetime {
    var owner: InstanceOwner?
    init(instance: consuming InstanceOwner) { owner = consume instance }
}

/// Owns one platform VkSurfaceKHR. It is created through the same factory path
/// on every WSI platform and must be released before its originating instance.
@MainActor
/// Encapsulates a surface handle while retaining its originating instance owner.
@safe public final class VulkanSurface {
    let instance: VkInstance
    let dispatch: VK.InstanceDispatch
    let handle: VkSurfaceKHR
    private let lifetime: VulkanInstanceLifetime

    init(
        lifetime: VulkanInstanceLifetime, instance: VkInstance,
        dispatch: VK.InstanceDispatch, handle: VkSurfaceKHR
    ) {
        self.lifetime = lifetime
        unsafe self.instance = instance
        self.dispatch = dispatch
        unsafe self.handle = handle
    }

    isolated deinit {
        unsafe dispatch.vkDestroySurfaceKHR?(instance, handle, nil)
    }
}

/// Instance-only bring-up. Android creates its real surface at this stage before
/// device selection; platforms with a pre-surface query finalize via a probe.
@MainActor
public final class VulkanBootstrap {
    let contract: VkRequirements.Contract
    let instanceLifetime: VulkanInstanceLifetime
    var finalized = false

    private init(contract: VkRequirements.Contract, instance: consuming InstanceOwner) {
        self.contract = contract
        self.instanceLifetime = VulkanInstanceLifetime(instance: consume instance)
    }

    public static func create(
        applicationName: String,
        presentation: VkRequirements.PresentationMode = .platformDefault,
        enableValidation: Bool = false
    ) -> VulkanBootstrap? {
        let contract = VkRequirements.contract(for: presentation)
        guard let instance = unsafe InstanceOwner.create(
            base: VK.loadBaseDispatch(), applicationName: applicationName,
            contract: contract, enableValidation: enableValidation
        ) else { return nil }
        return VulkanBootstrap(contract: contract, instance: consume instance)
    }

    public func createSurface(_ factory: VulkanSurfaceFactory) -> VulkanSurface? {
        guard !finalized else { return nil }
        guard let instance = unsafe instanceLifetime.owner?.handle,
              let dispatch = instanceLifetime.owner?.dispatch
        else { return nil }
        guard let token = unsafe factory(VulkanInstanceHandle(instance)) else {
            return nil
        }
        return unsafe VulkanSurface(
            lifetime: instanceLifetime, instance: instance, dispatch: dispatch,
            handle: token.vkSurface)
    }
}
