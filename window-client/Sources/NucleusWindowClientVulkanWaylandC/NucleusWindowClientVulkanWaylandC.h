#ifndef NUCLEUS_WINDOW_CLIENT_VULKAN_WAYLAND_C_H
#define NUCLEUS_WINDOW_CLIENT_VULKAN_WAYLAND_C_H

#include <stdint.h>

typedef int32_t (*nucleus_vk_create_wayland_surface_fn)(
    void *instance,
    const void *create_info,
    const void *allocator,
    void **surface);

typedef uint32_t (*nucleus_vk_wayland_presentation_support_fn)(
    void *physical_device,
    uint32_t queue_family,
    void *display);

struct nucleus_vk_wayland_surface_create_info {
    int32_t s_type;
    const void *p_next;
    uint32_t flags;
    void *display;
    void *surface;
};

static inline uint32_t
nucleus_vk_wayland_presentation_supported(
    void *function,
    void *physical_device,
    uint32_t queue_family,
    void *display) {
    return ((nucleus_vk_wayland_presentation_support_fn)function)(
        physical_device, queue_family, display);
}

static inline int32_t
nucleus_vk_create_wayland_surface(
    void *function,
    void *instance,
    void *display,
    void *wayland_surface,
    void **surface) {
    struct nucleus_vk_wayland_surface_create_info info = {
        .s_type = 1000006000,
        .p_next = 0,
        .flags = 0,
        .display = display,
        .surface = wayland_surface,
    };
    return ((nucleus_vk_create_wayland_surface_fn)function)(
        instance, &info, 0, surface);
}

#endif
