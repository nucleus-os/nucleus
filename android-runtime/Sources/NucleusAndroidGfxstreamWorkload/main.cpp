#include <dlfcn.h>
#include <errno.h>
#include <poll.h>
#include <sys/eventfd.h>
#include <unistd.h>
#include <vulkan/vulkan.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#define VK_GFXSTREAM_STRUCTURE_TYPE_EXT
#include "vulkan_gfxstream.h"

#include "NucleusAndroidDrmC.h"
#include "NucleusAndroidGfxstreamAdapters/GuestRingFactory.h"
#include "NucleusAndroidGfxstreamWorkerProtocolC.h"
#include "NucleusAndroidGfxstreamHostC.h"
#include "NucleusAndroidIPCC.h"
#include "NucleusAndroidSharedRingC.h"

#ifndef NUCLEUS_ANDROID_GFXSTREAM_GUEST_ICD
#error "The gfxstream guest ICD path must be provided by the build."
#endif

namespace {

constexpr uint32_t kInitialWidth = 64;
constexpr uint32_t kInitialHeight = 64;
constexpr uint32_t kResizedWidth = 96;
constexpr uint32_t kResizedHeight = 72;
constexpr uint32_t kBufferCount = 3;
constexpr uint32_t kFramesPerGeneration = 24;
constexpr uint32_t kFirstColorBufferHandle = 1;
constexpr int kCompletionTimeoutMilliseconds = 10000;

void traceStage(const char *stage) {
    std::fprintf(
        stderr,
        "{\"component\":\"nucleus-android-gfxstream-workload\","
        "\"stage\":\"%s\"}\n",
        stage);
    std::fflush(stderr);
}

void traceBufferStage(
    const char *stage,
    uint32_t colorBufferHandle,
    uint64_t point,
    uint32_t width,
    uint32_t height) {
    std::fprintf(
        stderr,
        "{\"component\":\"nucleus-android-gfxstream-workload\","
        "\"stage\":\"%s\","
        "\"colorBufferHandle\":%u,"
        "\"timelinePoint\":%llu,"
        "\"width\":%u,"
        "\"height\":%u}\n",
        stage,
        colorBufferHandle,
        static_cast<unsigned long long>(point),
        width,
        height);
    std::fflush(stderr);
}

template <typename T, void (*Destroy)(T *)>
using Owned = std::unique_ptr<T, decltype(Destroy)>;

using OwnedRing =
    Owned<nucleus_android_shared_ring, nucleus_android_shared_ring_destroy>;

void closeEndpointDescriptors(
    nucleus_android_gfxstream_endpoint_descriptors *descriptors) {
    const int values[] = {
        descriptors->command_memory_fd,
        descriptors->command_data_notification_fd,
        descriptors->command_space_notification_fd,
        descriptors->response_memory_fd,
        descriptors->response_data_notification_fd,
        descriptors->response_space_notification_fd,
    };
    for (const int descriptor : values) {
        if (descriptor >= 0) {
            close(descriptor);
        }
    }
    *descriptors = {
        .command_memory_fd = -1,
        .command_data_notification_fd = -1,
        .command_space_notification_fd = -1,
        .response_memory_fd = -1,
        .response_data_notification_fd = -1,
        .response_space_notification_fd = -1,
    };
}

nucleus_android_gfxstream_endpoint_descriptors emptyEndpointDescriptors() {
    return {
        .command_memory_fd = -1,
        .command_data_notification_fd = -1,
        .command_space_notification_fd = -1,
        .response_memory_fd = -1,
        .response_data_notification_fd = -1,
        .response_space_notification_fd = -1,
    };
}

bool exportEndpointDescriptors(
    nucleus_android_shared_ring *commands,
    nucleus_android_shared_ring *responses,
    nucleus_android_gfxstream_endpoint_descriptors *output) {
    *output = emptyEndpointDescriptors();
    output->command_memory_fd =
        nucleus_android_shared_ring_export_memory_fd(commands);
    output->command_data_notification_fd =
        nucleus_android_shared_ring_export_data_notification_fd(commands);
    output->command_space_notification_fd =
        nucleus_android_shared_ring_export_space_notification_fd(commands);
    output->response_memory_fd =
        nucleus_android_shared_ring_export_memory_fd(responses);
    output->response_data_notification_fd =
        nucleus_android_shared_ring_export_data_notification_fd(responses);
    output->response_space_notification_fd =
        nucleus_android_shared_ring_export_space_notification_fd(responses);
    const int values[] = {
        output->command_memory_fd,
        output->command_data_notification_fd,
        output->command_space_notification_fd,
        output->response_memory_fd,
        output->response_data_notification_fd,
        output->response_space_notification_fd,
    };
    for (const int descriptor : values) {
        if (descriptor < 0) {
            closeEndpointDescriptors(output);
            return false;
        }
    }
    return true;
}

void signalEventFd(int descriptor) {
    const uint64_t value = 1;
    ssize_t result;
    do {
        result = write(descriptor, &value, sizeof(value));
    } while (result < 0 && errno == EINTR);
}

void drainEventFd(int descriptor) {
    uint64_t value = 0;
    ssize_t result;
    do {
        result = read(descriptor, &value, sizeof(value));
    } while (result < 0 && errno == EINTR);
}

class RingConnection {
  public:
    explicit RingConnection(
        nucleus_android_gfxstream_host_renderer *renderer)
        : mRenderer(renderer) {
        if (!mRenderer) {
            throw std::runtime_error(
                "the gfxstream ring pool requires a renderer");
        }
    }

    RingConnection(const RingConnection &) = delete;
    RingConnection &operator=(const RingConnection &) = delete;

    ~RingConnection() {
        stop();
    }

    static int provide(
        void *context,
        nucleus_android_gfxstream_endpoint_descriptors *descriptors) {
        return static_cast<RingConnection *>(context)->provide(descriptors);
    }

    void stop() {
        std::lock_guard<std::mutex> lock(mEndpointsMutex);
        for (const auto &endpoint : mEndpoints) {
            endpoint->stopping.store(true, std::memory_order_release);
            (void)nucleus_android_shared_ring_close(
                endpoint->commands.get());
            (void)nucleus_android_shared_ring_close(
                endpoint->responses.get());
            signalEventFd(endpoint->stopFd);
        }
        for (const auto &endpoint : mEndpoints) {
            if (endpoint->thread.joinable()) {
                endpoint->thread.join();
            }
            nucleus_android_gfxstream_host_connection_destroy(
                endpoint->connection);
            endpoint->connection = nullptr;
        }
    }

    bool failed() const {
        std::lock_guard<std::mutex> lock(mEndpointsMutex);
        for (const auto &endpoint : mEndpoints) {
            if (endpoint->failed.load(std::memory_order_acquire)) {
                return true;
            }
        }
        return false;
    }

    std::string error() const {
        std::lock_guard<std::mutex> lock(mEndpointsMutex);
        for (const auto &endpoint : mEndpoints) {
            if (endpoint->failed.load(std::memory_order_acquire)) {
                return endpoint->error;
            }
        }
        return {};
    }

    uint32_t providerCalls() const {
        return mProviderCalls.load(std::memory_order_acquire);
    }

    uint64_t backpressureEvents() const {
        std::lock_guard<std::mutex> lock(mEndpointsMutex);
        uint64_t total = 0;
        for (const auto &endpoint : mEndpoints) {
            nucleus_android_shared_ring_diagnostic commands = {};
            nucleus_android_shared_ring_diagnostic responses = {};
            if (nucleus_android_shared_ring_get_diagnostic(
                    endpoint->commands.get(),
                    &commands) == 0) {
                total += commands.write_backpressure_count;
            }
            if (nucleus_android_shared_ring_get_diagnostic(
                    endpoint->responses.get(),
                    &responses) == 0) {
                total += responses.write_backpressure_count;
            }
        }
        return total;
    }

    uint64_t maximumRingOccupancy() const {
        std::lock_guard<std::mutex> lock(mEndpointsMutex);
        uint64_t maximum = 0;
        for (const auto &endpoint : mEndpoints) {
            nucleus_android_shared_ring_diagnostic commands = {};
            nucleus_android_shared_ring_diagnostic responses = {};
            if (nucleus_android_shared_ring_get_diagnostic(
                    endpoint->commands.get(),
                    &commands) == 0) {
                maximum =
                    std::max(maximum, commands.maximum_occupancy);
            }
            if (nucleus_android_shared_ring_get_diagnostic(
                    endpoint->responses.get(),
                    &responses) == 0) {
                maximum =
                    std::max(maximum, responses.maximum_occupancy);
            }
        }
        return maximum;
    }

    struct Diagnostics {
        uint64_t pumpProgress = 0;
        uint64_t commandNotifications = 0;
        uint64_t responseSpaceNotifications = 0;
        uint64_t rendererWakeups = 0;
        uint64_t peerDisconnects = 0;
        uint64_t orderlyStopWakeups = 0;
    };

    Diagnostics diagnostics() const {
        std::lock_guard<std::mutex> lock(mEndpointsMutex);
        Diagnostics result;
        for (const auto &endpoint : mEndpoints) {
            result.pumpProgress +=
                endpoint->pumpProgress.load(std::memory_order_acquire);
            result.commandNotifications +=
                endpoint->commandNotifications.load(
                    std::memory_order_acquire);
            result.responseSpaceNotifications +=
                endpoint->responseSpaceNotifications.load(
                    std::memory_order_acquire);
            result.rendererWakeups +=
                endpoint->rendererWakeups.load(std::memory_order_acquire);
            result.peerDisconnects +=
                endpoint->peerDisconnects.load(std::memory_order_acquire);
            result.orderlyStopWakeups +=
                endpoint->orderlyStopWakeups.load(
                    std::memory_order_acquire);
        }
        return result;
    }

  private:
    struct Endpoint {
        Endpoint()
            : commands(nullptr, nucleus_android_shared_ring_destroy),
              responses(nullptr, nucleus_android_shared_ring_destroy) {}

        ~Endpoint() {
            if (stopFd >= 0) {
                close(stopFd);
            }
        }

        OwnedRing commands;
        OwnedRing responses;
        int stopFd = -1;
        nucleus_android_gfxstream_host_connection *connection = nullptr;
        std::thread thread;
        std::atomic<bool> stopping = false;
        std::atomic<bool> failed = false;
        std::atomic<uint64_t> pumpProgress = 0;
        std::atomic<uint64_t> commandNotifications = 0;
        std::atomic<uint64_t> responseSpaceNotifications = 0;
        std::atomic<uint64_t> rendererWakeups = 0;
        std::atomic<uint64_t> peerDisconnects = 0;
        std::atomic<uint64_t> orderlyStopWakeups = 0;
        std::string error;
    };

