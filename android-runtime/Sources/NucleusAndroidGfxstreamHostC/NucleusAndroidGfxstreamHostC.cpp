#include "NucleusAndroidGfxstreamHostC.h"

#include <errno.h>
#include <sys/eventfd.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdlib>
#include <cstdio>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <utility>

#include "NucleusAndroidGfxstreamAdapters/HostRingChannelPump.h"
#include "NucleusAndroidSharedRingC.h"
#include "gfxstream/nucleus-gfxstream-renderer.h"
#include "gfxstream/host/features.h"
#include "render-utils/RenderLib.h"
#include "render-utils/render_api.h"
#include "render-utils/renderer_enums.h"

struct nucleus_android_gfxstream_host_renderer {
    gfxstream::RenderLibPtr library;
    gfxstream::RendererPtr renderer;
    std::mutex processMutex;
    std::unordered_map<uint32_t, std::size_t> processReferences;
};

struct nucleus_android_gfxstream_host_connection {
    std::unique_ptr<nucleus_android_shared_ring, decltype(
        &nucleus_android_shared_ring_destroy)> commands{
            nullptr, nucleus_android_shared_ring_destroy};
    std::unique_ptr<nucleus_android_shared_ring, decltype(
        &nucleus_android_shared_ring_destroy)> responses{
            nullptr, nucleus_android_shared_ring_destroy};
    gfxstream::RenderChannelPtr channel;
    std::unique_ptr<nucleus::android::gfxstream::HostRingChannelPump> pump;
    int rendererNotificationFd = -1;
    nucleus_android_gfxstream_host_renderer *parentRenderer = nullptr;
    uint32_t contextId = 0;
    bool processResourcesRegistered = false;
};

namespace {

void writeError(
    char *output,
    std::size_t capacity,
    const char *message) {
    if (output && capacity > 0) {
        std::snprintf(output, capacity, "%s", message);
    }
}

int hexadecimalNibble(char character) {
    if (character >= '0' && character <= '9') {
        return character - '0';
    }
    if (character >= 'a' && character <= 'f') {
        return character - 'a' + 10;
    }
    return -1;
}

bool parseDeviceUuid(
    const char *input,
    std::array<uint8_t, 16> *output) {
    if (!input || !output || std::char_traits<char>::length(input) != 32) {
        return false;
    }
    for (std::size_t index = 0; index < output->size(); ++index) {
        const int high = hexadecimalNibble(input[index * 2]);
        const int low = hexadecimalNibble(input[index * 2 + 1]);
        if (high < 0 || low < 0) {
            return false;
        }
        (*output)[index] = static_cast<uint8_t>((high << 4) | low);
    }
    return std::any_of(
        output->begin(),
        output->end(),
        [](uint8_t byte) { return byte != 0; });
}

bool excludeGuestVulkanDrivers() {
    constexpr const char *filter = "*gfxstream*";
    const char *current = std::getenv("VK_LOADER_DRIVERS_DISABLE");
    if (current && std::string(current).find(filter) != std::string::npos) {
        return true;
    }
    std::string updated;
    if (current && current[0] != '\0') {
        updated = current;
        updated += ",";
    }
    updated += filter;
    return setenv(
               "VK_LOADER_DRIVERS_DISABLE",
               updated.c_str(),
               1) == 0;
}

void enable(
    gfxstream::host::BoolFeatureInfo *feature) {
    feature->setEnabled(true);
    feature->setReason("Required by Nucleus Android runtime");
}

void closeEndpointDescriptors(
    const nucleus_android_gfxstream_endpoint_descriptors &descriptors) {
    const int values[] = {
        descriptors.command_memory_fd,
        descriptors.command_data_notification_fd,
        descriptors.command_space_notification_fd,
        descriptors.response_memory_fd,
        descriptors.response_data_notification_fd,
        descriptors.response_space_notification_fd,
    };
    for (const int descriptor : values) {
        if (descriptor >= 0) {
            close(descriptor);
        }
    }
}

void signalRendererNotification(int notificationFd) {
    const std::uint64_t value = 1;
    ssize_t result;
    do {
        result = write(notificationFd, &value, sizeof(value));
    } while (result < 0 && errno == EINTR);
}

void retainProcessResources(
    nucleus_android_gfxstream_host_renderer *renderer,
    uint32_t contextId) {
    std::lock_guard<std::mutex> lock(renderer->processMutex);
    auto &references = renderer->processReferences[contextId];
    if (references == 0) {
        renderer->renderer->onGuestGraphicsProcessCreate(contextId);
    }
    ++references;
}

void releaseProcessResources(
    nucleus_android_gfxstream_host_renderer *renderer,
    uint32_t contextId) {
    std::lock_guard<std::mutex> lock(renderer->processMutex);
    const auto found = renderer->processReferences.find(contextId);
    if (found == renderer->processReferences.end()) {
        return;
    }
    if (--found->second != 0) {
        return;
    }
    renderer->processReferences.erase(found);
    renderer->renderer->cleanupProcGLObjects(contextId);
    renderer->renderer->waitForProcessCleanup();
}

int drainNotification(int notificationFd) {
    std::uint64_t value = 0;
    ssize_t result;
    do {
        result = read(notificationFd, &value, sizeof(value));
    } while (result < 0 && errno == EINTR);
    if (result < 0 && errno == EAGAIN) {
        return 0;
    }
    return result == static_cast<ssize_t>(sizeof(value)) ? 0 : -1;
}

}  // namespace

