@_spi(NucleusPlatform) internal import NucleusRenderer
internal import VulkanC
import WaylandClientC

// The one Wayland-specific piece of the shell's render path: creating a VkSurfaceKHR for a
// client wl_surface via VK_KHR_wayland_surface. Everything else — the swapchain create/acquire/
// present/recreate machinery — is the shared `SwapchainPresenter` in NucleusRenderer, the same
// implementation the Android host uses. This supplies the shared `VulkanSurface`
// factory used before constructing a presenter.
@MainActor
enum WaylandVulkanSurface {
    /// Pre-surface queue-family qualification used during physical-device
    /// selection. A device that cannot present to this wl_display is never used
    /// to create the shared render core.
    static func supportsPresentation(
        instance: VulkanInstanceHandle, physicalDevice: VulkanPhysicalDeviceHandle,
        queueFamily: UInt32, display: OpaquePointer
    ) -> Bool {
        guard let raw = vkGetInstanceProcAddr(
            instance.vkInstance, "vkGetPhysicalDeviceWaylandPresentationSupportKHR")
        else { return false }
        let query = unsafeBitCast(
            raw, to: PFN_vkGetPhysicalDeviceWaylandPresentationSupportKHR.self)
        return query(physicalDevice.vkPhysicalDevice, queueFamily, display) != 0
    }

    /// Create a Wayland WSI surface. `display` is the client's wl_display, `surface` the client
    /// wl_surface the panel presents onto. Returns nil if the WSI entry point or create fails.
    static func make(instance: VulkanInstanceHandle, display: OpaquePointer, surface: OpaquePointer) -> VulkanSurfaceHandle? {
        guard let raw = vkGetInstanceProcAddr(instance.vkInstance, "vkCreateWaylandSurfaceKHR") else { return nil }
        let createFn = unsafeBitCast(raw, to: PFN_vkCreateWaylandSurfaceKHR.self)
        var sci = VkWaylandSurfaceCreateInfoKHR()
        sci.sType = VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR
        sci.display = display
        sci.surface = surface
        var surf: VkSurfaceKHR? = nil
        guard createFn(instance.vkInstance, &sci, nil, &surf) == VK_SUCCESS, let surf else { return nil }
        return VulkanSurfaceHandle(surf)
    }
}
