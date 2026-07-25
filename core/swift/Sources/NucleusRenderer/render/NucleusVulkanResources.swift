//
// The generic ergonomic helpers (VkOwned, VkOwnedImageBox, withCStringArray,
// device-child constructors) live in swift-vulkan (VulkanErgonomics.swift) and
// are available via the re-export in NucleusVulkanSupport.

public import VulkanC
public import Vulkan

// MARK: - Structure chains

/// Build the mutable feature chain shared by query and enable operations.
/// Every pointer is aligned for its concrete Vulkan structure and remains valid
/// only for `body`; no `pNext` or head pointer may escape the closure.
@unsafe private func withRequiredMutableFeatureChain<R>(
    contract: VkRequirements.Contract,
    enableRequiredFeatures: Bool,
    _ body: (UnsafeMutablePointer<VkPhysicalDeviceFeatures2>) -> R
) -> R {
    var v12 = unsafe VkPhysicalDeviceVulkan12Features()
    unsafe v12.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES
    unsafe v12.timelineSemaphore = enableRequiredFeatures && contract.requiresTimelineSemaphore ? 1 : 0
    var feats = unsafe VkPhysicalDeviceFeatures2()
    unsafe feats.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2

    return withUnsafeMutablePointer(to: &v12) { p12 -> R in
        func withYcbcrChain(_ tail: UnsafeMutableRawPointer?) -> R {
            unsafe p12.pointee.pNext = unsafe tail
            unsafe feats.pNext = UnsafeMutableRawPointer(p12)
            return withUnsafeMutablePointer(to: &feats) { unsafe body($0) }
        }
        func withOptionalYcbcr(_ tail: UnsafeMutableRawPointer?) -> R {
            guard contract.requiresSamplerYcbcrConversion else { return unsafe withYcbcrChain(tail) }
            var v11 = unsafe VkPhysicalDeviceVulkan11Features()
            unsafe v11.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES
            unsafe v11.samplerYcbcrConversion = enableRequiredFeatures ? 1 : 0
            return withUnsafeMutablePointer(to: &v11) { p11 -> R in
                unsafe p11.pointee.pNext = unsafe tail
                return unsafe withYcbcrChain(UnsafeMutableRawPointer(p11))
            }
        }
        guard contract.requiresSwapchainMaintenance1 else { return withOptionalYcbcr(nil) }
        var maintenance = unsafe VkPhysicalDeviceSwapchainMaintenance1FeaturesKHR()
        unsafe maintenance.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SWAPCHAIN_MAINTENANCE_1_FEATURES_KHR
        unsafe maintenance.swapchainMaintenance1 = enableRequiredFeatures ? 1 : 0
        return withUnsafeMutablePointer(to: &maintenance) { pointer in
            unsafe withOptionalYcbcr(UnsafeMutableRawPointer(pointer))
        }
    }
}

/// Supply a writable feature chain to `vkGetPhysicalDeviceFeatures2`.
/// Vulkan may mutate every structure in the chain; no pointer may escape.
@unsafe public func withRequiredFeatureQueryChain<R>(
    contract: VkRequirements.Contract,
    _ body: (UnsafeMutablePointer<VkPhysicalDeviceFeatures2>) -> R
) -> R {
    unsafe withRequiredMutableFeatureChain(
        contract: contract,
        enableRequiredFeatures: false,
        body)
}

/// Supply an immutable, fully enabled feature chain to `vkCreateDevice`.
/// The borrowed pointer and every `pNext` node remain valid only for `body`.
@unsafe public func withRequiredFeatureEnableChain<R>(
    contract: VkRequirements.Contract,
    _ body: (UnsafePointer<VkPhysicalDeviceFeatures2>) -> R
) -> R {
    unsafe withRequiredMutableFeatureChain(
        contract: contract,
        enableRequiredFeatures: true
    ) { mutableHead in
        unsafe body(UnsafePointer(mutableHead))
    }
}

@unsafe private func extensionName(_ property: VkExtensionProperties) -> String {
    var name = property.extensionName
    return withUnsafeBytes(of: &name) { bytes in
        let end = unsafe bytes.firstIndex(of: 0) ?? bytes.endIndex
        return unsafe String(decoding: bytes[..<end], as: UTF8.self)
    }
}

