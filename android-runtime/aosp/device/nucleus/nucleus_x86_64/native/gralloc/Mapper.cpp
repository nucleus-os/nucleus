#include <aidl/android/hardware/graphics/common/BlendMode.h>
#include <aidl/android/hardware/graphics/common/BufferUsage.h>
#include <aidl/android/hardware/graphics/common/Dataspace.h>
#include <aidl/android/hardware/graphics/common/PixelFormat.h>
#include <aidl/android/hardware/graphics/common/PlaneLayout.h>
#include <aidl/android/hardware/graphics/common/Rect.h>
#include <aidl/android/hardware/graphics/common/StandardMetadataType.h>
#include <android-base/unique_fd.h>
#include <android/hardware/graphics/mapper/IMapper.h>
#include <android/hardware/graphics/mapper/utils/IMapperMetadataTypes.h>
#include <android/hardware/graphics/mapper/utils/IMapperProvider.h>
#include <cutils/native_handle.h>
#include <drm_fourcc.h>
#include <gralloctypes/Gralloc4.h>
#include <log/log.h>
#include <sync/sync.h>
#include <sys/mman.h>

#include <array>
#include <cerrno>
#include <cstring>
#include <mutex>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

#include "NucleusGrallocBrokerClient.h"
#include "NucleusGrallocFormats.h"
#include "NucleusGrallocHandle.h"

namespace {

using namespace aidl::android::hardware::graphics::common;
using namespace android::hardware::graphics::mapper;
using android::base::unique_fd;

constexpr const char *kStandardMetadataName =
    "android.hardware.graphics.common.StandardMetadataType";

bool isStandard(AIMapper_MetadataType type) {
    return type.name != nullptr &&
           std::strcmp(type.name, kStandardMetadataName) == 0;
}

const nucleus_gralloc_handle *getHandle(buffer_handle_t buffer) {
    return nucleus_gralloc_handle_cast(buffer);
}

nucleus_gralloc_handle *getMutableHandle(buffer_handle_t buffer) {
    return nucleus_gralloc_handle_cast(
        const_cast<native_handle_t *>(buffer));
}

PlaneLayout planeLayout(const nucleus_gralloc_handle &handle) {
    PlaneLayout result = {};
    if (handle.drm_format == DRM_FORMAT_ARGB8888) {
        result.components = {
            {.type = android::gralloc4::PlaneLayoutComponentType_B,
             .offsetInBits = 0,
             .sizeInBits = 8},
            {.type = android::gralloc4::PlaneLayoutComponentType_G,
             .offsetInBits = 8,
             .sizeInBits = 8},
            {.type = android::gralloc4::PlaneLayoutComponentType_R,
             .offsetInBits = 16,
             .sizeInBits = 8},
            {.type = android::gralloc4::PlaneLayoutComponentType_A,
             .offsetInBits = 24,
             .sizeInBits = 8},
        };
    } else if (handle.drm_format == DRM_FORMAT_ABGR16161616F) {
        result.components = {
            {.type = android::gralloc4::PlaneLayoutComponentType_R,
             .offsetInBits = 0, .sizeInBits = 16},
            {.type = android::gralloc4::PlaneLayoutComponentType_G,
             .offsetInBits = 16, .sizeInBits = 16},
            {.type = android::gralloc4::PlaneLayoutComponentType_B,
             .offsetInBits = 32, .sizeInBits = 16},
            {.type = android::gralloc4::PlaneLayoutComponentType_A,
             .offsetInBits = 48, .sizeInBits = 16},
        };
    } else if (handle.drm_format == DRM_FORMAT_ABGR2101010) {
        result.components = {
            {.type = android::gralloc4::PlaneLayoutComponentType_R,
             .offsetInBits = 0, .sizeInBits = 10},
            {.type = android::gralloc4::PlaneLayoutComponentType_G,
             .offsetInBits = 10, .sizeInBits = 10},
            {.type = android::gralloc4::PlaneLayoutComponentType_B,
             .offsetInBits = 20, .sizeInBits = 10},
            {.type = android::gralloc4::PlaneLayoutComponentType_A,
             .offsetInBits = 30, .sizeInBits = 2},
        };
    } else {
        result.components = {
            {.type = android::gralloc4::PlaneLayoutComponentType_R,
             .offsetInBits = 0,
             .sizeInBits = 8},
            {.type = android::gralloc4::PlaneLayoutComponentType_G,
             .offsetInBits = 8,
             .sizeInBits = 8},
            {.type = android::gralloc4::PlaneLayoutComponentType_B,
             .offsetInBits = 16,
             .sizeInBits = 8},
            {.type = android::gralloc4::PlaneLayoutComponentType_A,
             .offsetInBits = 24,
             .sizeInBits = 8},
        };
    }
    result.offsetInBytes = handle.plane_offset;
    const auto *format = nucleus_gralloc_format_for_drm(handle.drm_format);
    result.sampleIncrementInBits =
        format == nullptr ? 0 : format->bytes_per_pixel * 8;
    result.strideInBytes = handle.plane_stride;
    result.widthInSamples = handle.width;
    result.heightInSamples = handle.height;
    result.totalSizeInBytes = handle.allocation_size;
    result.horizontalSubsampling = 1;
    result.verticalSubsampling = 1;
    return result;
}

constexpr AIMapper_MetadataTypeDescription describe(
    StandardMetadataType type,
    bool settable = false) {
    return {
        {kStandardMetadataName, static_cast<int64_t>(type)},
        nullptr,
        true,
        settable,
        {0},
    };
}

class NucleusMapper final : public vendor::mapper::IMapperV5Impl {
  public:
    AIMapper_Error importBuffer(
        const native_handle_t *handle,
        buffer_handle_t *output) override {
        const auto *nucleus = nucleus_gralloc_handle_cast(handle);
        if (nucleus == nullptr) {
            return AIMAPPER_ERROR_BAD_BUFFER;
        }
        native_handle_t *clone = native_handle_clone(handle);
        if (clone == nullptr) {
            return AIMAPPER_ERROR_NO_RESOURCES;
        }
        *output = clone;
        return AIMAPPER_ERROR_NONE;
    }

