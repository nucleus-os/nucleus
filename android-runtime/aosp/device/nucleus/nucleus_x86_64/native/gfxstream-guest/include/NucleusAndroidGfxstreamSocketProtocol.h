#ifndef NUCLEUS_ANDROID_GFXSTREAM_SOCKET_PROTOCOL_H
#define NUCLEUS_ANDROID_GFXSTREAM_SOCKET_PROTOCOL_H

#include <stdint.h>

#define NUCLEUS_ANDROID_GFXSTREAM_SOCKET_MAGIC UINT32_C(0x4e475846)
#define NUCLEUS_ANDROID_GFXSTREAM_SOCKET_VERSION UINT32_C(7)
#define NUCLEUS_ANDROID_GFXSTREAM_DESCRIPTOR_COUNT 6

enum nucleus_android_gfxstream_cpu_access {
    NUCLEUS_ANDROID_GFXSTREAM_CPU_ACCESS_READ = 1u << 0,
    NUCLEUS_ANDROID_GFXSTREAM_CPU_ACCESS_WRITE = 1u << 1,
};

enum nucleus_android_gfxstream_socket_operation {
    NUCLEUS_ANDROID_GFXSTREAM_OPEN_STREAM = 1,
    NUCLEUS_ANDROID_GFXSTREAM_ALLOCATE_BUFFER = 2,
    NUCLEUS_ANDROID_GFXSTREAM_MAP_HOST_MEMORY = 3,
    NUCLEUS_ANDROID_GFXSTREAM_EXPORT_VULKAN_FENCE = 4,
    NUCLEUS_ANDROID_GFXSTREAM_EXPORT_VULKAN_SEMAPHORE = 5,
    NUCLEUS_ANDROID_GFXSTREAM_EXPORT_VULKAN_QSRI = 6,
    NUCLEUS_ANDROID_GFXSTREAM_LOCK_BUFFER = 7,
    NUCLEUS_ANDROID_GFXSTREAM_UNLOCK_BUFFER = 8,
    NUCLEUS_ANDROID_GFXSTREAM_SYNC_BUFFER = 9,
};

struct nucleus_android_gfxstream_socket_message {
    uint32_t magic;
    uint32_t version;
    uint32_t operation;
    int32_t status;
    uint64_t allocation_id;
    uint64_t usage;
    uint64_t drm_modifier;
    uint64_t allocation_size;
    uint64_t vulkan_device_handle;
    uint64_t vulkan_fence_handle;
    uint64_t vulkan_semaphore_handle;
    uint64_t vulkan_image_handle;
    uint64_t cpu_lock_id;
    uint64_t cpu_mapping_size;
    uint32_t width;
    uint32_t height;
    uint32_t android_format;
    uint32_t drm_format;
    uint32_t plane_offset;
    uint32_t plane_stride;
    uint32_t color_buffer_handle;
    uint32_t cpu_access;
    uint32_t cpu_stride;
    uint32_t reserved;
};

#endif
