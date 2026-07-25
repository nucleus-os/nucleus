#pragma once

#include <mutex>

#include "FrameComposer.h"

namespace aidl::android::hardware::graphics::composer3::impl {

class NucleusFrameComposer final : public FrameComposer {
  public:
    HWC3::Error init() override;
    HWC3::Error registerOnHotplugCallback(const HotplugCallback& callback) override;
    HWC3::Error unregisterOnHotplugCallback() override;
    HWC3::Error onDisplayCreate(Display*) override;
    HWC3::Error onDisplayDestroy(Display*) override;
    HWC3::Error onDisplayClientTargetSet(Display*) override;
    HWC3::Error validateDisplay(Display*, DisplayChanges*) override;
    HWC3::Error presentDisplay(
        Display*,
        ::android::base::unique_fd*,
        std::unordered_map<int64_t, ::android::base::unique_fd>*) override;
    HWC3::Error onActiveConfigChange(Display*) override;

  private:
    std::mutex socket_mutex_;
    ::android::base::unique_fd socket_;
    uint64_t next_request_id_ = 1;
    uint64_t next_frame_number_ = 1;
};

}  // namespace aidl::android::hardware::graphics::composer3::impl
