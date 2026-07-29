#include "NucleusGrallocBrokerClient.h"
#include "NucleusGrallocFormats.h"

#include <cerrno>
#include <cstring>
#include <unistd.h>

#include "NucleusAndroidGfxstreamSocketProtocol.h"
#include "NucleusIPCTransportC.h"
#include "NucleusGrallocHandle.h"

namespace {

constexpr const char *kBrokerSocket = "/dev/nucleus/gfxstream.sock";

int transact(
    const nucleus_android_gfxstream_socket_message &request,
    nucleus_android_gfxstream_socket_message *response,
    const int *requestDescriptors,
    size_t requestDescriptorCount,
    int *responseDescriptors,
    size_t responseDescriptorCount) {
    const int socket = nucleus_ipc_connect(kBrokerSocket);
    if (socket < 0) {
        return -errno;
    }
    if (nucleus_ipc_send(
            socket,
            &request,
            sizeof(request),
            requestDescriptors,
            requestDescriptorCount) < 0) {
        const int result = -errno;
        close(socket);
        return result;
    }
    size_t descriptorCount = 0;
    const int received = nucleus_ipc_receive(
        socket,
        response,
        sizeof(*response),
        responseDescriptors,
        responseDescriptorCount,
        &descriptorCount);
    const int savedErrno = errno;
    close(socket);
    if (received != static_cast<int>(sizeof(*response)) ||
        response->magic != NUCLEUS_ANDROID_GFXSTREAM_SOCKET_MAGIC ||
        response->version != NUCLEUS_ANDROID_GFXSTREAM_SOCKET_VERSION ||
        response->operation != request.operation ||
        descriptorCount !=
            (response->status == 0 ? responseDescriptorCount : 0)) {
        for (size_t index = 0; index < descriptorCount; ++index) {
            close(responseDescriptors[index]);
            responseDescriptors[index] = -1;
        }
        return received < 0 ? -savedErrno : -EPROTO;
    }
    return response->status;
}

}  // namespace

native_handle_t *nucleus_gralloc_broker_allocate(
    const aidl::android::hardware::graphics::allocator::BufferDescriptorInfo
        &descriptor,
    uint32_t drmFormat) {
    nucleus_android_gfxstream_socket_message request = {};
    request.magic = NUCLEUS_ANDROID_GFXSTREAM_SOCKET_MAGIC;
    request.version = NUCLEUS_ANDROID_GFXSTREAM_SOCKET_VERSION;
    request.operation = NUCLEUS_ANDROID_GFXSTREAM_ALLOCATE_BUFFER;
    request.usage = static_cast<uint64_t>(descriptor.usage);
    request.width = descriptor.width;
    request.height = descriptor.height;
    request.android_format = static_cast<uint32_t>(descriptor.format);
    request.drm_format = drmFormat;
    nucleus_android_gfxstream_socket_message response = {};
    int descriptors[NUCLEUS_GRALLOC_HANDLE_FDS] = {-1, -1};
    if (transact(
            request,
            &response,
            nullptr,
            0,
            descriptors,
            NUCLEUS_GRALLOC_HANDLE_FDS) < 0) {
        return nullptr;
    }
    native_handle_t *native =
        native_handle_create(
            NUCLEUS_GRALLOC_HANDLE_FDS,
            NUCLEUS_GRALLOC_HANDLE_INTS);
    if (native == nullptr) {
        close(descriptors[0]);
        close(descriptors[1]);
        return nullptr;
    }
    auto *handle = reinterpret_cast<nucleus_gralloc_handle *>(native);
    handle->dmabuf_fd = descriptors[0];
    handle->lifetime_fd = descriptors[1];
    handle->magic = NUCLEUS_GRALLOC_HANDLE_MAGIC;
    handle->color_buffer_handle = response.color_buffer_handle;
    handle->allocation_id = response.allocation_id;
    handle->usage = response.usage;
    handle->drm_modifier = response.drm_modifier;
    handle->allocation_size = response.allocation_size;
    handle->width = response.width;
    handle->height = response.height;
    handle->android_format = response.android_format;
    handle->drm_format = response.drm_format;
    handle->plane_offset = response.plane_offset;
    handle->plane_stride = response.plane_stride;
    const auto *format = nucleus_gralloc_format_for_drm(response.drm_format);
    if (format == nullptr ||
        response.plane_stride % format->bytes_per_pixel != 0) {
        native_handle_close(native);
        native_handle_delete(native);
        return nullptr;
    }
    handle->pixel_stride = response.width;
    handle->dataspace = 0;
    handle->blend_mode = 0;
    return native;
}