@unsafe private func supportsExtensions(
    _ required: [String],
    enumerate: (_ count: UnsafeMutablePointer<UInt32>, _ out: UnsafeMutablePointer<VkExtensionProperties>?) -> VkResult
) -> Bool {
    guard let properties = unsafe VkEnumerate.array(enumerate) else { return false }
    let available = unsafe Set(properties.map(extensionName))
    return required.allSatisfy(available.contains)
}

@unsafe private func supportsFeatures(
    physicalDevice: VkPhysicalDevice,
    dispatch: VK.InstanceDispatch,
    contract: VkRequirements.Contract
) -> Bool {
    guard let getFeatures = unsafe dispatch.vkGetPhysicalDeviceFeatures2 else { return false }
    var supported = false
    unsafe withRequiredFeatureQueryChain(contract: contract) { pointer in
        unsafe getFeatures(physicalDevice, pointer)
        var feature = unsafe pointer.pointee.pNext
        var timeline = !contract.requiresTimelineSemaphore
        var ycbcr = !contract.requiresSamplerYcbcrConversion
        var maintenance = !contract.requiresSwapchainMaintenance1
        while let raw = unsafe feature {
            let header = unsafe raw.assumingMemoryBound(to: VkBaseOutStructure.self)
            switch unsafe header.pointee.sType {
            case VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES:
                timeline = unsafe raw.assumingMemoryBound(
                    to: VkPhysicalDeviceVulkan12Features.self).pointee.timelineSemaphore != 0
            case VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES:
                ycbcr = unsafe raw.assumingMemoryBound(
                    to: VkPhysicalDeviceVulkan11Features.self).pointee.samplerYcbcrConversion != 0
            case VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SWAPCHAIN_MAINTENANCE_1_FEATURES_KHR:
                maintenance = unsafe raw.assumingMemoryBound(
                    to: VkPhysicalDeviceSwapchainMaintenance1FeaturesKHR.self
                ).pointee.swapchainMaintenance1 != 0
            default: break
            }
            unsafe feature = unsafe UnsafeMutableRawPointer(header.pointee.pNext)
        }
        supported = timeline && ycbcr && maintenance
    }
    return supported
}

// MARK: - Instance owner

/// Owns the instance handle and destroys it exactly once after all child
/// devices and surfaces have been released.
@safe public struct InstanceOwner: ~Copyable {
    public let handle: VkInstance
    public let dispatch: VK.InstanceDispatch

    @unsafe public init(adopting handle: VkInstance, dispatch: VK.InstanceDispatch) {
        unsafe self.handle = unsafe handle
        self.dispatch = dispatch
    }

    @unsafe deinit { unsafe dispatch.vkDestroyInstance?(handle, nil) }

