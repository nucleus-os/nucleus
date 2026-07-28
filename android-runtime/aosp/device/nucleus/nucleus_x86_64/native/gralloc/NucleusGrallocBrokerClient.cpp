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
    int *descriptors,
    size_t descriptorCapacity) {
    const int socket = nucleus_ipc_connect(kBrokerSocket);
    if (socket < 0) {
        return -errno;
    }
    if (nucleus_ipc_send(
            socket, &request, sizeof(request), nullptr, 0) < 0) {
        const int result = -errno;
        close(socket);
        return result;
    }
    size_t descriptorCount = 0;
    const int received = nucleus_ipc_receive(
        socket,
        response,
        sizeof(*response),
        descriptors,
        descriptorCapacity,
        &descriptorCount);
    const int savedErrno = errno;
    close(socket);
    if (received != static_cast<int>(sizeof(*response)) ||
        response->magic != NUCLEUS_ANDROID_GFXSTREAM_SOCKET_MAGIC ||
        response->version != NUCLEUS_ANDROID_GFXSTREAM_SOCKET_VERSION ||
        response->operation != request.operation ||
        descriptorCount != descriptorCapacity) {
        for (size_t index = 0; index < descriptorCount; ++index) {
            close(descriptors[index]);
            descriptors[index] = -1;
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
    handle->pixel_stride =
        response.plane_stride / format->bytes_per_pixel;
    handle->dataspace = 0;
    handle->blend_mode = 0;
    return native;
}