extern "C" nucleus_android_gfxstream_host_renderer *
nucleus_android_gfxstream_host_renderer_create(
    uint32_t width,
    uint32_t height,
    const char *vulkanDeviceUuid,
    char *errorMessage,
    size_t errorCapacity) {
    if (width == 0 || height == 0) {
        errno = EINVAL;
        writeError(errorMessage, errorCapacity, "renderer dimensions must be nonzero");
        return nullptr;
    }
    std::array<uint8_t, 16> uuid;
    if (!parseDeviceUuid(vulkanDeviceUuid, &uuid)) {
        errno = EINVAL;
        writeError(
            errorMessage,
            errorCapacity,
            "Vulkan device UUID must be 32 lowercase hexadecimal digits");
        return nullptr;
    }
    if (!excludeGuestVulkanDrivers()) {
        writeError(
            errorMessage,
            errorCapacity,
            "failed to exclude guest Vulkan ICDs from the host loader");
        return nullptr;
    }
    const int requireResult =
        gfxstream_nucleus_require_vulkan_device_uuid(uuid.data());
    if (requireResult != 0) {
        errno = -requireResult;
        writeError(
            errorMessage,
            errorCapacity,
            "failed to install the required gfxstream Vulkan device UUID");
        return nullptr;
    }

    auto host = std::make_unique<nucleus_android_gfxstream_host_renderer>();
    host->library = gfxstream::initLibrary();
    if (!host->library) {
        errno = EIO;
        writeError(errorMessage, errorCapacity, "gfxstream library initialization failed");
        return nullptr;
    }
    host->library->setRenderer(SELECTED_RENDERER_HOST);
    host->library->setGuestAndroidApiLevel(35);

    gfxstream::host::FeatureSet features;
    enable(&features.Vulkan);
    enable(&features.GuestVulkanOnly);
    enable(&features.NoDelayCloseColorBuffer);
    enable(&features.VulkanBatchedDescriptorSetUpdate);
    enable(&features.VulkanIgnoredHandles);
    enable(&features.VulkanNullOptionalStrings);
    enable(&features.VulkanQueueSubmitWithCommands);
    enable(&features.VulkanShaderFloat16Int8);
    enable(&features.VulkanEnsureCachedCoherentMemoryAvailable);
    enable(&features.VirtioGpuNext);

    host->renderer =
        host->library->initRenderer(
            static_cast<int>(width),
            static_cast<int>(height),
            features,
            false);
    if (!host->renderer) {
        errno = EIO;
        writeError(errorMessage, errorCapacity, "gfxstream host renderer initialization failed");
        return nullptr;
    }
    return host.release();
}

