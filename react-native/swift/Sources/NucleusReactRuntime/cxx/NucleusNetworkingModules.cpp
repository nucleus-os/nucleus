#include <NucleusReactRuntime/NucleusNetworkingModules.hpp>

#include "NucleusNetworkClients.hpp"

#include <react/http/IHttpClient.h>
#include <react/http/IWebSocketClient.h>
#include <react/io/NetworkingModule.h>
#include <react/io/WebSocketModule.h>

#include <memory>
#include <utility>

namespace nucleus::react {

std::shared_ptr<facebook::react::TurboModule>
makeNetworkingModule(std::shared_ptr<facebook::react::CallInvoker> jsInvoker,
                     std::shared_ptr<NetworkTransportOwner> transport) {
  return std::make_shared<facebook::react::NetworkingModule>(
      std::move(jsInvoker),
      [transport = std::move(transport)] { return makeHttpClient(transport); });
}

std::shared_ptr<facebook::react::TurboModule>
makeWebSocketModule(std::shared_ptr<facebook::react::CallInvoker> jsInvoker,
                    std::shared_ptr<NetworkTransportOwner> transport) {
  return std::make_shared<facebook::react::WebSocketModule>(
      std::move(jsInvoker), [transport = std::move(transport)] {
        return makeWebSocketClient(transport);
      });
}

} // namespace nucleus::react
