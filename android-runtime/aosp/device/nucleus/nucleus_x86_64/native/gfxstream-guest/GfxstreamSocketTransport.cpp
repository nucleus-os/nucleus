#include "NucleusAndroidGfxstreamSocketTransport.h"

#include <cerrno>
#include <memory>
#include <string>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "NucleusAndroidGfxstreamSocketProtocol.h"
#include "NucleusAndroidIPCC.h"

namespace {

struct SocketTransport {
    std::string path;
    nucleus_android_gfxstream_factory_registration *registration = nullptr;
};

void closeDescriptors(int *descriptors, size_t count) {
    for (size_t index = 0; index < count; ++index) {
        if (descriptors[index] >= 0) {
            close(descriptors[index]);
            descriptors[index] = -1;
        }
    }
}

int provideSocketEndpoint(
    void *context,
    nucleus_android_gfxstream_endpoint_descriptors *output) {
    auto *transport = static_cast<SocketTransport *>(context);
    int socket = nucleus_android_ipc_connect(transport->path.c_str());
    if (socket < 0) {
        return -1;
    }
    const nucleus_android_gfxstream_socket_message request = {
        .magic = NUCLEUS_ANDROID_GFXSTREAM_SOCKET_MAGIC,
        .version = NUCLEUS_ANDROID_GFXSTREAM_SOCKET_VERSION,
        .operation = NUCLEUS_ANDROID_GFXSTREAM_OPEN_STREAM,
        .status = 0,
        .reserved = 0,
    };
    if (nucleus_android_ipc_send(
            socket, &request, sizeof(request), nullptr, 0) < 0) {
        const int savedErrno = errno;
        close(socket);
        errno = savedErrno;
        return -1;
    }

    nucleus_android_gfxstream_socket_message response = {};
    int descriptors[NUCLEUS_ANDROID_GFXSTREAM_DESCRIPTOR_COUNT] = {
        -1, -1, -1, -1, -1, -1,
    };
    size_t descriptorCount = 0;
    const int received = nucleus_android_ipc_receive(
        socket,
        &response,
        sizeof(response),
        descriptors,
        NUCLEUS_ANDROID_GFXSTREAM_DESCRIPTOR_COUNT,
        &descriptorCount);
    const int savedErrno = errno;
    if (received != static_cast<int>(sizeof(response)) ||
        descriptorCount != NUCLEUS_ANDROID_GFXSTREAM_DESCRIPTOR_COUNT ||
        response.magic != NUCLEUS_ANDROID_GFXSTREAM_SOCKET_MAGIC ||
        response.version != NUCLEUS_ANDROID_GFXSTREAM_SOCKET_VERSION ||
        response.status != 0) {
        closeDescriptors(
            descriptors, NUCLEUS_ANDROID_GFXSTREAM_DESCRIPTOR_COUNT);
        close(socket);
        errno = response.status < 0 ? -response.status
                                    : (received < 0 ? savedErrno : EPROTO);
        return -1;
    }

    *output = {
        .command_memory_fd = descriptors[0],
        .command_data_notification_fd = descriptors[1],
        .command_space_notification_fd = descriptors[2],
        .response_memory_fd = descriptors[3],
        .response_data_notification_fd = descriptors[4],
        .response_space_notification_fd = descriptors[5],
        .lifetime_fd = socket,
    };
    return 0;
}

int mapSocketMemory(
    void *context,
    uint64_t blobId,
    size_t size,
    void **address) {
    if (blobId == 0 || size == 0 || address == nullptr) {
        errno = EINVAL;
        return -1;
    }
    auto *transport = static_cast<SocketTransport *>(context);
    const int socket = nucleus_android_ipc_connect(transport->path.c_str());
    if (socket < 0) {
        return -1;
    }
    const nucleus_android_gfxstream_socket_message request = {
        .magic = NUCLEUS_ANDROID_GFXSTREAM_SOCKET_MAGIC,
        .version = NUCLEUS_ANDROID_GFXSTREAM_SOCKET_VERSION,
        .operation = NUCLEUS_ANDROID_GFXSTREAM_MAP_HOST_MEMORY,
        .status = 0,
        .allocation_id = blobId,
        .allocation_size = size,
        .reserved = 0,
    };
    if (nucleus_android_ipc_send(
            socket, &request, sizeof(request), nullptr, 0) < 0) {
        const int savedErrno = errno;
        close(socket);
        errno = savedErrno;
        return -1;
    }

    nucleus_android_gfxstream_socket_message response = {};
    int descriptor = -1;
    size_t descriptorCount = 0;
    const int received = nucleus_android_ipc_receive(
        socket,
        &response,
        sizeof(response),
        &descriptor,
        1,
        &descriptorCount);
    const int savedErrno = errno;
    close(socket);
    if (received != static_cast<int>(sizeof(response)) ||
        descriptorCount != 1 ||
        response.magic != NUCLEUS_ANDROID_GFXSTREAM_SOCKET_MAGIC ||
        response.version != NUCLEUS_ANDROID_GFXSTREAM_SOCKET_VERSION ||
        response.operation != NUCLEUS_ANDROID_GFXSTREAM_MAP_HOST_MEMORY ||
        response.status != 0) {
        if (descriptor >= 0) close(descriptor);
        errno = response.status < 0 ? -response.status
                                    : (received < 0 ? savedErrno : EPROTO);
        return -1;
    }
    struct stat status = {};
    if (fstat(descriptor, &status) < 0 ||
        status.st_size < 0 ||
        static_cast<uint64_t>(status.st_size) < size) {
        const int error = errno == 0 ? EPROTO : errno;
        close(descriptor);
        errno = error;
        return -1;
    }
    void *mapping = mmap(
        nullptr,
        size,
        PROT_READ | PROT_WRITE,
        MAP_SHARED,
        descriptor,
        0);
    const int mappingErrno = errno;
    close(descriptor);
    if (mapping == MAP_FAILED) {
        errno = mappingErrno;
        return -1;
    }
    *address = mapping;
    return 0;
}

void unmapSocketMemory(
    void *,
    void *address,
    size_t size) {
    if (address != nullptr && size != 0) {
        (void)munmap(address, size);
    }
}

int exportSocketVulkanSync(
    void *context,
    uint64_t deviceHandle,
    uint64_t syncHandle,
    uint32_t operation) {
    const bool qsri =
        operation == NUCLEUS_ANDROID_GFXSTREAM_EXPORT_VULKAN_QSRI;
    if (syncHandle == 0 || (!qsri && deviceHandle == 0)) {
        errno = EINVAL;
        return -1;
    }
    auto *transport = static_cast<SocketTransport *>(context);
    const int socket = nucleus_android_ipc_connect(transport->path.c_str());
    if (socket < 0) {
        return -1;
    }
    const nucleus_android_gfxstream_socket_message request = {
        .magic = NUCLEUS_ANDROID_GFXSTREAM_SOCKET_MAGIC,
        .version = NUCLEUS_ANDROID_GFXSTREAM_SOCKET_VERSION,
        .operation = operation,
        .status = 0,
        .vulkan_device_handle = deviceHandle,
        .vulkan_fence_handle =
            operation == NUCLEUS_ANDROID_GFXSTREAM_EXPORT_VULKAN_FENCE
                ? syncHandle
                : 0,
        .vulkan_semaphore_handle =
            operation ==
                    NUCLEUS_ANDROID_GFXSTREAM_EXPORT_VULKAN_SEMAPHORE
                ? syncHandle
                : 0,
        .vulkan_image_handle = qsri ? syncHandle : 0,
    };
    if (nucleus_android_ipc_send(
            socket, &request, sizeof(request), nullptr, 0) < 0) {
        const int savedErrno = errno;
        close(socket);
        errno = savedErrno;
        return -1;
    }

    nucleus_android_gfxstream_socket_message response = {};
    int descriptor = -1;
    size_t descriptorCount = 0;
    const int received = nucleus_android_ipc_receive(
        socket,
        &response,
        sizeof(response),
        &descriptor,
        1,
        &descriptorCount);
    const int savedErrno = errno;
    close(socket);
    if (received != static_cast<int>(sizeof(response)) ||
        descriptorCount != 1 ||
        response.magic != NUCLEUS_ANDROID_GFXSTREAM_SOCKET_MAGIC ||
        response.version != NUCLEUS_ANDROID_GFXSTREAM_SOCKET_VERSION ||
        response.operation != operation ||
        response.status != 0) {
        if (descriptor >= 0) close(descriptor);
        errno = response.status < 0 ? -response.status
                                    : (received < 0 ? savedErrno : EPROTO);
        return -1;
    }
    return descriptor;
}

int exportSocketVulkanFence(
    void *context,
    uint64_t deviceHandle,
    uint64_t fenceHandle) {
    return exportSocketVulkanSync(
        context,
        deviceHandle,
        fenceHandle,
        NUCLEUS_ANDROID_GFXSTREAM_EXPORT_VULKAN_FENCE);
}

int exportSocketVulkanSemaphore(
    void *context,
    uint64_t deviceHandle,
    uint64_t semaphoreHandle) {
    return exportSocketVulkanSync(
        context,
        deviceHandle,
        semaphoreHandle,
        NUCLEUS_ANDROID_GFXSTREAM_EXPORT_VULKAN_SEMAPHORE);
}

int exportSocketVulkanQsri(
    void *context,
    uint64_t imageHandle) {
    return exportSocketVulkanSync(
        context,
        0,
        imageHandle,
        NUCLEUS_ANDROID_GFXSTREAM_EXPORT_VULKAN_QSRI);
}

}  // namespace

