#include "DisplayFinder.h"

namespace aidl::android::hardware::graphics::composer3::impl {

void parseExternalDisplaysFromProperties(std::vector<int>&) {}

HWC3::Error findDisplays(
    const DrmClient*,
    std::vector<DisplayMultiConfigs>* out_displays) {
    out_displays->clear();
    return HWC3::Error::None;
}

}  // namespace aidl::android::hardware::graphics::composer3::impl
