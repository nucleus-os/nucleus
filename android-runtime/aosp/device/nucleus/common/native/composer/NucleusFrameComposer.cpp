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
#include "NucleusIPCTransportC.h"
#include "NucleusComposerProtocol.h"

namespace aidl::android::hardware::graphics::composer3::impl {
namespace {

constexpr const char* kDefaultSocket = "/dev/nucleus/composer.sock";
constexpr auto kInitialTopologyTimeout = std::chrono::seconds(5);

}  // namespace

HWC3::Error NucleusFrameComposer::init() {
    socket_path_ = ::android::base::GetProperty(
        "ro.vendor.nucleus.composer_socket", kDefaultSocket);
    topology_thread_ = std::thread(&NucleusFrameComposer::topologyLoop, this);
    {
        std::unique_lock<std::mutex> lock(topology_ready_mutex_);
        if (!topology_ready_condition_.wait_for(
                lock,
                kInitialTopologyTimeout,
                [this] {
                    return initial_topology_ready_ || stopping_.load();
                }) ||
            !initial_topology_ready_) {
            ALOGE(
                "Nucleus Composer3 timed out waiting for the initial topology "
                "snapshot from %s",
                socket_path_.c_str());
            stopping_.store(true);
            stop_condition_.notify_all();
            {
                std::lock_guard<std::mutex> connection_lock(
                    topology_connection_mutex_);
                if (topology_socket_.ok()) {
                    shutdown(topology_socket_.get(), SHUT_RDWR);
                }
            }
            return HWC3::Error::NoResources;
        }
    }
    ALOGI("Nucleus Composer3 initial topology is ready");
    return HWC3::Error::None;
}

bool NucleusFrameComposer::connectTopologySubscriber() {
    ::android::base::unique_fd subscriber(
        nucleus_ipc_connect(socket_path_.c_str()));
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
        .operation = NUCLEUS_COMPOSER_SUBSCRIBE_TOPOLOGY,
        .byte_count = sizeof(subscribe),
        .fd_count = 0,
        .last_generation = last_generation,
    };
    if (nucleus_ipc_send(
            subscriber.get(), &subscribe, sizeof(subscribe), nullptr, 0) != 0) {
        ALOGE("Nucleus Composer3 topology subscription failed: %s", strerror(errno));
        return false;
    }
    ALOGI(
        "Nucleus Composer3 topology subscription sent at generation %" PRIu64,
        last_generation);
    {
        std::lock_guard<std::mutex> lock(topology_connection_mutex_);
        topology_socket_ = std::move(subscriber);
    }
    return true;
}

NucleusFrameComposer::~NucleusFrameComposer() {
    stopping_.store(true);
    stop_condition_.notify_all();
    topology_ready_condition_.notify_all();
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
    std::lock_guard<std::mutex> callback_lock(callback_mutex_);
    hotplug_callback_ = callback;
    return HWC3::Error::None;
}

HWC3::Error NucleusFrameComposer::getDisplayConfigurations(
    std::vector<DisplayMultiConfigs>* out_displays) {
    if (out_displays == nullptr) {
        return HWC3::Error::BadParameter;
    }

    std::lock_guard<std::mutex> lock(topology_mutex_);
    out_displays->clear();
    out_displays->reserve(displays_.size());
    for (const auto& [_, display] : displays_) {
        DisplayConfig config(
            static_cast<int32_t>(display.id),
            static_cast<int32_t>(display.width),
            static_cast<int32_t>(display.height),
            /*dpiX=*/160,
            /*dpiY=*/160,
            display.vsync_period_ns);
        config.setConfigGroup(0);
        out_displays->push_back(DisplayMultiConfigs{
            .displayId = static_cast<int64_t>(display.id),
            .activeConfigId = static_cast<int32_t>(display.id),
            .configs = {std::move(config)},
        });
    }
    return HWC3::Error::None;
}

HWC3::Error NucleusFrameComposer::unregisterOnHotplugCallback() {
    std::lock_guard<std::mutex> callback_lock(callback_mutex_);
    std::lock_guard<std::mutex> lock(topology_mutex_);
    hotplug_callback_ = {};
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
    const int received = nucleus_ipc_receive(
        topology_fd, &event, sizeof(event), nullptr, 0, &fd_count);
    if (received < 0) {
        if (!stopping_.load()) {
            ALOGW("Nucleus Composer3 topology disconnected: %s", strerror(errno));
        }
        return false;
    }
    if (received != sizeof(event) ||
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
        bool snapshot_complete = false;
        if (!receiveTopologyEvent(topology_fd, &snapshot_complete)) {
            {
                std::lock_guard<std::mutex> lock(topology_connection_mutex_);
                if (topology_socket_.get() == topology_fd) {
                    topology_socket_.reset();
                }
            }
            std::unique_lock<std::mutex> lock(stop_mutex_);
            stop_condition_.wait_for(
                lock, std::chrono::milliseconds(250),
                [this] { return stopping_.load(); });
            continue;
        }
        if (snapshot_complete) {
            bool became_ready = false;
            {
                std::lock_guard<std::mutex> lock(topology_ready_mutex_);
                if (!initial_topology_ready_) {
                    initial_topology_ready_ = true;
                    became_ready = true;
                }
            }
            if (became_ready) {
                size_t display_count = 0;
                uint64_t generation = 0;
                {
                    std::lock_guard<std::mutex> lock(topology_mutex_);
                    display_count = displays_.size();
                    generation = topology_generation_;
                }
                ALOGI(
                    "Nucleus Composer3 received initial topology snapshot: "
                    "generation=%" PRIu64 " displays=%zu",
                    generation,
                    display_count);
                topology_ready_condition_.notify_all();
            }
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
    if (event.display_id > std::numeric_limits<uint32_t>::max() ||
        event.mode_width <= 0 ||
        event.mode_height <= 0 ||
        event.refresh_period_ns == 0 ||
        event.refresh_period_ns > std::numeric_limits<int32_t>::max()) {
        ALOGE("Nucleus Composer3 received invalid output topology values");
        return;
    }

    bool connected = event.operation != NUCLEUS_COMPOSER_OUTPUT_DISCONNECTED;
    DisplayTopology display = {
        .id = static_cast<uint32_t>(event.display_id),
        .width = static_cast<uint32_t>(event.mode_width),
        .height = static_cast<uint32_t>(event.mode_height),
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
                display.width,
                display.height,
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
    *out_display_fence = display->getClientTarget().getFence();
    return HWC3::Error::None;
}

}  // namespace aidl::android::hardware::graphics::composer3::impl
