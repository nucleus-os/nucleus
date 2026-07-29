#include <errno.h>
#include <drm/drm_fourcc.h>
#include <fcntl.h>
#include <linux/memfd.h>
#include <poll.h>
#include <signal.h>
#include <sys/eventfd.h>
#include <sys/resource.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#include <array>
#include <atomic>
#include <charconv>
#include <chrono>
#include <condition_variable>
#include <cstdarg>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <string_view>
#include <thread>
#include <unordered_map>
#include <vector>

#include "NucleusAndroidDrmC.h"
#include "NucleusAndroidGfxstreamAdapters/GuestRingFactory.h"
#include "NucleusAndroidGfxstreamHostC.h"
#include "NucleusAndroidGfxstreamSocketProtocol.h"
#include "NucleusIPCTransportC.h"
#include "NucleusAndroidProcessLifecycleC.h"
#include "NucleusAndroidSharedRingC.h"

namespace {

std::atomic<bool> stopping = false;
std::atomic<bool> brokerFailed = false;
std::atomic<int> listenerDescriptor = -1;
std::atomic_flag handlingFatalSignal = ATOMIC_FLAG_INIT;
alignas(16) std::array<std::byte, 64 * 1024> fatalSignalStack = {};

struct BrokerStatistics {
    std::atomic<uint64_t> connectionsOpened = 0;
    std::atomic<uint64_t> connectionsClosed = 0;
    std::atomic<uint64_t> buffersAllocated = 0;
    std::atomic<uint64_t> buffersReclaimed = 0;
    std::atomic<uint64_t> hostMemoryExports = 0;
    std::atomic<uint64_t> vulkanFenceExports = 0;
    std::atomic<uint64_t> vulkanSemaphoreExports = 0;
    std::atomic<uint64_t> vulkanQsriExports = 0;
    std::atomic<uint64_t> vulkanQsriSignals = 0;
    std::atomic<uint64_t> cpuLocksOpened = 0;
    std::atomic<uint64_t> cpuLocksClosed = 0;
    std::atomic<uint64_t> cpuReadbacks = 0;
    std::atomic<uint64_t> cpuUploads = 0;
    std::atomic<uint64_t> cpuSyncs = 0;
    std::atomic<uint64_t> cpuOperationFailures = 0;
    std::atomic<uint64_t> vulkanFenceExportMaxMicroseconds = 0;
    std::atomic<uint64_t> vulkanFenceWaitMaxMicroseconds = 0;
    std::atomic<uint64_t> vulkanSemaphoreExportMaxMicroseconds = 0;
    std::atomic<uint64_t> vulkanQsriExportMaxMicroseconds = 0;
    std::atomic<uint64_t> vulkanQsriWaitMaxMicroseconds = 0;
    std::atomic<uint64_t> cpuReadbackMaxMicroseconds = 0;
    std::atomic<uint64_t> cpuUploadMaxMicroseconds = 0;
    std::atomic<uint32_t> bufferDiagnosticBudget = 8;
    std::atomic_flag loggedFirstQsriExport = ATOMIC_FLAG_INIT;
    std::atomic_flag loggedFirstQsriSignal = ATOMIC_FLAG_INIT;
    std::atomic_flag loggedFirstCpuLock = ATOMIC_FLAG_INIT;
    std::atomic_flag loggedFirstCpuReadback = ATOMIC_FLAG_INIT;
    std::atomic_flag loggedFirstCpuUpload = ATOMIC_FLAG_INIT;
};

BrokerStatistics statistics;
std::mutex logMutex;

using MonotonicClock = std::chrono::steady_clock;

void writeLog(const char *format, ...) {
    std::lock_guard<std::mutex> lock(logMutex);
    va_list arguments;
    va_start(arguments, format);
    std::vfprintf(stderr, format, arguments);
    va_end(arguments);
    std::fflush(stderr);
}

uint64_t elapsedMicroseconds(MonotonicClock::time_point began) {
    return static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::microseconds>(
            MonotonicClock::now() - began)
            .count());
}

void recordMaximum(
    std::atomic<uint64_t> &maximum,
    uint64_t value) {
    uint64_t previous = maximum.load(std::memory_order_relaxed);
    while (previous < value &&
           !maximum.compare_exchange_weak(
               previous, value, std::memory_order_relaxed)) {}
}

constexpr uint64_t slowOperationMicroseconds = 50'000;

long currentThreadIdentifier() {
    return syscall(SYS_gettid);
}

void writeFatalSignalMessage(int signalNumber) {
    char message[] =
        "{\"component\":\"nucleus-android-gfxstream-broker\","
        "\"stage\":\"fatal-signal\",\"signal\":00}\n";
    message[sizeof(message) - 5] =
        static_cast<char>('0' + (signalNumber / 10) % 10);
    message[sizeof(message) - 4] =
        static_cast<char>('0' + signalNumber % 10);
    (void)write(STDERR_FILENO, message, sizeof(message) - 1);
}

void fatalSignal(
    int signalNumber,
    siginfo_t *,
    void *) {
    if (handlingFatalSignal.test_and_set(std::memory_order_relaxed)) {
        _exit(128 + signalNumber);
    }
    writeFatalSignalMessage(signalNumber);
    (void)kill(getpid(), signalNumber);
    _exit(128 + signalNumber);
}

bool installFatalSignalDiagnostics() {
    stack_t alternateStack = {
        .ss_sp = fatalSignalStack.data(),
        .ss_flags = 0,
        .ss_size = fatalSignalStack.size(),
    };
    if (sigaltstack(&alternateStack, nullptr) < 0) {
        return false;
    }
    struct sigaction action = {};
    action.sa_sigaction = fatalSignal;
    action.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_RESETHAND;
    sigemptyset(&action.sa_mask);
    for (const int signalNumber : {
             SIGSEGV,
             SIGABRT,
             SIGBUS,
             SIGILL,
             SIGFPE,
         }) {
        if (sigaction(signalNumber, &action, nullptr) < 0) {
            return false;
        }
    }
    return true;
}

constexpr bool addressSanitizerEnabled() {
#if defined(__has_feature)
#if __has_feature(address_sanitizer)
    return true;
#else
    return false;
#endif
#elif defined(__SANITIZE_ADDRESS__)
    return true;
#else
    return false;
#endif
}

void requestStop(bool failed) {
    if (failed) {
        brokerFailed.store(true, std::memory_order_release);
    }
    stopping.store(true, std::memory_order_release);
    const int listener =
        listenerDescriptor.exchange(-1, std::memory_order_acq_rel);
    if (listener >= 0) {
        shutdown(listener, SHUT_RDWR);
        close(listener);
    }
}

void stop(int) {
    requestStop(false);
}

bool raiseFileDescriptorLimit() {
    rlimit limit = {};
    if (getrlimit(RLIMIT_NOFILE, &limit) < 0) {
        return false;
    }
    if (limit.rlim_cur == limit.rlim_max) {
        return true;
    }
    limit.rlim_cur = limit.rlim_max;
    return setrlimit(RLIMIT_NOFILE, &limit) == 0;
}

bool restoreCoreFileLimit() {
    rlimit limit = {};
    if (getrlimit(RLIMIT_CORE, &limit) < 0) {
        return false;
    }
    limit.rlim_cur = limit.rlim_max;
    return setrlimit(RLIMIT_CORE, &limit) == 0;
}

std::string jsonEscape(const char *value) {
    std::string result;
    if (!value) return result;
    for (const unsigned char byte : std::string_view(value)) {
        switch (byte) {
            case '"': result += "\\\""; break;
            case '\\': result += "\\\\"; break;
            case '\n': result += "\\n"; break;
            case '\r': result += "\\r"; break;
            case '\t': result += "\\t"; break;
            default:
                if (byte >= 0x20) result.push_back(static_cast<char>(byte));
                break;
        }
    }
    return result;
}

void trace(const char *stage, const std::string &detail = {}) {
    const auto escapedDetail = jsonEscape(detail.c_str());
    writeLog(
        "{\"component\":\"nucleus-android-gfxstream-broker\","
        "\"stage\":\"%s\",\"detail\":\"%s\"}\n",
        stage,
        escapedDetail.c_str());
}

void gfxstreamLog(
    nucleus_android_gfxstream_log_level level,
    const char *file,
    int line,
    const char *function,
    const char *message) {
    const auto escapedFile = jsonEscape(file);
    const auto escapedFunction = jsonEscape(function);
    const auto escapedMessage = jsonEscape(message);
    writeLog(
        "{\"component\":\"gfxstream\",\"level\":%d,\"file\":\"%s\","
        "\"line\":%d,\"function\":\"%s\",\"message\":\"%s\"}\n",
        static_cast<int>(level),
        escapedFile.c_str(),
        line,
        escapedFunction.c_str(),
        escapedMessage.c_str());
}

void traceEndpoint(
    const char *stage,
    uint64_t endpointIdentifier,
    uint32_t peerPID,
    const char *detail,
    int errorNumber = 0) {
    if (std::strcmp(stage, "connection.opened") == 0 &&
        errorNumber == 0) {
        statistics.connectionsOpened.fetch_add(1, std::memory_order_relaxed);
        return;
    }
    if (std::strcmp(stage, "connection.closed") == 0 &&
        errorNumber == 0) {
        statistics.connectionsClosed.fetch_add(1, std::memory_order_relaxed);
        return;
    }
    const auto escapedDetail = jsonEscape(detail);
    writeLog(
        "{\"component\":\"nucleus-android-gfxstream-broker\","
        "\"stage\":\"%s\",\"endpointId\":%llu,\"peerPid\":%u,"
        "\"errno\":%d,\"detail\":\"%s\"}\n",
        stage,
        static_cast<unsigned long long>(endpointIdentifier),
        peerPID,
        errorNumber,
        escapedDetail.c_str());
}

