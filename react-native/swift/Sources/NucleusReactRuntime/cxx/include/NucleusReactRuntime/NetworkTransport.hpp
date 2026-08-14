#pragma once

#include <cstdint>
#include <functional>
#include <string>
#include <swift/bridging>
#include <utility>
#include <vector>

namespace nucleus::react {

using NetworkBytes = std::vector<std::uint8_t>;

struct SWIFT_ESCAPABLE SWIFT_SELF_CONTAINED NetworkHeader final {
  std::string name;
  std::string value;
};

enum class NetworkRequestBodyKind : std::uint8_t {
  none,
  bytes,
  base64,
  unsupported,
};

struct SWIFT_ESCAPABLE SWIFT_SELF_CONTAINED NetworkHTTPRequest final {
  std::string method;
  std::string url;
  std::vector<NetworkHeader> headers;
  NetworkRequestBodyKind bodyKind{NetworkRequestBodyKind::none};
  NetworkBytes body;
  std::uint32_t timeoutMilliseconds{0};
};

class SWIFT_ESCAPABLE SWIFT_SELF_CONTAINED NetworkHTTPCallbacks final {
public:
  using Upload = std::function<void(std::int64_t, std::int64_t)>;
  using Response = std::function<void(std::uint16_t)>;
  using Header = std::function<void(const std::string &, const std::string &)>;
  using FinishHeaders = std::function<void()>;
  using Body = std::function<std::int64_t(
      std::int64_t, std::int64_t, const NetworkBytes &)>;
  using Completion = std::function<void(const std::string &, bool)>;

  NetworkHTTPCallbacks(Upload upload, Response response, Header header,
                       FinishHeaders finishHeaders, Body body,
                       Completion completion) noexcept;

  void didSendBody(std::int64_t sent, std::int64_t total) const noexcept;
  void didReceiveResponse(std::uint16_t status) const noexcept;
  void didReceiveHeader(const std::string &name,
                        const std::string &value) const noexcept;
  void didFinishHeaders() const noexcept;
  std::int64_t didReceiveBody(
      std::int64_t received, std::int64_t total,
      const NetworkBytes &bytes) const noexcept;
  void didComplete(const std::string &error, bool timedOut) const noexcept;

private:
  Upload upload_;
  Response response_;
  Header header_;
  FinishHeaders finishHeaders_;
  Body body_;
  Completion completion_;
};

class SWIFT_ESCAPABLE SWIFT_SELF_CONTAINED NetworkRequestToken final {
public:
  using Cancel = std::function<void()>;

  NetworkRequestToken() noexcept = default;
  explicit NetworkRequestToken(Cancel cancel) noexcept;
  void cancel() const noexcept;

private:
  Cancel cancel_;
};

class SWIFT_ESCAPABLE SWIFT_SELF_CONTAINED NetworkWebSocketCallbacks final {
public:
  using Connect = std::function<void(bool, const std::string &)>;
  using Text = std::function<void(const std::string &)>;
  using Close = std::function<void(const std::string &)>;

  NetworkWebSocketCallbacks(Connect connect, Text text, Close close) noexcept;
  void didConnect(bool connected, const std::string &error) const noexcept;
  void didReceiveText(const std::string &text) const noexcept;
  void didClose(const std::string &reason) const noexcept;

private:
  Connect connect_;
  Text text_;
  Close close_;
};

class SWIFT_ESCAPABLE SWIFT_SELF_CONTAINED NetworkWebSocket final {
public:
  using Connect = std::function<void(const std::string &)>;
  using Send = std::function<void(const std::string &)>;
  using Ping = std::function<void()>;
  using Close = std::function<void(const std::string &)>;

  NetworkWebSocket() noexcept = default;
  NetworkWebSocket(Connect connect, Send send, Ping ping, Close close) noexcept;
  void connect(const std::string &url) const noexcept;
  void send(const std::string &text) const noexcept;
  void ping() const noexcept;
  void close(const std::string &reason) const noexcept;

private:
  Connect connect_;
  Send send_;
  Ping ping_;
  Close close_;
};

class SWIFT_ESCAPABLE SWIFT_SELF_CONTAINED NetworkTransport final {
public:
  using StartHTTPRequest = std::function<NetworkRequestToken(
      const NetworkHTTPRequest &, NetworkHTTPCallbacks)>;
  using CreateWebSocket =
      std::function<NetworkWebSocket(NetworkWebSocketCallbacks)>;

  NetworkTransport(StartHTTPRequest startHTTPRequest,
                   CreateWebSocket createWebSocket) noexcept;
  NetworkRequestToken
  startHTTPRequest(const NetworkHTTPRequest &request,
                   NetworkHTTPCallbacks callbacks) const noexcept;
  NetworkWebSocket
  createWebSocket(NetworkWebSocketCallbacks callbacks) const noexcept;

private:
  StartHTTPRequest startHTTPRequest_;
  CreateWebSocket createWebSocket_;
};

} // namespace nucleus::react
