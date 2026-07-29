#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include <array>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "NucleusAndroidDrmC.h"
#include "NucleusAndroidGfxstreamHostC.h"

namespace {

constexpr uint32_t kWidth = 1280;
constexpr uint32_t kHeight = 720;

template <typename T, void (*Destroy)(T *)>
using Owned = std::unique_ptr<T, decltype(Destroy)>;

struct FormatProbe {
    const char *name;
    uint32_t drmFormat;
    std::array<uint8_t, 4> vulkanClearBytes;
    uint64_t modifier = 0;
    uint32_t stride = 0;
};

void printFailure(const std::string &message) {
    std::printf(
        "{\"status\":\"rejected\",\"error\":\"%s\"}\n",
        message.c_str());
}

bool approximatelyMatches(
    const std::vector<uint8_t> &pixels,
    const std::array<uint8_t, 4> &expected) {
    for (std::size_t offset = 0; offset < pixels.size(); offset += 4) {
        for (std::size_t channel = 0; channel < expected.size(); ++channel) {
            const int difference =
                static_cast<int>(pixels[offset + channel]) -
                static_cast<int>(expected[channel]);
            if (difference < -2 || difference > 2) {
                return false;
            }
        }
    }
    return true;
}

bool waitForSyncFile(int descriptor) {
    pollfd fence = {
        .fd = descriptor,
        .events = POLLIN,
        .revents = 0,
    };
    int result;
    do {
        result = poll(&fence, 1, 10'000);
    } while (result < 0 && errno == EINTR);
    return result == 1 &&
        (fence.revents & (POLLIN | POLLHUP)) != 0;
}

bool probeFormat(
    nucleus_android_gpu *gpu,
    nucleus_android_gfxstream_host_renderer *renderer,
    FormatProbe *probe,
    uint32_t colorBufferHandle,
    std::string *failure) {
    const int modifierCount = nucleus_android_gpu_list_format_modifiers(
        gpu,
        probe->drmFormat,
        nullptr,
        0);
    if (modifierCount <= 0) {
        *failure = std::string("the selected GPU exposes no ") +
            probe->name + " modifiers";
        return false;
    }
    std::vector<nucleus_android_format_modifier_properties> modifiers(
        static_cast<std::size_t>(modifierCount));
    const int modifierFilled = nucleus_android_gpu_list_format_modifiers(
        gpu,
        probe->drmFormat,
        modifiers.data(),
        modifiers.size());
    if (modifierFilled <= 0) {
        *failure = std::string(probe->name) +
            " format-modifier enumeration failed";
        return false;
    }

    char error[1024] = {};
    Owned<nucleus_android_gpu_buffer, nucleus_android_gpu_buffer_destroy> buffer(
        nullptr,
        nucleus_android_gpu_buffer_destroy);
    for (int index = 0; index < modifierFilled; ++index) {
        buffer.reset(nucleus_android_gpu_buffer_create(
            gpu,
            kWidth,
            kHeight,
            probe->drmFormat,
            modifiers[index].modifier,
            0,
            error,
            sizeof(error)));
        if (buffer) {
            probe->modifier = modifiers[index].modifier;
            break;
        }
    }
    if (!buffer) {
        *failure = std::string(probe->name) + " allocation failed: " + error;
        return false;
    }
    if (nucleus_android_gpu_buffer_plane_count(buffer.get()) != 1) {
        *failure = std::string(probe->name) +
            " allocation was not single-plane";
        return false;
    }

    nucleus_android_dmabuf_plane plane = {};
    const int dmabufFd =
        nucleus_android_gpu_buffer_export_plane(buffer.get(), 0, &plane);
    if (dmabufFd < 0) {
        *failure = std::string(probe->name) + " dma-buf export failed";
        return false;
    }
    probe->stride = plane.stride;
    const nucleus_android_gfxstream_host_dmabuf dmabuf = {
        .color_buffer_handle = colorBufferHandle,
        .width = kWidth,
        .height = kHeight,
        .drm_format = probe->drmFormat,
        .drm_modifier = probe->modifier,
        .plane_offset = plane.offset,
        .plane_stride = plane.stride,
        .dmabuf_fd = dmabufFd,
    };
    if (nucleus_android_gfxstream_host_import_dmabuf(renderer, &dmabuf) != 0) {
        close(dmabufFd);
        *failure = std::string("gfxstream rejected the ") +
            probe->name + " broker-owned dma-buf";
        return false;
    }

    const std::size_t pixelBytes =
        static_cast<std::size_t>(kWidth) * kHeight * 4;
    std::vector<uint8_t> uploaded(pixelBytes);
    for (std::size_t index = 0; index < uploaded.size(); ++index) {
        uploaded[index] = static_cast<uint8_t>(
            (index * 37u + index / 17u) & 0xffu);
    }
    if (nucleus_android_gfxstream_host_update_color_buffer(
            renderer,
            colorBufferHandle,
            probe->drmFormat,
            kWidth,
            kHeight,
            uploaded.data(),
            uploaded.size()) != 0) {
        (void)nucleus_android_gfxstream_host_release_dmabuf(
            renderer, colorBufferHandle);
        *failure = std::string("gfxstream failed to upload ") +
            probe->name + " linear CPU pixels";
        return false;
    }
    std::vector<uint8_t> readback(uploaded.size());
    if (nucleus_android_gfxstream_host_read_color_buffer(
            renderer,
            colorBufferHandle,
            probe->drmFormat,
            kWidth,
            kHeight,
            readback.data(),
            readback.size()) != 0 ||
        readback != uploaded) {
        (void)nucleus_android_gfxstream_host_release_dmabuf(
            renderer, colorBufferHandle);
        *failure = std::string("gfxstream ") + probe->name +
            " linear CPU readback did not round-trip";
        return false;
    }

    Owned<
        nucleus_android_syncobj_timeline,
        nucleus_android_syncobj_timeline_destroy>
        timeline(
            nucleus_android_syncobj_timeline_create(gpu),
            nucleus_android_syncobj_timeline_destroy);
    if (!timeline ||
        nucleus_android_gpu_buffer_render(
            buffer.get(),
            0,
            timeline.get(),
            1,
            nullptr,
            0,
            error,
            sizeof(error)) != 0) {
        (void)nucleus_android_gfxstream_host_release_dmabuf(
            renderer, colorBufferHandle);
        *failure = std::string("Vulkan failed to clear the imported ") +
            probe->name + " dma-buf: " + error;
        return false;
    }
    const int syncFile =
        nucleus_android_syncobj_timeline_export_sync_file(timeline.get(), 1);
    if (syncFile < 0 || !waitForSyncFile(syncFile)) {
        if (syncFile >= 0) close(syncFile);
        (void)nucleus_android_gfxstream_host_release_dmabuf(
            renderer, colorBufferHandle);
        *failure = std::string("Vulkan ") + probe->name +
            " clear fence did not signal";
        return false;
    }
    close(syncFile);

    std::fill(readback.begin(), readback.end(), 0);
    if (nucleus_android_gfxstream_host_read_color_buffer(
            renderer,
            colorBufferHandle,
            probe->drmFormat,
            kWidth,
            kHeight,
            readback.data(),
            readback.size()) != 0 ||
        !approximatelyMatches(readback, probe->vulkanClearBytes)) {
        (void)nucleus_android_gfxstream_host_release_dmabuf(
            renderer, colorBufferHandle);
        *failure = std::string("gfxstream did not observe the independent ") +
            probe->name + " Vulkan clear";
        return false;
    }
    if (nucleus_android_gfxstream_host_release_dmabuf(
            renderer, colorBufferHandle) != 0) {
        *failure = std::string("gfxstream failed to release the ") +
            probe->name + " dma-buf";
        return false;
    }
    buffer.reset();
    if (nucleus_android_gpu_collect(gpu) != 0) {
        *failure = std::string(probe->name) +
            " buffer collection failed";
        return false;
    }
    return true;
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
                kWidth,
                kHeight,
                diagnostic.device_uuid,
                error,
                sizeof(error)),
            nucleus_android_gfxstream_host_renderer_destroy);
    if (!renderer) {
        printFailure(error);
        return 2;
    }

