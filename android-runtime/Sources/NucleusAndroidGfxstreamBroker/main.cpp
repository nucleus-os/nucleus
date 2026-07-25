#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <sys/socket.h>
#include <unistd.h>

#include <array>
#include <atomic>
#include <charconv>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <memory>
#include <string>
#include <string_view>
#include <thread>
#include <unordered_map>
#include <vector>

#include "NucleusAndroidDrmC.h"
#include "NucleusAndroidGfxstreamAdapters/GuestRingFactory.h"
#include "NucleusAndroidGfxstreamHostC.h"
#include "NucleusAndroidGfxstreamSocketProtocol.h"
#include "NucleusAndroidIPCC.h"
#include "NucleusAndroidSharedRingC.h"

namespace {

std::atomic<bool> stopping = false;
std::atomic<bool> brokerFailed = false;
std::atomic<int> listenerDescriptor = -1;

void requestStop(bool failed) {
    if (failed) {
        brokerFailed.store(true, std::memory_order_release);
    }
    stopping.store(true, std::memory_order_release);
    const int listener =
        listenerDescriptor.exchange(-1, std::memory_order_acq_rel);
    if (listener >= 0) {
        shutdown(listener, SHUT_RDWR);
        close(listener);
    }
}

void stop(int) {
    requestStop(false);
}

void trace(const char *stage, const std::string &detail = {}) {
    std::fprintf(
        stderr,
        "{\"component\":\"nucleus-android-gfxstream-broker\","
        "\"stage\":\"%s\",\"detail\":\"%s\"}\n",
        stage,
        detail.c_str());
    std::fflush(stderr);
}

bool parseUInt32(std::string_view value, uint32_t *output) {
    const auto result = std::from_chars(
        value.data(), value.data() + value.size(), *output);
    return result.ec == std::errc() &&
           result.ptr == value.data() + value.size();
}

std::string selectRenderNode(const char *requested) {
    if (requested != nullptr) {
        return requested;
    }
    std::array<char, NUCLEUS_ANDROID_DRM_PATH_MAX> selected = {};
    return nucleus_android_drm_select_display_render_path(
               selected.data(), selected.size()) == 0
        ? std::string(selected.data())
        : std::string();
}

using RingMapping = std::unique_ptr<
    nucleus_android_shared_ring_mapping,
    decltype(&nucleus_android_shared_ring_mapping_destroy)>;

nucleus_android_gfxstream_endpoint_descriptors emptyDescriptors() {
    return {-1, -1, -1, -1, -1, -1};
}

void closeDescriptors(
    nucleus_android_gfxstream_endpoint_descriptors descriptors) {
    for (const int descriptor : {
             descriptors.command_memory_fd,
             descriptors.command_data_notification_fd,
             descriptors.command_space_notification_fd,
             descriptors.response_memory_fd,
             descriptors.response_data_notification_fd,
             descriptors.response_space_notification_fd,
         }) {
        if (descriptor >= 0) {
            close(descriptor);
        }
    }
}

bool exportDescriptors(
    nucleus_android_shared_ring_mapping *commands,
    nucleus_android_shared_ring_mapping *responses,
    nucleus_android_gfxstream_endpoint_descriptors *output) {
    nucleus_android_shared_ring_descriptors command = {-1, -1, -1};
    nucleus_android_shared_ring_descriptors response = {-1, -1, -1};
    if (nucleus_android_shared_ring_mapping_export_descriptors(
            commands, &command) < 0 ||
        nucleus_android_shared_ring_mapping_export_descriptors(
            responses, &response) < 0) {
        nucleus_android_shared_ring_descriptors_close(command);
        nucleus_android_shared_ring_descriptors_close(response);
        return false;
    }
    *output = {
        command.memory_fd,
        command.data_notification_fd,
        command.space_notification_fd,
        response.memory_fd,
        response.data_notification_fd,
        response.space_notification_fd,
    };
    return true;
}

class Endpoint {
  public:
    Endpoint(
        nucleus_android_gfxstream_host_renderer *renderer,
        uint32_t context)
        : commands(nullptr, nucleus_android_shared_ring_mapping_destroy),
          responses(nullptr, nucleus_android_shared_ring_mapping_destroy) {
        commands.reset(nucleus_android_shared_ring_mapping_create(2, 64 * 1024));
        responses.reset(nucleus_android_shared_ring_mapping_create(2, 64 * 1024));
        if (!commands || !responses) {
            return;
        }
        auto hostDescriptors = emptyDescriptors();
        if (!exportDescriptors(
                commands.get(), responses.get(), &hostDescriptors) ||
            !exportDescriptors(
                commands.get(), responses.get(), &guestDescriptors)) {
            closeDescriptors(hostDescriptors);
            closeDescriptors(guestDescriptors);
            guestDescriptors = emptyDescriptors();
            return;
        }
        connection = nucleus_android_gfxstream_host_connection_create(
            renderer, hostDescriptors, context);
        if (connection == nullptr) {
            closeDescriptors(guestDescriptors);
            guestDescriptors = emptyDescriptors();
        }
    }

