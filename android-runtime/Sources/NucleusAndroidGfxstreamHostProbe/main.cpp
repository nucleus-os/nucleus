#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include <memory>
#include <string>
#include <vector>

#include "NucleusAndroidDrmC.h"
#include "NucleusAndroidGfxstreamHostC.h"

namespace {

template <typename T, void (*Destroy)(T *)>
using Owned = std::unique_ptr<T, decltype(Destroy)>;

void printFailure(const std::string &message) {
    std::printf(
        "{\"status\":\"rejected\",\"error\":\"%s\"}\n",
        message.c_str());
}

}  // namespace

int main(int argc, char **argv) {
    const char *requestedRenderNode = argc > 1 ? argv[1] : nullptr;
    const int candidateCount = nucleus_android_drm_enumerate(nullptr, 0);
    if (candidateCount <= 0) {
        printFailure("no DRM render nodes are available");
        return 2;
    }
    std::vector<nucleus_android_drm_candidate> candidates(
        static_cast<std::size_t>(candidateCount));
    const int filled =
        nucleus_android_drm_enumerate(candidates.data(), candidates.size());
    if (filled <= 0) {
        printFailure("DRM render-node enumeration failed");
        return 2;
    }

    const nucleus_android_drm_candidate *candidate = nullptr;
    for (int index = 0; index < filled; ++index) {
        if (!requestedRenderNode ||
            std::strcmp(candidates[index].render_path, requestedRenderNode) == 0) {
            candidate = &candidates[index];
            break;
        }
    }
    if (!candidate) {
        printFailure("the requested DRM render node was not found");
        return 2;
    }

    char error[1024] = {};
    Owned<nucleus_android_gpu, nucleus_android_gpu_destroy> gpu(
        nucleus_android_gpu_create(
            candidate->render_path,
            error,
            sizeof(error)),
        nucleus_android_gpu_destroy);
    if (!gpu) {
        printFailure(error);
        return 2;
    }
    nucleus_android_gpu_diagnostic diagnostic = {};
    if (nucleus_android_gpu_get_diagnostic(gpu.get(), &diagnostic) != 0) {
        printFailure("GPU diagnostic unavailable");
        return 2;
    }

    Owned<
        nucleus_android_gfxstream_host_renderer,
        nucleus_android_gfxstream_host_renderer_destroy>
        renderer(
            nucleus_android_gfxstream_host_renderer_create(
                64,
                64,
                diagnostic.device_uuid,
                error,
                sizeof(error)),
            nucleus_android_gfxstream_host_renderer_destroy);
    if (!renderer) {
        printFailure(error);
        return 2;
    }

    const uint32_t format = nucleus_android_drm_format_xrgb8888();
    const int modifierCount = nucleus_android_gpu_list_format_modifiers(
        gpu.get(),
        format,
        nullptr,
        0);
    if (modifierCount <= 0) {
        printFailure("the selected GPU exposes no XRGB8888 modifiers");
        return 2;
    }
    std::vector<nucleus_android_format_modifier_properties> modifiers(
        static_cast<std::size_t>(modifierCount));
    const int modifierFilled = nucleus_android_gpu_list_format_modifiers(
        gpu.get(),
        format,
        modifiers.data(),
        modifiers.size());
    if (modifierFilled <= 0) {
        printFailure("format-modifier enumeration failed");
        return 2;
    }

    Owned<nucleus_android_gpu_buffer, nucleus_android_gpu_buffer_destroy> buffer(
        nullptr,
        nucleus_android_gpu_buffer_destroy);
    uint64_t selectedModifier = 0;
    for (int index = 0; index < modifierFilled; ++index) {
        buffer.reset(nucleus_android_gpu_buffer_create(
            gpu.get(),
            64,
            64,
            format,
            modifiers[index].modifier,
            0,
            error,
            sizeof(error)));
        if (buffer) {
            selectedModifier = modifiers[index].modifier;
            break;
        }
    }
    if (!buffer) {
        printFailure(error);
        return 2;
    }
    if (nucleus_android_gpu_buffer_plane_count(buffer.get()) != 1) {
        printFailure("Phase 1 requires a single-plane XRGB8888 allocation");
        return 2;
    }

    nucleus_android_dmabuf_plane plane = {};
    const int dmabufFd =
        nucleus_android_gpu_buffer_export_plane(buffer.get(), 0, &plane);
    if (dmabufFd < 0) {
        printFailure("dma-buf export failed");
        return 2;
    }
    const nucleus_android_gfxstream_host_dmabuf dmabuf = {
        .color_buffer_handle = 1,
        .width = 64,
        .height = 64,
        .drm_format = format,
        .drm_modifier = selectedModifier,
        .plane_offset = plane.offset,
        .plane_stride = plane.stride,
        .dmabuf_fd = dmabufFd,
    };
    const int importResult =
        nucleus_android_gfxstream_host_import_dmabuf(renderer.get(), &dmabuf);
    if (importResult != 0) {
        close(dmabufFd);
        printFailure("gfxstream rejected the broker-owned dma-buf");
        return 2;
    }
    if (nucleus_android_gfxstream_host_release_dmabuf(
            renderer.get(),
            dmabuf.color_buffer_handle) != 0) {
        printFailure("gfxstream failed to release the imported dma-buf");
        return 2;
    }

    std::printf(
        "{\"status\":\"qualified\",\"renderNode\":\"%s\","
        "\"vulkanDevice\":\"%s\",\"vulkanDeviceUUID\":\"%s\","
        "\"drmFormat\":\"0x%08x\",\"drmModifier\":\"0x%016llx\","
        "\"exactDmaBufGfxstreamImport\":true}\n",
        candidate->render_path,
        diagnostic.device_name,
        diagnostic.device_uuid,
        format,
        static_cast<unsigned long long>(selectedModifier));
    return 0;
}
