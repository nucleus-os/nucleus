// VulkanC — the raw Vulkan C API imported below the generated
// Vulkan Swift layer. Core (no WSI) on Linux: the compositor reaches the
// surface/swapchain via DRM/GBM, not the Vulkan WSI extensions.
//
// On Android the presentation backend is a Vulkan swapchain over an
// ANativeWindow, so the Android-surface WSI is pulled in there (and only there —
// the include is platform-guarded, leaving the Linux compositor unchanged). The
// core VK_KHR_surface / VK_KHR_swapchain types live in vulkan_core.h already; the
// guarded header adds vkCreateAndroidSurfaceKHR + VkAndroidSurfaceCreateInfoKHR.
//
// Loader helpers can call global commands. Importer façades provide generated
// dispatch loading.
#ifndef VULKAN_C_H
#define VULKAN_C_H

// Quote-form includes resolve relative to this header, so the vendored
// Sources/VulkanC/vulkan headers are used regardless of any system Vulkan
// on the -I path (whose version may lag). Vulkan-Headers' own internal includes
// are already quote-form, so the whole tree resolves to the vendored copy.
#include "vulkan/vulkan_core.h"

#if defined(__ANDROID__)
#include "vulkan/vulkan_android.h"
#endif

// Import the Wayland WSI declarations when requested by a consumer. The platform header
// forward-declares `struct wl_display` and `struct wl_surface`, so consumers may provide
// their definitions by importing the Wayland client headers alongside this module.
#if defined(VK_USE_PLATFORM_WAYLAND_KHR)
#include "vulkan/vulkan_wayland.h"
#endif

#endif // VULKAN_C_H
