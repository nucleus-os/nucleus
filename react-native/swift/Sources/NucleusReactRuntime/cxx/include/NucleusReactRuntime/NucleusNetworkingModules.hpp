#pragma once

#include <memory>

#include <ReactCommon/CallInvoker.h>
#include <ReactCommon/TurboModule.h>
#include <NucleusReactRuntime/NetworkTransport.hpp>

namespace nucleus::react {

class NetworkTransportOwner;

std::shared_ptr<NetworkTransportOwner>
makeNetworkTransportOwner(NetworkTransport transport);

// Construct React Native's portable Networking and WebSocket TurboModules.
// The platform client factories remain private to the implementation so RN's
// request, event, and lifecycle semantics stay authoritative.
std::shared_ptr<facebook::react::TurboModule>
makeNetworkingModule(std::shared_ptr<facebook::react::CallInvoker> jsInvoker,
                     std::shared_ptr<NetworkTransportOwner> transport);

std::shared_ptr<facebook::react::TurboModule>
makeWebSocketModule(std::shared_ptr<facebook::react::CallInvoker> jsInvoker,
                    std::shared_ptr<NetworkTransportOwner> transport);

} // namespace nucleus::react
