#pragma once

#include <NucleusReactRuntime/NetworkTransport.hpp>

#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <unordered_map>

namespace facebook::react {
struct IHttpClient;
class IWebSocketClient;
} // namespace facebook::react

namespace nucleus::react {

class NetworkTransportOwner final {
public:
  using BinaryHandler =
      std::function<void(std::int32_t, const NetworkBytes &)>;

  explicit NetworkTransportOwner(NetworkTransport value);
  const NetworkTransport &value() const noexcept;

  void prepareWebSocket(std::int32_t id, BinaryHandler handler);
  std::optional<std::int32_t> consumePreparedWebSocket();
  void registerWebSocket(std::int32_t id, NetworkWebSocket socket);
  void unregisterWebSocket(std::int32_t id);
  void sendWebSocketBinary(std::int32_t id, const NetworkBytes &bytes);
  void didReceiveWebSocketBinary(std::int32_t id, const NetworkBytes &bytes);

private:
  struct PreparedWebSocket {
    std::int32_t id;
    BinaryHandler handler;
  };

  NetworkTransport value_;
  std::mutex mutex_;
  std::optional<PreparedWebSocket> preparedWebSocket_;
  std::unordered_map<std::int32_t, NetworkWebSocket> webSockets_;
  std::unordered_map<std::int32_t, BinaryHandler> binaryHandlers_;
};

std::unique_ptr<facebook::react::IHttpClient>
makeHttpClient(std::shared_ptr<NetworkTransportOwner> transport);

std::unique_ptr<facebook::react::IWebSocketClient>
makeWebSocketClient(std::shared_ptr<NetworkTransportOwner> transport);

} // namespace nucleus::react
