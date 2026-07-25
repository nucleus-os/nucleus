#include "Device.h"

#include "NucleusFrameComposer.h"

ANDROID_SINGLETON_STATIC_INSTANCE(aidl::android::hardware::graphics::composer3::impl::Device);

namespace aidl::android::hardware::graphics::composer3::impl {

HWC3::Error Device::getComposer(FrameComposer** out_composer) {
    std::lock_guard<std::mutex> lock(mMutex);
    if (mComposer == nullptr) {
        mComposer = std::make_unique<NucleusFrameComposer>();
        const HWC3::Error error = mComposer->init();
        if (error != HWC3::Error::None) {
            mComposer.reset();
            return error;
        }
    }
    *out_composer = mComposer.get();
    return HWC3::Error::None;
}

HWC3::Error Device::getPersistentKeyValue(
    const std::string&,
    const std::string& default_value,
    std::string* out_value) {
    *out_value = default_value;
    return HWC3::Error::None;
}

HWC3::Error Device::setPersistentKeyValue(const std::string&, const std::string&) {
    return HWC3::Error::Unsupported;
}

bool Device::persistentKeyValueEnabled() const {
    return false;
}

}  // namespace aidl::android::hardware::graphics::composer3::impl