void traceBuffer(
    const char *stage,
    uint64_t allocationIdentifier,
    uint32_t colorBufferHandle,
    const nucleus_android_gfxstream_socket_message &request,
    uint64_t modifier,
    uint32_t stride,
    int status) {
    if (status == 0) {
        if (std::strcmp(stage, "buffer.allocated") == 0) {
            statistics.buffersAllocated.fetch_add(
                1, std::memory_order_relaxed);
            uint32_t budget = statistics.bufferDiagnosticBudget.load(
                std::memory_order_relaxed);
            while (budget > 0 &&
                   !statistics.bufferDiagnosticBudget.compare_exchange_weak(
                       budget,
                       budget - 1,
                       std::memory_order_relaxed)) {}
            if (budget == 0) {
                return;
            }
        } else {
            if (std::strcmp(stage, "buffer.storage-released") == 0) {
                statistics.buffersReclaimed.fetch_add(
                    1, std::memory_order_relaxed);
            }
            return;
        }
    }
    writeLog(
        "{\"component\":\"nucleus-android-gfxstream-broker\","
        "\"stage\":\"%s\",\"allocationId\":%llu,\"colorBufferHandle\":%u,"
        "\"width\":%u,\"height\":%u,\"androidFormat\":%u,\"drmFormat\":%u,"
        "\"modifier\":%llu,\"usage\":%llu,\"stride\":%u,\"status\":%d}\n",
        stage,
        static_cast<unsigned long long>(allocationIdentifier),
        colorBufferHandle,
        request.width,
        request.height,
        request.android_format,
        request.drm_format,
        static_cast<unsigned long long>(modifier),
        static_cast<unsigned long long>(request.usage),
        stride,
        status);
}

void traceHostMemory(
    const char *stage,
    uint64_t blobIdentifier,
    uint32_t peerPID,
    uint64_t size,
    int status) {
    if (status == 0) {
        statistics.hostMemoryExports.fetch_add(
            1, std::memory_order_relaxed);
        return;
    }
    writeLog(
        "{\"component\":\"nucleus-android-gfxstream-broker\","
        "\"stage\":\"%s\",\"blobId\":%llu,\"peerPid\":%u,"
        "\"size\":%llu,\"status\":%d}\n",
        stage,
        static_cast<unsigned long long>(blobIdentifier),
        peerPID,
        static_cast<unsigned long long>(size),
        status);
}

void traceCpuTransfer(
    const char *stage,
    uint64_t allocationIdentifier,
    uint64_t cpuLockIdentifier,
    uint32_t peerPID,
    uint32_t access,
    uint64_t size,
    int status,
    uint64_t durationMicroseconds = 0,
    bool firstSuccess = false) {
    if (status != 0) {
        statistics.cpuOperationFailures.fetch_add(
            1, std::memory_order_relaxed);
    }
    if (status == 0 &&
        durationMicroseconds < slowOperationMicroseconds &&
        !firstSuccess) {
        return;
    }
    writeLog(
        "{\"component\":\"nucleus-android-gfxstream-broker\","
        "\"stage\":\"%s\",\"allocationId\":%llu,\"cpuLockId\":%llu,"
        "\"peerPid\":%u,\"access\":%u,\"size\":%llu,\"status\":%d,"
        "\"durationMicroseconds\":%llu}\n",
        stage,
        static_cast<unsigned long long>(allocationIdentifier),
        static_cast<unsigned long long>(cpuLockIdentifier),
        peerPID,
        access,
        static_cast<unsigned long long>(size),
        status,
        static_cast<unsigned long long>(durationMicroseconds));
}

void traceVulkanFence(
    const char *stage,
    uint64_t deviceHandle,
    uint64_t fenceHandle,
    uint32_t peerPID,
    int status,
    uint64_t durationMicroseconds = 0) {
    if (status == 0 &&
        std::strcmp(stage, "vulkan-fence.exported") == 0) {
        statistics.vulkanFenceExports.fetch_add(
            1, std::memory_order_relaxed);
        recordMaximum(
            statistics.vulkanFenceExportMaxMicroseconds,
            durationMicroseconds);
    } else if (
        status == 0 &&
        std::strcmp(stage, "vulkan-fence.wait.completed") == 0) {
        recordMaximum(
            statistics.vulkanFenceWaitMaxMicroseconds,
            durationMicroseconds);
    }
    if (status == 0 &&
        durationMicroseconds < slowOperationMicroseconds) {
        return;
    }
    writeLog(
        "{\"component\":\"nucleus-android-gfxstream-broker\","
        "\"stage\":\"%s\",\"deviceHandle\":%llu,\"fenceHandle\":%llu,"
        "\"peerPid\":%u,\"threadId\":%ld,\"status\":%d,"
        "\"durationMicroseconds\":%llu}\n",
        stage,
        static_cast<unsigned long long>(deviceHandle),
        static_cast<unsigned long long>(fenceHandle),
        peerPID,
        currentThreadIdentifier(),
        status,
        static_cast<unsigned long long>(durationMicroseconds));
}

void traceVulkanSemaphore(
    const char *stage,
    uint64_t deviceHandle,
    uint64_t semaphoreHandle,
    uint32_t peerPID,
    int status,
    uint64_t durationMicroseconds = 0) {
    if (status == 0) {
        statistics.vulkanSemaphoreExports.fetch_add(
            1, std::memory_order_relaxed);
        recordMaximum(
            statistics.vulkanSemaphoreExportMaxMicroseconds,
            durationMicroseconds);
    }
    if (status == 0 &&
        durationMicroseconds < slowOperationMicroseconds) {
        return;
    }
    writeLog(
        "{\"component\":\"nucleus-android-gfxstream-broker\","
        "\"stage\":\"%s\",\"deviceHandle\":%llu,"
        "\"semaphoreHandle\":%llu,\"peerPid\":%u,"
        "\"threadId\":%ld,\"status\":%d,"
        "\"durationMicroseconds\":%llu}\n",
        stage,
        static_cast<unsigned long long>(deviceHandle),
        static_cast<unsigned long long>(semaphoreHandle),
        peerPID,
        currentThreadIdentifier(),
        status,
        static_cast<unsigned long long>(durationMicroseconds));
}

void traceVulkanQsri(
    const char *stage,
    uint64_t imageHandle,
    uint32_t peerPID,
    int status,
    uint64_t durationMicroseconds = 0) {
    if (status == 0 &&
        std::strcmp(stage, "vulkan-qsri.exported") == 0) {
        statistics.vulkanQsriExports.fetch_add(
            1, std::memory_order_relaxed);
        recordMaximum(
            statistics.vulkanQsriExportMaxMicroseconds,
            durationMicroseconds);
    } else if (
        status == 0 &&
        std::strcmp(stage, "vulkan-qsri.signaled") == 0) {
        statistics.vulkanQsriSignals.fetch_add(
            1, std::memory_order_relaxed);
        recordMaximum(
            statistics.vulkanQsriWaitMaxMicroseconds,
            durationMicroseconds);
    }
    const bool firstSuccessfulExport =
        status == 0 &&
        std::strcmp(stage, "vulkan-qsri.exported") == 0 &&
        !statistics.loggedFirstQsriExport.test_and_set(
            std::memory_order_relaxed);
    const bool firstSuccessfulSignal =
        status == 0 &&
        std::strcmp(stage, "vulkan-qsri.signaled") == 0 &&
        !statistics.loggedFirstQsriSignal.test_and_set(
            std::memory_order_relaxed);
    if (status == 0 &&
        durationMicroseconds < slowOperationMicroseconds &&
        !firstSuccessfulExport &&
        !firstSuccessfulSignal) {
        return;
    }
    writeLog(
        "{\"component\":\"nucleus-android-gfxstream-broker\","
        "\"stage\":\"%s\",\"imageHandle\":%llu,\"peerPid\":%u,"
        "\"threadId\":%ld,\"status\":%d,"
        "\"durationMicroseconds\":%llu}\n",
        stage,
        static_cast<unsigned long long>(imageHandle),
        peerPID,
        currentThreadIdentifier(),
        status,
        static_cast<unsigned long long>(durationMicroseconds));
}

