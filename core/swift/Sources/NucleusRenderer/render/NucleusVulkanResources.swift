//
// The generic ergonomic helpers (VkOwned, VkOwnedImageBox, withCStringArray,
// device-child constructors) live in swift-vulkan (VulkanErgonomics.swift) and
// are available via the re-export in NucleusVulkanSupport.

import VulkanC
import Vulkan

// MARK: - Structure chains

/// Fixed structure chain: enable the contract's required modern features on a
/// `VkPhysicalDeviceFeatures2` head linked to the 1.1/1.2 feature structs, and
/// invoke `body` with a borrowed pointer to the head. No pNext escapes `body`.
public func withRequiredFeatureChain<R>(
    contract: VkRequirements.Contract,
    enableRequiredFeatures: Bool = true,
    _ body: (UnsafePointer<VkPhysicalDeviceFeatures2>) -> R
) -> R {
    var v12 = VkPhysicalDeviceVulkan12Features()
    v12.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES
    v12.timelineSemaphore = enableRequiredFeatures && contract.requiresTimelineSemaphore ? 1 : 0
    var feats = VkPhysicalDeviceFeatures2()
    feats.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2

    return withUnsafeMutablePointer(to: &v12) { p12 -> R in
        func withYcbcrChain(_ tail: UnsafeMutableRawPointer?) -> R {
            p12.pointee.pNext = tail
            feats.pNext = UnsafeMutableRawPointer(p12)
            return withUnsafePointer(to: &feats) { body($0) }
        }
        func withOptionalYcbcr(_ tail: UnsafeMutableRawPointer?) -> R {
            guard contract.requiresSamplerYcbcrConversion else { return withYcbcrChain(tail) }
            var v11 = VkPhysicalDeviceVulkan11Features()
            v11.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES
            v11.samplerYcbcrConversion = enableRequiredFeatures ? 1 : 0
            return withUnsafeMutablePointer(to: &v11) { p11 -> R in
                p11.pointee.pNext = tail
                return withYcbcrChain(UnsafeMutableRawPointer(p11))
            }
        }
        guard contract.requiresSwapchainMaintenance1 else { return withOptionalYcbcr(nil) }
        var maintenance = VkPhysicalDeviceSwapchainMaintenance1FeaturesKHR()
        maintenance.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SWAPCHAIN_MAINTENANCE_1_FEATURES_KHR
        maintenance.swapchainMaintenance1 = enableRequiredFeatures ? 1 : 0
        return withUnsafeMutablePointer(to: &maintenance) { pointer in
            withOptionalYcbcr(UnsafeMutableRawPointer(pointer))
        }
    }
}

private func extensionName(_ property: VkExtensionProperties) -> String {
    var name = property.extensionName
    return withUnsafeBytes(of: &name) { bytes in
        let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
        return String(decoding: bytes[..<end], as: UTF8.self)
    }
}

private func supportsExtensions(
    _ required: [String],
    enumerate: (_ count: UnsafeMutablePointer<UInt32>, _ out: UnsafeMutablePointer<VkExtensionProperties>?) -> VkResult
) -> Bool {
    guard let properties = VkEnumerate.array(enumerate) else { return false }
    let available = Set(properties.map(extensionName))
    return required.allSatisfy(available.contains)
}

private func supportsFeatures(
    physicalDevice: VkPhysicalDevice,
    dispatch: VK.InstanceDispatch,
    contract: VkRequirements.Contract
) -> Bool {
    guard let getFeatures = dispatch.vkGetPhysicalDeviceFeatures2 else { return false }
    var supported = false
    withRequiredFeatureChain(contract: contract, enableRequiredFeatures: false) { pointer in
        let mutable = UnsafeMutablePointer(mutating: pointer)
        getFeatures(physicalDevice, mutable)
        var feature = mutable.pointee.pNext
        var timeline = !contract.requiresTimelineSemaphore
        var ycbcr = !contract.requiresSamplerYcbcrConversion
        var maintenance = !contract.requiresSwapchainMaintenance1
        while let raw = feature {
            let header = raw.assumingMemoryBound(to: VkBaseOutStructure.self)
            switch header.pointee.sType {
            case VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES:
                timeline = raw.assumingMemoryBound(
                    to: VkPhysicalDeviceVulkan12Features.self).pointee.timelineSemaphore != 0
            case VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES:
                ycbcr = raw.assumingMemoryBound(
                    to: VkPhysicalDeviceVulkan11Features.self).pointee.samplerYcbcrConversion != 0
            case VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SWAPCHAIN_MAINTENANCE_1_FEATURES_KHR:
                maintenance = raw.assumingMemoryBound(
                    to: VkPhysicalDeviceSwapchainMaintenance1FeaturesKHR.self
                ).pointee.swapchainMaintenance1 != 0
            default: break
            }
            feature = UnsafeMutableRawPointer(header.pointee.pNext)
        }
        supported = timeline && ycbcr && maintenance
    }
    return supported
}