extern "C" int nucleus_android_gfxstream_install_socket_transport(
    nucleus_android_gfxstream_set_external_iostream_factory setter,
    nucleus_android_gfxstream_set_external_memory_mapper memorySetter,
    nucleus_android_gfxstream_set_external_vulkan_fence_exporter
        fenceExporterSetter,
    nucleus_android_gfxstream_set_external_vulkan_semaphore_exporter
        semaphoreExporterSetter,
    nucleus_android_gfxstream_set_external_vulkan_qsri_exporter
        qsriExporterSetter,
    const char *socketPath) {
    if (setter == nullptr || memorySetter == nullptr ||
        fenceExporterSetter == nullptr ||
        semaphoreExporterSetter == nullptr ||
        qsriExporterSetter == nullptr ||
        socketPath == nullptr || socketPath[0] != '/') {
        errno = EINVAL;
        return -1;
    }
    auto transport = std::make_unique<SocketTransport>();
    transport->path = socketPath;
    transport->registration =
        nucleus_android_gfxstream_factory_registration_create_with_setter(
            setter, provideSocketEndpoint, transport.get());
    if (transport->registration == nullptr) {
        return -1;
    }
    memorySetter(mapSocketMemory, unmapSocketMemory, transport.get());
    fenceExporterSetter(exportSocketVulkanFence, transport.get());
    semaphoreExporterSetter(
        exportSocketVulkanSemaphore,
        transport.get());
    qsriExporterSetter(exportSocketVulkanQsri, transport.get());
    (void)transport.release();
    return 0;
}
