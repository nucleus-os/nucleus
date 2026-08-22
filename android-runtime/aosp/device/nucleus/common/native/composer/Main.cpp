#include <android-base/logging.h>
#include <android/binder_manager.h>
#include <android/binder_process.h>

#include <cstdlib>
#include <string>

#include "Composer.h"

using aidl::android::hardware::graphics::composer3::impl::Composer;

int main() {
    ALOGI("Nucleus Composer3 service starting");
    auto composer = ndk::SharedRefBase::make<Composer>();
    CHECK(composer != nullptr);
    const std::string instance = std::string(Composer::descriptor) + "/default";
    CHECK_EQ(
        AServiceManager_addService(composer->asBinder().get(), instance.c_str()),
        STATUS_OK);
    ABinderProcess_setThreadPoolMaxThreadCount(5);
    ABinderProcess_startThreadPool();
    ABinderProcess_joinThreadPool();
    return EXIT_FAILURE;
}