    /// Create the Nucleus instance with the given extensions (and optionally the
    /// Khronos validation layer). Returns nil on any failure.
    @unsafe public static func create(
        base: VK.BaseDispatch,
        applicationName: String,
        contract: VkRequirements.Contract,
        enableValidation: Bool
    ) -> InstanceOwner? {
        guard let createFn = unsafe base.vkCreateInstance,
              let enumerateVersion = unsafe base.vkEnumerateInstanceVersion,
              let enumerateExtensions = unsafe base.vkEnumerateInstanceExtensionProperties
        else { return nil }
        var loaderVersion: UInt32 = 0
        guard unsafe enumerateVersion(&loaderVersion) == VK_SUCCESS,
              VkVersion(raw: loaderVersion) >= contract.minimumApiVersion,
              unsafe supportsExtensions(contract.instanceExtensions, enumerate: { count, out in
                  unsafe enumerateExtensions(nil, count, out)
              })
        else { return nil }
        let layers = enableValidation ? ["VK_LAYER_KHRONOS_validation"] : []

        // Create inside the borrowed-CString scopes, but capture only the
        // (copyable) handle out — a noncopyable owner cannot be returned through
        // the Copyable-constrained `withCString` generics.
        var created: VkInstance? = nil
        applicationName.withCString { appName in
            var app = unsafe VkApplicationInfo()
            unsafe app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO
            unsafe app.pApplicationName = unsafe appName
            unsafe app.apiVersion = contract.minimumApiVersion.raw

            unsafe withCStringArray(contract.instanceExtensions) { extPtr, extCount in
                unsafe withCStringArray(layers) { layerPtr, layerCount in
                    withUnsafePointer(to: &app) { appPtr in
                        var ci = unsafe VkInstanceCreateInfo()
                        unsafe ci.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
                        unsafe ci.pApplicationInfo = unsafe appPtr
                        unsafe ci.enabledExtensionCount = extCount
                        unsafe ci.ppEnabledExtensionNames = unsafe extPtr
                        unsafe ci.enabledLayerCount = layerCount
                        unsafe ci.ppEnabledLayerNames = unsafe layerPtr

                        var inst: VkInstance? = nil
                        if unsafe createFn(&ci, nil, &inst) == VK_SUCCESS { unsafe created = unsafe inst }
                    }
                }
            }
        }
        guard let inst = unsafe created else { return nil }
        let hasEntryPoints = contract.requiredInstanceEntryPoints.allSatisfy { name in
            name.withCString { unsafe base.vkGetInstanceProcAddr(inst, $0) != nil }
        }
        guard hasEntryPoints else {
            let dispatch = unsafe VK.InstanceDispatch(inst, loader: base.vkGetInstanceProcAddr)
            unsafe dispatch.vkDestroyInstance?(inst, nil)
            return nil
        }
        let dispatch = unsafe VK.InstanceDispatch(inst, loader: base.vkGetInstanceProcAddr)
        return unsafe InstanceOwner(adopting: inst, dispatch: dispatch)
    }
}

// MARK: - Device owner

/// Owns the device handle and destroys it exactly once; borrowed queues remain
/// valid only while this owner is alive.
@safe public struct DeviceOwner: ~Copyable {
    public let handle: VkDevice
    public let dispatch: VK.DeviceDispatch

    @unsafe public init(adopting handle: VkDevice, dispatch: VK.DeviceDispatch) {
        unsafe self.handle = unsafe handle
        self.dispatch = dispatch
    }

    @unsafe deinit { unsafe dispatch.vkDestroyDevice?(handle, nil) }

    /// Fetch a queue from a created device (handle is borrowed from the device).
    @unsafe public func queue(family: UInt32, index: UInt32 = 0) -> VkQueue? {
        guard let get = unsafe dispatch.vkGetDeviceQueue else { return nil }
        var q: VkQueue? = nil
        unsafe get(handle, family, index, &q)
        return unsafe q
    }

    /// A physical device plus the graphics queue family chosen for it.
    /// Borrows a physical-device handle from the instance supplied to
    /// `selectPhysicalDevice`; that instance must outlive every use.
    @safe public struct PhysicalSelection {
        public var physicalDevice: VkPhysicalDevice
        public var graphicsQueueFamily: UInt32
    }

