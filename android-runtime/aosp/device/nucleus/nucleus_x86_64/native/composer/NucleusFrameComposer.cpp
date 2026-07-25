#include "NucleusFrameComposer.h"

#include <android-base/properties.h>
#include <android-base/unique_fd.h>
#include <cerrno>
#include <cstring>
#include <inttypes.h>
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
    const std::string path = ::android::base::GetProperty(
        "ro.vendor.nucleus.composer_socket", kDefaultSocket);
    socket_.reset(nucleus_android_ipc_connect(path.c_str()));
    if (!socket_.ok()) {
        ALOGE("Nucleus Composer3 cannot connect to %s: %s", path.c_str(), strerror(errno));
        return HWC3::Error::NoResources;
    }
    return HWC3::Error::None;
}

HWC3::Error NucleusFrameComposer::registerOnHotplugCallback(
    const HotplugCallback& callback) {
    callback(true, 0, 1280, 720, 160, 160, 60);
    return HWC3::Error::None;
}

HWC3::Error NucleusFrameComposer::unregisterOnHotplugCallback() {
    return HWC3::Error::None;
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