    AIMapper_Error freeBuffer(buffer_handle_t buffer) override {
        const auto *handle = getHandle(buffer);
        if (handle == nullptr) {
            return AIMAPPER_ERROR_BAD_BUFFER;
        }
        {
            std::lock_guard lock(mutex_);
            const auto found = mappings_.find(buffer);
            if (found != mappings_.end()) {
                (void)nucleus_gralloc_broker_unlock(
                    *handle, found->second.broker);
                munmap(
                    found->second.address,
                    found->second.broker.size);
                close(found->second.broker.staging_fd);
                close(found->second.broker.lifetime_fd);
                mappings_.erase(found);
            }
        }
        native_handle_close(buffer);
        native_handle_delete(const_cast<native_handle_t *>(buffer));
        return AIMAPPER_ERROR_NONE;
    }

    AIMapper_Error getTransportSize(
        buffer_handle_t buffer,
        uint32_t *fds,
        uint32_t *ints) override {
        if (getHandle(buffer) == nullptr) {
            return AIMAPPER_ERROR_BAD_BUFFER;
        }
        *fds = buffer->numFds;
        *ints = buffer->numInts;
        return AIMAPPER_ERROR_NONE;
    }

    AIMapper_Error lock(
        buffer_handle_t buffer,
        uint64_t cpuUsage,
        ARect,
        int acquireFence,
        void **output) override {
        unique_fd fence(acquireFence);
        const auto *handle = getHandle(buffer);
        const uint64_t readMask =
            static_cast<uint64_t>(BufferUsage::CPU_READ_MASK);
        const uint64_t writeMask =
            static_cast<uint64_t>(BufferUsage::CPU_WRITE_MASK);
        uint32_t access = 0;
        if ((cpuUsage & readMask) != 0) {
            access |= NUCLEUS_GRALLOC_CPU_ACCESS_READ;
        }
        if ((cpuUsage & writeMask) != 0) {
            access |= NUCLEUS_GRALLOC_CPU_ACCESS_WRITE;
        }
        if (handle == nullptr || access == 0) {
            return AIMAPPER_ERROR_BAD_VALUE;
        }
        if (fence.ok() && sync_wait(fence.get(), -1) < 0) {
            return AIMAPPER_ERROR_NO_RESOURCES;
        }
        nucleus_gralloc_cpu_mapping brokerMapping = {};
        brokerMapping.staging_fd = -1;
        brokerMapping.lifetime_fd = -1;
        if (nucleus_gralloc_broker_lock(
                *handle, access, &brokerMapping) < 0) {
            return AIMAPPER_ERROR_NO_RESOURCES;
        }
        void *mapping = mmap(
            nullptr,
            brokerMapping.size,
            PROT_READ | PROT_WRITE,
            MAP_SHARED,
            brokerMapping.staging_fd,
            0);
        if (mapping == MAP_FAILED) {
            (void)nucleus_gralloc_broker_unlock(*handle, brokerMapping);
            close(brokerMapping.staging_fd);
            close(brokerMapping.lifetime_fd);
            return AIMAPPER_ERROR_NO_RESOURCES;
        }
        {
            std::lock_guard lock(mutex_);
            if (mappings_.contains(buffer)) {
                munmap(mapping, brokerMapping.size);
                (void)nucleus_gralloc_broker_unlock(
                    *handle, brokerMapping);
                close(brokerMapping.staging_fd);
                close(brokerMapping.lifetime_fd);
                return AIMAPPER_ERROR_BAD_VALUE;
            }
            mappings_.emplace(
                buffer,
                Mapping{mapping, brokerMapping});
        }
        *output = mapping;
        return AIMAPPER_ERROR_NONE;
    }