// MARK: - Instance owner

public struct InstanceOwner: ~Copyable {
    public let handle: VkInstance
    public let dispatch: VK.InstanceDispatch

    public init(adopting handle: VkInstance, dispatch: VK.InstanceDispatch) {
        self.handle = handle
        self.dispatch = dispatch
    }

    deinit { dispatch.vkDestroyInstance?(handle, nil) }

    /// Create the Nucleus instance with the given extensions (and optionally the
    /// Khronos validation layer). Returns nil on any failure.
    public static func create(
        base: VK.BaseDispatch,
        applicationName: String,
        contract: VkRequirements.Contract,
        enableValidation: Bool
    ) -> InstanceOwner? {
        guard let createFn = base.vkCreateInstance,
              let enumerateVersion = base.vkEnumerateInstanceVersion,
              let enumerateExtensions = base.vkEnumerateInstanceExtensionProperties
        else { return nil }
        var loaderVersion: UInt32 = 0
        guard enumerateVersion(&loaderVersion) == VK_SUCCESS,
              VkVersion(raw: loaderVersion) >= contract.minimumApiVersion,
              supportsExtensions(contract.instanceExtensions, enumerate: { count, out in
                  enumerateExtensions(nil, count, out)
              })
        else { return nil }
        let layers = enableValidation ? ["VK_LAYER_KHRONOS_validation"] : []

        // Create inside the borrowed-CString scopes, but capture only the
        // (copyable) handle out — a noncopyable owner cannot be returned through
        // the Copyable-constrained `withCString` generics.
        var created: VkInstance? = nil
        applicationName.withCString { appName in
            var app = VkApplicationInfo()
            app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO
            app.pApplicationName = appName
            app.apiVersion = contract.minimumApiVersion.raw

            withCStringArray(contract.instanceExtensions) { extPtr, extCount in
                withCStringArray(layers) { layerPtr, layerCount in
                    withUnsafePointer(to: &app) { appPtr in
                        var ci = VkInstanceCreateInfo()
                        ci.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
                        ci.pApplicationInfo = appPtr
                        ci.enabledExtensionCount = extCount
                        ci.ppEnabledExtensionNames = extPtr
                        ci.enabledLayerCount = layerCount
                        ci.ppEnabledLayerNames = layerPtr

                        var inst: VkInstance? = nil
                        if createFn(&ci, nil, &inst) == VK_SUCCESS { created = inst }
                    }
                }
            }
        }
        guard let inst = created else { return nil }
        let hasEntryPoints = contract.requiredInstanceEntryPoints.allSatisfy { name in
            name.withCString { base.vkGetInstanceProcAddr(inst, $0) != nil }
        }
        guard hasEntryPoints else {
            let dispatch = VK.InstanceDispatch(inst, loader: base.vkGetInstanceProcAddr)
            dispatch.vkDestroyInstance?(inst, nil)
            return nil
        }
        let dispatch = VK.InstanceDispatch(inst, loader: base.vkGetInstanceProcAddr)
        return InstanceOwner(adopting: inst, dispatch: dispatch)
    }
}

// MARK: - Device owner

public struct DeviceOwner: ~Copyable {
    public let handle: VkDevice
    public let dispatch: VK.DeviceDispatch

    public init(adopting handle: VkDevice, dispatch: VK.DeviceDispatch) {
        self.handle = handle
        self.dispatch = dispatch
    }

    deinit { dispatch.vkDestroyDevice?(handle, nil) }

    /// Fetch a queue from a created device (handle is borrowed from the device).
    public func queue(family: UInt32, index: UInt32 = 0) -> VkQueue? {
        guard let get = dispatch.vkGetDeviceQueue else { return nil }
        var q: VkQueue? = nil
        get(handle, family, index, &q)
        return q
    }

    /// A physical device plus the graphics queue family chosen for it.
    public struct PhysicalSelection {
        public var physicalDevice: VkPhysicalDevice
        public var graphicsQueueFamily: UInt32
    }