extern "C" void nucleus_android_gfxstream_host_renderer_destroy(
    nucleus_android_gfxstream_host_renderer *renderer) {
    delete renderer;
}

extern "C" int nucleus_android_gfxstream_host_import_dmabuf(
    nucleus_android_gfxstream_host_renderer *renderer,
    const nucleus_android_gfxstream_host_dmabuf *dmabuf) {
    if (!renderer || !renderer->renderer || !dmabuf) {
        return -EINVAL;
    }
    const gfxstream_nucleus_dmabuf gfxstreamDmabuf = {
        .color_buffer_handle = dmabuf->color_buffer_handle,
        .width = dmabuf->width,
        .height = dmabuf->height,
        .drm_format = dmabuf->drm_format,
        .drm_modifier = dmabuf->drm_modifier,
        .plane_offset = dmabuf->plane_offset,
        .plane_stride = dmabuf->plane_stride,
        .dmabuf_fd = dmabuf->dmabuf_fd,
        .sync = {
            .context = dmabuf->sync_context,
            .export_release_sync_file = dmabuf->export_release_sync_file,
            .import_acquire_sync_file = dmabuf->import_acquire_sync_file,
        },
    };
    return gfxstream_nucleus_import_color_buffer_dmabuf(&gfxstreamDmabuf);
}

extern "C" int nucleus_android_gfxstream_host_release_dmabuf(
    nucleus_android_gfxstream_host_renderer *renderer,
    uint32_t colorBufferHandle) {
    if (!renderer || !renderer->renderer) {
        return -EINVAL;
    }
    return gfxstream_nucleus_release_color_buffer(colorBufferHandle);
}

extern "C" nucleus_android_gfxstream_host_connection *
nucleus_android_gfxstream_host_connection_create(
    nucleus_android_gfxstream_host_renderer *renderer,
    nucleus_android_gfxstream_endpoint_descriptors descriptors,
    uint32_t contextId) {
    if (!renderer || !renderer->renderer) {
        closeEndpointDescriptors(descriptors);
        errno = EINVAL;
        return nullptr;
    }

    auto connection =
        std::make_unique<nucleus_android_gfxstream_host_connection>();
    connection->parentRenderer = renderer;
    connection->contextId = contextId;
    connection->commands.reset(nucleus_android_shared_ring_attach(
        descriptors.command_memory_fd,
        descriptors.command_data_notification_fd,
        descriptors.command_space_notification_fd));
    if (!connection->commands) {
        close(descriptors.response_memory_fd);
        close(descriptors.response_data_notification_fd);
        close(descriptors.response_space_notification_fd);
        return nullptr;
    }
    connection->responses.reset(nucleus_android_shared_ring_attach(
        descriptors.response_memory_fd,
        descriptors.response_data_notification_fd,
        descriptors.response_space_notification_fd));
    if (!connection->responses) {
        return nullptr;
    }
    retainProcessResources(connection->parentRenderer, contextId);
    connection->processResourcesRegistered = true;
    connection->channel =
        renderer->renderer->createRenderChannel(nullptr, contextId);
    if (!connection->channel) {
        releaseProcessResources(connection->parentRenderer, contextId);
        connection->processResourcesRegistered = false;
        errno = EIO;
        return nullptr;
    }
    connection->rendererNotificationFd =
        eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    if (connection->rendererNotificationFd < 0) {
        connection->channel->stop();
        connection->channel.reset();
        releaseProcessResources(connection->parentRenderer, contextId);
        connection->processResourcesRegistered = false;
        return nullptr;
    }
    const int rendererNotificationFd = connection->rendererNotificationFd;
    connection->channel->setEventCallback(
        [rendererNotificationFd](gfxstream::RenderChannel::State) {
            signalRendererNotification(rendererNotificationFd);
        });
    connection->channel->setWantedEvents(
        gfxstream::RenderChannel::State::CanRead);
    connection->pump =
        std::make_unique<nucleus::android::gfxstream::HostRingChannelPump>(
            connection->commands.get(),
            connection->responses.get(),
            connection->channel);
    return connection.release();
}