    AIMapper_Error unlock(
        buffer_handle_t buffer,
        int *releaseFence) override {
        std::lock_guard lock(mutex_);
        const auto found = mappings_.find(buffer);
        if (found == mappings_.end()) {
            return AIMAPPER_ERROR_BAD_BUFFER;
        }
        const auto *handle = getHandle(buffer);
        if (handle == nullptr) {
            return AIMAPPER_ERROR_BAD_BUFFER;
        }
        const int result = nucleus_gralloc_broker_unlock(
            *handle, found->second.broker);
        munmap(found->second.address, found->second.broker.size);
        close(found->second.broker.staging_fd);
        close(found->second.broker.lifetime_fd);
        mappings_.erase(found);
        *releaseFence = -1;
        return result == 0
            ? AIMAPPER_ERROR_NONE
            : AIMAPPER_ERROR_NO_RESOURCES;
    }

    AIMapper_Error flushLockedBuffer(buffer_handle_t buffer) override {
        return synchronize(
            buffer, NUCLEUS_GRALLOC_CPU_ACCESS_WRITE);
    }

    AIMapper_Error rereadLockedBuffer(buffer_handle_t buffer) override {
        return synchronize(
            buffer, NUCLEUS_GRALLOC_CPU_ACCESS_READ);
    }

    int32_t getMetadata(
        buffer_handle_t buffer,
        AIMapper_MetadataType type,
        void *output,
        size_t outputSize) override {
        return isStandard(type)
                   ? getStandardMetadata(
                         buffer, type.value, output, outputSize)
                   : -AIMAPPER_ERROR_UNSUPPORTED;
    }