int nucleus_gralloc_broker_lock(
    const nucleus_gralloc_handle &handle,
    uint32_t access,
    nucleus_gralloc_cpu_mapping *mapping) {
    if (mapping == nullptr ||
        (access & (NUCLEUS_ANDROID_GFXSTREAM_CPU_ACCESS_READ |
                   NUCLEUS_ANDROID_GFXSTREAM_CPU_ACCESS_WRITE)) == 0 ||
        (access & ~(NUCLEUS_ANDROID_GFXSTREAM_CPU_ACCESS_READ |
                    NUCLEUS_ANDROID_GFXSTREAM_CPU_ACCESS_WRITE)) != 0) {
        return -EINVAL;
    }
    nucleus_android_gfxstream_socket_message request = {};
    request.magic = NUCLEUS_ANDROID_GFXSTREAM_SOCKET_MAGIC;
    request.version = NUCLEUS_ANDROID_GFXSTREAM_SOCKET_VERSION;
    request.operation = NUCLEUS_ANDROID_GFXSTREAM_LOCK_BUFFER;
    request.allocation_id = handle.allocation_id;
    request.cpu_access = access;
    nucleus_android_gfxstream_socket_message response = {};
    int descriptors[2] = {-1, -1};
    const int result = transact(
        request,
        &response,
        nullptr,
        0,
        descriptors,
        2);
    if (result < 0) {
        return result;
    }
    if (response.allocation_id != handle.allocation_id ||
        response.cpu_lock_id == 0 ||
        response.cpu_mapping_size == 0 ||
        response.cpu_stride == 0 ||
        response.cpu_access != access) {
        close(descriptors[0]);
        close(descriptors[1]);
        return -EPROTO;
    }
    *mapping = {
        .staging_fd = descriptors[0],
        .lifetime_fd = descriptors[1],
        .lock_id = response.cpu_lock_id,
        .size = response.cpu_mapping_size,
        .stride = response.cpu_stride,
        .access = response.cpu_access,
    };
    return 0;
}

int nucleus_gralloc_broker_unlock(
    const nucleus_gralloc_handle &handle,
    const nucleus_gralloc_cpu_mapping &mapping) {
    if (mapping.staging_fd < 0 || mapping.lifetime_fd < 0 ||
        mapping.lock_id == 0 || mapping.size == 0) {
        return -EINVAL;
    }
    nucleus_android_gfxstream_socket_message request = {};
    request.magic = NUCLEUS_ANDROID_GFXSTREAM_SOCKET_MAGIC;
    request.version = NUCLEUS_ANDROID_GFXSTREAM_SOCKET_VERSION;
    request.operation = NUCLEUS_ANDROID_GFXSTREAM_UNLOCK_BUFFER;
    request.allocation_id = handle.allocation_id;
    request.cpu_lock_id = mapping.lock_id;
    request.cpu_mapping_size = mapping.size;
    request.cpu_access = mapping.access;
    nucleus_android_gfxstream_socket_message response = {};
    const int descriptor = mapping.staging_fd;
    const int result = transact(
        request,
        &response,
        &descriptor,
        1,
        nullptr,
        0);
    if (result < 0) {
        return result;
    }
    return response.allocation_id == handle.allocation_id &&
        response.cpu_lock_id == mapping.lock_id
        ? 0
        : -EPROTO;
}

int nucleus_gralloc_broker_sync(
    const nucleus_gralloc_handle &handle,
    const nucleus_gralloc_cpu_mapping &mapping,
    uint32_t access) {
    if (mapping.staging_fd < 0 || mapping.lifetime_fd < 0 ||
        mapping.lock_id == 0 || mapping.size == 0 ||
        (access != NUCLEUS_ANDROID_GFXSTREAM_CPU_ACCESS_READ &&
         access != NUCLEUS_ANDROID_GFXSTREAM_CPU_ACCESS_WRITE) ||
        (mapping.access & access) == 0) {
        return -EINVAL;
    }
    nucleus_android_gfxstream_socket_message request = {};
    request.magic = NUCLEUS_ANDROID_GFXSTREAM_SOCKET_MAGIC;
    request.version = NUCLEUS_ANDROID_GFXSTREAM_SOCKET_VERSION;
    request.operation = NUCLEUS_ANDROID_GFXSTREAM_SYNC_BUFFER;
    request.allocation_id = handle.allocation_id;
    request.cpu_lock_id = mapping.lock_id;
    request.cpu_mapping_size = mapping.size;
    request.cpu_access = access;
    nucleus_android_gfxstream_socket_message response = {};
    const int descriptor = mapping.staging_fd;
    const int result = transact(
        request,
        &response,
        &descriptor,
        1,
        nullptr,
        0);
    if (result < 0) {
        return result;
    }
    return response.allocation_id == handle.allocation_id &&
        response.cpu_lock_id == mapping.lock_id
        ? 0
        : -EPROTO;
}
