#include "NucleusAndroidGfxstreamAdaptersTestSupport.h"

#include <algorithm>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <deque>
#include <memory>
#include <poll.h>
#include <thread>
#include <utility>
#include <vector>

#include "NucleusAndroidGfxstreamAdapters/GuestRingStream.h"
#include "NucleusAndroidGfxstreamAdapters/GuestRingFactory.h"
#include "NucleusAndroidGfxstreamAdapters/HostRingChannelPump.h"
#include "NucleusAndroidSharedRingC.h"

namespace {

#define CHECK_OR_RETURN(condition) \
    do { \
        if (!(condition)) return __LINE__; \
    } while (false)

struct RingPair {
    nucleus_android_shared_ring *owner = nullptr;
    nucleus_android_shared_ring *peer = nullptr;

    RingPair() = default;
    RingPair(const RingPair &) = delete;
    RingPair &operator=(const RingPair &) = delete;

    RingPair(RingPair &&other) noexcept
        : owner(std::exchange(other.owner, nullptr)),
          peer(std::exchange(other.peer, nullptr)) {}

    RingPair &operator=(RingPair &&other) noexcept {
        if (this == &other) return *this;
        nucleus_android_shared_ring_destroy(peer);
        nucleus_android_shared_ring_destroy(owner);
        owner = std::exchange(other.owner, nullptr);
        peer = std::exchange(other.peer, nullptr);
        return *this;
    }

    ~RingPair() {
        nucleus_android_shared_ring_destroy(peer);
        nucleus_android_shared_ring_destroy(owner);
    }
};

RingPair makeRingPair(std::uint32_t slots, std::uint32_t slotSize) {
    RingPair pair;
    pair.owner = nucleus_android_shared_ring_create(slots, slotSize);
    if (pair.owner == nullptr) return pair;
    const int memoryFD = nucleus_android_shared_ring_export_memory_fd(pair.owner);
    const int dataFD =
        nucleus_android_shared_ring_export_data_notification_fd(pair.owner);
    const int spaceFD =
        nucleus_android_shared_ring_export_space_notification_fd(pair.owner);
    pair.peer = nucleus_android_shared_ring_attach(memoryFD, dataFD, spaceFD);
    return pair;
}

bool waitFor(int descriptor) {
    pollfd event = {
        .fd = descriptor,
        .events = POLLIN,
        .revents = 0,
    };
    int result;
    do {
        result = poll(&event, 1, -1);
    } while (result < 0 && errno == EINTR);
    return result == 1 && (event.revents & POLLIN) != 0;
}

bool readBytes(
    nucleus_android_shared_ring *ring,
    std::vector<std::uint8_t> *output,
    std::size_t expectedSize) {
    std::vector<std::uint8_t> chunk(
        nucleus_android_shared_ring_slot_size(ring) - sizeof(std::uint32_t));
    while (output->size() < expectedSize) {
        const int count = nucleus_android_shared_ring_read(
            ring,
            chunk.data(),
            static_cast<std::uint32_t>(chunk.size()));
        if (count >= 0) {
            output->insert(output->end(), chunk.begin(), chunk.begin() + count);
            continue;
        }
        if (errno != EAGAIN ||
            nucleus_android_shared_ring_drain_data_notification(ring) < 0) {
            return false;
        }
        const int retry = nucleus_android_shared_ring_read(
            ring,
            chunk.data(),
            static_cast<std::uint32_t>(chunk.size()));
        if (retry >= 0) {
            output->insert(output->end(), chunk.begin(), chunk.begin() + retry);
            continue;
        }
        if (errno != EAGAIN) return false;
        if (!waitFor(nucleus_android_shared_ring_data_notification_fd(ring))) {
            return false;
        }
    }
    return true;
}

bool writeBytes(
    nucleus_android_shared_ring *ring,
    const std::vector<std::uint8_t> &bytes) {
    const std::size_t capacity =
        nucleus_android_shared_ring_slot_size(ring) - sizeof(std::uint32_t);
    std::size_t offset = 0;
    while (offset < bytes.size()) {
        const std::size_t count = std::min(bytes.size() - offset, capacity);
        if (nucleus_android_shared_ring_write(
                ring,
                bytes.data() + offset,
                static_cast<std::uint32_t>(count)) == 0) {
            offset += count;
            continue;
        }
        if (errno != EAGAIN ||
            nucleus_android_shared_ring_drain_space_notification(ring) < 0) {
            return false;
        }
        if (nucleus_android_shared_ring_write(
                ring,
                bytes.data() + offset,
                static_cast<std::uint32_t>(count)) == 0) {
            offset += count;
            continue;
        }
        if (errno != EAGAIN) return false;
        if (!waitFor(nucleus_android_shared_ring_space_notification_fd(ring))) {
            return false;
        }
    }
    return true;
}

class FakeRenderChannel final : public ::gfxstream::RenderChannel {
public:
    void setEventCallback(EventCallback &&callback) override {
        mCallback = std::move(callback);
    }