    int provide(
        nucleus_android_gfxstream_endpoint_descriptors *guestDescriptors) {
        mProviderCalls.fetch_add(1, std::memory_order_release);
        if (!guestDescriptors) {
            errno = EINVAL;
            return -1;
        }
        auto endpoint = std::make_unique<Endpoint>();
        endpoint->commands.reset(
            nucleus_android_shared_ring_create(2, 64 * 1024));
        endpoint->responses.reset(
            nucleus_android_shared_ring_create(2, 64 * 1024));
        endpoint->stopFd =
            eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
        if (!endpoint->commands || !endpoint->responses ||
            endpoint->stopFd < 0) {
            errno = ENOMEM;
            return -1;
        }

        nucleus_android_gfxstream_endpoint_descriptors hostDescriptors =
            emptyEndpointDescriptors();
        if (!exportEndpointDescriptors(
                endpoint->commands.get(),
                endpoint->responses.get(),
                &hostDescriptors) ||
            !exportEndpointDescriptors(
                endpoint->commands.get(),
                endpoint->responses.get(),
                guestDescriptors)) {
            closeEndpointDescriptors(&hostDescriptors);
            return -1;
        }

        endpoint->connection =
            nucleus_android_gfxstream_host_connection_create(
                mRenderer,
                hostDescriptors,
                1);
        if (!endpoint->connection) {
            closeEndpointDescriptors(guestDescriptors);
            return -1;
        }
        Endpoint *endpointPointer = endpoint.get();
        {
            std::lock_guard<std::mutex> lock(mEndpointsMutex);
            mEndpoints.push_back(std::move(endpoint));
        }
        endpointPointer->thread =
            std::thread([this, endpointPointer] {
                pump(endpointPointer);
            });
        return 0;
    }

    static void fail(Endpoint *endpoint, const char *message) {
        endpoint->error = message;
        endpoint->failed.store(true, std::memory_order_release);
    }

    void pump(Endpoint *endpoint) {
        const int commandFd =
            nucleus_android_gfxstream_host_connection_command_notification_fd(
                endpoint->connection);
        const int responseSpaceFd =
            nucleus_android_gfxstream_host_connection_response_space_notification_fd(
                endpoint->connection);
        const int rendererFd =
            nucleus_android_gfxstream_host_connection_renderer_notification_fd(
                endpoint->connection);
        if (commandFd < 0 || responseSpaceFd < 0 || rendererFd < 0) {
            fail(
                endpoint,
                "the host pump did not expose all notification descriptors");
            return;
        }

        while (!endpoint->stopping.load(std::memory_order_acquire)) {
            nucleus_android_gfxstream_host_pump_result result =
                NUCLEUS_ANDROID_GFXSTREAM_HOST_PUMP_IDLE;
            do {
                result =
                    nucleus_android_gfxstream_host_connection_pump(
                        endpoint->connection);
                if (result == NUCLEUS_ANDROID_GFXSTREAM_HOST_PUMP_ERROR) {
                    fail(endpoint, "the gfxstream host pump failed");
                    return;
                }
                if (result == NUCLEUS_ANDROID_GFXSTREAM_HOST_PUMP_STOPPED) {
                    if (!endpoint->stopping.load(std::memory_order_acquire)) {
                        fail(
                            endpoint,
                            "the gfxstream renderer stopped unexpectedly");
                    }
                    return;
                }
                if (result ==
                    NUCLEUS_ANDROID_GFXSTREAM_HOST_PUMP_PEER_CLOSED) {
                    endpoint->peerDisconnects.fetch_add(
                        1,
                        std::memory_order_relaxed);
                    return;
                }
                if (result ==
                    NUCLEUS_ANDROID_GFXSTREAM_HOST_PUMP_PROGRESS) {
                    endpoint->pumpProgress.fetch_add(
                        1,
                        std::memory_order_relaxed);
                }
            } while (
                result == NUCLEUS_ANDROID_GFXSTREAM_HOST_PUMP_PROGRESS);

            pollfd descriptors[] = {
                {.fd = commandFd, .events = POLLIN, .revents = 0},
                {.fd = responseSpaceFd, .events = POLLIN, .revents = 0},
                {.fd = rendererFd, .events = POLLIN, .revents = 0},
                {.fd = endpoint->stopFd, .events = POLLIN, .revents = 0},
            };
            int pollResult;
            do {
                pollResult = poll(descriptors, 4, -1);
            } while (pollResult < 0 && errno == EINTR);
            if (pollResult < 0) {
                fail(endpoint, "poll failed in the gfxstream host pump");
                return;
            }
            if ((descriptors[3].revents & POLLIN) != 0) {
                endpoint->orderlyStopWakeups.fetch_add(
                    1,
                    std::memory_order_relaxed);
                drainEventFd(endpoint->stopFd);
                return;
            }
            if ((descriptors[0].revents & POLLIN) != 0) {
                endpoint->commandNotifications.fetch_add(
                    1,
                    std::memory_order_relaxed);
                if (nucleus_android_shared_ring_drain_data_notification(
                        endpoint->commands.get()) != 0) {
                    fail(
                        endpoint,
                        "failed to drain the command-ring notification");
                    return;
                }
            }
            if ((descriptors[1].revents & POLLIN) != 0) {
                endpoint->responseSpaceNotifications.fetch_add(
                    1,
                    std::memory_order_relaxed);
                if (nucleus_android_shared_ring_drain_space_notification(
                        endpoint->responses.get()) != 0) {
                    fail(
                        endpoint,
                        "failed to drain the response-ring notification");
                    return;
                }
            }
            if ((descriptors[2].revents & POLLIN) != 0) {
                endpoint->rendererWakeups.fetch_add(
                    1,
                    std::memory_order_relaxed);
                if (nucleus_android_gfxstream_host_connection_drain_renderer_notification(
                        endpoint->connection) != 0) {
                    fail(
                        endpoint,
                        "failed to drain the renderer notification");
                    return;
                }
            }
        }
    }

    nucleus_android_gfxstream_host_renderer *mRenderer;
    std::atomic<uint32_t> mProviderCalls = 0;
    mutable std::mutex mEndpointsMutex;
    std::vector<std::unique_ptr<Endpoint>> mEndpoints;
};

struct BufferSync {
    uint32_t colorBufferHandle = 0;
    uint32_t width = 0;
    uint32_t height = 0;
    nucleus_android_syncobj_timeline *releaseTimeline = nullptr;
    nucleus_android_syncobj_timeline *acquireTimeline = nullptr;
    std::atomic<uint64_t> releasePoint = 0;
    std::atomic<uint64_t> acquirePoint = 0;
    std::atomic<uint32_t> releaseExports = 0;
    std::atomic<uint32_t> acquireImports = 0;
};

int exportReleaseSyncFile(void *opaque, uint32_t colorBufferHandle) {
    auto *sync = static_cast<BufferSync *>(opaque);
    if (!sync || colorBufferHandle != sync->colorBufferHandle) {
        errno = EPROTO;
        return -1;
    }
    sync->releaseExports.fetch_add(1, std::memory_order_relaxed);
    traceBufferStage(
        "buffer.release-sync-file.export",
        colorBufferHandle,
        sync->releasePoint.load(std::memory_order_acquire),
        sync->width,
        sync->height);
    return nucleus_android_syncobj_timeline_export_sync_file(
        sync->releaseTimeline,
        sync->releasePoint.load(std::memory_order_acquire));
}

int importAcquireSyncFile(
    void *opaque,
    uint32_t colorBufferHandle,
    int syncFile) {
    auto *sync = static_cast<BufferSync *>(opaque);
    if (!sync || colorBufferHandle != sync->colorBufferHandle ||
        syncFile < 0) {
        errno = EPROTO;
        return -1;
    }
    sync->acquireImports.fetch_add(1, std::memory_order_relaxed);
    const int result =
        nucleus_android_syncobj_timeline_import_sync_file(
            sync->acquireTimeline,
            sync->acquirePoint.load(std::memory_order_acquire),
            syncFile);
    if (result == 0) {
        close(syncFile);
        traceBufferStage(
            "buffer.acquire-sync-file.import",
            colorBufferHandle,
            sync->acquirePoint.load(std::memory_order_acquire),
            sync->width,
            sync->height);
    }
    return result;
}

class ImportedColorBuffer {
  public:
    ImportedColorBuffer(
        nucleus_android_gfxstream_host_renderer *renderer,
        const nucleus_android_gfxstream_host_dmabuf &dmabuf)
        : mRenderer(renderer),
          mHandle(dmabuf.color_buffer_handle) {
        const int result =
            nucleus_android_gfxstream_host_import_dmabuf(
                renderer,
                &dmabuf);
        if (result != 0) {
            throw std::runtime_error(
                "gfxstream rejected the synchronized broker dma-buf");
        }
        mImported = true;
    }

    ImportedColorBuffer(const ImportedColorBuffer &) = delete;
    ImportedColorBuffer &operator=(const ImportedColorBuffer &) = delete;

    ~ImportedColorBuffer() {
        if (mImported) {
            (void)nucleus_android_gfxstream_host_release_dmabuf(
                mRenderer,
                mHandle);
        }
    }

