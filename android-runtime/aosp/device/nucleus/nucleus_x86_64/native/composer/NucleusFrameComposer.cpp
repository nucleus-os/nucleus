#include "NucleusFrameComposer.h"

#include <android-base/properties.h>
#include <android-base/unique_fd.h>
#include <algorithm>
#include <chrono>
#include <cerrno>
#include <cstring>
#include <inttypes.h>
#include <limits>
#include <sys/socket.h>
#include <unistd.h>

#include "Display.h"
#include "Layer.h"
#include "NucleusAndroidIPCC.h"
#include "NucleusComposerProtocol.h"
#include "NucleusGrallocHandle.h"

namespace aidl::android::hardware::graphics::composer3::impl {
namespace {

constexpr const char* kDefaultSocket = "/dev/nucleus/composer.sock";

}  // namespace

HWC3::Error NucleusFrameComposer::init() {
    socket_path_ = ::android::base::GetProperty(
        "ro.vendor.nucleus.composer_socket", kDefaultSocket);
    socket_.reset(nucleus_android_ipc_connect(socket_path_.c_str()));
    if (!socket_.ok()) {
        ALOGE("Nucleus Composer3 cannot connect to %s: %s",
              socket_path_.c_str(), strerror(errno));
        return HWC3::Error::NoResources;
    }
    if (!connectTopologySubscriber()) {
        socket_.reset();
        return HWC3::Error::NoResources;
    }
    topology_thread_ = std::thread(&NucleusFrameComposer::topologyLoop, this);
    return HWC3::Error::None;
}

bool NucleusFrameComposer::connectTopologySubscriber() {
    ::android::base::unique_fd subscriber(
        nucleus_android_ipc_connect(socket_path_.c_str()));
    if (!subscriber.ok()) {
        ALOGE("Nucleus Composer3 topology cannot connect to %s: %s",
              socket_path_.c_str(), strerror(errno));
        return false;
    }
    uint64_t last_generation = 0;
    {
        std::lock_guard<std::mutex> lock(topology_mutex_);
        last_generation = topology_generation_;
    }
    const nucleus_composer_topology_subscribe_request subscribe = {
        .magic = NUCLEUS_COMPOSER_PROTOCOL_MAGIC,
        .version = NUCLEUS_COMPOSER_PROTOCOL_VERSION,
        .operation = NUCLEUS_COMPOSER_SUBSCRIBE_TOPOLOGY,
        .byte_count = sizeof(subscribe),
        .fd_count = 0,
        .last_generation = last_generation,
    };
    if (nucleus_android_ipc_send(
            subscriber.get(), &subscribe, sizeof(subscribe), nullptr, 0) != 0) {
        ALOGE("Nucleus Composer3 topology subscription failed: %s", strerror(errno));
        return false;
    }
    bool initial_snapshot_complete = false;
    while (!initial_snapshot_complete) {
        if (!receiveTopologyEvent(
                subscriber.get(), &initial_snapshot_complete)) {
            return false;
        }
    }
    {
        std::lock_guard<std::mutex> lock(topology_connection_mutex_);
        topology_socket_ = std::move(subscriber);
    }
    return true;
}

NucleusFrameComposer::~NucleusFrameComposer() {
    stopping_.store(true);
    stop_condition_.notify_all();
    {
        std::lock_guard<std::mutex> lock(topology_connection_mutex_);
        if (topology_socket_.ok()) {
            shutdown(topology_socket_.get(), SHUT_RDWR);
        }
    }
    if (topology_thread_.joinable()) topology_thread_.join();
}

HWC3::Error NucleusFrameComposer::registerOnHotplugCallback(
    const HotplugCallback& callback) {
    std::vector<DisplayTopology> snapshot;
    {
        std::lock_guard<std::mutex> callback_lock(callback_mutex_);
        std::lock_guard<std::mutex> lock(topology_mutex_);
        hotplug_callback_ = callback;
        snapshot.reserve(displays_.size());
        for (const auto& [_, display] : displays_) snapshot.push_back(display);
    }
    for (const auto& display : snapshot) {
        callback(true, display.id, 1280, 720, 160, 160, display.vsync_period_ns);
    }
    return HWC3::Error::None;
}

HWC3::Error NucleusFrameComposer::unregisterOnHotplugCallback() {
    std::lock_guard<std::mutex> callback_lock(callback_mutex_);
    std::lock_guard<std::mutex> lock(topology_mutex_);
    hotplug_callback_ = {};
    return HWC3::Error::None;
}

HWC3::Error NucleusFrameComposer::registerOnPhysicalVsyncCallback(
    const PhysicalVsyncCallback& callback) {
    std::lock_guard<std::mutex> callback_lock(callback_mutex_);
    std::lock_guard<std::mutex> lock(topology_mutex_);
    physical_vsync_callback_ = callback;
    return HWC3::Error::None;
}

HWC3::Error NucleusFrameComposer::unregisterOnPhysicalVsyncCallback() {
    std::lock_guard<std::mutex> callback_lock(callback_mutex_);
    std::lock_guard<std::mutex> lock(topology_mutex_);
    physical_vsync_callback_ = {};
    return HWC3::Error::None;
}

std::vector<Capability> NucleusFrameComposer::getCapabilities() const {
    return {};
}

std::vector<DisplayCapability> NucleusFrameComposer::getDisplayCapabilities(
    int64_t) const {
    return {};
}

bool NucleusFrameComposer::receiveTopologyEvent(
    int topology_fd,
    bool* initial_snapshot_complete) {
    nucleus_composer_topology_event event = {};
    size_t fd_count = 0;
    const int received = nucleus_android_ipc_receive(
        topology_fd, &event, sizeof(event), nullptr, 0, &fd_count);
    if (received < 0) {
        if (!stopping_.load()) {
            ALOGW("Nucleus Composer3 topology disconnected: %s", strerror(errno));
        }
        return false;
    }
    if (received != sizeof(event) ||
        event.magic != NUCLEUS_COMPOSER_PROTOCOL_MAGIC ||
        event.version != NUCLEUS_COMPOSER_PROTOCOL_VERSION ||
        event.byte_count != sizeof(event) ||
        event.fd_count != 0 ||
        fd_count != 0) {
        ALOGE("Nucleus Composer3 received an invalid topology event");
        return false;
    }
    if (event.status != NUCLEUS_COMPOSER_STATUS_OK) {
        ALOGE("Nucleus Composer3 topology subscription rejected: status=%" PRIu32,
              event.status);
        return false;
    }
    handleTopologyEvent(event);
    if (initial_snapshot_complete != nullptr &&
        event.operation == NUCLEUS_COMPOSER_TOPOLOGY_SNAPSHOT &&
        event.display_id == std::numeric_limits<uint64_t>::max()) {
        *initial_snapshot_complete = true;
    }
    return true;
}

void NucleusFrameComposer::topologyLoop() {
    while (!stopping_.load()) {
        int topology_fd = -1;
        {
            std::lock_guard<std::mutex> lock(topology_connection_mutex_);
            topology_fd = topology_socket_.get();
        }
        if (topology_fd < 0) {
            if (connectTopologySubscriber()) {
                continue;
            }
            std::unique_lock<std::mutex> lock(stop_mutex_);
            stop_condition_.wait_for(
                lock, std::chrono::milliseconds(250),
                [this] { return stopping_.load(); });
            continue;
        }
        if (!receiveTopologyEvent(topology_fd, nullptr)) {
            {
                std::lock_guard<std::mutex> lock(topology_connection_mutex_);
                if (topology_socket_.get() == topology_fd) {
                    topology_socket_.reset();
                }
            }
            continue;
        }
    }
}

void NucleusFrameComposer::handleTopologyEvent(
    const nucleus_composer_topology_event& event) {
    if (event.operation == NUCLEUS_COMPOSER_TOPOLOGY_SNAPSHOT &&
        event.display_id == std::numeric_limits<uint64_t>::max()) {
        std::lock_guard<std::mutex> lock(topology_mutex_);
        topology_generation_ = std::max(topology_generation_, event.generation);
        return;
    }
    if (event.operation == NUCLEUS_COMPOSER_OUTPUT_PRESENTED) {
        if (event.display_id > std::numeric_limits<uint32_t>::max() ||
            event.presentation_timestamp_ns == 0 ||
            event.presentation_timestamp_ns >
                static_cast<uint64_t>(std::numeric_limits<int64_t>::max()) ||
            event.refresh_period_ns == 0 ||
            event.refresh_period_ns > std::numeric_limits<int32_t>::max()) {
            ALOGE("Nucleus Composer3 received invalid physical-vsync values");
            return;
        }
        {
            std::lock_guard<std::mutex> callback_lock(callback_mutex_);
            std::lock_guard<std::mutex> lock(topology_mutex_);
            const auto display = displays_.find(
                static_cast<uint32_t>(event.display_id));
            if (display == displays_.end()) {
                return;
            }
            const int32_t selected_period_ns =
                display->second.vsync_period_ns;
            if (event.refresh_period_ns !=
                static_cast<uint64_t>(selected_period_ns)) {
                ALOGW("Nucleus Composer3 presentation interval %" PRIu64
                      "ns differs from selected period %" PRId32 "ns",
                      event.refresh_period_ns, selected_period_ns);
            }
            if (physical_vsync_callback_) {
                physical_vsync_callback_(
                    static_cast<int64_t>(event.display_id),
                    event.presentation_timestamp_ns,
                    selected_period_ns);
            }
        }
        return;
    }
    if (event.display_id > std::numeric_limits<uint32_t>::max() ||
        event.refresh_period_ns == 0 ||
        event.refresh_period_ns > std::numeric_limits<int32_t>::max()) {
        ALOGE("Nucleus Composer3 received invalid output topology values");
        return;
    }

    bool connected = event.operation != NUCLEUS_COMPOSER_OUTPUT_DISCONNECTED;
    DisplayTopology display = {
        .id = static_cast<uint32_t>(event.display_id),
        .vsync_period_ns = static_cast<int32_t>(event.refresh_period_ns),
    };
    {
        std::lock_guard<std::mutex> lock(topology_mutex_);
        if (event.operation != NUCLEUS_COMPOSER_TOPOLOGY_SNAPSHOT &&
            event.generation <= topology_generation_) {
            ALOGW("Nucleus Composer3 ignored stale topology generation %" PRIu64,
                  event.generation);
            return;
        }
        topology_generation_ = std::max(topology_generation_, event.generation);
        if (connected) {
            displays_[display.id] = display;
        } else {
            displays_.erase(display.id);
        }
    }
    {
        std::lock_guard<std::mutex> callback_lock(callback_mutex_);
        std::lock_guard<std::mutex> lock(topology_mutex_);
        if (hotplug_callback_) {
            hotplug_callback_(
                connected,
                display.id,
                1280,
                720,
                160,
                160,
                display.vsync_period_ns);
        }
    }
}

HWC3::Error NucleusFrameComposer::onDisplayCreate(Display*) {
    return HWC3::Error::None;
}

HWC3::Error NucleusFrameComposer::onDisplayDestroy(Display*) {
    return HWC3::Error::None;
}

HWC3::Error NucleusFrameComposer::onDisplayClientTargetSet(Display*) {
    return HWC3::Error::None;
}

HWC3::Error NucleusFrameComposer::onActiveConfigChange(Display*) {
    return HWC3::Error::None;
}

HWC3::Error NucleusFrameComposer::validateDisplay(
    Display* display,
    DisplayChanges* out_changes) {
    for (Layer* layer : display->getOrderedLayers()) {
        if (layer->getCompositionType() != Composition::CLIENT) {
            out_changes->addLayerCompositionChange(
                display->getId(), layer->getId(), Composition::CLIENT);
        }
    }
    return HWC3::Error::None;
}

HWC3::Error NucleusFrameComposer::presentDisplay(
    Display* display,
    ::android::base::unique_fd* out_display_fence,
    std::unordered_map<int64_t, ::android::base::unique_fd>*) {
    std::lock_guard<std::mutex> lock(socket_mutex_);
    if (!socket_.ok()) {
        return HWC3::Error::NoResources;
    }

    const auto* handle =
        nucleus_gralloc_handle_cast(display->getClientTarget().getBuffer());
    if (handle == nullptr) {
        ALOGE("Nucleus Composer3 received a non-Nucleus client target");
        return HWC3::Error::BadParameter;
    }

    ::android::base::unique_fd acquire = display->getClientTarget().getFence();
    nucleus_composer_present_request request = {
        .magic = NUCLEUS_COMPOSER_PROTOCOL_MAGIC,
        .version = NUCLEUS_COMPOSER_PROTOCOL_VERSION,
        .operation = NUCLEUS_COMPOSER_PRESENT,
        .byte_count = sizeof(request),
        .fd_count = static_cast<uint32_t>(acquire.ok() ? 3 : 2),
        .request_id = next_request_id_++,
        .display_id = static_cast<uint64_t>(display->getId()),
        .allocation_id = handle->allocation_id,
        .frame_number = next_frame_number_++,
        .drm_modifier = handle->drm_modifier,
        .allocation_size = handle->allocation_size,
        .width = handle->width,
        .height = handle->height,
        .drm_format = handle->drm_format,
        .plane_offset = handle->plane_offset,
        .plane_stride = handle->plane_stride,
        .damage_left = 0,
        .damage_top = 0,
        .damage_right = static_cast<int32_t>(handle->width),
        .damage_bottom = static_cast<int32_t>(handle->height),
        .has_acquire_fence = acquire.ok() ? 1u : 0u,
        .reserved = 0,
    };
    int descriptors[3] = {handle->dmabuf_fd, handle->lifetime_fd, acquire.get()};
    if (nucleus_android_ipc_send(
            socket_.get(), &request, sizeof(request), descriptors, request.fd_count) != 0) {
        ALOGE("Nucleus Composer3 present send failed: %s", strerror(errno));
        socket_.reset();
        return HWC3::Error::NoResources;
    }

    nucleus_composer_present_reply reply = {};
    int reply_descriptors[1] = {-1};
    size_t reply_fd_count = 0;
    const int received = nucleus_android_ipc_receive(
        socket_.get(),
        &reply,
        sizeof(reply),
        reply_descriptors,
        1,
        &reply_fd_count);
    if (received != sizeof(reply) ||
        reply.magic != NUCLEUS_COMPOSER_PROTOCOL_MAGIC ||
        reply.version != NUCLEUS_COMPOSER_PROTOCOL_VERSION ||
        reply.operation != NUCLEUS_COMPOSER_PRESENT ||
        reply.byte_count != sizeof(reply) ||
        reply.request_id != request.request_id ||
        reply.status != NUCLEUS_COMPOSER_STATUS_OK ||
        reply.fd_count != 1 ||
        reply_fd_count != 1) {
        if (reply_fd_count == 1) close(reply_descriptors[0]);
        ALOGE("Nucleus Composer3 received an invalid present reply");
        socket_.reset();
        return HWC3::Error::NoResources;
    }
    out_display_fence->reset(reply_descriptors[0]);
    return HWC3::Error::None;
}

}  // namespace aidl::android::hardware::graphics::composer3::impl
