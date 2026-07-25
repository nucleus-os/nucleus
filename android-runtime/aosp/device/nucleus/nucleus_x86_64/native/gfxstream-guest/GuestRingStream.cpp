#include "NucleusAndroidGfxstreamAdapters/GuestRingStream.h"

#include <algorithm>
#include <cerrno>
#include <cstring>
#include <new>
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
    auto *commandProducer =
        nucleus_android_shared_ring_producer_attach({
            .memory_fd = commandMemoryFD,
            .data_notification_fd = commandDataNotificationFD,
            .space_notification_fd = commandSpaceNotificationFD,
        });
    if (commandProducer == nullptr) {
        if (responseSpaceNotificationFD >= 0) close(responseSpaceNotificationFD);
        if (responseDataNotificationFD >= 0) close(responseDataNotificationFD);
        if (responseMemoryFD >= 0) close(responseMemoryFD);
        return nullptr;
    }
    auto *responseConsumer =
        nucleus_android_shared_ring_consumer_attach({
            .memory_fd = responseMemoryFD,
            .data_notification_fd = responseDataNotificationFD,
            .space_notification_fd = responseSpaceNotificationFD,
        });
    if (responseConsumer == nullptr) {
        nucleus_android_shared_ring_producer_destroy(commandProducer);
        return nullptr;
    }
    return std::make_unique<GuestRingStream>(
        commandProducer,
        responseConsumer,
        true,
        bufferSize);
}

GuestRingStream::GuestRingStream(
    nucleus_android_shared_ring_producer *commandProducer,
    nucleus_android_shared_ring_consumer *responseConsumer,
    bool ownsRings,
    std::size_t bufferSize)
    : IOStream(bufferSize),
      mCommandProducer(commandProducer),
      mResponseConsumer(responseConsumer),
      mOwnsRings(ownsRings) {}

GuestRingStream::~GuestRingStream() {
    (void)nucleus_android_shared_ring_consumer_close(mResponseConsumer);
    (void)nucleus_android_shared_ring_producer_close(mCommandProducer);
    if (mOwnsRings) {
        nucleus_android_shared_ring_consumer_destroy(mResponseConsumer);
        nucleus_android_shared_ring_producer_destroy(mCommandProducer);
    }
}

void *GuestRingStream::allocBuffer(std::size_t minimumSize) {
    if (minimumSize > mCommitCapacity) {
        auto replacement = std::unique_ptr<unsigned char[]>(
            new (std::nothrow) unsigned char[minimumSize]);
        if (!replacement) {
            errno = ENOMEM;
            return nullptr;
        }
        mCommitBuffer = std::move(replacement);
        mCommitCapacity = minimumSize;
    }
    return mCommitBuffer.get();
}

int GuestRingStream::commitBuffer(std::size_t size) {
    if (size > mCommitCapacity) {
        errno = EMSGSIZE;
        return -EMSGSIZE;
    }
    return writeFully(mCommitBuffer.get(), size);
}

const unsigned char *GuestRingStream::readFully(
    void *buffer,
    std::size_t length) {
    auto *output = static_cast<unsigned char *>(buffer);
    std::size_t copied = 0;
    while (copied < length) {
        if (mResponseOffset == mResponseSize && !loadResponseChunk()) {
            return nullptr;
        }
        const std::size_t available = mResponseSize - mResponseOffset;
        const std::size_t count = std::min(length - copied, available);
        std::memcpy(output + copied, mResponseBuffer.get() + mResponseOffset, count);
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
    if (mResponseOffset == mResponseSize && !loadResponseChunk()) {
        return nullptr;
    }
    const std::size_t available = mResponseSize - mResponseOffset;
    const std::size_t count = std::min(*inoutLength, available);
    std::memcpy(buffer, mResponseBuffer.get() + mResponseOffset, count);
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
        nucleus_android_shared_ring_producer_slot_size(mCommandProducer) -
        sizeof(std::uint32_t);
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
        if (nucleus_android_shared_ring_producer_write(
                mCommandProducer,
                bytes,
                static_cast<std::uint32_t>(length)) == 0) {
            return 0;
        }
        if (errno != EAGAIN) {
            return -errno;
        }
        const auto preparation =
            nucleus_android_shared_ring_producer_prepare_space_wait(
                mCommandProducer);
        if (preparation == NUCLEUS_ANDROID_SHARED_RING_WAIT_READY) {
            continue;
        }
        if (preparation == NUCLEUS_ANDROID_SHARED_RING_WAIT_CLOSED) {
            errno = EPIPE;
            return -EPIPE;
        }
        if (preparation == NUCLEUS_ANDROID_SHARED_RING_WAIT_ERROR) {
            return -errno;
        }
        const int waitResult = waitFor(
            nucleus_android_shared_ring_producer_space_notification_fd(
                mCommandProducer));
        if (waitResult < 0) {
            return waitResult;
        }
        if (nucleus_android_shared_ring_producer_drain_space_notification(
                mCommandProducer) < 0) {
            return -errno;
        }
    }
}

bool GuestRingStream::loadResponseChunk() {
    const std::size_t capacity =
        nucleus_android_shared_ring_consumer_slot_size(mResponseConsumer) -
        sizeof(std::uint32_t);
    if (capacity > mResponseCapacity) {
        auto replacement = std::unique_ptr<unsigned char[]>(
            new (std::nothrow) unsigned char[capacity]);
        if (!replacement) {
            errno = ENOMEM;
            return false;
        }
        mResponseBuffer = std::move(replacement);
        mResponseCapacity = capacity;
    }
    while (true) {
        const int result = nucleus_android_shared_ring_consumer_read(
            mResponseConsumer,
            mResponseBuffer.get(),
            static_cast<std::uint32_t>(mResponseCapacity));
        if (result >= 0) {
            mResponseSize = static_cast<std::size_t>(result);
            mResponseOffset = 0;
            return true;
        }
        if (errno != EAGAIN) {
            return false;
        }
        const auto preparation =
            nucleus_android_shared_ring_consumer_prepare_data_wait(
                mResponseConsumer);
        if (preparation == NUCLEUS_ANDROID_SHARED_RING_WAIT_READY) {
            continue;
        }
        if (preparation == NUCLEUS_ANDROID_SHARED_RING_WAIT_CLOSED) {
            errno = EPIPE;
            return false;
        }
        if (preparation == NUCLEUS_ANDROID_SHARED_RING_WAIT_ERROR) {
            return false;
        }
        if (waitFor(
                nucleus_android_shared_ring_consumer_data_notification_fd(
                    mResponseConsumer)) < 0) {
            return false;
        }
        if (nucleus_android_shared_ring_consumer_drain_data_notification(
                mResponseConsumer) < 0) {
            return false;
        }
    }
}

}  // namespace nucleus::android::gfxstream