void traceStatistics() {
    writeLog(
        "{\"component\":\"nucleus-android-gfxstream-broker\","
        "\"stage\":\"statistics\","
        "\"connectionsOpened\":%llu,\"connectionsClosed\":%llu,"
        "\"buffersAllocated\":%llu,\"buffersReclaimed\":%llu,"
        "\"hostMemoryExports\":%llu,\"vulkanFenceExports\":%llu,"
        "\"vulkanSemaphoreExports\":%llu,\"vulkanQsriExports\":%llu,"
        "\"vulkanQsriSignals\":%llu,"
        "\"cpuLocksOpened\":%llu,\"cpuLocksClosed\":%llu,"
        "\"cpuReadbacks\":%llu,\"cpuUploads\":%llu,\"cpuSyncs\":%llu,"
        "\"cpuOperationFailures\":%llu,"
        "\"vulkanFenceExportMaxMicroseconds\":%llu,"
        "\"vulkanFenceWaitMaxMicroseconds\":%llu,"
        "\"vulkanSemaphoreExportMaxMicroseconds\":%llu,"
        "\"vulkanQsriExportMaxMicroseconds\":%llu,"
        "\"vulkanQsriWaitMaxMicroseconds\":%llu,"
        "\"cpuReadbackMaxMicroseconds\":%llu,"
        "\"cpuUploadMaxMicroseconds\":%llu}\n",
        static_cast<unsigned long long>(
            statistics.connectionsOpened.load(std::memory_order_relaxed)),
        static_cast<unsigned long long>(
            statistics.connectionsClosed.load(std::memory_order_relaxed)),
        static_cast<unsigned long long>(
            statistics.buffersAllocated.load(std::memory_order_relaxed)),
        static_cast<unsigned long long>(
            statistics.buffersReclaimed.load(std::memory_order_relaxed)),
        static_cast<unsigned long long>(
            statistics.hostMemoryExports.load(std::memory_order_relaxed)),
        static_cast<unsigned long long>(
            statistics.vulkanFenceExports.load(std::memory_order_relaxed)),
        static_cast<unsigned long long>(
            statistics.vulkanSemaphoreExports.load(
                std::memory_order_relaxed)),
        static_cast<unsigned long long>(
            statistics.vulkanQsriExports.load(std::memory_order_relaxed)),
        static_cast<unsigned long long>(
            statistics.vulkanQsriSignals.load(std::memory_order_relaxed)),
        static_cast<unsigned long long>(
            statistics.cpuLocksOpened.load(std::memory_order_relaxed)),
        static_cast<unsigned long long>(
            statistics.cpuLocksClosed.load(std::memory_order_relaxed)),
        static_cast<unsigned long long>(
            statistics.cpuReadbacks.load(std::memory_order_relaxed)),
        static_cast<unsigned long long>(
            statistics.cpuUploads.load(std::memory_order_relaxed)),
        static_cast<unsigned long long>(
            statistics.cpuSyncs.load(std::memory_order_relaxed)),
        static_cast<unsigned long long>(
            statistics.cpuOperationFailures.load(std::memory_order_relaxed)),
        static_cast<unsigned long long>(
            statistics.vulkanFenceExportMaxMicroseconds.load(
                std::memory_order_relaxed)),
        static_cast<unsigned long long>(
            statistics.vulkanFenceWaitMaxMicroseconds.load(
                std::memory_order_relaxed)),
        static_cast<unsigned long long>(
            statistics.vulkanSemaphoreExportMaxMicroseconds.load(
                std::memory_order_relaxed)),
        static_cast<unsigned long long>(
            statistics.vulkanQsriExportMaxMicroseconds.load(
                std::memory_order_relaxed)),
        static_cast<unsigned long long>(
            statistics.vulkanQsriWaitMaxMicroseconds.load(
                std::memory_order_relaxed)),
        static_cast<unsigned long long>(
            statistics.cpuReadbackMaxMicroseconds.load(
                std::memory_order_relaxed)),
        static_cast<unsigned long long>(
            statistics.cpuUploadMaxMicroseconds.load(
                std::memory_order_relaxed)));
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

bool parseUInt32(std::string_view value, uint32_t *output) {
    const auto result = std::from_chars(
        value.data(), value.data() + value.size(), *output);
    return result.ec == std::errc() &&
           result.ptr == value.data() + value.size();
}

std::string selectRenderNode(const char *requested) {
    if (requested != nullptr) {
        return requested;
    }
    std::array<char, NUCLEUS_ANDROID_DRM_PATH_MAX> selected = {};
    return nucleus_android_drm_select_display_render_path(
               selected.data(), selected.size()) == 0
        ? std::string(selected.data())
        : std::string();
}

using RingMapping = std::unique_ptr<
    nucleus_android_shared_ring_mapping,
    decltype(&nucleus_android_shared_ring_mapping_destroy)>;

class VulkanFenceCompletions {
  public:
    void begin() {
        std::lock_guard<std::mutex> lock(mutex);
        ++active;
    }

    void complete() {
        std::lock_guard<std::mutex> lock(mutex);
        if (--active == 0) {
            condition.notify_all();
        }
    }

    void wait() {
        std::unique_lock<std::mutex> lock(mutex);
        condition.wait(lock, [this] { return active == 0; });
    }

  private:
    std::mutex mutex;
    std::condition_variable condition;
    size_t active = 0;
};

struct VulkanFenceCompletion {
    VulkanFenceCompletions *completions;
    nucleus_android_native_fence *nativeFence;
    uint64_t deviceHandle;
    uint64_t fenceHandle;
    uint32_t peerPID;
    MonotonicClock::time_point began;
};

void completeVulkanFence(void *opaque, int waitStatus) {
    std::unique_ptr<VulkanFenceCompletion> completion(
        static_cast<VulkanFenceCompletion *>(opaque));
    char error[512] = {};
    const int result = nucleus_android_native_fence_signal(
        completion->nativeFence, error, sizeof(error));
    const int status = waitStatus != 0
        ? waitStatus
        : (result == 0 ? 0 : -errno);
    if (result != 0) {
        trace("vulkan-fence.signal.failed", error);
    }
    if (status != 0) {
        traceVulkanFence(
            "vulkan-fence.wait.failed",
            completion->deviceHandle,
            completion->fenceHandle,
            completion->peerPID,
            status,
            elapsedMicroseconds(completion->began));
        requestStop(true);
    } else {
        traceVulkanFence(
            "vulkan-fence.wait.completed",
            completion->deviceHandle,
            completion->fenceHandle,
            completion->peerPID,
            0,
            elapsedMicroseconds(completion->began));
    }
    nucleus_android_native_fence_destroy(completion->nativeFence);
    completion->completions->complete();
}

struct VulkanQsriCompletion {
    VulkanFenceCompletions *completions;
    nucleus_android_native_fence *nativeFence;
    uint64_t imageHandle;
    uint32_t peerPID;
    MonotonicClock::time_point began;
};

void completeVulkanQsri(void *opaque, int waitStatus) {
    std::unique_ptr<VulkanQsriCompletion> completion(
        static_cast<VulkanQsriCompletion *>(opaque));
    char error[512] = {};
    const int result = nucleus_android_native_fence_signal(
        completion->nativeFence, error, sizeof(error));
    const int status = waitStatus != 0
        ? waitStatus
        : (result == 0 ? 0 : -errno);
    if (result != 0) {
        trace("vulkan-qsri.signal.failed", error);
    }
    if (status != 0) {
        traceVulkanQsri(
            "vulkan-qsri.wait.failed",
            completion->imageHandle,
            completion->peerPID,
            status,
            elapsedMicroseconds(completion->began));
        requestStop(true);
    } else {
        traceVulkanQsri(
            "vulkan-qsri.signaled",
            completion->imageHandle,
            completion->peerPID,
            0,
            elapsedMicroseconds(completion->began));
    }
    nucleus_android_native_fence_destroy(completion->nativeFence);
    completion->completions->complete();
}

nucleus_android_gfxstream_endpoint_descriptors emptyDescriptors() {
    return {-1, -1, -1, -1, -1, -1, -1};
}

void closeDescriptors(
    nucleus_android_gfxstream_endpoint_descriptors descriptors) {
    for (const int descriptor : {
             descriptors.command_memory_fd,
             descriptors.command_data_notification_fd,
             descriptors.command_space_notification_fd,
             descriptors.response_memory_fd,
             descriptors.response_data_notification_fd,
             descriptors.response_space_notification_fd,
             descriptors.lifetime_fd,
         }) {
        if (descriptor >= 0) {
            close(descriptor);
        }
    }
}

bool exportDescriptors(
    nucleus_android_shared_ring_mapping *commands,
    nucleus_android_shared_ring_mapping *responses,
    nucleus_android_gfxstream_endpoint_descriptors *output) {
    nucleus_android_shared_ring_descriptors command = {-1, -1, -1};
    nucleus_android_shared_ring_descriptors response = {-1, -1, -1};
    if (nucleus_android_shared_ring_mapping_export_descriptors(
            commands, &command) < 0 ||
        nucleus_android_shared_ring_mapping_export_descriptors(
            responses, &response) < 0) {
        nucleus_android_shared_ring_descriptors_close(command);
        nucleus_android_shared_ring_descriptors_close(response);
        return false;
    }
    *output = {
        command.memory_fd,
        command.data_notification_fd,
        command.space_notification_fd,
        response.memory_fd,
        response.data_notification_fd,
        response.space_notification_fd,
        -1,
    };
    return true;
}

class Endpoint {
  public:
    Endpoint(
        nucleus_android_gfxstream_host_renderer *renderer,
        uint64_t identifier,
        uint32_t peerPID,
        int peerDescriptor,
        int completionDescriptor)
        : identifier(identifier),
          peerPID(peerPID),
          peerDescriptor(peerDescriptor),
          completionDescriptor(completionDescriptor),
          commands(nullptr, nucleus_android_shared_ring_mapping_destroy),
          responses(nullptr, nucleus_android_shared_ring_mapping_destroy) {
        commands.reset(nucleus_android_shared_ring_mapping_create(2, 64 * 1024));
        if (!commands) {
            recordConstructionFailure("command ring creation");
            return;
        }
        responses.reset(nucleus_android_shared_ring_mapping_create(2, 64 * 1024));
        if (!responses) {
            recordConstructionFailure("response ring creation");
            return;
        }
        auto hostDescriptors = emptyDescriptors();
        if (!exportDescriptors(
                commands.get(), responses.get(), &hostDescriptors)) {
            recordConstructionFailure("host ring descriptor export");
            return;
        }
        if (!exportDescriptors(
                commands.get(), responses.get(), &guestDescriptors)) {
            recordConstructionFailure("guest ring descriptor export");
            closeDescriptors(hostDescriptors);
            return;
        }
        connection = nucleus_android_gfxstream_host_connection_create(
            renderer, hostDescriptors, peerPID);
        if (connection == nullptr) {
            recordConstructionFailure("host render-channel creation");
            closeDescriptors(guestDescriptors);
            guestDescriptors = emptyDescriptors();
        }
    }

    ~Endpoint() {
        localStopping.store(true, std::memory_order_release);
        if (peerDescriptor >= 0) {
            shutdown(peerDescriptor, SHUT_RDWR);
        }
        if (worker.joinable()) {
            worker.join();
        }
        nucleus_android_gfxstream_host_connection_destroy(connection);
        if (peerDescriptor >= 0) {
            close(peerDescriptor);
        }
    }

    bool valid() const {
        return connection != nullptr &&
               guestDescriptors.command_memory_fd >= 0;
    }

    nucleus_android_gfxstream_endpoint_descriptors takeGuestDescriptors() {
        auto result = guestDescriptors;
        guestDescriptors = emptyDescriptors();
        return result;
    }

    void start() {
        worker = std::thread([this] { pump(); });
    }

    bool completed() const {
        return terminal.load(std::memory_order_acquire);
    }

    const char *constructionFailure() const {
        return failureStage;
    }

    int constructionErrno() const {
        return failureErrno;
    }

  private:
    void recordConstructionFailure(const char *stage) {
        failureStage = stage;
        failureErrno = errno != 0 ? errno : EIO;
    }

    void finish(const char *stage, const char *detail, int errorNumber = 0) {
        const std::string summary =
            std::string(detail)
            + "; pump_calls=" + std::to_string(pumpCalls)
            + "; progress_calls=" + std::to_string(progressCalls);
        traceEndpoint(
            stage, identifier, peerPID, summary.c_str(), errorNumber);
        terminal.store(true, std::memory_order_release);
        signalEventFd(completionDescriptor);
    }

    void pump() {
        const int command =
            nucleus_android_gfxstream_host_connection_command_notification_fd(
                connection);
        const int responseSpace =
            nucleus_android_gfxstream_host_connection_response_space_notification_fd(
                connection);
        const int renderer =
            nucleus_android_gfxstream_host_connection_renderer_notification_fd(
                connection);
        if (command < 0 || responseSpace < 0 || renderer < 0) {
            finish(
                "connection.failed",
                "missing notification descriptor",
                EBADF);
            return;
        }
        const auto pumpOnce = [&]() {
            ++pumpCalls;
            const auto result =
                nucleus_android_gfxstream_host_connection_pump(connection);
            if (result == NUCLEUS_ANDROID_GFXSTREAM_HOST_PUMP_PROGRESS) {
                ++progressCalls;
            }
            return result;
        };
        while (!stopping.load(std::memory_order_acquire) &&
               !localStopping.load(std::memory_order_acquire)) {
            auto result = pumpOnce();
            while (result == NUCLEUS_ANDROID_GFXSTREAM_HOST_PUMP_PROGRESS) {
                result = pumpOnce();
            }
            if (result == NUCLEUS_ANDROID_GFXSTREAM_HOST_PUMP_PEER_CLOSED) {
                finish("connection.closed", "shared ring closed");
                return;
            }
            if (result == NUCLEUS_ANDROID_GFXSTREAM_HOST_PUMP_ERROR ||
                result == NUCLEUS_ANDROID_GFXSTREAM_HOST_PUMP_STOPPED) {
                finish(
                    "connection.failed",
                    "host render-channel pump stopped",
                    EIO);
                return;
            }
            pollfd descriptors[] = {
                {command, POLLIN, 0},
                {responseSpace, POLLIN, 0},
                {renderer, POLLIN, 0},
                {peerDescriptor, POLLIN, 0},
            };
            int pollResult;
            do {
                pollResult = poll(descriptors, 4, 250);
            } while (pollResult < 0 && errno == EINTR &&
                     !stopping.load(std::memory_order_acquire) &&
                     !localStopping.load(std::memory_order_acquire));
            if (pollResult < 0) {
                const int savedErrno = errno;
                finish(
                    "connection.failed",
                    std::strerror(savedErrno),
                    savedErrno);
                return;
            }
            if ((descriptors[3].revents &
                 (POLLHUP | POLLRDHUP | POLLERR | POLLNVAL)) != 0) {
                finish("connection.closed", "peer process exited");
                return;
            }
            if ((descriptors[0].revents & POLLIN) != 0) {
                (void)nucleus_android_gfxstream_host_connection_drain_command_notification(
                    connection);
            }
            if ((descriptors[1].revents & POLLIN) != 0) {
                (void)nucleus_android_gfxstream_host_connection_drain_response_space_notification(
                    connection);
            }
            if ((descriptors[2].revents & POLLIN) != 0) {
                (void)nucleus_android_gfxstream_host_connection_drain_renderer_notification(
                    connection);
            }
        }
        finish("connection.closed", "broker stopping");
    }

    uint64_t identifier;
    uint32_t peerPID;
    int peerDescriptor;
    int completionDescriptor;
    const char *failureStage = "unknown endpoint construction failure";
    int failureErrno = EIO;
    RingMapping commands;
    RingMapping responses;
    nucleus_android_gfxstream_endpoint_descriptors guestDescriptors =
        emptyDescriptors();
    nucleus_android_gfxstream_host_connection *connection = nullptr;
    std::thread worker;
    std::atomic<bool> localStopping = false;
    std::atomic<bool> terminal = false;
    uint64_t pumpCalls = 0;
    uint64_t progressCalls = 0;
};

int sendResponse(
    int socket,
    int status,
    nucleus_android_gfxstream_endpoint_descriptors descriptors) {
    nucleus_android_gfxstream_socket_message response = {};
    response.magic = NUCLEUS_ANDROID_GFXSTREAM_SOCKET_MAGIC;
    response.version = NUCLEUS_ANDROID_GFXSTREAM_SOCKET_VERSION;
    response.operation = NUCLEUS_ANDROID_GFXSTREAM_OPEN_STREAM;
    response.status = status;
    const int fds[] = {
        descriptors.command_memory_fd,
        descriptors.command_data_notification_fd,
        descriptors.command_space_notification_fd,
        descriptors.response_memory_fd,
        descriptors.response_data_notification_fd,
        descriptors.response_space_notification_fd,
    };
    return nucleus_ipc_send(
        socket,
        &response,
        sizeof(response),
        status == 0 ? fds : nullptr,
        status == 0 ? NUCLEUS_ANDROID_GFXSTREAM_DESCRIPTOR_COUNT : 0);
}

using GpuBuffer = std::unique_ptr<
    nucleus_android_gpu_buffer,
    decltype(&nucleus_android_gpu_buffer_destroy)>;

struct Allocation {
    Allocation(
        nucleus_android_gfxstream_host_renderer *rendererValue,
        uint64_t identifierValue,
        uint32_t colorBufferHandleValue,
        int lifetimeDescriptorValue,
        nucleus_android_gfxstream_socket_message requestValue,
        uint64_t modifierValue,
        uint32_t strideValue,
        GpuBuffer bufferValue)
        : renderer(rendererValue),
          identifier(identifierValue),
          colorBufferHandle(colorBufferHandleValue),
          lifetimeDescriptor(lifetimeDescriptorValue),
          request(requestValue),
          modifier(modifierValue),
          stride(strideValue),
          buffer(std::move(bufferValue)) {}

    ~Allocation() {
        traceBuffer(
            "buffer.renderer-release.begin",
            identifier,
            colorBufferHandle,
            request,
            modifier,
            stride,
            0);
        int releaseStatus = 0;
        if (colorBufferHandle != 0) {
            releaseStatus = nucleus_android_gfxstream_host_release_dmabuf(
                renderer, colorBufferHandle);
        }
        traceBuffer(
            releaseStatus == 0
                ? "buffer.renderer-release.completed"
                : "buffer.renderer-release.failed",
            identifier,
            colorBufferHandle,
            request,
            modifier,
            stride,
            releaseStatus);
        if (lifetimeDescriptor >= 0) {
            close(lifetimeDescriptor);
        }
        traceBuffer(
            "buffer.storage-release.begin",
            identifier,
            colorBufferHandle,
            request,
            modifier,
            stride,
            0);
        buffer.reset();
        traceBuffer(
            "buffer.storage-released",
            identifier,
            colorBufferHandle,
            request,
            modifier,
            stride,
            0);
    }

    nucleus_android_gfxstream_host_renderer *renderer;
    uint64_t identifier;
    uint32_t colorBufferHandle;
    int lifetimeDescriptor;
    nucleus_android_gfxstream_socket_message request;
    uint64_t modifier;
    uint32_t stride;
    GpuBuffer buffer;
};

struct CpuLock {
    CpuLock(
        uint64_t identifierValue,
        uint64_t allocationIdentifierValue,
        uint32_t peerPIDValue,
        uint32_t accessValue,
        uint64_t sizeValue,
        uint32_t strideValue,
        int stagingDescriptorValue,
        int lifetimeDescriptorValue)
        : identifier(identifierValue),
          allocationIdentifier(allocationIdentifierValue),
          peerPID(peerPIDValue),
          access(accessValue),
          size(sizeValue),
          stride(strideValue),
          stagingDescriptor(stagingDescriptorValue),
          lifetimeDescriptor(lifetimeDescriptorValue) {}
    CpuLock(const CpuLock &) = delete;
    CpuLock &operator=(const CpuLock &) = delete;

    uint64_t identifier;
    uint64_t allocationIdentifier;
    uint32_t peerPID;
    uint32_t access;
    uint64_t size;
    uint32_t stride;
    int stagingDescriptor;
    int lifetimeDescriptor;

    ~CpuLock() {
        if (stagingDescriptor >= 0) {
            close(stagingDescriptor);
        }
        if (lifetimeDescriptor >= 0) {
            close(lifetimeDescriptor);
        }
    }
};

uint32_t formatBytesPerPixel(uint32_t drmFormat) {
    switch (drmFormat) {
        case DRM_FORMAT_ARGB8888:
        case DRM_FORMAT_XRGB8888:
        case DRM_FORMAT_ABGR8888:
        case DRM_FORMAT_XBGR8888:
        case DRM_FORMAT_ABGR2101010:
            return 4;
        case DRM_FORMAT_ABGR16161616F:
            return 8;
        default:
            return 0;
    }
}

int createCpuStaging(uint64_t size) {
    if (size == 0 || size > static_cast<uint64_t>(INT64_MAX)) {
        errno = EINVAL;
        return -1;
    }
    const int descriptor = static_cast<int>(syscall(
        SYS_memfd_create,
        "nucleus-gralloc-cpu",
        MFD_CLOEXEC | MFD_ALLOW_SEALING));
    if (descriptor < 0) {
        return -1;
    }
    if (ftruncate(descriptor, static_cast<off_t>(size)) < 0) {
        const int savedErrno = errno;
        close(descriptor);
        errno = savedErrno;
        return -1;
    }
    if (fcntl(
            descriptor,
            F_ADD_SEALS,
            F_SEAL_GROW | F_SEAL_SHRINK | F_SEAL_SEAL) < 0) {
        const int savedErrno = errno;
        close(descriptor);
        errno = savedErrno;
        return -1;
    }
    return descriptor;
}

bool validateCpuStaging(int descriptor, uint64_t size) {
    struct stat status = {};
    return descriptor >= 0 &&
        size > 0 &&
        size <= static_cast<uint64_t>(INT64_MAX) &&
        fstat(descriptor, &status) == 0 &&
        S_ISREG(status.st_mode) &&
        status.st_size >= 0 &&
        static_cast<uint64_t>(status.st_size) == size;
}

int sendControlResponse(
    int socket,
    const nucleus_android_gfxstream_socket_message &response,
    const int *descriptors = nullptr,
    size_t descriptorCount = 0) {
    return nucleus_ipc_send(
        socket,
        &response,
        sizeof(response),
        descriptors,
        descriptorCount);
}

}  // namespace