  private:
    nucleus_android_gfxstream_host_renderer *mRenderer;
    uint32_t mHandle;
    bool mImported = false;
};

void waitForAcquirePoint(
    const char *renderPath,
    nucleus_android_syncobj_timeline *timeline,
    uint64_t point);

class BufferSlot {
  public:
    BufferSlot(
        nucleus_android_gpu *gpu,
        nucleus_android_gfxstream_host_renderer *renderer,
        uint32_t format,
        const std::vector<nucleus_android_format_modifier_properties>
            &modifiers,
        uint32_t colorBufferHandle,
        uint32_t width,
        uint32_t height,
        char *error,
        std::size_t errorCapacity)
        : mBuffer(nullptr, nucleus_android_gpu_buffer_destroy),
          mReleaseTimeline(
              nucleus_android_syncobj_timeline_create(gpu),
              nucleus_android_syncobj_timeline_destroy),
          mAcquireTimeline(
              nucleus_android_syncobj_timeline_create(gpu),
              nucleus_android_syncobj_timeline_destroy),
          mColorBufferHandle(colorBufferHandle),
          mWidth(width),
          mHeight(height) {
        for (const auto &candidate : modifiers) {
            mBuffer.reset(
                nucleus_android_gpu_buffer_create(
                    gpu,
                    width,
                    height,
                    format,
                    candidate.modifier,
                    0,
                    error,
                    errorCapacity));
            if (mBuffer) {
                mModifier = candidate.modifier;
                break;
            }
        }
        if (!mBuffer) {
            throw std::runtime_error(error);
        }
        if (nucleus_android_gpu_buffer_plane_count(mBuffer.get()) != 1) {
            throw std::runtime_error(
                "the Phase 1 workload requires one dma-buf plane");
        }
        if (!mReleaseTimeline || !mAcquireTimeline ||
            nucleus_android_syncobj_timeline_signal(
                mReleaseTimeline.get(),
                1) != 0) {
            throw std::runtime_error(
                "failed to initialize the explicit-sync timelines");
        }

        mSync.colorBufferHandle = colorBufferHandle;
        mSync.width = width;
        mSync.height = height;
        mSync.releaseTimeline = mReleaseTimeline.get();
        mSync.acquireTimeline = mAcquireTimeline.get();
        mSync.releasePoint.store(1, std::memory_order_release);
        mSync.acquirePoint.store(1, std::memory_order_release);

        const int dmabufFd =
            nucleus_android_gpu_buffer_export_plane(
                mBuffer.get(),
                0,
                &mPlane);
        if (dmabufFd < 0) {
            throw std::runtime_error("dma-buf export failed");
        }
        const nucleus_android_gfxstream_host_dmabuf dmabuf = {
            .color_buffer_handle = colorBufferHandle,
            .width = width,
            .height = height,
            .drm_format = format,
            .drm_modifier = mModifier,
            .plane_offset = mPlane.offset,
            .plane_stride = mPlane.stride,
            .dmabuf_fd = dmabufFd,
            .sync_context = &mSync,
            .export_release_sync_file = exportReleaseSyncFile,
            .import_acquire_sync_file = importAcquireSyncFile,
        };
        try {
            mImported =
                std::make_unique<ImportedColorBuffer>(renderer, dmabuf);
        } catch (...) {
            close(dmabufFd);
            throw;
        }
        traceBufferStage(
            "buffer.allocate-import.complete",
            mColorBufferHandle,
            0,
            mWidth,
            mHeight);
    }

    BufferSlot(
        nucleus_android_gpu *gpu,
        nucleus_android_gfxstream_host_renderer *renderer,
        uint32_t format,
        uint64_t modifier,
        uint32_t colorBufferHandle,
        uint32_t width,
        uint32_t height,
        nucleus_android_dmabuf_plane plane,
        int dmabufFd,
        int acquireTimelineFd,
        int releaseTimelineFd)
        : mBuffer(nullptr, nucleus_android_gpu_buffer_destroy),
          mReleaseTimeline(
              nucleus_android_syncobj_timeline_import_fd(
                  gpu,
                  releaseTimelineFd),
              nucleus_android_syncobj_timeline_destroy),
          mAcquireTimeline(
              nucleus_android_syncobj_timeline_import_fd(
                  gpu,
                  acquireTimelineFd),
              nucleus_android_syncobj_timeline_destroy),
          mColorBufferHandle(colorBufferHandle),
          mWidth(width),
          mHeight(height),
          mModifier(modifier),
          mPlane(plane) {
        if (!mReleaseTimeline || !mAcquireTimeline ||
            dmabufFd < 0 || plane.stride == 0) {
            throw std::runtime_error(
                "failed to import the broker worker allocation");
        }
        mSync.colorBufferHandle = colorBufferHandle;
        mSync.width = width;
        mSync.height = height;
        mSync.releaseTimeline = mReleaseTimeline.get();
        mSync.acquireTimeline = mAcquireTimeline.get();

        const nucleus_android_gfxstream_host_dmabuf dmabuf = {
            .color_buffer_handle = colorBufferHandle,
            .width = width,
            .height = height,
            .drm_format = format,
            .drm_modifier = modifier,
            .plane_offset = plane.offset,
            .plane_stride = plane.stride,
            .dmabuf_fd = dmabufFd,
            .sync_context = &mSync,
            .export_release_sync_file = exportReleaseSyncFile,
            .import_acquire_sync_file = importAcquireSyncFile,
        };
        try {
            mImported =
                std::make_unique<ImportedColorBuffer>(renderer, dmabuf);
        } catch (...) {
            close(dmabufFd);
            throw;
        }
        traceBufferStage(
            "buffer.allocate-import.complete",
            mColorBufferHandle,
            0,
            mWidth,
            mHeight);
    }

    BufferSlot(const BufferSlot &) = delete;
    BufferSlot &operator=(const BufferSlot &) = delete;

    ~BufferSlot() {
        traceBufferStage(
            "buffer.release.begin",
            mColorBufferHandle,
            mSubmittedPoint,
            mWidth,
            mHeight);
        mImported.reset();
        mBuffer.reset();
        mAcquireTimeline.reset();
        mReleaseTimeline.reset();
        traceBufferStage(
            "buffer.release.complete",
            mColorBufferHandle,
            mSubmittedPoint,
            mWidth,
            mHeight);
    }

    void prepareSubmission(uint64_t point) {
        if (point == 0) {
            throw std::runtime_error(
                "the explicit-sync point must be nonzero");
        }
        if (point > 1 &&
            nucleus_android_syncobj_timeline_signal(
                mReleaseTimeline.get(),
                point) != 0) {
            throw std::runtime_error(
                "failed to signal the compositor release point");
        }
        mSync.releasePoint.store(point, std::memory_order_release);
        mSync.acquirePoint.store(point, std::memory_order_release);
        mSubmittedPoint = point;
        mInFlight = true;
        traceBufferStage(
            point == 1
                ? "buffer.release-ready.initial"
                : "buffer.release-ready.reuse",
            mColorBufferHandle,
            point,
            mWidth,
            mHeight);
    }

    void prepareBrokerSubmission(
        uint64_t acquirePoint,
        bool hasReleasePoint,
        uint64_t releasePoint) {
        if (acquirePoint == 0 ||
            (hasReleasePoint && releasePoint == 0) ||
            (!hasReleasePoint && releasePoint != 0)) {
            throw std::runtime_error(
                "the broker worker received invalid timeline points");
        }
        uint64_t waitPoint = releasePoint;
        if (!hasReleasePoint) {
            waitPoint = 1;
            if (mHasSubmitted ||
                nucleus_android_syncobj_timeline_signal(
                    mReleaseTimeline.get(),
                    waitPoint) != 0) {
                throw std::runtime_error(
                    "failed to initialize the broker release timeline");
            }
        }
        mSync.releasePoint.store(waitPoint, std::memory_order_release);
        mSync.acquirePoint.store(acquirePoint, std::memory_order_release);
        mSubmittedPoint = acquirePoint;
        mHasSubmitted = true;
        traceBufferStage(
            hasReleasePoint
                ? "buffer.release-ready.reuse"
                : "buffer.release-ready.initial",
            mColorBufferHandle,
            waitPoint,
            mWidth,
            mHeight);
    }

    void waitForCompletion(const char *renderPath) {
        if (!mInFlight) {
            return;
        }
        waitForAcquirePoint(
            renderPath,
            mAcquireTimeline.get(),
            mSubmittedPoint);
        traceBufferStage(
            "buffer.acquire-signaled",
            mColorBufferHandle,
            mSubmittedPoint,
            mWidth,
            mHeight);
        mInFlight = false;
    }

    uint32_t colorBufferHandle() const {
        return mColorBufferHandle;
    }

    uint32_t width() const {
        return mWidth;
    }

    uint32_t height() const {
        return mHeight;
    }

    uint64_t modifier() const {
        return mModifier;
    }

    const nucleus_android_dmabuf_plane &plane() const {
        return mPlane;
    }

    int exportPlane() const {
        if (!mBuffer) {
            errno = ENOTSUP;
            return -1;
        }
        nucleus_android_dmabuf_plane ignored = {};
        return nucleus_android_gpu_buffer_export_plane(
            mBuffer.get(),
            0,
            &ignored);
    }

    BufferSync &sync() {
        return mSync;
    }

    std::size_t guestResourceIndex = 0;

