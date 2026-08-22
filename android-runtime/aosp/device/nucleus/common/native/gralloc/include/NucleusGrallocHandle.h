#pragma once

#include <cstdint>
#include <cutils/native_handle.h>

constexpr uint32_t NUCLEUS_GRALLOC_HANDLE_MAGIC = UINT32_C(0x4e475248);

struct nucleus_gralloc_handle : public native_handle_t {
    int32_t dmabuf_fd;
    int32_t lifetime_fd;
    uint32_t magic;
    uint32_t color_buffer_handle;
    uint64_t allocation_id;
    uint64_t usage;
    uint64_t drm_modifier;
    uint64_t allocation_size;
    uint32_t width;
    uint32_t height;
    uint32_t android_format;
    uint32_t drm_format;
    uint32_t plane_offset;
    uint32_t plane_stride;
    uint32_t pixel_stride;
    int32_t dataspace;
    int32_t blend_mode;
};

constexpr int NUCLEUS_GRALLOC_HANDLE_FDS = 2;
constexpr int NUCLEUS_GRALLOC_HANDLE_INTS =
    (sizeof(nucleus_gralloc_handle) - sizeof(native_handle_t)) / sizeof(int) -
    NUCLEUS_GRALLOC_HANDLE_FDS;

inline nucleus_gralloc_handle *nucleus_gralloc_handle_cast(
    native_handle_t *handle) {
    if (handle == nullptr ||
        handle->numFds != NUCLEUS_GRALLOC_HANDLE_FDS ||
        handle->numInts != NUCLEUS_GRALLOC_HANDLE_INTS) {
        return nullptr;
    }
    auto *result = reinterpret_cast<nucleus_gralloc_handle *>(handle);
    return result->magic == NUCLEUS_GRALLOC_HANDLE_MAGIC ? result : nullptr;
}

inline const nucleus_gralloc_handle *nucleus_gralloc_handle_cast(
    const native_handle_t *handle) {
    return nucleus_gralloc_handle_cast(
        const_cast<native_handle_t *>(handle));
}