    void setWantedEvents(State state) override {
        mWanted = state;
    }

    State state() const override {
        return mStopped ? State::Stopped : State::CanWrite;
    }

    IoResult tryWrite(Buffer &&buffer) override {
        if (mStopped) return IoResult::Error;
        if (blockWrites) return IoResult::TryAgain;
        received.emplace_back(buffer.data(), buffer.data() + buffer.size());
        return IoResult::Ok;
    }

    void waitUntilWritable() override {}

    IoResult tryRead(Buffer *buffer) override {
        if (mStopped) return IoResult::Error;
        if (responses.empty()) return IoResult::TryAgain;
        *buffer = std::move(responses.front());
        responses.pop_front();
        return IoResult::Ok;
    }

    IoResult readBefore(Buffer *buffer, Duration) override {
        return tryRead(buffer);
    }

    void waitUntilReadable() override {}

    void stop() override {
        mStopped = true;
    }

    void onSave(::gfxstream::Stream *) override {}

    void queueResponse(const std::vector<char> &bytes) {
        Buffer response;
        response.resize_noinit(bytes.size());
        std::memcpy(response.data(), bytes.data(), bytes.size());
        responses.push_back(std::move(response));
    }

    bool blockWrites = false;
    std::vector<std::vector<char>> received;
    std::deque<Buffer> responses;

private:
    EventCallback mCallback;
    State mWanted = State::Empty;
    bool mStopped = false;
};

struct FactoryProviderContext {
    nucleus_android_shared_ring *commands = nullptr;
    nucleus_android_shared_ring *responses = nullptr;

    ~FactoryProviderContext() {
        nucleus_android_shared_ring_destroy(responses);
        nucleus_android_shared_ring_destroy(commands);
    }
};

nucleus_android_gfxstream_external_iostream_factory capturedFactory = nullptr;
void *capturedFactoryContext = nullptr;

void captureFactory(
    nucleus_android_gfxstream_external_iostream_factory factory,
    void *context) {
    capturedFactory = factory;
    capturedFactoryContext = context;
}

int provideEndpoint(
    void *context,
    nucleus_android_gfxstream_endpoint_descriptors *descriptors) {
    auto *provider = static_cast<FactoryProviderContext *>(context);
    provider->commands = nucleus_android_shared_ring_create(2, 64);
    provider->responses = nucleus_android_shared_ring_create(2, 64);
    if (provider->commands == nullptr || provider->responses == nullptr) {
        return -1;
    }
    descriptors->command_memory_fd =
        nucleus_android_shared_ring_export_memory_fd(provider->commands);
    descriptors->command_data_notification_fd =
        nucleus_android_shared_ring_export_data_notification_fd(provider->commands);
    descriptors->command_space_notification_fd =
        nucleus_android_shared_ring_export_space_notification_fd(provider->commands);
    descriptors->response_memory_fd =
        nucleus_android_shared_ring_export_memory_fd(provider->responses);
    descriptors->response_data_notification_fd =
        nucleus_android_shared_ring_export_data_notification_fd(provider->responses);
    descriptors->response_space_notification_fd =
        nucleus_android_shared_ring_export_space_notification_fd(provider->responses);
    return 0;
}

}  // namespace