    /// Pick the first physical device satisfying the complete Nucleus contract.
    /// Incompatible devices are never returned and are not retried through a
    /// reduced extension/feature set.
    @unsafe public static func selectPhysicalDevice(
        instance: VkInstance,
        dispatch: VK.InstanceDispatch,
        contract: VkRequirements.Contract,
        requiredPresentationSurface: VkSurfaceKHR? = nil,
        queueFamilyPresentationSupport: ((VkInstance, VkPhysicalDevice, UInt32) -> Bool)? = nil
    ) -> PhysicalSelection? {
        guard let enumerate = unsafe dispatch.vkEnumeratePhysicalDevices,
              let queueProps = unsafe dispatch.vkGetPhysicalDeviceQueueFamilyProperties,
              let getProperties = unsafe dispatch.vkGetPhysicalDeviceProperties,
              let enumerateExtensions = unsafe dispatch.vkEnumerateDeviceExtensionProperties
        else { return nil }

        guard let devices = unsafe VkEnumerate.array({ count, out in
            unsafe enumerate(instance, count, out)
        }) else { return nil }

        for index in unsafe devices.indices {
            guard let device = unsafe devices[index] else { continue }
            var properties = VkPhysicalDeviceProperties()
            unsafe getProperties(device, &properties)
            guard VkVersion(raw: properties.apiVersion) >= contract.minimumApiVersion,
                  unsafe supportsExtensions(contract.deviceExtensions, enumerate: { count, out in
                      unsafe enumerateExtensions(device, nil, count, out)
                  }),
                  unsafe supportsFeatures(physicalDevice: device, dispatch: dispatch, contract: contract)
            else { continue }
            var count: UInt32 = 0
            unsafe queueProps(device, &count, nil)
            if count == 0 { continue }
            var families = [VkQueueFamilyProperties](repeating: VkQueueFamilyProperties(), count: Int(count))
            unsafe queueProps(device, &count, &families)
            for (index, family) in families.enumerated() {
                guard family.queueFlags & VK.QueueFlags.graphicsBit.rawValue != 0 else { continue }
                let familyIndex = UInt32(index)
                if let requiredPresentationSurface = unsafe requiredPresentationSurface {
                    guard let getSurfaceSupport = unsafe dispatch.vkGetPhysicalDeviceSurfaceSupportKHR else {
                        continue
                    }
                    var supported: VkBool32 = 0
                    guard unsafe getSurfaceSupport(
                        device, familyIndex, requiredPresentationSurface, &supported) == VK_SUCCESS,
                        supported != 0
                    else { continue }
                }
                if let queueFamilyPresentationSupport = unsafe queueFamilyPresentationSupport,
                   unsafe !queueFamilyPresentationSupport(instance, device, familyIndex) {
                    continue
                }
                return unsafe PhysicalSelection(physicalDevice: device, graphicsQueueFamily: familyIndex)
            }
        }
        return nil
    }

    /// Create a logical device on `selection` with the required extensions and
    /// modern feature chain. Returns nil on failure (e.g. a required extension or
    /// feature is unsupported) — fail-closed, no fallback.
    @unsafe public static func create(
        selection: PhysicalSelection,
        instanceDispatch: VK.InstanceDispatch,
        contract: VkRequirements.Contract
    ) -> DeviceOwner? {
        guard let createFn = unsafe instanceDispatch.vkCreateDevice,
              let deviceLoader = unsafe instanceDispatch.vkGetDeviceProcAddr
        else { return nil }

        var created: VkDevice? = nil
        var priority: Float = 1.0
        withUnsafePointer(to: &priority) { priorityPtr in
            var queueInfo = unsafe VkDeviceQueueCreateInfo()
            unsafe queueInfo.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
            unsafe queueInfo.queueFamilyIndex = selection.graphicsQueueFamily
            unsafe queueInfo.queueCount = 1
            unsafe queueInfo.pQueuePriorities = unsafe priorityPtr

            withUnsafePointer(to: &queueInfo) { queuePtr in
                unsafe withRequiredFeatureEnableChain(
                    contract: contract
                ) { featuresPtr in
                    unsafe withCStringArray(contract.deviceExtensions) { extPtr, extCount in
                        var ci = unsafe VkDeviceCreateInfo()
                        unsafe ci.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
                        unsafe ci.pNext = unsafe UnsafeRawPointer(featuresPtr)
                        unsafe ci.queueCreateInfoCount = 1
                        unsafe ci.pQueueCreateInfos = unsafe queuePtr
                        unsafe ci.enabledExtensionCount = extCount
                        unsafe ci.ppEnabledExtensionNames = unsafe extPtr

                        var device: VkDevice? = nil
                        if unsafe createFn(selection.physicalDevice, &ci, nil, &device) == VK_SUCCESS {
                            unsafe created = unsafe device
                        }
                    }
                }
            }
        }
        guard let device = unsafe created else { return nil }
        let dispatch = unsafe VK.DeviceDispatch(device, loader: deviceLoader)
        let hasEntryPoints = contract.requiredDeviceEntryPoints.allSatisfy { name in
            name.withCString { unsafe deviceLoader(device, $0) != nil }
        }
        guard hasEntryPoints else {
            unsafe dispatch.vkDestroyDevice?(device, nil)
            return nil
        }
        return unsafe DeviceOwner(adopting: device, dispatch: dispatch)
    }
}