extern "C" void nucleus_android_gfxstream_host_connection_destroy(
    nucleus_android_gfxstream_host_connection *connection) {
    if (!connection) {
        return;
    }
    (void)nucleus_android_shared_ring_close(
        connection->commands.get());
    (void)nucleus_android_shared_ring_close(
        connection->responses.get());
    if (connection->channel) {
        connection->channel->setEventCallback(
            [](gfxstream::RenderChannel::State) {});
        connection->channel->stop();
    }
    connection->pump.reset();
    connection->channel.reset();
    if (connection->processResourcesRegistered &&
        connection->parentRenderer) {
        releaseProcessResources(
            connection->parentRenderer,
            connection->contextId);
        connection->processResourcesRegistered = false;
    }
    if (connection->rendererNotificationFd >= 0) {
        close(connection->rendererNotificationFd);
        connection->rendererNotificationFd = -1;
    }
    delete connection;
}

extern "C" nucleus_android_gfxstream_host_pump_result
nucleus_android_gfxstream_host_connection_pump(
    nucleus_android_gfxstream_host_connection *connection) {
    if (!connection || !connection->pump) {
        return NUCLEUS_ANDROID_GFXSTREAM_HOST_PUMP_ERROR;
    }
    using nucleus::android::gfxstream::HostRingPumpResult;
    const HostRingPumpResult result = connection->pump->pumpOnce();
    gfxstream::RenderChannel::State wanted =
        gfxstream::RenderChannel::State::CanRead;
    if (result == HostRingPumpResult::waitingForRenderChannel) {
        wanted = static_cast<gfxstream::RenderChannel::State>(
            static_cast<int>(wanted) |
            static_cast<int>(gfxstream::RenderChannel::State::CanWrite));
    }
    connection->channel->setWantedEvents(wanted);
    switch (result) {
    case HostRingPumpResult::idle:
        return NUCLEUS_ANDROID_GFXSTREAM_HOST_PUMP_IDLE;
    case HostRingPumpResult::progress:
        return NUCLEUS_ANDROID_GFXSTREAM_HOST_PUMP_PROGRESS;
    case HostRingPumpResult::waitingForResponseRingSpace:
        return NUCLEUS_ANDROID_GFXSTREAM_HOST_PUMP_WAITING_FOR_RESPONSE_SPACE;
    case HostRingPumpResult::waitingForRenderChannel:
        return NUCLEUS_ANDROID_GFXSTREAM_HOST_PUMP_WAITING_FOR_RENDER_CHANNEL;
    case HostRingPumpResult::peerClosed:
        return NUCLEUS_ANDROID_GFXSTREAM_HOST_PUMP_PEER_CLOSED;
    case HostRingPumpResult::stopped:
        return NUCLEUS_ANDROID_GFXSTREAM_HOST_PUMP_STOPPED;
    case HostRingPumpResult::error:
        return NUCLEUS_ANDROID_GFXSTREAM_HOST_PUMP_ERROR;
    }
}

extern "C" int
nucleus_android_gfxstream_host_connection_command_notification_fd(
    nucleus_android_gfxstream_host_connection *connection) {
    return connection && connection->pump
               ? connection->pump->commandDataNotificationFD()
               : -1;
}

extern "C" int
nucleus_android_gfxstream_host_connection_response_space_notification_fd(
    nucleus_android_gfxstream_host_connection *connection) {
    return connection && connection->pump
               ? connection->pump->responseSpaceNotificationFD()
               : -1;
}

extern "C" int
nucleus_android_gfxstream_host_connection_renderer_notification_fd(
    nucleus_android_gfxstream_host_connection *connection) {
    return connection ? connection->rendererNotificationFd : -1;
}

extern "C" int
nucleus_android_gfxstream_host_connection_drain_renderer_notification(
    nucleus_android_gfxstream_host_connection *connection) {
    if (!connection || connection->rendererNotificationFd < 0) {
        errno = EINVAL;
        return -1;
    }
    return drainNotification(connection->rendererNotificationFd);
}
