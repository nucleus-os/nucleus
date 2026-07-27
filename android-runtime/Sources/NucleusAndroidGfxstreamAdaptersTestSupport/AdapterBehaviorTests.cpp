#include "NucleusAndroidGfxstreamAdaptersTestSupport.h"

#include <algorithm>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <deque>
#include <memory>
#include <poll.h>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>
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
    nucleus_android_shared_ring_mapping *mapping = nullptr;
    nucleus_android_shared_ring_producer *producer = nullptr;
    nucleus_android_shared_ring_consumer *consumer = nullptr;

    RingPair() = default;
    RingPair(const RingPair &) = delete;
    RingPair &operator=(const RingPair &) = delete;

    RingPair(RingPair &&other) noexcept
        : mapping(std::exchange(other.mapping, nullptr)),
          producer(std::exchange(other.producer, nullptr)),
          consumer(std::exchange(other.consumer, nullptr)) {}

    RingPair &operator=(RingPair &&other) noexcept {
        if (this == &other) return *this;
        nucleus_android_shared_ring_consumer_destroy(consumer);
        nucleus_android_shared_ring_producer_destroy(producer);
        nucleus_android_shared_ring_mapping_destroy(mapping);
        mapping = std::exchange(other.mapping, nullptr);
        producer = std::exchange(other.producer, nullptr);
        consumer = std::exchange(other.consumer, nullptr);
        return *this;
    }

    ~RingPair() {
        nucleus_android_shared_ring_consumer_destroy(consumer);
        nucleus_android_shared_ring_producer_destroy(producer);
        nucleus_android_shared_ring_mapping_destroy(mapping);
    }
};

RingPair makeRingPair(std::uint32_t slots, std::uint32_t slotSize) {
    RingPair pair;
    pair.mapping =
        nucleus_android_shared_ring_mapping_create(slots, slotSize);
    if (pair.mapping == nullptr) return pair;
    nucleus_android_shared_ring_descriptors producerDescriptors = {
        .memory_fd = -1,
        .data_notification_fd = -1,
        .space_notification_fd = -1,
    };
    nucleus_android_shared_ring_descriptors consumerDescriptors = {
        .memory_fd = -1,
        .data_notification_fd = -1,
        .space_notification_fd = -1,
    };
    if (nucleus_android_shared_ring_mapping_export_descriptors(
            pair.mapping,
            &producerDescriptors) < 0 ||
        nucleus_android_shared_ring_mapping_export_descriptors(
            pair.mapping,
            &consumerDescriptors) < 0) {
        nucleus_android_shared_ring_descriptors_close(
            producerDescriptors);
        nucleus_android_shared_ring_descriptors_close(
            consumerDescriptors);
        return pair;
    }
    pair.producer =
        nucleus_android_shared_ring_producer_attach(producerDescriptors);
    pair.consumer =
        nucleus_android_shared_ring_consumer_attach(consumerDescriptors);
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
    nucleus_android_shared_ring_consumer *consumer,
    std::vector<std::uint8_t> *output,
    std::size_t expectedSize) {
    std::vector<std::uint8_t> chunk(
        nucleus_android_shared_ring_consumer_slot_size(consumer) -
        sizeof(std::uint32_t));
    while (output->size() < expectedSize) {
        const int count = nucleus_android_shared_ring_consumer_read(
            consumer,
            chunk.data(),
            static_cast<std::uint32_t>(chunk.size()));
        if (count >= 0) {
            output->insert(output->end(), chunk.begin(), chunk.begin() + count);
            continue;
        }
        if (errno != EAGAIN) return false;
        const auto preparation =
            nucleus_android_shared_ring_consumer_prepare_data_wait(
                consumer);
        if (preparation == NUCLEUS_ANDROID_SHARED_RING_WAIT_READY) {
            continue;
        }
        if (preparation != NUCLEUS_ANDROID_SHARED_RING_WAIT_ARMED ||
            !waitFor(
                nucleus_android_shared_ring_consumer_data_notification_fd(
                    consumer)) ||
            nucleus_android_shared_ring_consumer_drain_data_notification(
                consumer) < 0) {
            return false;
        }
    }
    return true;
}

