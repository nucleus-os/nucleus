#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <vector>

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
        std::size_t bufferSize = 4 * 1024 * 1024);

    GuestRingStream(
        nucleus_android_shared_ring *commands,
        nucleus_android_shared_ring *responses,
        bool ownsRings,
        std::size_t bufferSize = 4 * 1024 * 1024);
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

    nucleus_android_shared_ring *mCommands;
    nucleus_android_shared_ring *mResponses;
    bool mOwnsRings;
    std::vector<unsigned char> mCommitBuffer;
    std::vector<unsigned char> mResponseBuffer;
    std::size_t mResponseOffset = 0;
};

}  // namespace nucleus::android::gfxstream
