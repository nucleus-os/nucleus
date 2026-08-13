#pragma once

#include <NucleusReactRuntime/NetworkTransport.hpp>

#include <memory>

namespace facebook::react {
struct IHttpClient;
class IWebSocketClient;
} // namespace facebook::react

namespace nucleus::react {

class NetworkTransportOwner;

std::unique_ptr<facebook::react::IHttpClient>
makeHttpClient(std::shared_ptr<NetworkTransportOwner> transport);

std::unique_ptr<facebook::react::IWebSocketClient>
makeWebSocketClient(std::shared_ptr<NetworkTransportOwner> transport);

} // namespace nucleus::react