extern "C" int nucleus_android_test_guest_ring_stream(void) {
    RingPair commands = makeRingPair(2, 64);
    RingPair responses = makeRingPair(2, 64);
    CHECK_OR_RETURN(
        commands.owner != nullptr && commands.peer != nullptr &&
        responses.owner != nullptr && responses.peer != nullptr);

    nucleus::android::gfxstream::GuestRingStream stream(
        commands.owner,
        responses.peer,
        false,
        128);

    std::vector<std::uint8_t> command(257);
    for (std::size_t index = 0; index < command.size(); ++index) {
        command[index] = static_cast<std::uint8_t>(index);
    }
    std::vector<std::uint8_t> receivedCommand;
    bool commandRead = false;
    std::jthread commandConsumer([&] {
        commandRead = readBytes(commands.peer, &receivedCommand, command.size());
    });
    CHECK_OR_RETURN(stream.writeFully(command.data(), command.size()) == 0);
    commandConsumer.join();
    CHECK_OR_RETURN(commandRead);
    CHECK_OR_RETURN(receivedCommand == command);

    std::vector<std::uint8_t> response(193);
    for (std::size_t index = 0; index < response.size(); ++index) {
        response[index] = static_cast<std::uint8_t>(255 - index);
    }
    bool responseWritten = false;
    std::jthread responseProducer([&] {
        responseWritten = writeBytes(responses.owner, response);
    });
    std::vector<std::uint8_t> receivedResponse(response.size());
    CHECK_OR_RETURN(
        stream.readFully(receivedResponse.data(), receivedResponse.size()) ==
        receivedResponse.data());
    responseProducer.join();
    CHECK_OR_RETURN(responseWritten);
    CHECK_OR_RETURN(receivedResponse == response);
    return 0;
}

extern "C" int nucleus_android_test_guest_ring_factory_registration(void) {
    FactoryProviderContext provider;
    auto *registration =
        nucleus_android_gfxstream_factory_registration_create_with_setter(
            captureFactory,
            provideEndpoint,
            &provider);
    CHECK_OR_RETURN(registration != nullptr);
    CHECK_OR_RETURN(capturedFactory != nullptr);
    CHECK_OR_RETURN(capturedFactoryContext == registration);

    auto *stream = static_cast<::gfxstream::guest::IOStream *>(
        capturedFactory(capturedFactoryContext, 128));
    CHECK_OR_RETURN(stream != nullptr);

    const std::vector<std::uint8_t> command = {3, 1, 4};
    CHECK_OR_RETURN(stream->writeFully(command.data(), command.size()) == 0);
    std::vector<std::uint8_t> scratch(60);
    CHECK_OR_RETURN(
        nucleus_android_shared_ring_read(
            provider.commands,
            scratch.data(),
            static_cast<std::uint32_t>(scratch.size())) ==
        static_cast<int>(command.size()));
    CHECK_OR_RETURN(std::equal(command.begin(), command.end(), scratch.begin()));

    const std::vector<std::uint8_t> response = {2, 7, 1, 8};
    CHECK_OR_RETURN(
        nucleus_android_shared_ring_write(
            provider.responses,
            response.data(),
            static_cast<std::uint32_t>(response.size())) == 0);
    std::vector<std::uint8_t> received(response.size());
    CHECK_OR_RETURN(
        stream->readFully(received.data(), received.size()) == received.data());
    CHECK_OR_RETURN(received == response);
    CHECK_OR_RETURN(stream->decRef());

    nucleus_android_gfxstream_factory_registration_destroy(registration);
    CHECK_OR_RETURN(capturedFactory == nullptr);
    CHECK_OR_RETURN(capturedFactoryContext == nullptr);
    return 0;
}