int main(int argc, char **argv) {
    nucleus_android_gfxstream_host_set_logger(
        gfxstreamLog,
        std::getenv("VK_INSTANCE_LAYERS")
            ? NUCLEUS_ANDROID_GFXSTREAM_LOG_INFO
            : NUCLEUS_ANDROID_GFXSTREAM_LOG_WARNING);
    const char *socketPath = nullptr;
    const char *renderNode = nullptr;
    uint32_t uidRangeStart = 0;
    uint32_t uidRangeCount = 0;
    uint32_t parentPID = 0;
    for (int index = 1; index < argc; ++index) {
        const std::string_view argument(argv[index]);
        if (argument == "--socket" && ++index < argc) {
            socketPath = argv[index];
        } else if (argument == "--uid-range-start" && ++index < argc) {
            if (!parseUInt32(argv[index], &uidRangeStart)) {
                uidRangeStart = 0;
            }
        } else if (argument == "--uid-range-count" && ++index < argc) {
            if (!parseUInt32(argv[index], &uidRangeCount)) {
                uidRangeCount = 0;
            }
        } else if (argument == "--parent-pid" && ++index < argc) {
            if (!parseUInt32(argv[index], &parentPID)) {
                parentPID = 0;
            }
        } else if (argument == "--render-node" && ++index < argc) {
            renderNode = argv[index];
        } else {
            trace("invocation.invalid-argument", argv[index]);
            return 2;
        }
    }
    const uint64_t uidRangeEnd =
        static_cast<uint64_t>(uidRangeStart) + uidRangeCount;
    if (socketPath == nullptr || uidRangeStart == 0 || uidRangeCount == 0 ||
        uidRangeEnd > static_cast<uint64_t>(UINT32_MAX) + 1 ||
        parentPID == 0 ||
        nucleus_android_require_parent_lifetime(SIGTERM, parentPID) < 0) {
        trace("invocation.invalid");
        return 2;
    }
    signal(SIGTERM, stop);
    signal(SIGINT, stop);
    if (addressSanitizerEnabled()) {
        const char *scope =
            std::getenv("NUCLEUS_ADDRESS_SANITIZER_SCOPE");
        trace(
            "address-sanitizer.enabled",
            scope != nullptr ? scope : "broker");
        if (!restoreCoreFileLimit()) {
            trace("core-dump.limit-failed", std::strerror(errno));
            return 1;
        }
        trace("core-dump.enabled", "systemd-coredump");
    } else if (!installFatalSignalDiagnostics()) {
        trace("fatal-signal.install-failed", std::strerror(errno));
        return 1;
    }
    if (!raiseFileDescriptorLimit()) {
        trace("file-descriptor-limit.failed", std::strerror(errno));
        return 1;
    }

    const std::string selectedRenderNode = selectRenderNode(renderNode);
    if (selectedRenderNode.empty()) {
        trace("gpu.selection-failed", std::strerror(errno));
        return 1;
    }
    char error[512] = {};
    std::unique_ptr<nucleus_android_gpu, decltype(&nucleus_android_gpu_destroy)>
        gpu(
            nucleus_android_gpu_create(
                selectedRenderNode.c_str(), error, sizeof(error)),
            nucleus_android_gpu_destroy);
    nucleus_android_gpu_diagnostic diagnostic = {};
    if (!gpu ||
        nucleus_android_gpu_get_diagnostic(gpu.get(), &diagnostic) < 0) {
        trace("gpu.discovery-failed", error);
        return 1;
    }
    std::unique_ptr<
        nucleus_android_gfxstream_host_renderer,
        decltype(&nucleus_android_gfxstream_host_renderer_destroy)>
        renderer(
            nucleus_android_gfxstream_host_renderer_create(
                1, 1, diagnostic.device_uuid, error, sizeof(error)),
            nucleus_android_gfxstream_host_renderer_destroy);
    if (!renderer) {
        trace("gfxstream.renderer-failed", error);
        return 1;
    }
    const int listener = nucleus_ipc_listen(socketPath, 0666);
    if (listener < 0) {
        trace("listener.failed", std::strerror(errno));
        return 1;
    }
    listenerDescriptor.store(listener, std::memory_order_release);
    const int endpointCompletionDescriptor =
        eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    if (endpointCompletionDescriptor < 0) {
        trace("endpoint-completion.failed", std::strerror(errno));
        close(listener);
        return 1;
    }
    trace("ready", selectedRenderNode);

    std::vector<std::unique_ptr<Endpoint>> endpoints;
    std::unordered_map<uint64_t, std::unique_ptr<Allocation>> allocations;
    std::unordered_map<uint64_t, std::unique_ptr<CpuLock>> cpuLocks;
    VulkanFenceCompletions fenceCompletions;
    uint64_t nextEndpointIdentifier = 1;
    uint32_t nextColorBufferHandle = UINT32_C(0x40000000);
    uint64_t nextAllocationIdentifier = 1;
    uint64_t nextCpuLockIdentifier = 1;
    while (!stopping.load(std::memory_order_acquire)) {
        std::vector<pollfd> pollDescriptors;
        std::vector<uint64_t> pollAllocations;
        std::vector<uint64_t> pollCpuLocks;
        pollDescriptors.push_back({listener, POLLIN, 0});
        pollAllocations.push_back(0);
        pollCpuLocks.push_back(0);
        pollDescriptors.push_back(
            {endpointCompletionDescriptor, POLLIN, 0});
        pollAllocations.push_back(0);
        pollCpuLocks.push_back(0);
        for (const auto &[identifier, allocation] : allocations) {
            pollDescriptors.push_back(
                {allocation->lifetimeDescriptor, POLLIN, 0});
            pollAllocations.push_back(identifier);
            pollCpuLocks.push_back(0);
        }
        for (const auto &[identifier, cpuLock] : cpuLocks) {
            pollDescriptors.push_back(
                {cpuLock->lifetimeDescriptor, POLLIN, 0});
            pollAllocations.push_back(0);
            pollCpuLocks.push_back(identifier);
        }
        int pollResult;
        do {
            pollResult = poll(
                pollDescriptors.data(), pollDescriptors.size(), -1);
        } while (pollResult < 0 && errno == EINTR &&
                 !stopping.load(std::memory_order_acquire));
        if (pollResult < 0) {
            if (stopping.load(std::memory_order_acquire)) {
                break;
            }
            trace("poll.failed", std::strerror(errno));
            return 1;
        }
        if ((pollDescriptors[1].revents & POLLIN) != 0) {
            drainEventFd(endpointCompletionDescriptor);
            for (auto endpoint = endpoints.begin();
                 endpoint != endpoints.end();) {
                if ((*endpoint)->completed()) {
                    endpoint = endpoints.erase(endpoint);
                } else {
                    ++endpoint;
                }
            }
        }
        for (size_t index = 2; index < pollDescriptors.size(); ++index) {
            if ((pollDescriptors[index].revents &
                 (POLLHUP | POLLERR | POLLNVAL)) != 0) {
                const auto found =
                    allocations.find(pollAllocations[index]);
                if (found != allocations.end()) {
                    traceBuffer(
                        "buffer.released",
                        found->second->identifier,
                        found->second->colorBufferHandle,
                        found->second->request,
                        found->second->modifier,
                        found->second->stride,
                        0);
                    for (auto lock = cpuLocks.begin();
                         lock != cpuLocks.end();) {
                        if (lock->second->allocationIdentifier ==
                            found->first) {
                            statistics.cpuLocksClosed.fetch_add(
                                1, std::memory_order_relaxed);
                            lock = cpuLocks.erase(lock);
                        } else {
                            ++lock;
                        }
                    }
                    allocations.erase(found);
                }
                const auto foundCpuLock =
                    cpuLocks.find(pollCpuLocks[index]);
                if (foundCpuLock != cpuLocks.end()) {
                    statistics.cpuLocksClosed.fetch_add(
                        1, std::memory_order_relaxed);
                    cpuLocks.erase(foundCpuLock);
                }
            }
        }
        if ((pollDescriptors.front().revents & POLLIN) == 0) {
            continue;
        }
        const int peer = nucleus_ipc_accept(listener);
        if (peer < 0) {
            if (stopping.load(std::memory_order_acquire)) {
                break;
            }
            if (errno == EINTR) {
                continue;
            }
            trace("accept.failed", std::strerror(errno));
            return 1;
        }
        struct nucleus_ipc_peer_credentials credentials = {};
        nucleus_android_gfxstream_socket_message request = {};
        size_t receivedDescriptors = 0;
        const int received = nucleus_ipc_receive(
            peer,
            &request,
            sizeof(request),
            nullptr,
            0,
            &receivedDescriptors);
        const int credentialsResult =
            nucleus_ipc_peer_credentials(peer, &credentials);
        const bool peerUIDAuthorized =
            credentialsResult == 0 &&
            credentials.pid > 0 &&
            static_cast<uint64_t>(credentials.uid) >= uidRangeStart &&
            static_cast<uint64_t>(credentials.uid) < uidRangeEnd;
        if (!peerUIDAuthorized ||
            received != static_cast<int>(sizeof(request)) ||
            receivedDescriptors != 0 ||
            request.magic != NUCLEUS_ANDROID_GFXSTREAM_SOCKET_MAGIC ||
            request.version != NUCLEUS_ANDROID_GFXSTREAM_SOCKET_VERSION ||
            request.operation < NUCLEUS_ANDROID_GFXSTREAM_OPEN_STREAM ||
            request.operation >
                NUCLEUS_ANDROID_GFXSTREAM_SYNC_BUFFER) {
            (void)sendResponse(peer, -EPERM, emptyDescriptors());
            close(peer);
            trace("peer.rejected", std::to_string(credentials.uid));
            continue;
        }
        if (request.operation ==
            NUCLEUS_ANDROID_GFXSTREAM_LOCK_BUFFER) {
            nucleus_android_gfxstream_socket_message response = {};
            response.magic = NUCLEUS_ANDROID_GFXSTREAM_SOCKET_MAGIC;
            response.version = NUCLEUS_ANDROID_GFXSTREAM_SOCKET_VERSION;
            response.operation = request.operation;
            response.allocation_id = request.allocation_id;
            response.cpu_access = request.cpu_access;
            response.status = -EINVAL;
            int stagingDescriptor = -1;
            int lifetimeDescriptors[2] = {-1, -1};
            auto allocation = allocations.find(request.allocation_id);
            bool alreadyLocked = false;
            for (const auto &[unused, lock] : cpuLocks) {
                if (lock->allocationIdentifier == request.allocation_id) {
                    alreadyLocked = true;
                    break;
                }
            }
            const uint32_t validAccess =
                NUCLEUS_ANDROID_GFXSTREAM_CPU_ACCESS_READ |
                NUCLEUS_ANDROID_GFXSTREAM_CPU_ACCESS_WRITE;
            if (allocation == allocations.end() ||
                request.cpu_access == 0 ||
                (request.cpu_access & ~validAccess) != 0) {
                response.status = -EINVAL;
            } else if (alreadyLocked) {
                response.status = -EBUSY;
            } else {
                const auto &buffer = *allocation->second;
                const uint32_t bytesPerPixel =
                    formatBytesPerPixel(buffer.request.drm_format);
                const uint64_t stride =
                    static_cast<uint64_t>(buffer.request.width) *
                    bytesPerPixel;
                const uint64_t size =
                    stride * buffer.request.height;
                if (bytesPerPixel == 0 ||
                    stride > UINT32_MAX ||
                    (buffer.request.height != 0 &&
                     size / buffer.request.height != stride) ||
                    size > SIZE_MAX) {
                    response.status = -EOVERFLOW;
                } else {
                    stagingDescriptor = createCpuStaging(size);
                    void *pixels = stagingDescriptor >= 0
                        ? mmap(
                            nullptr,
                            static_cast<size_t>(size),
                            PROT_READ | PROT_WRITE,
                            MAP_SHARED,
                            stagingDescriptor,
                            0)
                        : MAP_FAILED;
                    if (stagingDescriptor < 0 || pixels == MAP_FAILED) {
                        response.status = -errno;
                    } else {
                        const auto readbackBegan = MonotonicClock::now();
                        response.status =
                            nucleus_android_gfxstream_host_read_color_buffer(
                                renderer.get(),
                                buffer.colorBufferHandle,
                                buffer.request.drm_format,
                                buffer.request.width,
                                buffer.request.height,
                                pixels,
                                size);
                        const uint64_t duration =
                            elapsedMicroseconds(readbackBegan);
                        if (response.status == 0) {
                            statistics.cpuReadbacks.fetch_add(
                                1, std::memory_order_relaxed);
                            recordMaximum(
                                statistics.cpuReadbackMaxMicroseconds,
                                duration);
                        }
                        traceCpuTransfer(
                            "cpu-readback.completed",
                            request.allocation_id,
                            0,
                            static_cast<uint32_t>(credentials.pid),
                            request.cpu_access,
                            size,
                            response.status,
                            duration,
                            response.status == 0 &&
                                !statistics.loggedFirstCpuReadback
                                    .test_and_set(
                                        std::memory_order_relaxed));
                        munmap(pixels, static_cast<size_t>(size));
                    }
                    if (response.status == 0 &&
                        socketpair(
                            AF_UNIX,
                            SOCK_SEQPACKET | SOCK_CLOEXEC,
                            0,
                            lifetimeDescriptors) < 0) {
                        response.status = -errno;
                    }
                    if (response.status == 0) {
                        response.cpu_lock_id =
                            nextCpuLockIdentifier++;
                        response.cpu_mapping_size = size;
                        response.cpu_stride =
                            static_cast<uint32_t>(stride);
                    }
                }
            }
            const int descriptors[2] = {
                stagingDescriptor,
                lifetimeDescriptors[1],
            };
            const int result = response.status == 0
                ? sendControlResponse(peer, response, descriptors, 2)
                : sendControlResponse(peer, response);
            const int sendErrno = errno;
            if (result == 0 && response.status == 0) {
                cpuLocks.emplace(
                    response.cpu_lock_id,
                    std::make_unique<CpuLock>(
                        response.cpu_lock_id,
                        request.allocation_id,
                        static_cast<uint32_t>(credentials.pid),
                        request.cpu_access,
                        response.cpu_mapping_size,
                        response.cpu_stride,
                        stagingDescriptor,
                        lifetimeDescriptors[0]));
                statistics.cpuLocksOpened.fetch_add(
                    1, std::memory_order_relaxed);
                traceCpuTransfer(
                    "cpu-lock.opened",
                    request.allocation_id,
                    response.cpu_lock_id,
                    static_cast<uint32_t>(credentials.pid),
                    request.cpu_access,
                    response.cpu_mapping_size,
                    0,
                    0,
                    !statistics.loggedFirstCpuLock.test_and_set(
                        std::memory_order_relaxed));
                stagingDescriptor = -1;
                lifetimeDescriptors[0] = -1;
            } else if (response.status == 0) {
                response.status = -sendErrno;
            }
            if (stagingDescriptor >= 0) {
                close(stagingDescriptor);
            }
            if (lifetimeDescriptors[0] >= 0) {
                close(lifetimeDescriptors[0]);
            }
            if (lifetimeDescriptors[1] >= 0) {
                close(lifetimeDescriptors[1]);
            }
            close(peer);
            if (response.status != 0) {
                traceCpuTransfer(
                    "cpu-lock.failed",
                    request.allocation_id,
                    response.cpu_lock_id,
                    static_cast<uint32_t>(credentials.pid),
                    request.cpu_access,
                    response.cpu_mapping_size,
                    response.status);
            }
            continue;
        }
        if (request.operation ==
                NUCLEUS_ANDROID_GFXSTREAM_UNLOCK_BUFFER ||
            request.operation ==
                NUCLEUS_ANDROID_GFXSTREAM_SYNC_BUFFER) {
            nucleus_android_gfxstream_socket_message response = {};
            response.magic = NUCLEUS_ANDROID_GFXSTREAM_SOCKET_MAGIC;
            response.version = NUCLEUS_ANDROID_GFXSTREAM_SOCKET_VERSION;
            response.operation = request.operation;
            response.allocation_id = request.allocation_id;
            response.cpu_lock_id = request.cpu_lock_id;
            response.status = -EINVAL;
            const auto lock = cpuLocks.find(request.cpu_lock_id);
            const auto allocation = allocations.find(request.allocation_id);
            const bool unlock =
                request.operation ==
                NUCLEUS_ANDROID_GFXSTREAM_UNLOCK_BUFFER;
            const bool lockValid =
                lock != cpuLocks.end() &&
                allocation != allocations.end() &&
                lock->second->allocationIdentifier ==
                    request.allocation_id &&
                lock->second->peerPID ==
                    static_cast<uint32_t>(credentials.pid) &&
                lock->second->size == request.cpu_mapping_size &&
                validateCpuStaging(
                    lock->second->stagingDescriptor,
                    request.cpu_mapping_size);
            if (!lockValid) {
                response.status = -EINVAL;
            } else {
                const uint32_t access = unlock
                    ? lock->second->access
                    : request.cpu_access;
                const bool accessValid = unlock ||
                    ((access ==
                         NUCLEUS_ANDROID_GFXSTREAM_CPU_ACCESS_READ ||
                      access ==
                         NUCLEUS_ANDROID_GFXSTREAM_CPU_ACCESS_WRITE) &&
                     (lock->second->access & access) != 0);
                if (!accessValid) {
                    response.status = -EINVAL;
                } else {
                    void *pixels = mmap(
                        nullptr,
                        static_cast<size_t>(lock->second->size),
                        PROT_READ | PROT_WRITE,
                        MAP_SHARED,
                        lock->second->stagingDescriptor,
                        0);
                    if (pixels == MAP_FAILED) {
                        response.status = -errno;
                    } else {
                        const auto &buffer = *allocation->second;
                        if (!unlock &&
                            access ==
                            NUCLEUS_ANDROID_GFXSTREAM_CPU_ACCESS_READ) {
                            const auto readbackBegan =
                                MonotonicClock::now();
                            response.status =
                                nucleus_android_gfxstream_host_read_color_buffer(
                                    renderer.get(),
                                    buffer.colorBufferHandle,
                                    buffer.request.drm_format,
                                    buffer.request.width,
                                    buffer.request.height,
                                    pixels,
                                    lock->second->size);
                            const uint64_t duration =
                                elapsedMicroseconds(readbackBegan);
                            if (response.status == 0) {
                                statistics.cpuReadbacks.fetch_add(
                                    1, std::memory_order_relaxed);
                                recordMaximum(
                                    statistics.cpuReadbackMaxMicroseconds,
                                    duration);
                            }
                            traceCpuTransfer(
                                "cpu-readback.completed",
                                request.allocation_id,
                                request.cpu_lock_id,
                                static_cast<uint32_t>(credentials.pid),
                                access,
                                lock->second->size,
                                response.status,
                                duration,
                                response.status == 0 &&
                                    !statistics.loggedFirstCpuReadback
                                        .test_and_set(
                                            std::memory_order_relaxed));
                        } else if (
                            (access &
                             NUCLEUS_ANDROID_GFXSTREAM_CPU_ACCESS_WRITE) != 0) {
                            const auto uploadBegan =
                                MonotonicClock::now();
                            response.status =
                                nucleus_android_gfxstream_host_update_color_buffer(
                                    renderer.get(),
                                    buffer.colorBufferHandle,
                                    buffer.request.drm_format,
                                    buffer.request.width,
                                    buffer.request.height,
                                    pixels,
                                    lock->second->size);
                            const uint64_t duration =
                                elapsedMicroseconds(uploadBegan);
                            if (response.status == 0) {
                                statistics.cpuUploads.fetch_add(
                                    1, std::memory_order_relaxed);
                                recordMaximum(
                                    statistics.cpuUploadMaxMicroseconds,
                                    duration);
                            }
                            traceCpuTransfer(
                                "cpu-upload.completed",
                                request.allocation_id,
                                request.cpu_lock_id,
                                static_cast<uint32_t>(credentials.pid),
                                access,
                                lock->second->size,
                                response.status,
                                duration,
                                response.status == 0 &&
                                    !statistics.loggedFirstCpuUpload
                                        .test_and_set(
                                            std::memory_order_relaxed));
                        } else {
                            response.status = 0;
                        }
                        munmap(
                            pixels,
                            static_cast<size_t>(lock->second->size));
                    }
                }
            }
            if (unlock && lockValid) {
                statistics.cpuLocksClosed.fetch_add(
                    1, std::memory_order_relaxed);
                cpuLocks.erase(lock);
            }
            if (!unlock && response.status == 0) {
                statistics.cpuSyncs.fetch_add(
                    1, std::memory_order_relaxed);
            }
            (void)sendControlResponse(peer, response);
            close(peer);
            if (response.status != 0) {
                traceCpuTransfer(
                    unlock ? "cpu-unlock.failed" : "cpu-sync.failed",
                    request.allocation_id,
                    request.cpu_lock_id,
                    static_cast<uint32_t>(credentials.pid),
                    request.cpu_access,
                    request.cpu_mapping_size,
                    response.status);
            }
            continue;
        }
        if (request.operation ==
            NUCLEUS_ANDROID_GFXSTREAM_EXPORT_VULKAN_QSRI) {
            const auto operationBegan = MonotonicClock::now();
            nucleus_android_gfxstream_socket_message response = {};
            response.magic = NUCLEUS_ANDROID_GFXSTREAM_SOCKET_MAGIC;
            response.version = NUCLEUS_ANDROID_GFXSTREAM_SOCKET_VERSION;
            response.operation = request.operation;
            response.vulkan_image_handle = request.vulkan_image_handle;
            int descriptor = -1;
            nucleus_android_native_fence *nativeFence = nullptr;
            VulkanQsriCompletion *completion = nullptr;
            char nativeFenceError[512] = {};
            if (request.vulkan_image_handle == 0) {
                response.status = -EINVAL;
            } else {
                nativeFence = nucleus_android_native_fence_create(
                    gpu.get(),
                    &descriptor,
                    nativeFenceError,
                    sizeof(nativeFenceError));
                const int nativeFenceErrno = errno;
                if (nativeFence && descriptor >= 0) {
                    completion = new (std::nothrow) VulkanQsriCompletion{
                        &fenceCompletions,
                        nativeFence,
                        request.vulkan_image_handle,
                        static_cast<uint32_t>(credentials.pid),
                        operationBegan,
                    };
                }
                if (!nativeFence || descriptor < 0) {
                    response.status = -(
                        nativeFenceErrno != 0 ? nativeFenceErrno : EIO);
                    trace(
                        "vulkan-qsri.materialize.failed",
                        nativeFenceError);
                } else if (!completion) {
                    response.status = -ENOMEM;
                } else {
                    fenceCompletions.begin();
                    response.status =
                        nucleus_android_gfxstream_host_wait_vulkan_qsri(
                            renderer.get(),
                            request.vulkan_image_handle,
                            completeVulkanQsri,
                            completion);
                    if (response.status != 0) {
                        fenceCompletions.complete();
                    }
                }
            }
            if (response.status != 0) {
                delete completion;
                if (nativeFence) {
                    nucleus_android_native_fence_destroy(nativeFence);
                }
            }
            const int result =
                descriptor >= 0 && response.status == 0
                ? sendControlResponse(peer, response, &descriptor, 1)
                : sendControlResponse(peer, response);
            const int sendErrno = errno;
            if (descriptor >= 0) close(descriptor);
            close(peer);
            traceVulkanQsri(
                result == 0 && response.status == 0
                    ? "vulkan-qsri.exported"
                    : "vulkan-qsri.export.failed",
                request.vulkan_image_handle,
                static_cast<uint32_t>(credentials.pid),
                response.status != 0
                    ? response.status
                    : (result == 0 ? 0 : -sendErrno),
                elapsedMicroseconds(operationBegan));
            continue;
        }
        if (request.operation ==
            NUCLEUS_ANDROID_GFXSTREAM_EXPORT_VULKAN_SEMAPHORE) {
            const auto operationBegan = MonotonicClock::now();
            nucleus_android_gfxstream_socket_message response = {};
            response.magic = NUCLEUS_ANDROID_GFXSTREAM_SOCKET_MAGIC;
            response.version = NUCLEUS_ANDROID_GFXSTREAM_SOCKET_VERSION;
            response.operation = request.operation;
            response.vulkan_device_handle =
                request.vulkan_device_handle;
            response.vulkan_semaphore_handle =
                request.vulkan_semaphore_handle;
            int descriptor = -1;
            if (request.vulkan_device_handle == 0 ||
                request.vulkan_semaphore_handle == 0) {
                response.status = -EINVAL;
            } else {
                descriptor =
                    nucleus_android_gfxstream_host_export_vulkan_semaphore(
                        renderer.get(),
                        request.vulkan_device_handle,
                        request.vulkan_semaphore_handle);
                response.status = descriptor < 0 ? descriptor : 0;
            }
            const int result =
                descriptor >= 0 && response.status == 0
                ? sendControlResponse(peer, response, &descriptor, 1)
                : sendControlResponse(peer, response);
            const int sendErrno = errno;
            if (descriptor >= 0) close(descriptor);
            close(peer);
            traceVulkanSemaphore(
                result == 0 && response.status == 0
                    ? "vulkan-semaphore.exported"
                    : "vulkan-semaphore.export.failed",
                request.vulkan_device_handle,
                request.vulkan_semaphore_handle,
                static_cast<uint32_t>(credentials.pid),
                response.status != 0
                    ? response.status
                    : (result == 0 ? 0 : -sendErrno),
                elapsedMicroseconds(operationBegan));
            continue;
        }
        if (request.operation ==
            NUCLEUS_ANDROID_GFXSTREAM_EXPORT_VULKAN_FENCE) {
            const auto operationBegan = MonotonicClock::now();
            nucleus_android_gfxstream_socket_message response = {};
            response.magic = NUCLEUS_ANDROID_GFXSTREAM_SOCKET_MAGIC;
            response.version = NUCLEUS_ANDROID_GFXSTREAM_SOCKET_VERSION;
            response.operation = request.operation;
            response.vulkan_device_handle =
                request.vulkan_device_handle;
            response.vulkan_fence_handle =
                request.vulkan_fence_handle;
            int descriptor = -1;
            nucleus_android_native_fence *nativeFence = nullptr;
            VulkanFenceCompletion *completion = nullptr;
            char nativeFenceError[512] = {};
            if (request.vulkan_device_handle == 0 ||
                request.vulkan_fence_handle == 0) {
                response.status = -EINVAL;
            } else {
                nativeFence = nucleus_android_native_fence_create(
                    gpu.get(),
                    &descriptor,
                    nativeFenceError,
                    sizeof(nativeFenceError));
                const int nativeFenceErrno = errno;
                if (nativeFence && descriptor >= 0) {
                    completion = new (std::nothrow) VulkanFenceCompletion{
                        &fenceCompletions,
                        nativeFence,
                        request.vulkan_device_handle,
                        request.vulkan_fence_handle,
                        static_cast<uint32_t>(credentials.pid),
                        operationBegan,
                    };
                }
                if (!nativeFence || descriptor < 0) {
                    response.status = -(
                        nativeFenceErrno != 0 ? nativeFenceErrno : EIO);
                    trace(
                        "vulkan-fence.materialize.failed",
                        nativeFenceError);
                } else if (!completion) {
                    response.status = -ENOMEM;
                } else {
                    fenceCompletions.begin();
                    response.status =
                        nucleus_android_gfxstream_host_wait_vulkan_fence(
                            renderer.get(),
                            request.vulkan_device_handle,
                            request.vulkan_fence_handle,
                            completeVulkanFence,
                            completion);
                    if (response.status != 0) {
                        fenceCompletions.complete();
                    }
                }
            }
            if (response.status != 0) {
                delete completion;
                if (nativeFence) {
                    nucleus_android_native_fence_destroy(nativeFence);
                }
            }
            const int result =
                descriptor >= 0 && response.status == 0
                ? sendControlResponse(peer, response, &descriptor, 1)
                : sendControlResponse(peer, response);
            const int sendErrno = errno;
            if (descriptor >= 0) close(descriptor);
            close(peer);
            traceVulkanFence(
                result == 0 && response.status == 0
                    ? "vulkan-fence.exported"
                    : "vulkan-fence.export.failed",
                request.vulkan_device_handle,
                request.vulkan_fence_handle,
                static_cast<uint32_t>(credentials.pid),
                response.status != 0
                    ? response.status
                    : (result == 0 ? 0 : -sendErrno),
                elapsedMicroseconds(operationBegan));
            continue;
        }
        if (request.operation ==
            NUCLEUS_ANDROID_GFXSTREAM_MAP_HOST_MEMORY) {
            nucleus_android_gfxstream_socket_message response = {};
            response.magic = NUCLEUS_ANDROID_GFXSTREAM_SOCKET_MAGIC;
            response.version = NUCLEUS_ANDROID_GFXSTREAM_SOCKET_VERSION;
            response.operation = request.operation;
            response.allocation_id = request.allocation_id;
            response.allocation_size = request.allocation_size;
            int descriptor = -1;
            if (request.allocation_id == 0 ||
                request.allocation_size == 0) {
                response.status = -EINVAL;
            } else {
                descriptor = nucleus_android_gfxstream_host_export_memory(
                    renderer.get(),
                    static_cast<uint32_t>(credentials.pid),
                    request.allocation_id);
                response.status = descriptor < 0 ? descriptor : 0;
            }
            if (descriptor >= 0) {
                struct stat status = {};
                if (fstat(descriptor, &status) < 0 ||
                    status.st_size < 0 ||
                    static_cast<uint64_t>(status.st_size) <
                        request.allocation_size) {
                    response.status = -EPROTO;
                }
            }
            const int result = descriptor >= 0 && response.status == 0
                ? sendControlResponse(peer, response, &descriptor, 1)
                : sendControlResponse(peer, response);
            const int sendErrno = errno;
            if (descriptor >= 0) close(descriptor);
            close(peer);
            traceHostMemory(
                result == 0 && response.status == 0
                    ? "host-memory.exported"
                    : "host-memory.export.failed",
                request.allocation_id,
                static_cast<uint32_t>(credentials.pid),
                request.allocation_size,
                response.status != 0
                    ? response.status
                    : (result == 0 ? 0 : -sendErrno));
            continue;
        }
        if (request.operation == NUCLEUS_ANDROID_GFXSTREAM_ALLOCATE_BUFFER) {
            nucleus_android_gfxstream_socket_message response = {};
            response.magic = NUCLEUS_ANDROID_GFXSTREAM_SOCKET_MAGIC;
            response.version = NUCLEUS_ANDROID_GFXSTREAM_SOCKET_VERSION;
            response.operation = request.operation;
            response.status = -EINVAL;
            traceBuffer(
                "buffer.allocate.requested",
                0,
                0,
                request,
                0,
                0,
                0);
            if (request.width == 0 || request.height == 0 ||
                request.drm_format == 0) {
                (void)sendControlResponse(peer, response);
                close(peer);
                continue;
            }
            uint64_t modifier = 0;
            if (nucleus_android_gpu_preferred_modifier(
                    gpu.get(), request.drm_format, &modifier) < 0) {
                response.status = -ENOTSUP;
                (void)sendControlResponse(peer, response);
                close(peer);
                traceBuffer(
                    "buffer.allocate.failed",
                    0,
                    0,
                    request,
                    0,
                    0,
                    response.status);
                continue;
            }
            char allocationError[512] = {};
            GpuBuffer buffer(
                nucleus_android_gpu_buffer_create(
                    gpu.get(),
                    request.width,
                    request.height,
                    request.drm_format,
                    modifier,
                    0,
                    allocationError,
                    sizeof(allocationError)),
                nucleus_android_gpu_buffer_destroy);
            nucleus_android_dmabuf_plane plane = {};
            if (!buffer ||
                nucleus_android_gpu_buffer_plane_count(buffer.get()) != 1) {
                response.status = -ENOMEM;
                (void)sendControlResponse(peer, response);
                close(peer);
                traceBuffer(
                    "buffer.allocate.failed",
                    0,
                    0,
                    request,
                    modifier,
                    0,
                    response.status);
                trace("buffer.allocate.failed", allocationError);
                continue;
            }
            traceBuffer(
                "buffer.storage.created",
                0,
                0,
                request,
                modifier,
                plane.stride,
                0);
            const int rendererDescriptor =
                nucleus_android_gpu_buffer_export_plane(
                    buffer.get(), 0, &plane);
            const uint32_t colorBufferHandle = nextColorBufferHandle++;
            const nucleus_android_gfxstream_host_dmabuf dmabuf = {
                .color_buffer_handle = colorBufferHandle,
                .width = request.width,
                .height = request.height,
                .drm_format = request.drm_format,
                .drm_modifier = modifier,
                .plane_offset = plane.offset,
                .plane_stride = plane.stride,
                .dmabuf_fd = rendererDescriptor,
                .sync_context = nullptr,
                .export_release_sync_file = nullptr,
                .import_acquire_sync_file = nullptr,
            };
            traceBuffer(
                "buffer.renderer-import.begin",
                0,
                colorBufferHandle,
                request,
                modifier,
                plane.stride,
                rendererDescriptor < 0 ? rendererDescriptor : 0);
            if (rendererDescriptor < 0 ||
                nucleus_android_gfxstream_host_import_dmabuf(
                    renderer.get(), &dmabuf) < 0) {
                if (rendererDescriptor >= 0) {
                    close(rendererDescriptor);
                }
                response.status = -EIO;
                (void)sendControlResponse(peer, response);
                close(peer);
                traceBuffer(
                    "buffer.import.failed",
                    0,
                    colorBufferHandle,
                    request,
                    modifier,
                    plane.stride,
                    response.status);
                continue;
            }
            traceBuffer(
                "buffer.renderer-import.completed",
                0,
                colorBufferHandle,
                request,
                modifier,
                plane.stride,
                0);
            const int guestDescriptor =
                nucleus_android_gpu_buffer_export_plane(
                    buffer.get(), 0, &plane);
            if (guestDescriptor < 0) {
                (void)nucleus_android_gfxstream_host_release_dmabuf(
                    renderer.get(), colorBufferHandle);
                response.status = -EIO;
                (void)sendControlResponse(peer, response);
                close(peer);
                traceBuffer(
                    "buffer.allocate.failed",
                    0,
                    colorBufferHandle,
                    request,
                    modifier,
                    plane.stride,
                    response.status);
                continue;
            }
            traceBuffer(
                "buffer.guest-export.completed",
                0,
                colorBufferHandle,
                request,
                modifier,
                plane.stride,
                0);
            int lifetimeDescriptors[2] = {-1, -1};
            if (socketpair(
                    AF_UNIX,
                    SOCK_SEQPACKET | SOCK_CLOEXEC,
                    0,
                    lifetimeDescriptors) < 0) {
                const int savedErrno = errno;
                close(guestDescriptor);
                (void)nucleus_android_gfxstream_host_release_dmabuf(
                    renderer.get(), colorBufferHandle);
                response.status = -savedErrno;
                (void)sendControlResponse(peer, response);
                close(peer);
                traceBuffer(
                    "buffer.allocate.failed",
                    0,
                    colorBufferHandle,
                    request,
                    modifier,
                    plane.stride,
                    response.status);
                continue;
            }
            const uint64_t identifier = nextAllocationIdentifier++;
            traceBuffer(
                "buffer.lifetime.created",
                identifier,
                colorBufferHandle,
                request,
                modifier,
                plane.stride,
                0);
            response.status = 0;
            response.allocation_id = identifier;
            response.usage = request.usage;
            response.drm_modifier = modifier;
            response.allocation_size =
                nucleus_android_gpu_buffer_allocation_size(buffer.get());
            response.width = request.width;
            response.height = request.height;
            response.android_format = request.android_format;
            response.drm_format = request.drm_format;
            response.plane_offset = plane.offset;
            response.plane_stride = plane.stride;
            response.color_buffer_handle = colorBufferHandle;
            traceBuffer(
                "buffer.ownership.publish.begin",
                identifier,
                colorBufferHandle,
                request,
                modifier,
                plane.stride,
                0);
            allocations.emplace(
                identifier,
                std::make_unique<Allocation>(
                    renderer.get(),
                    identifier,
                    colorBufferHandle,
                    lifetimeDescriptors[0],
                    request,
                    modifier,
                    plane.stride,
                    std::move(buffer)));
            traceBuffer(
                "buffer.ownership.published",
                identifier,
                colorBufferHandle,
                request,
                modifier,
                plane.stride,
                0);
            const int responseDescriptors[] = {
                guestDescriptor,
                lifetimeDescriptors[1],
            };
            traceBuffer(
                "buffer.response.begin",
                identifier,
                colorBufferHandle,
                request,
                modifier,
                plane.stride,
                0);
            const int result = sendControlResponse(
                peer, response, responseDescriptors, 2);
            const int responseErrno = errno;
            traceBuffer(
                result == 0
                    ? "buffer.response.completed"
                    : "buffer.response.failed",
                identifier,
                colorBufferHandle,
                request,
                modifier,
                plane.stride,
                result == 0 ? 0 : -responseErrno);
            close(guestDescriptor);
            close(lifetimeDescriptors[1]);
            close(peer);
            if (result < 0) {
                allocations.erase(identifier);
                traceBuffer(
                    "buffer.allocate.failed",
                    identifier,
                    colorBufferHandle,
                    request,
                    modifier,
                    plane.stride,
                    -responseErrno);
            } else {
                traceBuffer(
                    "buffer.allocated",
                    identifier,
                    colorBufferHandle,
                    request,
                    modifier,
                    plane.stride,
                    0);
            }
            continue;
        }
        const uint64_t endpointIdentifier = nextEndpointIdentifier++;
        auto endpoint = std::make_unique<Endpoint>(
            renderer.get(),
            endpointIdentifier,
            static_cast<uint32_t>(credentials.pid),
            peer,
            endpointCompletionDescriptor);
        if (!endpoint->valid()) {
            (void)sendResponse(peer, -EIO, emptyDescriptors());
            traceEndpoint(
                "connection.failed",
                endpointIdentifier,
                static_cast<uint32_t>(credentials.pid),
                endpoint->constructionFailure(),
                endpoint->constructionErrno());
            continue;
        }
        auto guestDescriptors = endpoint->takeGuestDescriptors();
        const int sendResult = sendResponse(peer, 0, guestDescriptors);
        closeDescriptors(guestDescriptors);
        if (sendResult < 0) {
            const int savedErrno = errno;
            traceEndpoint(
                "connection.failed",
                endpointIdentifier,
                static_cast<uint32_t>(credentials.pid),
                "descriptor transfer failed",
                savedErrno);
            continue;
        }
        endpoint->start();
        endpoints.push_back(std::move(endpoint));
        traceEndpoint(
            "connection.opened",
            endpointIdentifier,
            static_cast<uint32_t>(credentials.pid),
            "render channel ready");
    }
    stopping.store(true, std::memory_order_release);
    endpoints.clear();
    statistics.cpuLocksClosed.fetch_add(
        cpuLocks.size(), std::memory_order_relaxed);
    cpuLocks.clear();
    allocations.clear();
    close(endpointCompletionDescriptor);
    fenceCompletions.wait();
    renderer.reset();
    std::filesystem::remove(socketPath);
    traceStatistics();
    trace("stopped");
    return brokerFailed.load(std::memory_order_acquire) ? 1 : 0;
}
