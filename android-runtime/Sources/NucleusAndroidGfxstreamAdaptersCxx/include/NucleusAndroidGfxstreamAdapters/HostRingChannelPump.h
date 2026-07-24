#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

#include "NucleusAndroidSharedRingC.h"
#include "render-utils/RenderChannel.h"

namespace nucleus::android::gfxstream {

enum class HostRingPumpResult : std::uint8_t {
    idle,
    progress,
    waitingForResponseRingSpace,
    waitingForRenderChannel,
    peerClosed,
    stopped,
    error,
};

class HostRingChannelPump final {
public:
    HostRingChannelPump(
        nucleus_android_shared_ring_consumer *commandConsumer,
        nucleus_android_shared_ring_producer *responseProducer,
        ::gfxstream::RenderChannelPtr channel);

    HostRingPumpResult pumpOnce();

    int commandDataNotificationFD() const;
    int responseSpaceNotificationFD() const;
    bool hasPendingCommand() const;
    bool hasPendingResponse() const;

private:
    HostRingPumpResult flushPendingCommand(bool *madeProgress);
    HostRingPumpResult flushPendingResponse(bool *madeProgress);

    nucleus_android_shared_ring_consumer *mCommandConsumer;
    nucleus_android_shared_ring_producer *mResponseProducer;
    ::gfxstream::RenderChannelPtr mChannel;
    std::vector<char> mCommandBuffer;
    std::vector<char> mResponseBuffer;
    std::size_t mResponseOffset = 0;
};

}  // namespace nucleus::android::gfxstream