    ~Endpoint() {
        if (worker.joinable()) {
            worker.join();
        }
        nucleus_android_gfxstream_host_connection_destroy(connection);
    }

    bool valid() const {
        return connection != nullptr &&
               guestDescriptors.command_memory_fd >= 0;
    }

    nucleus_android_gfxstream_endpoint_descriptors takeGuestDescriptors() {
        auto result = guestDescriptors;
        guestDescriptors = emptyDescriptors();
        return result;
    }

    void start() {
        worker = std::thread([this] { pump(); });
    }

  private:
    void pump() {
        const int command =
            nucleus_android_gfxstream_host_connection_command_notification_fd(
                connection);
        const int responseSpace =
            nucleus_android_gfxstream_host_connection_response_space_notification_fd(
                connection);
        const int renderer =
            nucleus_android_gfxstream_host_connection_renderer_notification_fd(
                connection);
        if (command < 0 || responseSpace < 0 || renderer < 0) {
            trace("connection.failed", "missing notification descriptor");
            return;
        }
        while (!stopping.load(std::memory_order_acquire)) {
            auto result =
                nucleus_android_gfxstream_host_connection_pump(connection);
            while (result == NUCLEUS_ANDROID_GFXSTREAM_HOST_PUMP_PROGRESS) {
                result =
                    nucleus_android_gfxstream_host_connection_pump(connection);
            }
            if (result == NUCLEUS_ANDROID_GFXSTREAM_HOST_PUMP_PEER_CLOSED) {
                trace("connection.closed");
                return;
            }
            if (result == NUCLEUS_ANDROID_GFXSTREAM_HOST_PUMP_ERROR ||
                result == NUCLEUS_ANDROID_GFXSTREAM_HOST_PUMP_STOPPED) {
                trace("connection.failed", "host render-channel pump stopped");
                requestStop(true);
                return;
            }
            pollfd descriptors[] = {
                {command, POLLIN, 0},
                {responseSpace, POLLIN, 0},
                {renderer, POLLIN, 0},
            };
            int pollResult;
            do {
                pollResult = poll(descriptors, 3, 250);
            } while (pollResult < 0 && errno == EINTR &&
                     !stopping.load(std::memory_order_acquire));
            if (pollResult < 0) {
                trace("connection.failed", std::strerror(errno));
                requestStop(true);
                return;
            }
            if ((descriptors[0].revents & POLLIN) != 0) {
                (void)nucleus_android_gfxstream_host_connection_drain_command_notification(
                    connection);
            }
            if ((descriptors[1].revents & POLLIN) != 0) {
                (void)nucleus_android_gfxstream_host_connection_drain_response_space_notification(
                    connection);
            }
            if ((descriptors[2].revents & POLLIN) != 0) {
                (void)nucleus_android_gfxstream_host_connection_drain_renderer_notification(
                    connection);
            }
        }
    }

    RingMapping commands;
    RingMapping responses;
    nucleus_android_gfxstream_endpoint_descriptors guestDescriptors =
        emptyDescriptors();
    nucleus_android_gfxstream_host_connection *connection = nullptr;
    std::thread worker;
};

int sendResponse(
    int socket,
    int status,
    nucleus_android_gfxstream_endpoint_descriptors descriptors) {
    nucleus_android_gfxstream_socket_message response = {};
    response.magic = NUCLEUS_ANDROID_GFXSTREAM_SOCKET_MAGIC;
    response.version = NUCLEUS_ANDROID_GFXSTREAM_SOCKET_VERSION;
    response.operation = NUCLEUS_ANDROID_GFXSTREAM_OPEN_STREAM;
    response.status = status;
    const int fds[] = {
        descriptors.command_memory_fd,
        descriptors.command_data_notification_fd,
        descriptors.command_space_notification_fd,
        descriptors.response_memory_fd,
        descriptors.response_data_notification_fd,
        descriptors.response_space_notification_fd,
    };
    return nucleus_android_ipc_send(
        socket,
        &response,
        sizeof(response),
        status == 0 ? fds : nullptr,
        status == 0 ? NUCLEUS_ANDROID_GFXSTREAM_DESCRIPTOR_COUNT : 0);
}

using GpuBuffer = std::unique_ptr<
    nucleus_android_gpu_buffer,
    decltype(&nucleus_android_gpu_buffer_destroy)>;

struct Allocation {
    Allocation(
        nucleus_android_gfxstream_host_renderer *rendererValue,
        uint64_t identifierValue,
        uint32_t colorBufferHandleValue,
        int lifetimeDescriptorValue,
        GpuBuffer bufferValue)
        : renderer(rendererValue),
          identifier(identifierValue),
          colorBufferHandle(colorBufferHandleValue),
          lifetimeDescriptor(lifetimeDescriptorValue),
          buffer(std::move(bufferValue)) {}

