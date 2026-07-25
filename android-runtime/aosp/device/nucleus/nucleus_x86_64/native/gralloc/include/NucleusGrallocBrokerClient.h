#pragma once

#include <aidl/android/hardware/graphics/allocator/BufferDescriptorInfo.h>
#include <cutils/native_handle.h>

native_handle_t *nucleus_gralloc_broker_allocate(
    const aidl::android::hardware::graphics::allocator::BufferDescriptorInfo
        &descriptor,
    uint32_t drmFormat);
