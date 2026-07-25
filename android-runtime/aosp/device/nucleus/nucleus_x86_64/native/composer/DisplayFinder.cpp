#include "DisplayFinder.h"

#include "Time.h"

namespace aidl::android::hardware::graphics::composer3::impl {

void parseExternalDisplaysFromProperties(std::vector<int>&) {}

HWC3::Error findDisplays(
    const DrmClient*,
    std::vector<DisplayMultiConfigs>* out_displays) {
    out_displays->clear();
    out_displays->push_back(DisplayMultiConfigs{
        .displayId = 0,
        .activeConfigId = 0,
        .configs = {
            DisplayConfig(
                0,
                1280,
                720,
                160,
                160,
                HertzToPeriodNanos(60)),
        },
    });
    DisplayConfig::addConfigGroups(&out_displays->front().configs);
    return HWC3::Error::None;
}

}  // namespace aidl::android::hardware::graphics::composer3::impl
