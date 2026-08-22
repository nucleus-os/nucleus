#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>

#include "NucleusAndroidSharedRingC.h"
#include "gfxstream/guest/IOStream.h"

namespace nucleus::android::gfxstream {

class GuestRingStream final : public ::gfxstream::guest::IOStream {
public:
    static std::unique_ptr<GuestRingStream> attach(
        int commandMemoryFD,
        int commandDataNotificationFD,
        int commandSpaceNotificationFD,
        int responseMemoryFD,
        int responseDataNotificationFD,
        int responseSpaceNotificationFD,
        int lifetimeFD,
        std::size_t bufferSize = 4 * 1024 * 1024);

    GuestRingStream(
        nucleus_android_shared_ring_producer *commandProducer,
        nucleus_android_shared_ring_consumer *responseConsumer,
        bool ownsRings,
        std::size_t bufferSize = 4 * 1024 * 1024,
        int lifetimeFD = -1);
    ~GuestRingStream() override;

    void *allocBuffer(std::size_t minimumSize) override;
    int commitBuffer(std::size_t size) override;
    const unsigned char *readFully(void *buffer, std::size_t length) override;
    const unsigned char *commitBufferAndReadFully(
        std::size_t size,
        void *buffer,
        std::size_t length) override;
    const unsigned char *read(void *buffer, std::size_t *inoutLength) override;
    int writeFully(const void *buffer, std::size_t length) override;

private:
    int waitFor(int descriptor);
    int writeChunk(const std::uint8_t *bytes, std::size_t length);
    bool loadResponseChunk();

    nucleus_android_shared_ring_producer *mCommandProducer;
    nucleus_android_shared_ring_consumer *mResponseConsumer;
    bool mOwnsRings;
    int mLifetimeFD;
    std::unique_ptr<unsigned char[]> mCommitBuffer;
    std::size_t mCommitCapacity = 0;
    std::unique_ptr<unsigned char[]> mResponseBuffer;
    std::size_t mResponseCapacity = 0;
    std::size_t mResponseSize = 0;
    std::size_t mResponseOffset = 0;
};

}  // namespace nucleus::android::gfxstream