    ~Allocation() {
        if (colorBufferHandle != 0) {
            (void)nucleus_android_gfxstream_host_release_dmabuf(
                renderer, colorBufferHandle);
        }
        if (lifetimeDescriptor >= 0) {
            close(lifetimeDescriptor);
        }
    }

    nucleus_android_gfxstream_host_renderer *renderer;
    uint64_t identifier;
    uint32_t colorBufferHandle;
    int lifetimeDescriptor;
    GpuBuffer buffer;
};

int sendControlResponse(
    int socket,
    const nucleus_android_gfxstream_socket_message &response,
    const int *descriptors = nullptr,
    size_t descriptorCount = 0) {
    return nucleus_android_ipc_send(
        socket,
        &response,
        sizeof(response),
        descriptors,
        descriptorCount);
}

}  // namespace

int main(int argc, char **argv) {
    const char *socketPath = nullptr;
    const char *renderNode = nullptr;
    uint32_t expectedUID = 0;
    uint32_t parentPID = 0;
    for (int index = 1; index < argc; ++index) {
        const std::string_view argument(argv[index]);
        if (argument == "--socket" && ++index < argc) {
            socketPath = argv[index];
        } else if (argument == "--expected-uid" && ++index < argc) {
            if (!parseUInt32(argv[index], &expectedUID)) {
                expectedUID = 0;
            }
        } else if (argument == "--parent-pid" && ++index < argc) {
            if (!parseUInt32(argv[index], &parentPID)) {
                parentPID = 0;
            }
        } else if (argument == "--render-node" && ++index < argc) {
            renderNode = argv[index];
        } else {
            std::fprintf(stderr, "invalid argument: %s\n", argv[index]);
            return 2;
        }
    }
    if (socketPath == nullptr || expectedUID == 0 || parentPID == 0 ||
        nucleus_android_ipc_require_parent_lifetime(SIGTERM, parentPID) < 0) {
        std::fprintf(stderr, "invalid or incomplete broker invocation\n");
        return 2;
    }
    signal(SIGTERM, stop);
    signal(SIGINT, stop);

    const std::string selectedRenderNode = selectRenderNode(renderNode);
    if (selectedRenderNode.empty()) {
        std::fprintf(
            stderr,
            "could not select exactly one display-connected GPU: %s\n",
            std::strerror(errno));
        return 1;
    }
    char error[512] = {};
    std::unique_ptr<nucleus_android_gpu, decltype(&nucleus_android_gpu_destroy)>
        gpu(
            nucleus_android_gpu_create(
                selectedRenderNode.c_str(), error, sizeof(error)),
            nucleus_android_gpu_destroy);
    nucleus_android_gpu_diagnostic diagnostic = {};
    if (!gpu ||
        nucleus_android_gpu_get_diagnostic(gpu.get(), &diagnostic) < 0) {
        std::fprintf(stderr, "GPU discovery failed: %s\n", error);
        return 1;
    }
    std::unique_ptr<
        nucleus_android_gfxstream_host_renderer,
        decltype(&nucleus_android_gfxstream_host_renderer_destroy)>
        renderer(
            nucleus_android_gfxstream_host_renderer_create(
                1, 1, diagnostic.device_uuid, error, sizeof(error)),
            nucleus_android_gfxstream_host_renderer_destroy);
    if (!renderer) {
        std::fprintf(stderr, "gfxstream renderer failed: %s\n", error);
        return 1;
    }
    const int listener = nucleus_android_ipc_listen(socketPath, 0666);
    if (listener < 0) {
        std::fprintf(stderr, "listen failed: %s\n", std::strerror(errno));
        return 1;
    }
    listenerDescriptor.store(listener, std::memory_order_release);
    trace("ready", selectedRenderNode);

    std::vector<std::unique_ptr<Endpoint>> endpoints;
    std::unordered_map<uint64_t, std::unique_ptr<Allocation>> allocations;
    uint32_t nextContext = 1;
    uint32_t nextColorBufferHandle = UINT32_C(0x40000000);
    uint64_t nextAllocationIdentifier = 1;
    while (!stopping.load(std::memory_order_acquire)) {
        std::vector<pollfd> pollDescriptors;
        std::vector<uint64_t> pollAllocations;
        pollDescriptors.push_back({listener, POLLIN, 0});
        pollAllocations.push_back(0);
        for (const auto &[identifier, allocation] : allocations) {
            pollDescriptors.push_back(
                {allocation->lifetimeDescriptor, POLLIN, 0});
            pollAllocations.push_back(identifier);
        }
        int pollResult;
        do {
            pollResult = poll(
                pollDescriptors.data(), pollDescriptors.size(), -1);
        } while (pollResult < 0 && errno == EINTR &&
                 !stopping.load(std::memory_order_acquire));
        if (pollResult < 0) {
            if (stopping.load(std::memory_order_acquire)) {
                break;
            }
            std::fprintf(stderr, "poll failed: %s\n", std::strerror(errno));
            return 1;
        }
        for (size_t index = 1; index < pollDescriptors.size(); ++index) {
            if ((pollDescriptors[index].revents &
                 (POLLHUP | POLLERR | POLLNVAL)) != 0) {
                trace(
                    "buffer.released",
                    std::to_string(pollAllocations[index]));
                allocations.erase(pollAllocations[index]);
            }
        }
        if ((pollDescriptors.front().revents & POLLIN) == 0) {
            continue;
        }
        const int peer = nucleus_android_ipc_accept(listener);
        if (peer < 0) {
            if (stopping.load(std::memory_order_acquire)) {
                break;
            }
            if (errno == EINTR) {
                continue;
            }
            std::fprintf(stderr, "accept failed: %s\n", std::strerror(errno));
            return 1;
        }
        nucleus_android_peer_credentials credentials = {};
        nucleus_android_gfxstream_socket_message request = {};
        size_t receivedDescriptors = 0;
        const int received = nucleus_android_ipc_receive(
            peer,
            &request,
            sizeof(request),
            nullptr,
            0,
            &receivedDescriptors);
        if (nucleus_android_ipc_peer_credentials(peer, &credentials) < 0 ||
            credentials.uid != expectedUID ||
            received != static_cast<int>(sizeof(request)) ||
            receivedDescriptors != 0 ||
            request.magic != NUCLEUS_ANDROID_GFXSTREAM_SOCKET_MAGIC ||
            request.version != NUCLEUS_ANDROID_GFXSTREAM_SOCKET_VERSION ||
            request.operation < NUCLEUS_ANDROID_GFXSTREAM_OPEN_STREAM ||
            request.operation > NUCLEUS_ANDROID_GFXSTREAM_ALLOCATE_BUFFER) {
            (void)sendResponse(peer, -EPERM, emptyDescriptors());
            close(peer);
            trace("peer.rejected");
            continue;
        }
        if (request.operation == NUCLEUS_ANDROID_GFXSTREAM_ALLOCATE_BUFFER) {
            nucleus_android_gfxstream_socket_message response = {};
            response.magic = NUCLEUS_ANDROID_GFXSTREAM_SOCKET_MAGIC;
            response.version = NUCLEUS_ANDROID_GFXSTREAM_SOCKET_VERSION;
            response.operation = request.operation;
            response.status = -EINVAL;
            if (request.width == 0 || request.height == 0 ||
                request.drm_format == 0) {
                (void)sendControlResponse(peer, response);
                close(peer);
                continue;
            }
            uint64_t modifier = 0;
            if (nucleus_android_gpu_preferred_modifier(
                    gpu.get(), request.drm_format, &modifier) < 0) {
                response.status = -ENOTSUP;
                (void)sendControlResponse(peer, response);
                close(peer);
                continue;
            }
            char allocationError[512] = {};
            GpuBuffer buffer(
                nucleus_android_gpu_buffer_create(
                    gpu.get(),
                    request.width,
                    request.height,
                    request.drm_format,
                    modifier,
                    0,
                    allocationError,
                    sizeof(allocationError)),
                nucleus_android_gpu_buffer_destroy);
            nucleus_android_dmabuf_plane plane = {};
            if (!buffer ||
                nucleus_android_gpu_buffer_plane_count(buffer.get()) != 1) {
                response.status = -ENOMEM;
                (void)sendControlResponse(peer, response);
                close(peer);
                trace("buffer.allocate.failed", allocationError);
                continue;
            }
            const int rendererDescriptor =
                nucleus_android_gpu_buffer_export_plane(
                    buffer.get(), 0, &plane);
            const uint32_t colorBufferHandle = nextColorBufferHandle++;
            const nucleus_android_gfxstream_host_dmabuf dmabuf = {
                .color_buffer_handle = colorBufferHandle,
                .width = request.width,
                .height = request.height,
                .drm_format = request.drm_format,
                .drm_modifier = modifier,
                .plane_offset = plane.offset,
                .plane_stride = plane.stride,
                .dmabuf_fd = rendererDescriptor,
                .sync_context = nullptr,
                .export_release_sync_file = nullptr,
                .import_acquire_sync_file = nullptr,
            };
            if (rendererDescriptor < 0 ||
                nucleus_android_gfxstream_host_import_dmabuf(
                    renderer.get(), &dmabuf) < 0) {
                if (rendererDescriptor >= 0) {
                    close(rendererDescriptor);
                }
                response.status = -EIO;
                (void)sendControlResponse(peer, response);
                close(peer);
                trace("buffer.import.failed");
                continue;
            }
            const int guestDescriptor =
                nucleus_android_gpu_buffer_export_plane(
                    buffer.get(), 0, &plane);
            if (guestDescriptor < 0) {
                (void)nucleus_android_gfxstream_host_release_dmabuf(
                    renderer.get(), colorBufferHandle);
                response.status = -EIO;
                (void)sendControlResponse(peer, response);
                close(peer);
                continue;
            }
            int lifetimeDescriptors[2] = {-1, -1};
            if (socketpair(
                    AF_UNIX,
                    SOCK_SEQPACKET | SOCK_CLOEXEC,
                    0,
                    lifetimeDescriptors) < 0) {
                close(guestDescriptor);
                (void)nucleus_android_gfxstream_host_release_dmabuf(
                    renderer.get(), colorBufferHandle);
                response.status = -errno;
                (void)sendControlResponse(peer, response);
                close(peer);
                continue;
            }
            const uint64_t identifier = nextAllocationIdentifier++;
            response.status = 0;
            response.allocation_id = identifier;
            response.usage = request.usage;
            response.drm_modifier = modifier;
            response.allocation_size =
                static_cast<uint64_t>(plane.stride) * request.height;
            response.width = request.width;
            response.height = request.height;
            response.android_format = request.android_format;
            response.drm_format = request.drm_format;
            response.plane_offset = plane.offset;
            response.plane_stride = plane.stride;
            response.color_buffer_handle = colorBufferHandle;
            allocations.emplace(
                identifier,
                std::make_unique<Allocation>(
                    renderer.get(),
                    identifier,
                    colorBufferHandle,
                    lifetimeDescriptors[0],
                    std::move(buffer)));
            const int responseDescriptors[] = {
                guestDescriptor,
                lifetimeDescriptors[1],
            };
            const int result = sendControlResponse(
                peer, response, responseDescriptors, 2);
            close(guestDescriptor);
            close(lifetimeDescriptors[1]);
            close(peer);
            if (result < 0) {
                allocations.erase(identifier);
                trace("buffer.allocate.failed", "descriptor transfer failed");
            } else {
                trace("buffer.allocated", std::to_string(identifier));
            }
            continue;
        }
        auto endpoint =
            std::make_unique<Endpoint>(renderer.get(), nextContext++);
        if (!endpoint->valid()) {
            (void)sendResponse(peer, -EIO, emptyDescriptors());
            close(peer);
            trace("connection.failed", "ring allocation failed");
            continue;
        }
        auto guestDescriptors = endpoint->takeGuestDescriptors();
        const int sendResult = sendResponse(peer, 0, guestDescriptors);
        closeDescriptors(guestDescriptors);
        close(peer);
        if (sendResult < 0) {
            trace("connection.failed", "descriptor transfer failed");
            continue;
        }
        endpoint->start();
        endpoints.push_back(std::move(endpoint));
        trace("connection.opened");
    }
    stopping.store(true, std::memory_order_release);
    endpoints.clear();
    allocations.clear();
    renderer.reset();
    std::filesystem::remove(socketPath);
    trace("stopped");
    return brokerFailed.load(std::memory_order_acquire) ? 1 : 0;
}