extern "C" int nucleus_android_test_host_ring_channel_pump(void) {
    RingPair commands = makeRingPair(2, 64);
    RingPair responses = makeRingPair(2, 64);
    CHECK_OR_RETURN(
        commands.owner != nullptr && commands.peer != nullptr &&
        responses.owner != nullptr && responses.peer != nullptr);

    auto channel = std::make_shared<FakeRenderChannel>();
    nucleus::android::gfxstream::HostRingChannelPump pump(
        commands.peer,
        responses.owner,
        channel);

    const std::vector<std::uint8_t> command = {1, 2, 3, 4};
    CHECK_OR_RETURN(
        nucleus_android_shared_ring_write(
            commands.owner,
            command.data(),
            static_cast<std::uint32_t>(command.size())) == 0);
    CHECK_OR_RETURN(
        pump.pumpOnce() ==
        nucleus::android::gfxstream::HostRingPumpResult::progress);
    CHECK_OR_RETURN(channel->received.size() == 1);
    CHECK_OR_RETURN(std::vector<std::uint8_t>(
        channel->received[0].begin(),
        channel->received[0].end()) == command);

    channel->blockWrites = true;
    const std::vector<std::uint8_t> blockedCommand = {8, 9};
    CHECK_OR_RETURN(
        nucleus_android_shared_ring_write(
            commands.owner,
            blockedCommand.data(),
            static_cast<std::uint32_t>(blockedCommand.size())) == 0);
    CHECK_OR_RETURN(
        pump.pumpOnce() ==
        nucleus::android::gfxstream::HostRingPumpResult::waitingForRenderChannel);
    CHECK_OR_RETURN(pump.hasPendingCommand());
    channel->blockWrites = false;
    CHECK_OR_RETURN(
        pump.pumpOnce() ==
        nucleus::android::gfxstream::HostRingPumpResult::progress);
    CHECK_OR_RETURN(!pump.hasPendingCommand());
    CHECK_OR_RETURN(channel->received.size() == 2);

    const std::vector<std::uint8_t> filler(1, 0xee);
    CHECK_OR_RETURN(
        nucleus_android_shared_ring_write(
            responses.owner,
            filler.data(),
            static_cast<std::uint32_t>(filler.size())) == 0);
    CHECK_OR_RETURN(
        nucleus_android_shared_ring_write(
            responses.owner,
            filler.data(),
            static_cast<std::uint32_t>(filler.size())) == 0);
    channel->queueResponse(std::vector<char>(90, 0x5a));
    CHECK_OR_RETURN(
        pump.pumpOnce() ==
        nucleus::android::gfxstream::HostRingPumpResult::waitingForResponseRingSpace);
    CHECK_OR_RETURN(pump.hasPendingResponse());

    std::vector<std::uint8_t> scratch(60);
    CHECK_OR_RETURN(
        nucleus_android_shared_ring_read(
            responses.peer,
            scratch.data(),
            static_cast<std::uint32_t>(scratch.size())) == 1);
    CHECK_OR_RETURN(
        pump.pumpOnce() ==
        nucleus::android::gfxstream::HostRingPumpResult::progress);
    CHECK_OR_RETURN(pump.hasPendingResponse());
    return 0;
}

extern "C" int nucleus_android_test_ring_peer_closure(void) {
    {
        RingPair commands = makeRingPair(2, 64);
        RingPair responses = makeRingPair(2, 64);
        CHECK_OR_RETURN(
            commands.owner != nullptr && commands.peer != nullptr &&
            responses.owner != nullptr && responses.peer != nullptr);
        nucleus::android::gfxstream::GuestRingStream stream(
            commands.owner,
            responses.peer,
            false,
            128);

        CHECK_OR_RETURN(
            nucleus_android_shared_ring_close(responses.owner) == 0);
        std::uint8_t response = 0;
        errno = 0;
        CHECK_OR_RETURN(
            stream.readFully(&response, sizeof(response)) == nullptr);
        CHECK_OR_RETURN(errno == EPIPE);

        CHECK_OR_RETURN(
            nucleus_android_shared_ring_close(commands.peer) == 0);
        const std::uint8_t command = 1;
        errno = 0;
        CHECK_OR_RETURN(
            stream.writeFully(&command, sizeof(command)) == -EPIPE);
        CHECK_OR_RETURN(errno == EPIPE);
    }

    RingPair commands = makeRingPair(2, 64);
    RingPair responses = makeRingPair(2, 64);
    CHECK_OR_RETURN(
        commands.owner != nullptr && commands.peer != nullptr &&
        responses.owner != nullptr && responses.peer != nullptr);
    auto channel = std::make_shared<FakeRenderChannel>();
    nucleus::android::gfxstream::HostRingChannelPump pump(
        commands.peer,
        responses.owner,
        channel);
    CHECK_OR_RETURN(
        nucleus_android_shared_ring_close(commands.owner) == 0);
    CHECK_OR_RETURN(
        pump.pumpOnce() ==
        nucleus::android::gfxstream::HostRingPumpResult::peerClosed);
    return 0;
}