  private:
    Owned<
        nucleus_android_gpu_buffer,
        nucleus_android_gpu_buffer_destroy>
        mBuffer;
    Owned<
        nucleus_android_syncobj_timeline,
        nucleus_android_syncobj_timeline_destroy>
        mReleaseTimeline;
    Owned<
        nucleus_android_syncobj_timeline,
        nucleus_android_syncobj_timeline_destroy>
        mAcquireTimeline;
    BufferSync mSync;
    std::unique_ptr<ImportedColorBuffer> mImported;
    uint32_t mColorBufferHandle;
    uint32_t mWidth;
    uint32_t mHeight;
    uint64_t mModifier = 0;
    nucleus_android_dmabuf_plane mPlane = {};
    uint64_t mSubmittedPoint = 0;
    bool mInFlight = false;
    bool mHasSubmitted = false;
};

template <typename Function>
Function requireProc(
    PFN_vkGetInstanceProcAddr getInstanceProcAddr,
    VkInstance instance,
    const char *name) {
    const auto function =
        reinterpret_cast<Function>(
            getInstanceProcAddr(instance, name));
    if (!function) {
        throw std::runtime_error(
            std::string("the guest ICD omitted ") + name);
    }
    return function;
}

template <typename Function>
Function requireDeviceProc(
    PFN_vkGetDeviceProcAddr getDeviceProcAddr,
    VkDevice device,
    const char *name) {
    const auto function =
        reinterpret_cast<Function>(
            getDeviceProcAddr(device, name));
    if (!function) {
        throw std::runtime_error(
            std::string("the guest ICD omitted ") + name);
    }
    return function;
}

class GuestWorkload {
  public:
    explicit GuestWorkload(void *icdHandle) {
        traceStage("guest.resolve-instance-dispatch.begin");
        mGetInstanceProcAddr =
            reinterpret_cast<PFN_vkGetInstanceProcAddr>(
                dlsym(icdHandle, "vk_icdGetInstanceProcAddr"));
        if (!mGetInstanceProcAddr) {
            throw std::runtime_error(
                "the guest ICD omitted vk_icdGetInstanceProcAddr");
        }
        mCreateInstance =
            requireProc<PFN_vkCreateInstance>(
                mGetInstanceProcAddr,
                VK_NULL_HANDLE,
                "vkCreateInstance");
        traceStage("guest.resolve-instance-dispatch.complete");

        const VkApplicationInfo applicationInfo = {
            .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pNext = nullptr,
            .pApplicationName = "Nucleus Phase 1 gfxstream workload",
            .applicationVersion = 1,
            .pEngineName = "Nucleus",
            .engineVersion = 1,
            .apiVersion = VK_API_VERSION_1_1,
        };
        const VkInstanceCreateInfo createInfo = {
            .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pNext = nullptr,
            .flags = 0,
            .pApplicationInfo = &applicationInfo,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = nullptr,
            .enabledExtensionCount = 0,
            .ppEnabledExtensionNames = nullptr,
        };
        traceStage("guest.vkCreateInstance.begin");
        check(
            mCreateInstance(
                &createInfo,
                nullptr,
                &mInstance),
            "vkCreateInstance");
        traceStage("guest.vkCreateInstance.complete");

        traceStage("guest.load-instance-dispatch.begin");
        mDestroyInstance =
            requireProc<PFN_vkDestroyInstance>(
                mGetInstanceProcAddr,
                mInstance,
                "vkDestroyInstance");
        mEnumeratePhysicalDevices =
            requireProc<PFN_vkEnumeratePhysicalDevices>(
                mGetInstanceProcAddr,
                mInstance,
                "vkEnumeratePhysicalDevices");
        mGetPhysicalDeviceProperties =
            requireProc<PFN_vkGetPhysicalDeviceProperties>(
                mGetInstanceProcAddr,
                mInstance,
                "vkGetPhysicalDeviceProperties");
        mGetPhysicalDeviceQueueFamilyProperties =
            requireProc<PFN_vkGetPhysicalDeviceQueueFamilyProperties>(
                mGetInstanceProcAddr,
                mInstance,
                "vkGetPhysicalDeviceQueueFamilyProperties");
        mGetPhysicalDeviceMemoryProperties =
            requireProc<PFN_vkGetPhysicalDeviceMemoryProperties>(
                mGetInstanceProcAddr,
                mInstance,
                "vkGetPhysicalDeviceMemoryProperties");
        mEnumerateDeviceExtensionProperties =
            requireProc<PFN_vkEnumerateDeviceExtensionProperties>(
                mGetInstanceProcAddr,
                mInstance,
                "vkEnumerateDeviceExtensionProperties");
        mCreateDevice =
            requireProc<PFN_vkCreateDevice>(
                mGetInstanceProcAddr,
                mInstance,
                "vkCreateDevice");
        mGetDeviceProcAddr =
            requireProc<PFN_vkGetDeviceProcAddr>(
                mGetInstanceProcAddr,
                mInstance,
                "vkGetDeviceProcAddr");
        traceStage("guest.load-instance-dispatch.complete");

        uint32_t physicalDeviceCount = 0;
        traceStage("guest.vkEnumeratePhysicalDevices-count.begin");
        check(
            mEnumeratePhysicalDevices(
                mInstance,
                &physicalDeviceCount,
                nullptr),
            "vkEnumeratePhysicalDevices");
        traceStage("guest.vkEnumeratePhysicalDevices-count.complete");
        if (physicalDeviceCount == 0) {
            throw std::runtime_error(
                "the guest ICD exposed no physical device");
        }
        std::vector<VkPhysicalDevice> physicalDevices(
            physicalDeviceCount);
        traceStage("guest.vkEnumeratePhysicalDevices-list.begin");
        check(
            mEnumeratePhysicalDevices(
                mInstance,
                &physicalDeviceCount,
                physicalDevices.data()),
            "vkEnumeratePhysicalDevices");
        traceStage("guest.vkEnumeratePhysicalDevices-list.complete");
        mPhysicalDevice = physicalDevices.front();
        mGetPhysicalDeviceProperties(
            mPhysicalDevice,
            &mPhysicalDeviceProperties);

        uint32_t queueFamilyCount = 0;
        mGetPhysicalDeviceQueueFamilyProperties(
            mPhysicalDevice,
            &queueFamilyCount,
            nullptr);
        std::vector<VkQueueFamilyProperties> queueFamilies(
            queueFamilyCount);
        mGetPhysicalDeviceQueueFamilyProperties(
            mPhysicalDevice,
            &queueFamilyCount,
            queueFamilies.data());
        bool foundQueue = false;
        for (uint32_t index = 0; index < queueFamilyCount; ++index) {
            if ((queueFamilies[index].queueFlags &
                 VK_QUEUE_GRAPHICS_BIT) != 0) {
                mQueueFamily = index;
                foundQueue = true;
                break;
            }
        }
        if (!foundQueue) {
            throw std::runtime_error(
                "the guest ICD exposed no graphics queue");
        }

        uint32_t extensionCount = 0;
        check(
            mEnumerateDeviceExtensionProperties(
                mPhysicalDevice,
                nullptr,
                &extensionCount,
                nullptr),
            "vkEnumerateDeviceExtensionProperties");
        std::vector<VkExtensionProperties> extensions(extensionCount);
        check(
            mEnumerateDeviceExtensionProperties(
                mPhysicalDevice,
                nullptr,
                &extensionCount,
                extensions.data()),
            "vkEnumerateDeviceExtensionProperties");
        bool hasModifierExtension = false;
        bool hasExternalMemoryFdExtension = false;
        bool hasDmaBufExtension = false;
        for (const auto &extension : extensions) {
            if (std::strcmp(
                    extension.extensionName,
                    VK_EXT_IMAGE_DRM_FORMAT_MODIFIER_EXTENSION_NAME) == 0) {
                hasModifierExtension = true;
            } else if (std::strcmp(
                           extension.extensionName,
                           VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME) == 0) {
                hasExternalMemoryFdExtension = true;
            } else if (std::strcmp(
                           extension.extensionName,
                           VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME) == 0) {
                hasDmaBufExtension = true;
            }
        }
        if (!hasModifierExtension || !hasExternalMemoryFdExtension ||
            !hasDmaBufExtension) {
            throw std::runtime_error(
                "the guest ICD omitted required dma-buf external-memory extensions");
        }

        const float priority = 1.0f;
        const VkDeviceQueueCreateInfo queueCreateInfo = {
            .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .pNext = nullptr,
            .flags = 0,
            .queueFamilyIndex = mQueueFamily,
            .queueCount = 1,
            .pQueuePriorities = &priority,
        };
        const char *deviceExtensions[] = {
            VK_EXT_IMAGE_DRM_FORMAT_MODIFIER_EXTENSION_NAME,
            VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME,
            VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME,
        };
        const VkDeviceCreateInfo deviceCreateInfo = {
            .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .pNext = nullptr,
            .flags = 0,
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = &queueCreateInfo,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = nullptr,
            .enabledExtensionCount =
                static_cast<uint32_t>(
                    sizeof(deviceExtensions) /
                    sizeof(deviceExtensions[0])),
            .ppEnabledExtensionNames = deviceExtensions,
            .pEnabledFeatures = nullptr,
        };
        traceStage("guest.vkCreateDevice.begin");
        check(
            mCreateDevice(
                mPhysicalDevice,
                &deviceCreateInfo,
                nullptr,
                &mDevice),
            "vkCreateDevice");
        traceStage("guest.vkCreateDevice.complete");
        traceStage("guest.load-device-dispatch.begin");
        loadDeviceFunctions();
        traceStage("guest.load-device-dispatch.complete");
        mGetDeviceQueue(mDevice, mQueueFamily, 0, &mQueue);
        if (!mQueue) {
            throw std::runtime_error(
                "the guest ICD returned a null graphics queue");
        }
    }

    GuestWorkload(const GuestWorkload &) = delete;
    GuestWorkload &operator=(const GuestWorkload &) = delete;

    ~GuestWorkload() {
        if (mDevice) {
            destroyResources();
            traceStage("guest.vkDestroyDevice.begin");
            mDestroyDevice(mDevice, nullptr);
            traceStage("guest.vkDestroyDevice.complete");
        }
        if (mInstance) {
            traceStage("guest.vkDestroyInstance.begin");
            mDestroyInstance(mInstance, nullptr);
            traceStage("guest.vkDestroyInstance.complete");
        }
    }

    void destroyResources() {
        if (!mDevice) {
            return;
        }
        if (mCommandPool) {
            traceStage("guest.vkDestroyCommandPool.begin");
            mDestroyCommandPool(
                mDevice,
                mCommandPool,
                nullptr);
            traceStage("guest.vkDestroyCommandPool.complete");
            mCommandPool = VK_NULL_HANDLE;
        }
        for (const auto &resource : mResources) {
            traceStage("guest.vkDestroyImage.begin");
            mDestroyImage(mDevice, resource.image, nullptr);
            traceStage("guest.vkDestroyImage.complete");
        }
        for (const auto &resource : mResources) {
            traceStage("guest.vkFreeMemory.begin");
            mFreeMemory(mDevice, resource.memory, nullptr);
            traceStage("guest.vkFreeMemory.complete");
        }
        mResources.clear();
    }