    int32_t getStandardMetadata(
        buffer_handle_t buffer,
        int64_t rawType,
        void *output,
        size_t outputSize) override {
        const auto *handle = getHandle(buffer);
        if (handle == nullptr) {
            return -AIMAPPER_ERROR_BAD_BUFFER;
        }
        const auto type = static_cast<StandardMetadataType>(rawType);
        auto provider = [&]<StandardMetadataType Type>(
                            auto &&provide) -> int32_t {
            if constexpr (Type == StandardMetadataType::BUFFER_ID) {
                return provide(handle->allocation_id);
            } else if constexpr (Type == StandardMetadataType::NAME) {
                return provide(std::string("Nucleus Android buffer"));
            } else if constexpr (Type == StandardMetadataType::WIDTH) {
                return provide(handle->width);
            } else if constexpr (Type == StandardMetadataType::HEIGHT) {
                return provide(handle->height);
            } else if constexpr (Type == StandardMetadataType::LAYER_COUNT) {
                return provide(uint64_t{1});
            } else if constexpr (
                Type == StandardMetadataType::PIXEL_FORMAT_REQUESTED) {
                return provide(
                    static_cast<PixelFormat>(handle->android_format));
            } else if constexpr (
                Type == StandardMetadataType::PIXEL_FORMAT_FOURCC) {
                return provide(handle->drm_format);
            } else if constexpr (
                Type == StandardMetadataType::PIXEL_FORMAT_MODIFIER) {
                return provide(handle->drm_modifier);
            } else if constexpr (Type == StandardMetadataType::USAGE) {
                return provide(static_cast<BufferUsage>(handle->usage));
            } else if constexpr (
                Type == StandardMetadataType::ALLOCATION_SIZE) {
                return provide(handle->allocation_size);
            } else if constexpr (
                Type == StandardMetadataType::PROTECTED_CONTENT) {
                return provide(uint64_t{0});
            } else if constexpr (
                Type == StandardMetadataType::COMPRESSION) {
                return provide(android::gralloc4::Compression_None);
            } else if constexpr (
                Type == StandardMetadataType::INTERLACED) {
                return provide(android::gralloc4::Interlaced_None);
            } else if constexpr (
                Type == StandardMetadataType::CHROMA_SITING) {
                return provide(android::gralloc4::ChromaSiting_None);
            } else if constexpr (
                Type == StandardMetadataType::PLANE_LAYOUTS) {
                return provide(
                    std::vector<PlaneLayout>{planeLayout(*handle)});
            } else if constexpr (Type == StandardMetadataType::CROP) {
                return provide(std::vector<Rect>{{
                    .left = 0,
                    .top = 0,
                    .right = static_cast<int32_t>(handle->width),
                    .bottom = static_cast<int32_t>(handle->height),
                }});
            } else if constexpr (Type == StandardMetadataType::DATASPACE) {
                return provide(static_cast<Dataspace>(handle->dataspace));
            } else if constexpr (Type == StandardMetadataType::BLEND_MODE) {
                return provide(static_cast<BlendMode>(handle->blend_mode));
            } else if constexpr (Type == StandardMetadataType::STRIDE) {
                return provide(handle->pixel_stride);
            } else if constexpr (
                Type == StandardMetadataType::SMPTE2086) {
                return provide(std::optional<Smpte2086>{});
            } else if constexpr (
                Type == StandardMetadataType::CTA861_3) {
                return provide(std::optional<Cta861_3>{});
            } else if constexpr (
                Type == StandardMetadataType::SMPTE2094_10 ||
                Type == StandardMetadataType::SMPTE2094_40 ||
                Type == StandardMetadataType::SMPTE2094_50) {
                return provide(
                    std::optional<std::vector<uint8_t>>{});
            } else {
                return -AIMAPPER_ERROR_UNSUPPORTED;
            }
        };
        return provideStandardMetadata(
            type, output, outputSize, provider);
    }

    AIMapper_Error setMetadata(
        buffer_handle_t buffer,
        AIMapper_MetadataType type,
        const void *metadata,
        size_t size) override {
        return isStandard(type)
                   ? setStandardMetadata(
                         buffer, type.value, metadata, size)
                   : AIMAPPER_ERROR_UNSUPPORTED;
    }

    AIMapper_Error setStandardMetadata(
        buffer_handle_t buffer,
        int64_t rawType,
        const void *metadata,
        size_t size) override {
        auto *handle = getMutableHandle(buffer);
        if (handle == nullptr) {
            return AIMAPPER_ERROR_BAD_BUFFER;
        }
        const auto type = static_cast<StandardMetadataType>(rawType);
        if (type != StandardMetadataType::DATASPACE &&
            type != StandardMetadataType::BLEND_MODE) {
            return AIMAPPER_ERROR_UNSUPPORTED;
        }
        auto apply = [&]<StandardMetadataType Type>(
                         auto &&value) -> AIMapper_Error {
            if constexpr (Type == StandardMetadataType::DATASPACE) {
                handle->dataspace = static_cast<int32_t>(value);
                return AIMAPPER_ERROR_NONE;
            } else if constexpr (
                Type == StandardMetadataType::BLEND_MODE) {
                handle->blend_mode = static_cast<int32_t>(value);
                return AIMAPPER_ERROR_NONE;
            } else {
                return AIMAPPER_ERROR_UNSUPPORTED;
            }
        };
        return applyStandardMetadata(type, metadata, size, apply);
    }