    FormatProbe xrgb = {
        .name = "XRGB8888",
        .drmFormat = nucleus_android_drm_format_xrgb8888(),
        .vulkanClearBytes = {10, 51, 217, 255},
    };
    FormatProbe abgr = {
        .name = "ABGR8888",
        .drmFormat = nucleus_android_drm_format_abgr8888(),
        .vulkanClearBytes = {217, 51, 10, 255},
    };
    std::string failure;
    if (!probeFormat(
            gpu.get(), renderer.get(), &xrgb, 1, &failure) ||
        !probeFormat(
            gpu.get(), renderer.get(), &abgr, 2, &failure)) {
        printFailure(failure);
        return 2;
    }
    if (nucleus_android_gpu_get_diagnostic(gpu.get(), &diagnostic) != 0 ||
        diagnostic.live_buffer_count != 0 ||
        diagnostic.retired_buffer_count != 0 ||
        diagnostic.reclaimed_buffer_count != 2) {
        printFailure("broker buffer reclamation did not return to baseline");
        return 2;
    }

    std::printf(
        "{\"status\":\"qualified\",\"renderNode\":\"%s\","
        "\"vulkanDevice\":\"%s\",\"vulkanDeviceUUID\":\"%s\","
        "\"width\":%u,\"height\":%u,"
        "\"xrgb8888\":{\"drmFormat\":\"0x%08x\","
        "\"drmModifier\":\"0x%016llx\",\"stride\":%u},"
        "\"abgr8888\":{\"drmFormat\":\"0x%08x\","
        "\"drmModifier\":\"0x%016llx\",\"stride\":%u},"
        "\"exactDmaBufGfxstreamImport\":true,"
        "\"linearCpuRoundTrip\":true,"
        "\"independentVulkanWriteGfxstreamRead\":true,"
        "\"liveBuffersAfterRelease\":%llu,"
        "\"retiredBuffersAfterRelease\":%llu,"
        "\"reclaimedBuffers\":%llu}\n",
        candidate->render_path,
        diagnostic.device_name,
        diagnostic.device_uuid,
        kWidth,
        kHeight,
        xrgb.drmFormat,
        static_cast<unsigned long long>(xrgb.modifier),
        xrgb.stride,
        abgr.drmFormat,
        static_cast<unsigned long long>(abgr.modifier),
        abgr.stride,
        static_cast<unsigned long long>(diagnostic.live_buffer_count),
        static_cast<unsigned long long>(diagnostic.retired_buffer_count),
        static_cast<unsigned long long>(diagnostic.reclaimed_buffer_count));
    return 0;
}
