#pragma once

#include <aidl/android/hardware/graphics/common/PixelFormat.h>
#include <drm_fourcc.h>

#include <cstdint>

struct nucleus_gralloc_format {
    aidl::android::hardware::graphics::common::PixelFormat android;
    uint32_t drm;
    uint32_t bytes_per_pixel;
    uint32_t component_bits[4];
};

inline const nucleus_gralloc_format *nucleus_gralloc_format_for_android(
    aidl::android::hardware::graphics::common::PixelFormat format) {
    using aidl::android::hardware::graphics::common::PixelFormat;
    static constexpr nucleus_gralloc_format formats[] = {
        {PixelFormat::RGBA_8888, DRM_FORMAT_ABGR8888, 4, {8, 8, 8, 8}},
        {PixelFormat::RGBX_8888, DRM_FORMAT_XBGR8888, 4, {8, 8, 8, 0}},
        {PixelFormat::BGRA_8888, DRM_FORMAT_ARGB8888, 4, {8, 8, 8, 8}},
        {PixelFormat::IMPLEMENTATION_DEFINED, DRM_FORMAT_ABGR8888, 4, {8, 8, 8, 8}},
        {PixelFormat::RGBA_FP16, DRM_FORMAT_ABGR16161616F, 8, {16, 16, 16, 16}},
        {PixelFormat::RGBA_1010102, DRM_FORMAT_ABGR2101010, 4, {10, 10, 10, 2}},
    };
    for (const auto &candidate : formats) {
        if (candidate.android == format) return &candidate;
    }
    return nullptr;
}

inline const nucleus_gralloc_format *nucleus_gralloc_format_for_drm(
    uint32_t drm) {
    using aidl::android::hardware::graphics::common::PixelFormat;
    static constexpr PixelFormat android_formats[] = {
        PixelFormat::RGBA_8888,
        PixelFormat::RGBX_8888,
        PixelFormat::BGRA_8888,
        PixelFormat::RGBA_FP16,
        PixelFormat::RGBA_1010102,
    };
    for (const auto android : android_formats) {
        const auto *candidate = nucleus_gralloc_format_for_android(android);
        if (candidate->drm == drm) return candidate;
    }
    return nullptr;
}
