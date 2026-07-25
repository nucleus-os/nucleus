#include "NucleusAndroidGfxstreamSocketTransport.h"

#include <cerrno>
#include <memory>
#include <string>
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
    close(socket);
    if (received != static_cast<int>(sizeof(response)) ||
        descriptorCount != NUCLEUS_ANDROID_GFXSTREAM_DESCRIPTOR_COUNT ||
        response.magic != NUCLEUS_ANDROID_GFXSTREAM_SOCKET_MAGIC ||
        response.version != NUCLEUS_ANDROID_GFXSTREAM_SOCKET_VERSION ||
        response.status != 0) {
        closeDescriptors(
            descriptors, NUCLEUS_ANDROID_GFXSTREAM_DESCRIPTOR_COUNT);
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
    };
    return 0;
}

}  // namespace

extern "C" int nucleus_android_gfxstream_install_socket_transport(
    nucleus_android_gfxstream_set_external_iostream_factory setter,
    const char *socketPath) {
    if (setter == nullptr || socketPath == nullptr || socketPath[0] != '/') {
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
    (void)transport.release();
    return 0;
}