    std::size_t createResource(
        uint32_t colorBufferHandle,
        uint32_t width,
        uint32_t height,
        uint64_t modifier,
        uint32_t planeOffset,
        uint32_t planeStride,
        const std::array<float, 4> &clearColor) {
        const std::size_t resourceIndex = mResources.size();
        mResources.push_back({
            .colorBufferHandle = colorBufferHandle,
        });
        auto &resource = mResources.back();
        const VkSubresourceLayout planeLayout = {
            .offset = planeOffset,
            .size =
                static_cast<VkDeviceSize>(planeStride) *
                static_cast<VkDeviceSize>(height),
            .rowPitch = planeStride,
            .arrayPitch = 0,
            .depthPitch = 0,
        };
        const VkImageDrmFormatModifierExplicitCreateInfoEXT modifierInfo = {
            .sType =
                VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_EXPLICIT_CREATE_INFO_EXT,
            .pNext = nullptr,
            .drmFormatModifier = modifier,
            .drmFormatModifierPlaneCount = 1,
            .pPlaneLayouts = &planeLayout,
        };
        const VkExternalMemoryImageCreateInfo externalInfo = {
            .sType =
                VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
            .pNext = &modifierInfo,
            .handleTypes =
                VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
        };
        const VkImageCreateInfo imageCreateInfo = {
            .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = &externalInfo,
            .flags = 0,
            .imageType = VK_IMAGE_TYPE_2D,
            .format = VK_FORMAT_B8G8R8A8_UNORM,
            .extent = {
                .width = width,
                .height = height,
                .depth = 1,
            },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = VK_SAMPLE_COUNT_1_BIT,
            .tiling = VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT,
            .usage =
                VK_IMAGE_USAGE_TRANSFER_SRC_BIT |
                VK_IMAGE_USAGE_TRANSFER_DST_BIT,
            .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = nullptr,
            .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
        };
        traceStage("guest.vkCreateImage.begin");
        check(
            mCreateImage(
                mDevice,
                &imageCreateInfo,
                nullptr,
                &resource.image),
            "vkCreateImage");
        traceStage("guest.vkCreateImage.complete");

        VkMemoryRequirements requirements = {};
        traceStage("guest.vkGetImageMemoryRequirements.begin");
        mGetImageMemoryRequirements(
            mDevice,
            resource.image,
            &requirements);
        traceStage("guest.vkGetImageMemoryRequirements.complete");
        VkPhysicalDeviceMemoryProperties memoryProperties = {};
        mGetPhysicalDeviceMemoryProperties(
            mPhysicalDevice,
            &memoryProperties);
        uint32_t memoryTypeIndex = UINT32_MAX;
        for (uint32_t index = 0;
             index < memoryProperties.memoryTypeCount;
             ++index) {
            if ((requirements.memoryTypeBits & (1u << index)) == 0) {
                continue;
            }
            if ((memoryProperties.memoryTypes[index].propertyFlags &
                 VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) != 0) {
                memoryTypeIndex = index;
                break;
            }
            if (memoryTypeIndex == UINT32_MAX) {
                memoryTypeIndex = index;
            }
        }
        if (memoryTypeIndex == UINT32_MAX) {
            throw std::runtime_error(
                "the guest image has no compatible memory type");
        }

        VkMemoryDedicatedAllocateInfo dedicatedInfo = {
            .sType =
                VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO,
            .pNext = nullptr,
            .image = resource.image,
            .buffer = VK_NULL_HANDLE,
        };
        VkImportColorBufferGOOGLE importInfo = {
            .sType =
                VK_STRUCTURE_TYPE_IMPORT_COLOR_BUFFER_GOOGLE,
            .pNext = &dedicatedInfo,
            .colorBuffer = colorBufferHandle,
        };
        const VkMemoryAllocateInfo allocateInfo = {
            .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = &importInfo,
            .allocationSize = requirements.size,
            .memoryTypeIndex = memoryTypeIndex,
        };
        traceStage("guest.vkAllocateMemory-import-color-buffer.begin");
        check(
            mAllocateMemory(
                mDevice,
                &allocateInfo,
                nullptr,
                &resource.memory),
            "vkAllocateMemory(VkImportColorBufferGOOGLE)");
        traceStage("guest.vkAllocateMemory-import-color-buffer.complete");
        traceStage("guest.vkBindImageMemory.begin");
        check(
            mBindImageMemory(
                mDevice,
                resource.image,
                resource.memory,
                0),
            "vkBindImageMemory");
        traceStage("guest.vkBindImageMemory.complete");

        if (!mCommandPool) {
            const VkCommandPoolCreateInfo poolCreateInfo = {
                .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
                .pNext = nullptr,
                .flags = VK_COMMAND_POOL_CREATE_TRANSIENT_BIT,
                .queueFamilyIndex = mQueueFamily,
            };
            traceStage("guest.vkCreateCommandPool.begin");
            check(
                mCreateCommandPool(
                    mDevice,
                    &poolCreateInfo,
                    nullptr,
                    &mCommandPool),
                "vkCreateCommandPool");
            traceStage("guest.vkCreateCommandPool.complete");
        }
        const VkCommandBufferAllocateInfo commandAllocateInfo = {
            .sType =
                VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = nullptr,
            .commandPool = mCommandPool,
            .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount =
                static_cast<uint32_t>(resource.commandBuffers.size()),
        };
        traceStage("guest.vkAllocateCommandBuffers.begin");
        check(
            mAllocateCommandBuffers(
                mDevice,
                &commandAllocateInfo,
                resource.commandBuffers.data()),
            "vkAllocateCommandBuffers");
        traceStage("guest.vkAllocateCommandBuffers.complete");
        const VkCommandBufferBeginInfo beginInfo = {
            .sType =
                VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = nullptr,
            .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pInheritanceInfo = nullptr,
        };
        const VkImageSubresourceRange range = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        };
        const VkClearColorValue color = {
            .float32 = {
                clearColor[0],
                clearColor[1],
                clearColor[2],
                clearColor[3],
            },
        };
        const auto record =
            [&](VkCommandBuffer commandBuffer, VkImageLayout oldLayout) {
                traceStage("guest.vkBeginCommandBuffer.begin");
                check(
                    mBeginCommandBuffer(commandBuffer, &beginInfo),
                    "vkBeginCommandBuffer");
                traceStage("guest.vkBeginCommandBuffer.complete");
                const VkImageMemoryBarrier acquireBarrier = {
                    .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                    .pNext = nullptr,
                    .srcAccessMask = 0,
                    .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
                    .oldLayout = oldLayout,
                    .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                    .srcQueueFamilyIndex = VK_QUEUE_FAMILY_EXTERNAL,
                    .dstQueueFamilyIndex = mQueueFamily,
                    .image = resource.image,
                    .subresourceRange = range,
                };
                mCmdPipelineBarrier(
                    commandBuffer,
                    VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                    VK_PIPELINE_STAGE_TRANSFER_BIT,
                    0,
                    0,
                    nullptr,
                    0,
                    nullptr,
                    1,
                    &acquireBarrier);
                mCmdClearColorImage(
                    commandBuffer,
                    resource.image,
                    VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                    &color,
                    1,
                    &range);
                const VkImageMemoryBarrier releaseBarrier = {
                    .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                    .pNext = nullptr,
                    .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
                    .dstAccessMask = VK_ACCESS_MEMORY_READ_BIT,
                    .oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                    .newLayout = VK_IMAGE_LAYOUT_GENERAL,
                    .srcQueueFamilyIndex = mQueueFamily,
                    .dstQueueFamilyIndex = VK_QUEUE_FAMILY_EXTERNAL,
                    .image = resource.image,
                    .subresourceRange = range,
                };
                mCmdPipelineBarrier(
                    commandBuffer,
                    VK_PIPELINE_STAGE_TRANSFER_BIT,
                    VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
                    0,
                    0,
                    nullptr,
                    0,
                    nullptr,
                    1,
                    &releaseBarrier);
                traceStage("guest.vkEndCommandBuffer.begin");
                check(
                    mEndCommandBuffer(commandBuffer),
                    "vkEndCommandBuffer");
                traceStage("guest.vkEndCommandBuffer.complete");
            };
        record(
            resource.commandBuffers[0],
            VK_IMAGE_LAYOUT_UNDEFINED);
        record(
            resource.commandBuffers[1],
            VK_IMAGE_LAYOUT_GENERAL);
        return resourceIndex;
    }

    void submit(std::size_t resourceIndex) {
        if (resourceIndex >= mResources.size()) {
            throw std::runtime_error(
                "the guest workload selected an invalid resource");
        }
        auto &resource = mResources[resourceIndex];
        const VkCommandBuffer commandBuffer =
            resource.commandBuffers[
                resource.submissionCount == 0 ? 0 : 1];
        const VkSubmitInfo submitInfo = {
            .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = nullptr,
            .waitSemaphoreCount = 0,
            .pWaitSemaphores = nullptr,
            .pWaitDstStageMask = nullptr,
            .commandBufferCount = 1,
            .pCommandBuffers = &commandBuffer,
            .signalSemaphoreCount = 0,
            .pSignalSemaphores = nullptr,
        };
        traceStage("guest.vkQueueSubmit.begin");
        check(
            mQueueSubmit(
                mQueue,
                1,
                &submitInfo,
                VK_NULL_HANDLE),
            "vkQueueSubmit");
        ++resource.submissionCount;
        traceStage("guest.vkQueueSubmit.complete");
    }

    const char *deviceName() const {
        return mPhysicalDeviceProperties.deviceName;
    }

  private:
    struct Resource {
        uint32_t colorBufferHandle = 0;
        VkImage image = VK_NULL_HANDLE;
        VkDeviceMemory memory = VK_NULL_HANDLE;
        std::array<VkCommandBuffer, 2> commandBuffers = {
            VK_NULL_HANDLE,
            VK_NULL_HANDLE,
        };
        uint32_t submissionCount = 0;
    };

    static void check(VkResult result, const char *operation) {
        if (result != VK_SUCCESS) {
            throw std::runtime_error(
                std::string(operation) + " failed with VkResult " +
                std::to_string(result));
        }
    }

    void loadDeviceFunctions() {
#define LOAD_DEVICE(name)                                                     \
    m##name = requireDeviceProc<PFN_vk##name>(                                \
        mGetDeviceProcAddr, mDevice, "vk" #name)
        LOAD_DEVICE(DestroyDevice);
        LOAD_DEVICE(GetDeviceQueue);
        LOAD_DEVICE(CreateImage);
        LOAD_DEVICE(DestroyImage);
        LOAD_DEVICE(GetImageMemoryRequirements);
        LOAD_DEVICE(AllocateMemory);
        LOAD_DEVICE(FreeMemory);
        LOAD_DEVICE(BindImageMemory);
        LOAD_DEVICE(CreateCommandPool);
        LOAD_DEVICE(DestroyCommandPool);
        LOAD_DEVICE(AllocateCommandBuffers);
        LOAD_DEVICE(BeginCommandBuffer);
        LOAD_DEVICE(CmdPipelineBarrier);
        LOAD_DEVICE(CmdClearColorImage);
        LOAD_DEVICE(EndCommandBuffer);
        LOAD_DEVICE(QueueSubmit);
#undef LOAD_DEVICE
    }

