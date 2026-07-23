#include "NucleusAndroidGfxstreamAdapters/HostRingChannelPump.h"

#include <algorithm>
#include <cerrno>
#include <cstring>
#include <utility>

namespace nucleus::android::gfxstream {

HostRingChannelPump::HostRingChannelPump(
    nucleus_android_shared_ring *commands,
    nucleus_android_shared_ring *responses,
    ::gfxstream::RenderChannelPtr channel)
    : mCommands(commands),
      mResponses(responses),
      mChannel(std::move(channel)) {}

HostRingPumpResult HostRingChannelPump::pumpOnce() {
    if (mCommands == nullptr || mResponses == nullptr || mChannel == nullptr) {
        return HostRingPumpResult::error;
    }

    bool madeProgress = false;
    auto result = flushPendingResponse(&madeProgress);
    if (result != HostRingPumpResult::idle) {
        return result;
    }

    result = flushPendingCommand(&madeProgress);
    if (result != HostRingPumpResult::idle) {
        return result;
    }

    if (mCommandBuffer.empty()) {
        const std::size_t capacity =
            nucleus_android_shared_ring_slot_size(mCommands) - sizeof(std::uint32_t);
        mCommandBuffer.resize(capacity);
        const int count = nucleus_android_shared_ring_read(
            mCommands,
            mCommandBuffer.data(),
            static_cast<std::uint32_t>(mCommandBuffer.size()));
        if (count >= 0) {
            mCommandBuffer.resize(static_cast<std::size_t>(count));
            madeProgress = true;
            result = flushPendingCommand(&madeProgress);
            if (result != HostRingPumpResult::idle) {
                return result;
            }
        } else {
            mCommandBuffer.clear();
            if (errno == EPIPE) {
                return HostRingPumpResult::peerClosed;
            }
            if (errno != EAGAIN) {
                return HostRingPumpResult::error;
            }
        }
    }

    if (mResponseBuffer.empty()) {
        ::gfxstream::RenderChannel::Buffer response;
        const auto readResult = mChannel->tryRead(&response);
        switch (readResult) {
        case ::gfxstream::RenderChannel::IoResult::Ok:
            mResponseBuffer.assign(response.data(), response.data() + response.size());
            mResponseOffset = 0;
            madeProgress = true;
            result = flushPendingResponse(&madeProgress);
            if (result != HostRingPumpResult::idle) {
                return result;
            }
            break;
        case ::gfxstream::RenderChannel::IoResult::TryAgain:
        case ::gfxstream::RenderChannel::IoResult::Timeout:
            break;
        case ::gfxstream::RenderChannel::IoResult::Error:
            return HostRingPumpResult::stopped;
        }
    }

    const auto channelState = mChannel->state();
    if ((static_cast<int>(channelState) &
         static_cast<int>(::gfxstream::RenderChannel::State::Stopped)) != 0) {
        return HostRingPumpResult::stopped;
    }
    return madeProgress ? HostRingPumpResult::progress : HostRingPumpResult::idle;
}

int HostRingChannelPump::commandDataNotificationFD() const {
    return nucleus_android_shared_ring_data_notification_fd(mCommands);
}

int HostRingChannelPump::responseSpaceNotificationFD() const {
    return nucleus_android_shared_ring_space_notification_fd(mResponses);
}

bool HostRingChannelPump::hasPendingCommand() const {
    return !mCommandBuffer.empty();
}

bool HostRingChannelPump::hasPendingResponse() const {
    return !mResponseBuffer.empty();
}

HostRingPumpResult HostRingChannelPump::flushPendingCommand(bool *madeProgress) {
    if (mCommandBuffer.empty()) {
        return HostRingPumpResult::idle;
    }

    ::gfxstream::RenderChannel::Buffer command;
    command.resize_noinit(mCommandBuffer.size());
    std::memcpy(command.data(), mCommandBuffer.data(), mCommandBuffer.size());
    const auto writeResult = mChannel->tryWrite(std::move(command));
    switch (writeResult) {
    case ::gfxstream::RenderChannel::IoResult::Ok:
        mCommandBuffer.clear();
        *madeProgress = true;
        return HostRingPumpResult::idle;
    case ::gfxstream::RenderChannel::IoResult::TryAgain:
    case ::gfxstream::RenderChannel::IoResult::Timeout:
        return HostRingPumpResult::waitingForRenderChannel;
    case ::gfxstream::RenderChannel::IoResult::Error:
        return HostRingPumpResult::stopped;
    }
    return HostRingPumpResult::error;
}

HostRingPumpResult HostRingChannelPump::flushPendingResponse(bool *madeProgress) {
    if (mResponseBuffer.empty()) {
        return HostRingPumpResult::idle;
    }

    const std::size_t capacity =
        nucleus_android_shared_ring_slot_size(mResponses) - sizeof(std::uint32_t);
    const std::size_t count =
        std::min(mResponseBuffer.size() - mResponseOffset, capacity);
    if (nucleus_android_shared_ring_write(
            mResponses,
            mResponseBuffer.data() + mResponseOffset,
            static_cast<std::uint32_t>(count)) < 0) {
        if (errno == EAGAIN) {
            return HostRingPumpResult::waitingForResponseRingSpace;
        }
        if (errno == EPIPE) {
            return HostRingPumpResult::peerClosed;
        }
        return HostRingPumpResult::error;
    }

    mResponseOffset += count;
    *madeProgress = true;
    if (mResponseOffset == mResponseBuffer.size()) {
        mResponseBuffer.clear();
        mResponseOffset = 0;
    }
    return HostRingPumpResult::idle;
}

}  // namespace nucleus::android::gfxstream