bool writeBytes(
    nucleus_android_shared_ring_producer *producer,
    const std::vector<std::uint8_t> &bytes) {
    const std::size_t capacity =
        nucleus_android_shared_ring_producer_slot_size(producer) -
        sizeof(std::uint32_t);
    std::size_t offset = 0;
    while (offset < bytes.size()) {
        const std::size_t count = std::min(bytes.size() - offset, capacity);
        if (nucleus_android_shared_ring_producer_write(
                producer,
                bytes.data() + offset,
                static_cast<std::uint32_t>(count)) == 0) {
            offset += count;
            continue;
        }
        if (errno != EAGAIN) return false;
        const auto preparation =
            nucleus_android_shared_ring_producer_prepare_space_wait(
                producer);
        if (preparation == NUCLEUS_ANDROID_SHARED_RING_WAIT_READY) {
            continue;
        }
        if (preparation != NUCLEUS_ANDROID_SHARED_RING_WAIT_ARMED ||
            !waitFor(
                nucleus_android_shared_ring_producer_space_notification_fd(
                    producer)) ||
            nucleus_android_shared_ring_producer_drain_space_notification(
                producer) < 0) {
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
    nucleus_android_shared_ring_mapping *commands = nullptr;
    nucleus_android_shared_ring_mapping *responses = nullptr;
    nucleus_android_shared_ring_consumer *commandConsumer = nullptr;
    nucleus_android_shared_ring_producer *responseProducer = nullptr;
    int lifetimePeer = -1;

    ~FactoryProviderContext() {
        if (lifetimePeer >= 0) close(lifetimePeer);
        nucleus_android_shared_ring_producer_destroy(responseProducer);
        nucleus_android_shared_ring_consumer_destroy(commandConsumer);
        nucleus_android_shared_ring_mapping_destroy(responses);
        nucleus_android_shared_ring_mapping_destroy(commands);
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
    provider->commands =
        nucleus_android_shared_ring_mapping_create(2, 64);
    provider->responses =
        nucleus_android_shared_ring_mapping_create(2, 64);
    if (provider->commands == nullptr || provider->responses == nullptr) {
        return -1;
    }
    nucleus_android_shared_ring_descriptors commandConsumer = {
        .memory_fd = -1,
        .data_notification_fd = -1,
        .space_notification_fd = -1,
    };
    nucleus_android_shared_ring_descriptors responseProducer = {
        .memory_fd = -1,
        .data_notification_fd = -1,
        .space_notification_fd = -1,
    };
    nucleus_android_shared_ring_descriptors commandProducer = {
        .memory_fd = -1,
        .data_notification_fd = -1,
        .space_notification_fd = -1,
    };
    nucleus_android_shared_ring_descriptors responseConsumer = {
        .memory_fd = -1,
        .data_notification_fd = -1,
        .space_notification_fd = -1,
    };
    if (nucleus_android_shared_ring_mapping_export_descriptors(
            provider->commands,
            &commandConsumer) < 0 ||
        nucleus_android_shared_ring_mapping_export_descriptors(
            provider->responses,
            &responseProducer) < 0 ||
        nucleus_android_shared_ring_mapping_export_descriptors(
            provider->commands,
            &commandProducer) < 0 ||
        nucleus_android_shared_ring_mapping_export_descriptors(
            provider->responses,
            &responseConsumer) < 0) {
        nucleus_android_shared_ring_descriptors_close(commandConsumer);
        nucleus_android_shared_ring_descriptors_close(responseProducer);
        nucleus_android_shared_ring_descriptors_close(commandProducer);
        nucleus_android_shared_ring_descriptors_close(responseConsumer);
        return -1;
    }
    provider->commandConsumer =
        nucleus_android_shared_ring_consumer_attach(commandConsumer);
    provider->responseProducer =
        nucleus_android_shared_ring_producer_attach(responseProducer);
    if (provider->commandConsumer == nullptr ||
        provider->responseProducer == nullptr) {
        nucleus_android_shared_ring_descriptors_close(commandProducer);
        nucleus_android_shared_ring_descriptors_close(responseConsumer);
        return -1;
    }
    descriptors->command_memory_fd = commandProducer.memory_fd;
    descriptors->command_data_notification_fd =
        commandProducer.data_notification_fd;
    descriptors->command_space_notification_fd =
        commandProducer.space_notification_fd;
    descriptors->response_memory_fd = responseConsumer.memory_fd;
    descriptors->response_data_notification_fd =
        responseConsumer.data_notification_fd;
    descriptors->response_space_notification_fd =
        responseConsumer.space_notification_fd;
    int lifetimeDescriptors[2] = {-1, -1};
    if (socketpair(
            AF_UNIX,
            SOCK_SEQPACKET | SOCK_CLOEXEC,
            0,
            lifetimeDescriptors) < 0) {
        return -1;
    }
    descriptors->lifetime_fd = lifetimeDescriptors[0];
    provider->lifetimePeer = lifetimeDescriptors[1];
    return 0;
}

}  // namespace

extern "C" int nucleus_android_test_guest_ring_stream(void) {
    RingPair commands = makeRingPair(2, 64);
    RingPair responses = makeRingPair(2, 64);
    CHECK_OR_RETURN(
        commands.producer != nullptr && commands.consumer != nullptr &&
        responses.producer != nullptr && responses.consumer != nullptr);

    nucleus::android::gfxstream::GuestRingStream stream(
        commands.producer,
        responses.consumer,
        false,
        128);

    std::vector<std::uint8_t> command(257);
    for (std::size_t index = 0; index < command.size(); ++index) {
        command[index] = static_cast<std::uint8_t>(index);
    }
    std::vector<std::uint8_t> receivedCommand;
    bool commandRead = false;
    std::jthread commandConsumer([&] {
        commandRead = readBytes(
            commands.consumer,
            &receivedCommand,
            command.size());
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
        responseWritten = writeBytes(responses.producer, response);
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
    pollfd lifetime = {
        .fd = provider.lifetimePeer,
        .events = POLLIN,
        .revents = 0,
    };
    CHECK_OR_RETURN(poll(&lifetime, 1, 0) == 0);

    const std::vector<std::uint8_t> command = {3, 1, 4};
    CHECK_OR_RETURN(stream->writeFully(command.data(), command.size()) == 0);
    std::vector<std::uint8_t> scratch(60);
    CHECK_OR_RETURN(
        nucleus_android_shared_ring_consumer_read(
            provider.commandConsumer,
            scratch.data(),
            static_cast<std::uint32_t>(scratch.size())) ==
        static_cast<int>(command.size()));
    CHECK_OR_RETURN(std::equal(command.begin(), command.end(), scratch.begin()));

    const std::vector<std::uint8_t> response = {2, 7, 1, 8};
    CHECK_OR_RETURN(
        nucleus_android_shared_ring_producer_write(
            provider.responseProducer,
            response.data(),
            static_cast<std::uint32_t>(response.size())) == 0);
    std::vector<std::uint8_t> received(response.size());
    CHECK_OR_RETURN(
        stream->readFully(received.data(), received.size()) == received.data());
    CHECK_OR_RETURN(received == response);
    CHECK_OR_RETURN(stream->decRef());
    lifetime.revents = 0;
    CHECK_OR_RETURN(poll(&lifetime, 1, 0) == 1);
    CHECK_OR_RETURN(
        (lifetime.revents & (POLLHUP | POLLRDHUP)) != 0);

    nucleus_android_gfxstream_factory_registration_destroy(registration);
    CHECK_OR_RETURN(capturedFactory == nullptr);
    CHECK_OR_RETURN(capturedFactoryContext == nullptr);
    return 0;
}

extern "C" int nucleus_android_test_host_ring_channel_pump(void) {
    RingPair commands = makeRingPair(2, 64);
    RingPair responses = makeRingPair(2, 64);
    CHECK_OR_RETURN(
        commands.producer != nullptr && commands.consumer != nullptr &&
        responses.producer != nullptr && responses.consumer != nullptr);

    auto channel = std::make_shared<FakeRenderChannel>();
    nucleus::android::gfxstream::HostRingChannelPump pump(
        commands.consumer,
        responses.producer,
        channel);

    const std::vector<std::uint8_t> command = {1, 2, 3, 4};
    CHECK_OR_RETURN(
        nucleus_android_shared_ring_producer_write(
            commands.producer,
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
        nucleus_android_shared_ring_producer_write(
            commands.producer,
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
        nucleus_android_shared_ring_producer_write(
            responses.producer,
            filler.data(),
            static_cast<std::uint32_t>(filler.size())) == 0);
    CHECK_OR_RETURN(
        nucleus_android_shared_ring_producer_write(
            responses.producer,
            filler.data(),
            static_cast<std::uint32_t>(filler.size())) == 0);
    channel->queueResponse(std::vector<char>(90, 0x5a));
    CHECK_OR_RETURN(
        pump.pumpOnce() ==
        nucleus::android::gfxstream::HostRingPumpResult::waitingForResponseRingSpace);
    CHECK_OR_RETURN(pump.hasPendingResponse());

    std::vector<std::uint8_t> scratch(60);
    CHECK_OR_RETURN(
        nucleus_android_shared_ring_consumer_read(
            responses.consumer,
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
            commands.producer != nullptr && commands.consumer != nullptr &&
            responses.producer != nullptr && responses.consumer != nullptr);
        nucleus::android::gfxstream::GuestRingStream stream(
            commands.producer,
            responses.consumer,
            false,
            128);

        CHECK_OR_RETURN(
            nucleus_android_shared_ring_producer_close(
                responses.producer) == 0);
        std::uint8_t response = 0;
        errno = 0;
        CHECK_OR_RETURN(
            stream.readFully(&response, sizeof(response)) == nullptr);
        CHECK_OR_RETURN(errno == EPIPE);

        CHECK_OR_RETURN(
            nucleus_android_shared_ring_consumer_close(
                commands.consumer) == 0);
        const std::uint8_t command = 1;
        errno = 0;
        CHECK_OR_RETURN(
            stream.writeFully(&command, sizeof(command)) == -EPIPE);
        CHECK_OR_RETURN(errno == EPIPE);
    }

    RingPair commands = makeRingPair(2, 64);
    RingPair responses = makeRingPair(2, 64);
    CHECK_OR_RETURN(
        commands.producer != nullptr && commands.consumer != nullptr &&
        responses.producer != nullptr && responses.consumer != nullptr);
    auto channel = std::make_shared<FakeRenderChannel>();
    nucleus::android::gfxstream::HostRingChannelPump pump(
        commands.consumer,
        responses.producer,
        channel);
    CHECK_OR_RETURN(
        nucleus_android_shared_ring_producer_close(
            commands.producer) == 0);
    CHECK_OR_RETURN(
        pump.pumpOnce() ==
        nucleus::android::gfxstream::HostRingPumpResult::peerClosed);
    return 0;
}
