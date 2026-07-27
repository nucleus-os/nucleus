#include <aidl/android/hardware/graphics/allocator/AllocationError.h>
#include <aidl/android/hardware/graphics/allocator/AllocationResult.h>
#include <aidl/android/hardware/graphics/allocator/BnAllocator.h>
#include <aidl/android/hardware/graphics/common/BufferUsage.h>
#include <aidl/android/hardware/graphics/common/PixelFormat.h>
#include <aidlcommonsupport/NativeHandle.h>
#include <android-base/logging.h>
#include <android/binder_manager.h>
#include <android/binder_process.h>
#include <android/binder_ibinder_platform.h>
#include <drm_fourcc.h>
#include <log/log.h>

#include <memory>
#include <string>
#include <vector>

#include "NucleusGrallocBrokerClient.h"
#include "NucleusGrallocFormats.h"
#include "NucleusGrallocHandle.h"

namespace {

using aidl::android::hardware::graphics::allocator::AllocationError;
using aidl::android::hardware::graphics::allocator::AllocationResult;
using aidl::android::hardware::graphics::allocator::BnAllocator;
using aidl::android::hardware::graphics::allocator::BufferDescriptorInfo;
using aidl::android::hardware::graphics::common::BufferUsage;
using aidl::android::hardware::graphics::common::PixelFormat;

ndk::ScopedAStatus error(AllocationError value) {
    return ndk::ScopedAStatus::fromServiceSpecificError(
        static_cast<int32_t>(value));
}

uint32_t drmFormat(PixelFormat format) {
    const auto *contract = nucleus_gralloc_format_for_android(format);
    return contract == nullptr ? 0 : contract->drm;
}

bool supported(const BufferDescriptorInfo &descriptor) {
    if (descriptor.width <= 0 || descriptor.height <= 0 ||
        descriptor.layerCount != 1 || descriptor.reservedSize != 0 ||
        drmFormat(descriptor.format) == 0 ||
        (static_cast<uint64_t>(descriptor.usage) &
         static_cast<uint64_t>(BufferUsage::PROTECTED)) != 0) {
        return false;
    }
    for (const auto &option : descriptor.additionalOptions) {
        if (option.name !=
            "android.hardware.graphics.common.Dataspace") {
            return false;
        }
    }
    return true;
}

void releaseHandle(native_handle_t *native) {
    native_handle_close(native);
    native_handle_delete(native);
}

class NucleusAllocator final : public BnAllocator {
  public:
    ndk::ScopedAStatus allocate2(
        const BufferDescriptorInfo &descriptor,
        int32_t count,
        AllocationResult *result) override {
        if (count <= 0 || !supported(descriptor)) {
            return error(AllocationError::BAD_DESCRIPTOR);
        }
        std::vector<native_handle_t *> handles;
        handles.reserve(count);
        for (int32_t index = 0; index < count; ++index) {
            native_handle_t *handle = nucleus_gralloc_broker_allocate(
                descriptor, drmFormat(descriptor.format));
            if (handle == nullptr) {
                for (native_handle_t *allocated : handles) {
                    releaseHandle(allocated);
                }
                return error(AllocationError::NO_RESOURCES);
            }
            handles.push_back(handle);
        }
        result->stride =
            nucleus_gralloc_handle_cast(handles.front())->pixel_stride;
        result->buffers.reserve(count);
        for (native_handle_t *handle : handles) {
            result->buffers.push_back(android::dupToAidl(handle));
            releaseHandle(handle);
        }
        return ndk::ScopedAStatus::ok();
    }

    ndk::ScopedAStatus allocate(
        const std::vector<uint8_t> &,
        int32_t,
        AllocationResult *) override {
        return error(AllocationError::UNSUPPORTED);
    }

    ndk::ScopedAStatus isSupported(
        const BufferDescriptorInfo &descriptor,
        bool *result) override {
        *result = supported(descriptor);
        return ndk::ScopedAStatus::ok();
    }

    ndk::ScopedAStatus getIMapperLibrarySuffix(
        std::string *result) override {
        *result = "nucleus";
        return ndk::ScopedAStatus::ok();
    }

    ndk::ScopedAStatus isMultiViewSupported(
        const std::vector<BufferDescriptorInfo> &,
        int32_t,
        bool *result) override {
        *result = false;
        return ndk::ScopedAStatus::ok();
    }

    ndk::ScopedAStatus allocateMultiView(
        const std::vector<BufferDescriptorInfo> &,
        int32_t,
        AllocationResult *) override {
        return error(AllocationError::UNSUPPORTED);
    }

    ndk::SpAIBinder createBinder() override {
        auto binder = BnAllocator::createBinder();
        AIBinder_setInheritRt(binder.get(), true);
        return binder;
    }
};

}  // namespace

int main() {
    auto allocator = ndk::SharedRefBase::make<NucleusAllocator>();
    const std::string instance =
        std::string(NucleusAllocator::descriptor) + "/default";
    CHECK_EQ(
        AServiceManager_addServiceWithFlags(
            allocator->asBinder().get(),
            instance.c_str(),
            AServiceManager_AddServiceFlag::ADD_SERVICE_ALLOW_ISOLATED),
        STATUS_OK);
    ABinderProcess_setThreadPoolMaxThreadCount(4);
    ABinderProcess_startThreadPool();
    ABinderProcess_joinThreadPool();
    return EXIT_FAILURE;
}