    PFN_vkGetInstanceProcAddr mGetInstanceProcAddr = nullptr;
    PFN_vkCreateInstance mCreateInstance = nullptr;
    PFN_vkDestroyInstance mDestroyInstance = nullptr;
    PFN_vkEnumeratePhysicalDevices mEnumeratePhysicalDevices = nullptr;
    PFN_vkGetPhysicalDeviceProperties mGetPhysicalDeviceProperties =
        nullptr;
    PFN_vkGetPhysicalDeviceQueueFamilyProperties
        mGetPhysicalDeviceQueueFamilyProperties = nullptr;
    PFN_vkGetPhysicalDeviceMemoryProperties
        mGetPhysicalDeviceMemoryProperties = nullptr;
    PFN_vkEnumerateDeviceExtensionProperties
        mEnumerateDeviceExtensionProperties = nullptr;
    PFN_vkCreateDevice mCreateDevice = nullptr;
    PFN_vkGetDeviceProcAddr mGetDeviceProcAddr = nullptr;
    PFN_vkDestroyDevice mDestroyDevice = nullptr;
    PFN_vkGetDeviceQueue mGetDeviceQueue = nullptr;
    PFN_vkCreateImage mCreateImage = nullptr;
    PFN_vkDestroyImage mDestroyImage = nullptr;
    PFN_vkGetImageMemoryRequirements mGetImageMemoryRequirements =
        nullptr;
    PFN_vkAllocateMemory mAllocateMemory = nullptr;
    PFN_vkFreeMemory mFreeMemory = nullptr;
    PFN_vkBindImageMemory mBindImageMemory = nullptr;
    PFN_vkCreateCommandPool mCreateCommandPool = nullptr;
    PFN_vkDestroyCommandPool mDestroyCommandPool = nullptr;
    PFN_vkAllocateCommandBuffers mAllocateCommandBuffers = nullptr;
    PFN_vkBeginCommandBuffer mBeginCommandBuffer = nullptr;
    PFN_vkCmdPipelineBarrier mCmdPipelineBarrier = nullptr;
    PFN_vkCmdClearColorImage mCmdClearColorImage = nullptr;
    PFN_vkEndCommandBuffer mEndCommandBuffer = nullptr;
    PFN_vkQueueSubmit mQueueSubmit = nullptr;

    VkInstance mInstance = VK_NULL_HANDLE;
    VkPhysicalDevice mPhysicalDevice = VK_NULL_HANDLE;
    VkPhysicalDeviceProperties mPhysicalDeviceProperties = {};
    VkDevice mDevice = VK_NULL_HANDLE;
    VkQueue mQueue = VK_NULL_HANDLE;
    uint32_t mQueueFamily = 0;
    VkCommandPool mCommandPool = VK_NULL_HANDLE;
    std::vector<Resource> mResources;
};

void waitForAcquirePoint(
    const char *renderPath,
    nucleus_android_syncobj_timeline *timeline,
    uint64_t point) {
    traceStage("broker.wait-acquire-point.begin");
    const int timelineFd =
        nucleus_android_syncobj_timeline_export_fd(timeline);
    if (timelineFd < 0) {
        throw std::runtime_error(
            "failed to export the acquire timeline");
    }
    Owned<
        nucleus_android_syncobj_waiter,
        nucleus_android_syncobj_waiter_destroy>
        waiter(
            nucleus_android_syncobj_waiter_create(
                renderPath,
                timelineFd),
            nucleus_android_syncobj_waiter_destroy);
    close(timelineFd);
    if (!waiter) {
        throw std::runtime_error(
            "failed to create the acquire timeline waiter");
    }
    if (nucleus_android_syncobj_waiter_arm(waiter.get(), point) != 0) {
        throw std::runtime_error(
            "failed to arm the acquire timeline waiter");
    }
    pollfd descriptor = {
        .fd =
            nucleus_android_syncobj_waiter_notification_fd(
                waiter.get()),
        .events = POLLIN,
        .revents = 0,
    };
    int result;
    do {
        result =
            poll(
                &descriptor,
                1,
                kCompletionTimeoutMilliseconds);
    } while (result < 0 && errno == EINTR);
    if (result != 1 || (descriptor.revents & POLLIN) == 0 ||
        nucleus_android_syncobj_waiter_drain(waiter.get()) != 0 ||
        nucleus_android_syncobj_waiter_is_signaled(
            waiter.get(),
            point) != 1) {
        throw std::runtime_error(
            "the guest submission did not signal its acquire point");
    }
    traceStage("broker.wait-acquire-point.complete");
}

using BufferGeneration =
    std::vector<std::unique_ptr<BufferSlot>>;

void verifyHostStartupFailures(const char *validDeviceUuid) {
    char error[256] = {};
    auto *invalidExtent =
        nucleus_android_gfxstream_host_renderer_create(
            0,
            kInitialHeight,
            validDeviceUuid,
            error,
            sizeof(error));
    if (invalidExtent) {
        nucleus_android_gfxstream_host_renderer_destroy(invalidExtent);
        throw std::runtime_error(
            "the host renderer accepted a zero-sized extent");
    }
    auto *invalidUuid =
        nucleus_android_gfxstream_host_renderer_create(
            kInitialWidth,
            kInitialHeight,
            "00000000000000000000000000000000",
            error,
            sizeof(error));
    if (invalidUuid) {
        nucleus_android_gfxstream_host_renderer_destroy(invalidUuid);
        throw std::runtime_error(
            "the host renderer accepted an invalid device UUID");
    }
}

void verifyBrokerCapabilityFailure(
    nucleus_android_gpu *gpu,
    uint32_t format) {
    char error[256] = {};
    Owned<
        nucleus_android_gpu_buffer,
        nucleus_android_gpu_buffer_destroy>
        unsupported(
            nucleus_android_gpu_buffer_create(
                gpu,
                kInitialWidth,
                kInitialHeight,
                format,
                UINT64_MAX,
                0,
                error,
                sizeof(error)),
            nucleus_android_gpu_buffer_destroy);
    if (unsupported) {
        throw std::runtime_error(
            "the broker accepted an unsupported DRM modifier");
    }
}

void verifyHostImportFailure(
    nucleus_android_gfxstream_host_renderer *renderer,
    const BufferSlot &reference) {
    const int dmabufFd = reference.exportPlane();
    if (dmabufFd < 0) {
        throw std::runtime_error(
            "failed to export a dma-buf for the negative import test");
    }
    const nucleus_android_gfxstream_host_dmabuf unsupported = {
        .color_buffer_handle = UINT32_MAX,
        .width = reference.width(),
        .height = reference.height(),
        .drm_format = 0,
        .drm_modifier = reference.modifier(),
        .plane_offset = reference.plane().offset,
        .plane_stride = reference.plane().stride,
        .dmabuf_fd = dmabufFd,
    };
    const int result =
        nucleus_android_gfxstream_host_import_dmabuf(
            renderer,
            &unsupported);
    close(dmabufFd);
    if (result != -ENOTSUP) {
        throw std::runtime_error(
            "the host renderer did not reject an unsupported DRM format");
    }
}

void verifyGuestImportFailure(
    GuestWorkload &guest,
    const BufferSlot &reference) {
    bool rejected = false;
    try {
        (void)guest.createResource(
            UINT32_MAX,
            reference.width(),
            reference.height(),
            reference.modifier(),
            reference.plane().offset,
            reference.plane().stride,
            {0.0f, 0.0f, 0.0f, 1.0f});
    } catch (const std::exception &) {
        rejected = true;
    }
    guest.destroyResources();
    if (!rejected) {
        throw std::runtime_error(
            "the guest decoder accepted an unknown color-buffer identity");
    }
}

BufferGeneration createBufferGeneration(
    nucleus_android_gpu *gpu,
    nucleus_android_gfxstream_host_renderer *renderer,
    uint32_t format,
    const std::vector<nucleus_android_format_modifier_properties>
        &modifiers,
    uint32_t firstColorBufferHandle,
    uint32_t width,
    uint32_t height,
    char *error,
    std::size_t errorCapacity) {
    BufferGeneration generation;
    generation.reserve(kBufferCount);
    for (uint32_t index = 0; index < kBufferCount; ++index) {
        traceBufferStage(
            "buffer.allocate-import.begin",
            firstColorBufferHandle + index,
            0,
            width,
            height);
        generation.push_back(
            std::make_unique<BufferSlot>(
                gpu,
                renderer,
                format,
                modifiers,
                firstColorBufferHandle + index,
                width,
                height,
                error,
                errorCapacity));
    }
    return generation;
}

void createGuestResources(
    GuestWorkload &guest,
    BufferGeneration &generation,
    uint32_t paletteOffset) {
    constexpr std::array<std::array<float, 4>, 6> colors = {{
        {0.92f, 0.12f, 0.18f, 1.0f},
        {0.08f, 0.78f, 0.32f, 1.0f},
        {0.07f, 0.42f, 0.94f, 1.0f},
        {0.96f, 0.62f, 0.08f, 1.0f},
        {0.58f, 0.16f, 0.90f, 1.0f},
        {0.04f, 0.78f, 0.84f, 1.0f},
    }};
    for (std::size_t index = 0; index < generation.size(); ++index) {
        auto &slot = *generation[index];
        slot.guestResourceIndex =
            guest.createResource(
                slot.colorBufferHandle(),
                slot.width(),
                slot.height(),
                slot.modifier(),
                slot.plane().offset,
                slot.plane().stride,
                colors[(paletteOffset + index) % colors.size()]);
    }
}

void runBufferGeneration(
    GuestWorkload &guest,
    BufferGeneration &generation,
    const char *renderPath) {
    if (generation.size() != kBufferCount) {
        throw std::runtime_error(
            "the workload did not create a three-buffer generation");
    }
    for (uint32_t frame = 0; frame < kFramesPerGeneration; ++frame) {
        const std::size_t slotIndex = frame % generation.size();
        auto &slot = *generation[slotIndex];
        slot.waitForCompletion(renderPath);
        const uint64_t point =
            static_cast<uint64_t>(
                frame / generation.size()) +
            1;
        slot.prepareSubmission(point);
        traceBufferStage(
            "buffer.guest-submit.begin",
            slot.colorBufferHandle(),
            point,
            slot.width(),
            slot.height());
        guest.submit(slot.guestResourceIndex);
        traceBufferStage(
            "buffer.guest-submit.complete",
            slot.colorBufferHandle(),
            point,
            slot.width(),
            slot.height());
    }
    for (const auto &slot : generation) {
        slot->waitForCompletion(renderPath);
    }

    const uint32_t expectedCallbacks =
        kFramesPerGeneration / kBufferCount;
    for (const auto &slot : generation) {
        const auto &sync = slot->sync();
        if (sync.releaseExports.load(std::memory_order_acquire) !=
                expectedCallbacks ||
            sync.acquireImports.load(std::memory_order_acquire) !=
                expectedCallbacks) {
            throw std::runtime_error(
                "sustained buffer reuse did not traverse both sync callbacks");
        }
    }
}

