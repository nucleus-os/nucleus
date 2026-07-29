#pragma once

#include <aidl/android/hardware/graphics/allocator/BufferDescriptorInfo.h>
#include <cutils/native_handle.h>

#include "NucleusGrallocHandle.h"

struct nucleus_gralloc_cpu_mapping {
    int32_t staging_fd;
    int32_t lifetime_fd;
    uint64_t lock_id;
    uint64_t size;
    uint32_t stride;
    uint32_t access;
};

native_handle_t *nucleus_gralloc_broker_allocate(
    const aidl::android::hardware::graphics::allocator::BufferDescriptorInfo
        &descriptor,
    uint32_t drmFormat);

int nucleus_gralloc_broker_lock(
    const nucleus_gralloc_handle &handle,
    uint32_t access,
    nucleus_gralloc_cpu_mapping *mapping);
int nucleus_gralloc_broker_unlock(
    const nucleus_gralloc_handle &handle,
    const nucleus_gralloc_cpu_mapping &mapping);
int nucleus_gralloc_broker_sync(
    const nucleus_gralloc_handle &handle,
    const nucleus_gralloc_cpu_mapping &mapping,
    uint32_t access);