    AIMapper_Error listSupportedMetadataTypes(
        const AIMapper_MetadataTypeDescription **descriptions,
        size_t *count) override {
        static constexpr std::array metadata = {
            describe(StandardMetadataType::BUFFER_ID),
            describe(StandardMetadataType::NAME),
            describe(StandardMetadataType::WIDTH),
            describe(StandardMetadataType::HEIGHT),
            describe(StandardMetadataType::LAYER_COUNT),
            describe(StandardMetadataType::PIXEL_FORMAT_REQUESTED),
            describe(StandardMetadataType::PIXEL_FORMAT_FOURCC),
            describe(StandardMetadataType::PIXEL_FORMAT_MODIFIER),
            describe(StandardMetadataType::USAGE),
            describe(StandardMetadataType::ALLOCATION_SIZE),
            describe(StandardMetadataType::PROTECTED_CONTENT),
            describe(StandardMetadataType::COMPRESSION),
            describe(StandardMetadataType::INTERLACED),
            describe(StandardMetadataType::CHROMA_SITING),
            describe(StandardMetadataType::PLANE_LAYOUTS),
            describe(StandardMetadataType::CROP),
            describe(StandardMetadataType::DATASPACE, true),
            describe(StandardMetadataType::BLEND_MODE, true),
            describe(StandardMetadataType::STRIDE),
        };
        *descriptions = metadata.data();
        *count = metadata.size();
        return AIMAPPER_ERROR_NONE;
    }

    AIMapper_Error dumpBuffer(
        buffer_handle_t buffer,
        AIMapper_DumpBufferCallback,
        void *) override {
        return getHandle(buffer) == nullptr
                   ? AIMAPPER_ERROR_BAD_BUFFER
                   : AIMAPPER_ERROR_NONE;
    }

    AIMapper_Error dumpAllBuffers(
        AIMapper_BeginDumpBufferCallback,
        AIMapper_DumpBufferCallback,
        void *) override {
        return AIMAPPER_ERROR_NONE;
    }

    AIMapper_Error getReservedRegion(
        buffer_handle_t buffer,
        void **output,
        uint64_t *size) override {
        if (getHandle(buffer) == nullptr) {
            return AIMAPPER_ERROR_BAD_BUFFER;
        }
        *output = nullptr;
        *size = 0;
        return AIMAPPER_ERROR_NONE;
    }

  private:
    struct Mapping {
        void *address;
        nucleus_gralloc_cpu_mapping broker;
    };

    AIMapper_Error synchronize(buffer_handle_t buffer, uint32_t access) {
        std::lock_guard lock(mutex_);
        const auto found = mappings_.find(buffer);
        if (found == mappings_.end()) {
            return AIMAPPER_ERROR_BAD_BUFFER;
        }
        const auto *handle = getHandle(buffer);
        if (handle == nullptr) {
            return AIMAPPER_ERROR_BAD_BUFFER;
        }
        return nucleus_gralloc_broker_sync(
            *handle, found->second.broker, access) == 0
                   ? AIMAPPER_ERROR_NONE
                   : AIMAPPER_ERROR_BAD_VALUE;
    }

    std::mutex mutex_;
    std::unordered_map<buffer_handle_t, Mapping> mappings_;
};

}  // namespace

extern "C" uint32_t ANDROID_HAL_MAPPER_VERSION = AIMAPPER_VERSION_5;

extern "C" AIMapper_Error AIMapper_loadIMapper(AIMapper **output) {
    static vendor::mapper::IMapperProvider<NucleusMapper> provider;
    return provider.load(output);
}