bool sendWorkerResponse(
    int controlDescriptor,
    int32_t status,
    uint64_t frameNumber,
    const char *error) {
    nucleus_android_gfxstream_worker_response response = {
        .version = NUCLEUS_ANDROID_GFXSTREAM_WORKER_VERSION,
        .type = NUCLEUS_ANDROID_GFXSTREAM_WORKER_RESPONSE,
        .byte_count =
            sizeof(nucleus_android_gfxstream_worker_response),
        .status = status,
        .frame_number = frameNumber,
    };
    if (error) {
        std::snprintf(
            response.error,
            sizeof(response.error),
            "%s",
            error);
    }
    return nucleus_android_ipc_send(
               controlDescriptor,
               &response,
               sizeof(response),
               nullptr,
               0) == 0;
}

void closeWorkerDescriptors(
    std::array<
        int,
        NUCLEUS_ANDROID_GFXSTREAM_WORKER_DESCRIPTOR_COUNT>
        &descriptors) {
    for (int &descriptor : descriptors) {
        if (descriptor >= 0) {
            close(descriptor);
            descriptor = -1;
        }
    }
}

int runBrokerWorker(int controlDescriptor) {
    std::array<
        int,
        NUCLEUS_ANDROID_GFXSTREAM_WORKER_DESCRIPTOR_COUNT>
        descriptors;
    descriptors.fill(-1);
    uint64_t activeFrame = 0;
    bool initialized = false;
    try {
        nucleus_android_gfxstream_worker_initialize initialization =
            {};
        std::size_t descriptorCount = 0;
        const int received =
            nucleus_android_ipc_receive(
                controlDescriptor,
                &initialization,
                sizeof(initialization),
                descriptors.data(),
                descriptors.size(),
                &descriptorCount);
        if (received != static_cast<int>(sizeof(initialization)) ||
            descriptorCount != descriptors.size() ||
            initialization.version !=
                NUCLEUS_ANDROID_GFXSTREAM_WORKER_VERSION ||
            initialization.type !=
                NUCLEUS_ANDROID_GFXSTREAM_WORKER_INITIALIZE ||
            initialization.byte_count != sizeof(initialization) ||
            initialization.buffer_count !=
                NUCLEUS_ANDROID_GFXSTREAM_WORKER_BUFFER_COUNT ||
            initialization.width == 0 ||
            initialization.height == 0 ||
            initialization.render_node[
                sizeof(initialization.render_node) - 1] != '\0' ||
            initialization.device_uuid[
                sizeof(initialization.device_uuid) - 1] != '\0') {
            throw std::runtime_error(
                "invalid gfxstream worker initialization packet");
        }

        char error[1024] = {};
        traceStage("broker-worker.create-gpu.begin");
        Owned<nucleus_android_gpu, nucleus_android_gpu_destroy> gpu(
            nucleus_android_gpu_create(
                initialization.render_node,
                error,
                sizeof(error)),
            nucleus_android_gpu_destroy);
        if (!gpu) {
            throw std::runtime_error(error);
        }
        traceStage("broker-worker.create-gpu.complete");

        traceStage("broker-worker.create-renderer.begin");
        Owned<
            nucleus_android_gfxstream_host_renderer,
            nucleus_android_gfxstream_host_renderer_destroy>
            renderer(
                nucleus_android_gfxstream_host_renderer_create(
                    initialization.width,
                    initialization.height,
                    initialization.device_uuid,
                    error,
                    sizeof(error)),
                nucleus_android_gfxstream_host_renderer_destroy);
        if (!renderer) {
            throw std::runtime_error(error);
        }
        traceStage("broker-worker.create-renderer.complete");

        traceStage("broker-worker.load-icd.begin");
        void *icdHandle =
            dlopen(
                NUCLEUS_ANDROID_GFXSTREAM_GUEST_ICD,
                RTLD_NOW | RTLD_LOCAL | RTLD_DEEPBIND);
        if (!icdHandle) {
            throw std::runtime_error(
                std::string("failed to load the guest ICD: ") +
                dlerror());
        }
        traceStage("broker-worker.load-icd.complete");

        RingConnection connection(renderer.get());
        Owned<
            nucleus_android_gfxstream_factory_registration,
            nucleus_android_gfxstream_factory_registration_destroy>
            registration(
                nucleus_android_gfxstream_factory_registration_create(
                    icdHandle,
                    RingConnection::provide,
                    &connection),
                nucleus_android_gfxstream_factory_registration_destroy);
        if (!registration) {
            dlclose(icdHandle);
            throw std::runtime_error(
                "failed to install the guest IOStream factory");
        }

        try {
            BufferGeneration buffers;
            buffers.reserve(
                NUCLEUS_ANDROID_GFXSTREAM_WORKER_BUFFER_COUNT);
            traceStage("guest.workload-construction.begin");
            GuestWorkload guest(icdHandle);
            traceStage("guest.workload-construction.complete");
            for (uint32_t index = 0;
                 index <
                    NUCLEUS_ANDROID_GFXSTREAM_WORKER_BUFFER_COUNT;
                 ++index) {
                const auto &description =
                    initialization.buffers[index];
                if (description.color_buffer_handle == 0 ||
                    description.plane_stride == 0) {
                    throw std::runtime_error(
                        "gfxstream worker buffer metadata is invalid");
                }
                const nucleus_android_dmabuf_plane plane = {
                    .offset = description.plane_offset,
                    .stride = description.plane_stride,
                };
                traceBufferStage(
                    "buffer.allocate-import.begin",
                    description.color_buffer_handle,
                    0,
                    initialization.width,
                    initialization.height);
                buffers.push_back(
                    std::make_unique<BufferSlot>(
                        gpu.get(),
                        renderer.get(),
                        initialization.drm_format,
                        initialization.drm_modifier,
                        description.color_buffer_handle,
                        initialization.width,
                        initialization.height,
                        plane,
                        descriptors[index],
                        descriptors[3],
                        descriptors[4 + index]));
                descriptors[index] = -1;
            }
            closeWorkerDescriptors(descriptors);
            createGuestResources(guest, buffers, 0);
            if (!sendWorkerResponse(
                    controlDescriptor,
                    0,
                    0,
                    nullptr)) {
                throw std::runtime_error(
                    "failed to acknowledge gfxstream worker initialization");
            }
            initialized = true;

            while (true) {
                nucleus_android_gfxstream_worker_submit request = {};
                std::array<
                    int,
                    NUCLEUS_ANDROID_GFXSTREAM_WORKER_DESCRIPTOR_COUNT>
                    unexpectedDescriptors;
                unexpectedDescriptors.fill(-1);
                std::size_t unexpectedDescriptorCount = 0;
                const int requestBytes =
                    nucleus_android_ipc_receive(
                        controlDescriptor,
                        &request,
                        sizeof(request),
                        unexpectedDescriptors.data(),
                        unexpectedDescriptors.size(),
                        &unexpectedDescriptorCount);
                closeWorkerDescriptors(unexpectedDescriptors);
                if (requestBytes < 0) {
                    if (errno == ECONNRESET || errno == EPIPE) {
                        break;
                    }
                    throw std::runtime_error(
                        "failed to receive a gfxstream worker request");
                }
                if (unexpectedDescriptorCount != 0 ||
                    request.version !=
                        NUCLEUS_ANDROID_GFXSTREAM_WORKER_VERSION) {
                    throw std::runtime_error(
                        "gfxstream worker request is invalid");
                }
                if (request.type ==
                        NUCLEUS_ANDROID_GFXSTREAM_WORKER_SHUTDOWN &&
                    requestBytes ==
                        static_cast<int>(
                            sizeof(
                                nucleus_android_gfxstream_worker_shutdown)) &&
                    request.byte_count ==
                        sizeof(
                            nucleus_android_gfxstream_worker_shutdown)) {
                    break;
                }
                if (request.type !=
                        NUCLEUS_ANDROID_GFXSTREAM_WORKER_SUBMIT ||
                    requestBytes !=
                        static_cast<int>(sizeof(request)) ||
                    request.byte_count != sizeof(request) ||
                    request.acquire_point == 0 ||
                    request.frame_number == 0) {
                    throw std::runtime_error(
                        "gfxstream worker submission is invalid");
                }
                activeFrame = request.frame_number;
                const auto found =
                    std::find_if(
                        buffers.begin(),
                        buffers.end(),
                        [&request](const auto &buffer) {
                            return buffer->colorBufferHandle() ==
                                request.color_buffer_handle;
                        });
                if (found == buffers.end()) {
                    throw std::runtime_error(
                        "gfxstream worker submission names an unknown buffer");
                }
                auto &slot = **found;
                slot.prepareBrokerSubmission(
                    request.acquire_point,
                    request.has_release_point != 0,
                    request.release_point);
                traceBufferStage(
                    "buffer.guest-submit.begin",
                    slot.colorBufferHandle(),
                    request.acquire_point,
                    slot.width(),
                    slot.height());
                guest.submit(slot.guestResourceIndex);
                traceBufferStage(
                    "buffer.guest-submit.complete",
                    slot.colorBufferHandle(),
                    request.acquire_point,
                    slot.width(),
                    slot.height());
                if (!sendWorkerResponse(
                        controlDescriptor,
                        0,
                        activeFrame,
                        nullptr)) {
                    throw std::runtime_error(
                        "failed to acknowledge gfxstream worker submission");
                }
            }
            traceStage("guest.workload-destruction.begin");
        } catch (...) {
            registration.reset();
            connection.stop();
            dlclose(icdHandle);
            throw;
        }
        traceStage("guest.workload-destruction.complete");
        registration.reset();
        connection.stop();
        if (connection.failed()) {
            dlclose(icdHandle);
            throw std::runtime_error(connection.error());
        }
        dlclose(icdHandle);
        closeWorkerDescriptors(descriptors);
        return 0;
    } catch (const std::exception &exception) {
        closeWorkerDescriptors(descriptors);
        (void)sendWorkerResponse(
            controlDescriptor,
            -1,
            initialized ? activeFrame : 0,
            exception.what());
        return 2;
    }
}

const nucleus_android_drm_candidate *selectCandidate(
    const std::vector<nucleus_android_drm_candidate> &candidates,
    const char *requestedRenderNode) {
    for (const auto &candidate : candidates) {
        if (!requestedRenderNode ||
            std::strcmp(
                candidate.render_path,
                requestedRenderNode) == 0) {
            return &candidate;
        }
    }
    return nullptr;
}

