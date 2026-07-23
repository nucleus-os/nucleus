#include "NucleusAndroidGfxstreamAdapters/GuestRingStream.h"

#include <algorithm>
#include <cerrno>
#include <cstring>
#include <poll.h>
#include <unistd.h>
#include <utility>

namespace nucleus::android::gfxstream {

std::unique_ptr<GuestRingStream> GuestRingStream::attach(
    int commandMemoryFD,
    int commandDataNotificationFD,
    int commandSpaceNotificationFD,
    int responseMemoryFD,
    int responseDataNotificationFD,
    int responseSpaceNotificationFD,
    std::size_t bufferSize) {
    auto *commands = nucleus_android_shared_ring_attach(
        commandMemoryFD,
        commandDataNotificationFD,
        commandSpaceNotificationFD);
    if (commands == nullptr) {
        if (responseSpaceNotificationFD >= 0) close(responseSpaceNotificationFD);
        if (responseDataNotificationFD >= 0) close(responseDataNotificationFD);
        if (responseMemoryFD >= 0) close(responseMemoryFD);
        return nullptr;
    }
    auto *responses = nucleus_android_shared_ring_attach(
        responseMemoryFD,
        responseDataNotificationFD,
        responseSpaceNotificationFD);
    if (responses == nullptr) {
        nucleus_android_shared_ring_destroy(commands);
        return nullptr;
    }
    return std::make_unique<GuestRingStream>(
        commands,
        responses,
        true,
        bufferSize);
}

GuestRingStream::GuestRingStream(
    nucleus_android_shared_ring *commands,
    nucleus_android_shared_ring *responses,
    bool ownsRings,
    std::size_t bufferSize)
    : IOStream(bufferSize),
      mCommands(commands),
      mResponses(responses),
      mOwnsRings(ownsRings) {}

GuestRingStream::~GuestRingStream() {
    (void)nucleus_android_shared_ring_close(mResponses);
    (void)nucleus_android_shared_ring_close(mCommands);
    if (mOwnsRings) {
        nucleus_android_shared_ring_destroy(mResponses);
        nucleus_android_shared_ring_destroy(mCommands);
    }
}

void *GuestRingStream::allocBuffer(std::size_t minimumSize) {
    try {
        mCommitBuffer.resize(minimumSize);
    } catch (...) {
        errno = ENOMEM;
        return nullptr;
    }
    return mCommitBuffer.data();
}

int GuestRingStream::commitBuffer(std::size_t size) {
    if (size > mCommitBuffer.size()) {
        errno = EMSGSIZE;
        return -EMSGSIZE;
    }
    return writeFully(mCommitBuffer.data(), size);
}

const unsigned char *GuestRingStream::readFully(
    void *buffer,
    std::size_t length) {
    auto *output = static_cast<unsigned char *>(buffer);
    std::size_t copied = 0;
    while (copied < length) {
        if (mResponseOffset == mResponseBuffer.size() && !loadResponseChunk()) {
            return nullptr;
        }
        const std::size_t available = mResponseBuffer.size() - mResponseOffset;
        const std::size_t count = std::min(length - copied, available);
        std::memcpy(output + copied, mResponseBuffer.data() + mResponseOffset, count);
        copied += count;
        mResponseOffset += count;
    }
    return output;
}

const unsigned char *GuestRingStream::commitBufferAndReadFully(
    std::size_t size,
    void *buffer,
    std::size_t length) {
    if (commitBuffer(size) < 0) {
        return nullptr;
    }
    return readFully(buffer, length);
}

const unsigned char *GuestRingStream::read(
    void *buffer,
    std::size_t *inoutLength) {
    if (buffer == nullptr || inoutLength == nullptr) {
        errno = EINVAL;
        return nullptr;
    }
    if (*inoutLength == 0) {
        return static_cast<unsigned char *>(buffer);
    }
    if (mResponseOffset == mResponseBuffer.size() && !loadResponseChunk()) {
        return nullptr;
    }
    const std::size_t available = mResponseBuffer.size() - mResponseOffset;
    const std::size_t count = std::min(*inoutLength, available);
    std::memcpy(buffer, mResponseBuffer.data() + mResponseOffset, count);
    mResponseOffset += count;
    *inoutLength = count;
    return static_cast<unsigned char *>(buffer);
}

int GuestRingStream::writeFully(const void *buffer, std::size_t length) {
    if (buffer == nullptr && length != 0) {
        errno = EINVAL;
        return -EINVAL;
    }
    if (length == 0) {
        return 0;
    }
    const std::size_t payloadCapacity =
        nucleus_android_shared_ring_slot_size(mCommands) - sizeof(std::uint32_t);
    const auto *bytes = static_cast<const std::uint8_t *>(buffer);
    std::size_t offset = 0;
    while (offset < length) {
        const std::size_t count = std::min(length - offset, payloadCapacity);
        const int result = writeChunk(bytes + offset, count);
        if (result < 0) {
            return result;
        }
        offset += count;
    }
    return 0;
}

int GuestRingStream::waitFor(int descriptor) {
    pollfd event = {
        .fd = descriptor,
        .events = POLLIN,
        .revents = 0,
    };
    int result;
    do {
        result = poll(&event, 1, -1);
    } while (result < 0 && errno == EINTR);
    if (result < 0) {
        return -errno;
    }
    if ((event.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
        errno = EIO;
        return -EIO;
    }
    return 0;
}

int GuestRingStream::writeChunk(
    const std::uint8_t *bytes,
    std::size_t length) {
    while (true) {
        if (nucleus_android_shared_ring_write(
                mCommands,
                bytes,
                static_cast<std::uint32_t>(length)) == 0) {
            return 0;
        }
        if (errno != EAGAIN) {
            return -errno;
        }
        if (nucleus_android_shared_ring_drain_space_notification(mCommands) < 0) {
            return -errno;
        }
        if (nucleus_android_shared_ring_write(
                mCommands,
                bytes,
                static_cast<std::uint32_t>(length)) == 0) {
            return 0;
        }
        if (errno != EAGAIN) {
            return -errno;
        }
        const int waitResult = waitFor(
            nucleus_android_shared_ring_space_notification_fd(mCommands));
        if (waitResult < 0) {
            return waitResult;
        }
    }
}

bool GuestRingStream::loadResponseChunk() {
    const std::size_t capacity =
        nucleus_android_shared_ring_slot_size(mResponses) - sizeof(std::uint32_t);
    try {
        mResponseBuffer.resize(capacity);
    } catch (...) {
        errno = ENOMEM;
        return false;
    }
    while (true) {
        const int result = nucleus_android_shared_ring_read(
            mResponses,
            mResponseBuffer.data(),
            static_cast<std::uint32_t>(mResponseBuffer.size()));
        if (result >= 0) {
            mResponseBuffer.resize(static_cast<std::size_t>(result));
            mResponseOffset = 0;
            return true;
        }
        if (errno != EAGAIN) {
            return false;
        }
        if (nucleus_android_shared_ring_drain_data_notification(mResponses) < 0) {
            return false;
        }
        const int retry = nucleus_android_shared_ring_read(
            mResponses,
            mResponseBuffer.data(),
            static_cast<std::uint32_t>(mResponseBuffer.size()));
        if (retry >= 0) {
            mResponseBuffer.resize(static_cast<std::size_t>(retry));
            mResponseOffset = 0;
            return true;
        }
        if (errno != EAGAIN) {
            return false;
        }
        if (waitFor(nucleus_android_shared_ring_data_notification_fd(mResponses)) < 0) {
            return false;
        }
    }
}

}  // namespace nucleus::android::gfxstream