    /// Pick the first physical device satisfying the complete Nucleus contract.
    /// Incompatible devices are never returned and are not retried through a
    /// reduced extension/feature set.
    public static func selectPhysicalDevice(
        instance: VkInstance,
        dispatch: VK.InstanceDispatch,
        contract: VkRequirements.Contract,
        requiredPresentationSurface: VkSurfaceKHR? = nil,
        queueFamilyPresentationSupport: ((VkInstance, VkPhysicalDevice, UInt32) -> Bool)? = nil
    ) -> PhysicalSelection? {
        guard let enumerate = dispatch.vkEnumeratePhysicalDevices,
              let queueProps = dispatch.vkGetPhysicalDeviceQueueFamilyProperties,
              let getProperties = dispatch.vkGetPhysicalDeviceProperties,
              let enumerateExtensions = dispatch.vkEnumerateDeviceExtensionProperties
        else { return nil }

        guard let devices = VkEnumerate.array({ count, out in
            enumerate(instance, count, out)
        }) else { return nil }

        for case let device? in devices {
            var properties = VkPhysicalDeviceProperties()
            getProperties(device, &properties)
            guard VkVersion(raw: properties.apiVersion) >= contract.minimumApiVersion,
                  supportsExtensions(contract.deviceExtensions, enumerate: { count, out in
                      enumerateExtensions(device, nil, count, out)
                  }),
                  supportsFeatures(physicalDevice: device, dispatch: dispatch, contract: contract)
            else { continue }
            var count: UInt32 = 0
            queueProps(device, &count, nil)
            if count == 0 { continue }
            var families = [VkQueueFamilyProperties](repeating: VkQueueFamilyProperties(), count: Int(count))
            queueProps(device, &count, &families)
            for (index, family) in families.enumerated() {
                guard family.queueFlags & VK.QueueFlags.graphicsBit.rawValue != 0 else { continue }
                let familyIndex = UInt32(index)
                if let requiredPresentationSurface {
                    guard let getSurfaceSupport = dispatch.vkGetPhysicalDeviceSurfaceSupportKHR else {
                        continue
                    }
                    var supported: VkBool32 = 0
                    guard getSurfaceSupport(
                        device, familyIndex, requiredPresentationSurface, &supported) == VK_SUCCESS,
                        supported != 0
                    else { continue }
                }
                if let queueFamilyPresentationSupport,
                   !queueFamilyPresentationSupport(instance, device, familyIndex) {
                    continue
                }
                return PhysicalSelection(physicalDevice: device, graphicsQueueFamily: familyIndex)
            }
        }
        return nil
    }

    /// Create a logical device on `selection` with the required extensions and
    /// modern feature chain. Returns nil on failure (e.g. a required extension or
    /// feature is unsupported) — fail-closed, no fallback.
    public static func create(
        selection: PhysicalSelection,
        instanceDispatch: VK.InstanceDispatch,
        contract: VkRequirements.Contract
    ) -> DeviceOwner? {
        guard let createFn = instanceDispatch.vkCreateDevice,
              let deviceLoader = instanceDispatch.vkGetDeviceProcAddr
        else { return nil }

        var created: VkDevice? = nil
        var priority: Float = 1.0
        withUnsafePointer(to: &priority) { priorityPtr in
            var queueInfo = VkDeviceQueueCreateInfo()
            queueInfo.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
            queueInfo.queueFamilyIndex = selection.graphicsQueueFamily
            queueInfo.queueCount = 1
            queueInfo.pQueuePriorities = priorityPtr

            withUnsafePointer(to: &queueInfo) { queuePtr in
                withRequiredFeatureChain(
                    contract: contract
                ) { featuresPtr in
                    withCStringArray(contract.deviceExtensions) { extPtr, extCount in
                        var ci = VkDeviceCreateInfo()
                        ci.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
                        ci.pNext = UnsafeRawPointer(featuresPtr)
                        ci.queueCreateInfoCount = 1
                        ci.pQueueCreateInfos = queuePtr
                        ci.enabledExtensionCount = extCount
                        ci.ppEnabledExtensionNames = extPtr

                        var device: VkDevice? = nil
                        if createFn(selection.physicalDevice, &ci, nil, &device) == VK_SUCCESS {
                            created = device
                        }
                    }
                }
            }
        }
        guard let device = created else { return nil }
        let dispatch = VK.DeviceDispatch(device, loader: deviceLoader)
        let hasEntryPoints = contract.requiredDeviceEntryPoints.allSatisfy { name in
            name.withCString { deviceLoader(device, $0) != nil }
        }
        guard hasEntryPoints else {
            dispatch.vkDestroyDevice?(device, nil)
            return nil
        }
        return DeviceOwner(adopting: device, dispatch: dispatch)
    }
}