void printFailure(const std::string &message) {
    std::string escaped;
    escaped.reserve(message.size());
    for (const char character : message) {
        switch (character) {
            case '\\':
                escaped += "\\\\";
                break;
            case '"':
                escaped += "\\\"";
                break;
            case '\n':
                escaped += "\\n";
                break;
            case '\r':
                escaped += "\\r";
                break;
            case '\t':
                escaped += "\\t";
                break;
            default:
                if (static_cast<unsigned char>(character) < 0x20) {
                    escaped += '?';
                } else {
                    escaped += character;
                }
                break;
        }
    }
    std::printf(
        "{\"status\":\"rejected\",\"error\":\"%s\"}\n",
        escaped.c_str());
}

}  // namespace

int main(int argc, char **argv) {
    if (argc == 2 &&
        std::strcmp(argv[1], "--broker-worker") == 0) {
        return runBrokerWorker(STDIN_FILENO);
    }
    try {
        traceStage("workload.begin");
        const char *requestedRenderNode =
            argc > 1 ? argv[1] : nullptr;
        const int candidateCount =
            nucleus_android_drm_enumerate(nullptr, 0);
        if (candidateCount <= 0) {
            throw std::runtime_error(
                "no DRM render nodes are available");
        }
        std::vector<nucleus_android_drm_candidate> candidates(
            static_cast<std::size_t>(candidateCount));
        const int filled =
            nucleus_android_drm_enumerate(
                candidates.data(),
                candidates.size());
        if (filled <= 0) {
            throw std::runtime_error(
                "DRM render-node enumeration failed");
        }
        candidates.resize(static_cast<std::size_t>(filled));
        const nucleus_android_drm_candidate *candidate =
            selectCandidate(candidates, requestedRenderNode);
        if (!candidate) {
            throw std::runtime_error(
                "the requested DRM render node was not found");
        }

        char error[1024] = {};
        traceStage("broker.create-gpu.begin");
        Owned<nucleus_android_gpu, nucleus_android_gpu_destroy> gpu(
            nucleus_android_gpu_create(
                candidate->render_path,
                error,
                sizeof(error)),
            nucleus_android_gpu_destroy);
        if (!gpu) {
            throw std::runtime_error(error);
        }
        traceStage("broker.create-gpu.complete");
        nucleus_android_gpu_diagnostic diagnostic = {};
        if (nucleus_android_gpu_get_diagnostic(
                gpu.get(),
                &diagnostic) != 0) {
            throw std::runtime_error(
                "GPU diagnostic unavailable");
        }

        traceStage("failure-paths.host-startup.begin");
        verifyHostStartupFailures(diagnostic.device_uuid);
        traceStage("failure-paths.host-startup.complete");
        traceStage("host.create-renderer.begin");
        Owned<
            nucleus_android_gfxstream_host_renderer,
            nucleus_android_gfxstream_host_renderer_destroy>
            renderer(
                nucleus_android_gfxstream_host_renderer_create(
                    kResizedWidth,
                    kResizedHeight,
                    diagnostic.device_uuid,
                    error,
                    sizeof(error)),
                nucleus_android_gfxstream_host_renderer_destroy);
        if (!renderer) {
            throw std::runtime_error(error);
        }
        traceStage("host.create-renderer.complete");

        const uint32_t format =
            nucleus_android_drm_format_xrgb8888();
        traceStage("failure-paths.broker-capability.begin");
        verifyBrokerCapabilityFailure(gpu.get(), format);
        traceStage("failure-paths.broker-capability.complete");
        const int modifierCount =
            nucleus_android_gpu_list_format_modifiers(
                gpu.get(),
                format,
                nullptr,
                0);
        if (modifierCount <= 0) {
            throw std::runtime_error(
                "the selected GPU exposes no XRGB8888 modifiers");
        }
        std::vector<nucleus_android_format_modifier_properties>
            modifiers(static_cast<std::size_t>(modifierCount));
        const int modifierFilled =
            nucleus_android_gpu_list_format_modifiers(
                gpu.get(),
                format,
                modifiers.data(),
                modifiers.size());
        if (modifierFilled <= 0) {
            throw std::runtime_error(
                "format-modifier enumeration failed");
        }
        modifiers.resize(static_cast<std::size_t>(modifierFilled));
        BufferGeneration buffers =
            createBufferGeneration(
                gpu.get(),
                renderer.get(),
                format,
                modifiers,
                kFirstColorBufferHandle,
                kInitialWidth,
                kInitialHeight,
                error,
                sizeof(error));
        const uint64_t initialModifier =
            buffers.front()->modifier();
        traceStage("failure-paths.host-import.begin");
        verifyHostImportFailure(renderer.get(), *buffers.front());
        traceStage("failure-paths.host-import.complete");

        traceStage("guest.load-icd.begin");
        void *icdHandle =
            dlopen(
                NUCLEUS_ANDROID_GFXSTREAM_GUEST_ICD,
                RTLD_NOW | RTLD_LOCAL | RTLD_DEEPBIND);
        if (!icdHandle) {
            throw std::runtime_error(
                std::string("failed to load the guest ICD: ") +
                dlerror());
        }
        traceStage("guest.load-icd.complete");

        RingConnection connection(renderer.get());
        traceStage("guest.install-iostream-factory.begin");
        Owned<
            nucleus_android_gfxstream_factory_registration,
            nucleus_android_gfxstream_factory_registration_destroy>
            registration(
                nucleus_android_gfxstream_factory_registration_create(
                    icdHandle,
                    RingConnection::provide,
                    &connection),
                nucleus_android_gfxstream_factory_registration_destroy);
        if (!registration) {
            throw std::runtime_error(
                "failed to install the guest IOStream factory");
        }
        traceStage("guest.install-iostream-factory.complete");
        using HasExternalFactory = int (*)();
        const auto hasExternalFactory =
            reinterpret_cast<HasExternalFactory>(
                dlsym(
                    icdHandle,
                    "gfxstream_vk_has_external_iostream_factory"));
        if (!hasExternalFactory || hasExternalFactory() != 1) {
            throw std::runtime_error(
                "the pinned guest ICD did not retain its external IOStream factory");
        }

        std::string guestDeviceName;
        try {
            {
                traceStage("guest.workload-construction.begin");
                GuestWorkload guest(icdHandle);
                traceStage("guest.workload-construction.complete");
                guestDeviceName = guest.deviceName();
                traceStage("failure-paths.guest-import.begin");
                verifyGuestImportFailure(
                    guest,
                    *buffers.front());
                traceStage("failure-paths.guest-import.complete");
                traceStage("guest.submit-workload.begin");
                createGuestResources(guest, buffers, 0);
                runBufferGeneration(
                    guest,
                    buffers,
                    candidate->render_path);
                traceStage("guest.resize-reallocation.begin");
                guest.destroyResources();
                buffers.clear();
                buffers =
                    createBufferGeneration(
                        gpu.get(),
                        renderer.get(),
                        format,
                        modifiers,
                        kFirstColorBufferHandle + kBufferCount,
                        kResizedWidth,
                        kResizedHeight,
                        error,
                        sizeof(error));
                createGuestResources(guest, buffers, kBufferCount);
                runBufferGeneration(
                    guest,
                    buffers,
                    candidate->render_path);
                traceStage("guest.resize-reallocation.complete");
                traceStage("guest.submit-workload.complete");
                traceStage("guest.workload-destruction.begin");
            }
            traceStage("guest.workload-destruction.complete");
        } catch (const std::exception &exception) {
            registration.reset();
            connection.stop();
            std::string detail =
                exception.what() +
                std::string("; endpointProviderCalls=") +
                std::to_string(connection.providerCalls());
            if (connection.failed()) {
                detail += "; hostPump=" + connection.error();
            }
            throw std::runtime_error(detail);
        }
        registration.reset();
        connection.stop();
        if (connection.failed()) {
            throw std::runtime_error(connection.error());
        }
        const uint64_t backpressureEvents =
            connection.backpressureEvents();
        const uint64_t maximumRingOccupancy =
            connection.maximumRingOccupancy();
        const auto connectionDiagnostics =
            connection.diagnostics();

        std::printf(
            "{\"status\":\"qualified\","
            "\"renderNode\":\"%s\","
            "\"hostVulkanDevice\":\"%s\","
            "\"guestVulkanDevice\":\"%s\","
            "\"vulkanDeviceUUID\":\"%s\","
            "\"drmFormat\":\"0x%08x\","
            "\"drmModifier\":\"0x%016llx\","
            "\"bufferCount\":%u,"
            "\"frameCount\":%u,"
            "\"generationCount\":2,"
            "\"initialExtent\":\"%ux%u\","
            "\"resizedExtent\":\"%ux%u\","
            "\"distinctFrameColors\":6,"
            "\"sustainedBufferReuse\":true,"
            "\"resizeReallocation\":true,"
            "\"ringSlotCount\":2,"
            "\"ringMaximumOccupancy\":%llu,"
            "\"ringBackpressureEvents\":%llu,"
            "\"ringPumpProgressEvents\":%llu,"
            "\"ringCommandNotifications\":%llu,"
            "\"ringResponseSpaceNotifications\":%llu,"
            "\"rendererWakeups\":%llu,"
            "\"peerDisconnects\":%llu,"
            "\"orderlyStopWakeups\":%llu,"
            "\"boundedBackpressure\":%s,"
            "\"orderlyTeardown\":true,"
            "\"unsupportedCapabilityFailures\":true,"
            "\"guestImportColorBuffer\":true,"
            "\"liveRingDecoder\":true,"
            "\"releaseSyncFileWait\":true,"
            "\"acquireSyncFileSignal\":true,"
            "\"cpuFenceWait\":false}\n",
            candidate->render_path,
            diagnostic.device_name,
            guestDeviceName.c_str(),
            diagnostic.device_uuid,
            format,
            static_cast<unsigned long long>(initialModifier),
            kBufferCount,
            kFramesPerGeneration * 2,
            kInitialWidth,
            kInitialHeight,
            kResizedWidth,
            kResizedHeight,
            static_cast<unsigned long long>(maximumRingOccupancy),
            static_cast<unsigned long long>(backpressureEvents),
            static_cast<unsigned long long>(
                connectionDiagnostics.pumpProgress),
            static_cast<unsigned long long>(
                connectionDiagnostics.commandNotifications),
            static_cast<unsigned long long>(
                connectionDiagnostics.responseSpaceNotifications),
            static_cast<unsigned long long>(
                connectionDiagnostics.rendererWakeups),
            static_cast<unsigned long long>(
                connectionDiagnostics.peerDisconnects),
            static_cast<unsigned long long>(
                connectionDiagnostics.orderlyStopWakeups),
            backpressureEvents > 0 ? "true" : "false");
        return 0;
    } catch (const std::exception &exception) {
        printFailure(exception.what());
        return 2;
    }
}
