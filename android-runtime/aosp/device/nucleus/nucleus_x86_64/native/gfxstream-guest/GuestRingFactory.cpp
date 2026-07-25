#include "NucleusAndroidGfxstreamAdapters/GuestRingFactory.h"

#include <cerrno>
#include <dlfcn.h>
#include <memory>
#include <unistd.h>

#include "NucleusAndroidGfxstreamAdapters/GuestRingStream.h"

struct nucleus_android_gfxstream_factory_registration {
    nucleus_android_gfxstream_set_external_iostream_factory setter;
    nucleus_android_gfxstream_endpoint_provider provider;
    void *providerContext;
};

namespace {

void closeDescriptors(
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

void *createGuestRingStream(void *context, std::size_t bufferSize) {
    auto *registration =
        static_cast<nucleus_android_gfxstream_factory_registration *>(context);
    nucleus_android_gfxstream_endpoint_descriptors descriptors = {
        .command_memory_fd = -1,
        .command_data_notification_fd = -1,
        .command_space_notification_fd = -1,
        .response_memory_fd = -1,
        .response_data_notification_fd = -1,
        .response_space_notification_fd = -1,
    };
    if (registration->provider(
            registration->providerContext,
            &descriptors) != 0) {
        closeDescriptors(descriptors);
        return nullptr;
    }

    auto stream = nucleus::android::gfxstream::GuestRingStream::attach(
        descriptors.command_memory_fd,
        descriptors.command_data_notification_fd,
        descriptors.command_space_notification_fd,
        descriptors.response_memory_fd,
        descriptors.response_data_notification_fd,
        descriptors.response_space_notification_fd,
        bufferSize);
    if (!stream) {
        return nullptr;
    }
    return stream.release();
}

}  // namespace

extern "C" nucleus_android_gfxstream_factory_registration *
nucleus_android_gfxstream_factory_registration_create(
    void *gfxstreamICDHandle,
    nucleus_android_gfxstream_endpoint_provider provider,
    void *providerContext) {
    if (gfxstreamICDHandle == nullptr) {
        errno = EINVAL;
        return nullptr;
    }
    auto setter = reinterpret_cast<
        nucleus_android_gfxstream_set_external_iostream_factory>(
        dlsym(
            gfxstreamICDHandle,
            "gfxstream_vk_set_external_iostream_factory"));
    if (setter == nullptr) {
        errno = ENOENT;
        return nullptr;
    }
    return nucleus_android_gfxstream_factory_registration_create_with_setter(
        setter,
        provider,
        providerContext);
}

extern "C" nucleus_android_gfxstream_factory_registration *
nucleus_android_gfxstream_factory_registration_create_with_setter(
    nucleus_android_gfxstream_set_external_iostream_factory setter,
    nucleus_android_gfxstream_endpoint_provider provider,
    void *providerContext) {
    if (setter == nullptr || provider == nullptr) {
        errno = EINVAL;
        return nullptr;
    }
    auto registration =
        std::make_unique<nucleus_android_gfxstream_factory_registration>();
    registration->setter = setter;
    registration->provider = provider;
    registration->providerContext = providerContext;
    setter(createGuestRingStream, registration.get());
    return registration.release();
}

extern "C" void nucleus_android_gfxstream_factory_registration_destroy(
    nucleus_android_gfxstream_factory_registration *registration) {
    if (registration == nullptr) {
        return;
    }
    registration->setter(nullptr, nullptr);
    delete registration;
}
