#pragma once

#include <atomic>
#include <condition_variable>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>

#include "FrameComposer.h"
#include "NucleusComposerProtocol.h"

namespace aidl::android::hardware::graphics::composer3::impl {

class NucleusFrameComposer final : public FrameComposer {
  public:
    ~NucleusFrameComposer() override;
    HWC3::Error init() override;
    HWC3::Error getDisplayConfigurations(
        std::vector<DisplayMultiConfigs>* out_displays) override;
    HWC3::Error registerOnHotplugCallback(const HotplugCallback& callback) override;
    HWC3::Error unregisterOnHotplugCallback() override;
    HWC3::Error registerOnPhysicalVsyncCallback(
        const PhysicalVsyncCallback& callback) override;
    HWC3::Error unregisterOnPhysicalVsyncCallback() override;
    HWC3::Error onDisplayCreate(Display*) override;
    HWC3::Error onDisplayDestroy(Display*) override;
    HWC3::Error onDisplayClientTargetSet(Display*) override;
    HWC3::Error validateDisplay(Display*, DisplayChanges*) override;
    HWC3::Error presentDisplay(
        Display*,
        ::android::base::unique_fd*,
        std::unordered_map<int64_t, ::android::base::unique_fd>*) override;
    HWC3::Error onActiveConfigChange(Display*) override;
    std::vector<Capability> getCapabilities() const override;
    std::vector<DisplayCapability> getDisplayCapabilities(
        int64_t display_id) const override;

  private:
    struct DisplayTopology {
        uint32_t id;
        int32_t vsync_period_ns;
    };

    bool connectTopologySubscriber();
    bool receiveTopologyEvent(int topology_fd, bool* initial_snapshot_complete);
    void topologyLoop();
    void handleTopologyEvent(const nucleus_composer_topology_event& event);

    std::mutex socket_mutex_;
    ::android::base::unique_fd socket_;
    std::mutex topology_connection_mutex_;
    ::android::base::unique_fd topology_socket_;
    std::thread topology_thread_;
    std::mutex topology_ready_mutex_;
    std::condition_variable topology_ready_condition_;
    bool initial_topology_ready_ = false;
    std::atomic<bool> stopping_ = false;
    std::mutex stop_mutex_;
    std::condition_variable stop_condition_;
    std::string socket_path_;
    std::mutex topology_mutex_;
    std::mutex callback_mutex_;
    HotplugCallback hotplug_callback_;
    PhysicalVsyncCallback physical_vsync_callback_;
    std::unordered_map<uint32_t, DisplayTopology> displays_;
    uint64_t topology_generation_ = 0;
    uint64_t next_request_id_ = 1;
    uint64_t next_frame_number_ = 1;
};

}  // namespace aidl::android::hardware::graphics::composer3::impl
