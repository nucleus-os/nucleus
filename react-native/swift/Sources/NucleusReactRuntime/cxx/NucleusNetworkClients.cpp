#include "NucleusNetworkClients.hpp"

#include <react/http/IHttpClient.h>
#include <react/http/IWebSocketClient.h>

#include <folly/io/IOBuf.h>

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace nucleus::react {

namespace {

using facebook::react::http::Body;
using facebook::react::http::Headers;
using facebook::react::http::NetworkCallbacks;

constexpr std::size_t maximumBufferedResponseBodyBytes = 64 * 1024 * 1024;

struct HTTPCallbackState final {
  explicit HTTPCallbackState(NetworkCallbacks value)
      : callbacks(std::move(value)) {}

  std::mutex mutex;
  NetworkCallbacks callbacks;
  Headers responseHeaders;
  std::vector<std::uint8_t> responseBody;
  std::uint16_t responseStatus{0};
  bool bufferingFailed{false};
  bool responseDelivered{false};
  bool completed{false};
};

NetworkHTTPCallbacks makeHTTPCallbacks(
    const std::shared_ptr<HTTPCallbackState> &state) {
  return NetworkHTTPCallbacks{
      [state](std::int64_t sent, std::int64_t total) {
        if (state->callbacks.onUploadProgress) {
          state->callbacks.onUploadProgress(sent, total);
        }
      },
      [state](std::uint16_t status) {
        std::lock_guard lock(state->mutex);
        state->responseHeaders.clear();
        state->responseDelivered = false;
        state->responseStatus = status;
      },
      [state](const std::string &name, const std::string &value) {
        std::lock_guard lock(state->mutex);
        state->responseHeaders.emplace_back(name, value);
      },
      [state] {
        facebook::react::http::OnResponse callback;
        Headers headers;
        std::uint16_t status = 0;
        {
          std::lock_guard lock(state->mutex);
          if (state->completed || state->responseDelivered) return;
          state->responseDelivered = true;
          callback = state->callbacks.onResponse;
          headers = state->responseHeaders;
          status = state->responseStatus;
        }
        if (callback) callback(status, std::move(headers));
      },
      [state](std::int64_t received, std::int64_t total,
              const std::vector<std::uint8_t> &bytes) -> std::int64_t {
        if (state->callbacks.sendIncrementalUpdates &&
            state->callbacks.onBodyIncremental) {
          return state->callbacks.onBodyIncremental(
              received, total,
              folly::IOBuf::copyBuffer(bytes.data(), bytes.size()));
        }
        if (state->callbacks.sendProgressUpdates &&
            state->callbacks.onBodyProgress) {
          state->callbacks.onBodyProgress(received, total);
        }
        std::lock_guard lock(state->mutex);
        if (state->responseBody.size() + bytes.size() >
            maximumBufferedResponseBodyBytes) {
          state->bufferingFailed = true;
          return 0;
        }
        state->responseBody.insert(
            state->responseBody.end(), bytes.begin(), bytes.end());
        return static_cast<std::int64_t>(bytes.size());
      },
      [state](const std::string &error, bool timedOut) {
        NetworkCallbacks callbacks;
        std::vector<std::uint8_t> responseBody;
        bool bufferingFailed = false;
        {
          std::lock_guard lock(state->mutex);
          if (state->completed) return;
          state->completed = true;
          callbacks = std::move(state->callbacks);
          responseBody = std::move(state->responseBody);
          bufferingFailed = state->bufferingFailed;
        }
        if (!bufferingFailed && error.empty() && callbacks.onBody &&
            !callbacks.sendIncrementalUpdates) {
          callbacks.onBody(folly::IOBuf::copyBuffer(
              responseBody.data(), responseBody.size()));
        }
        if (callbacks.onResponseComplete) {
          callbacks.onResponseComplete(
              bufferingFailed ? "response exceeded the buffered-body limit"
                              : error,
              timedOut);
        }
      }};
}

struct WebSocketCallbackState final {
  std::mutex mutex;
  facebook::react::IWebSocketClient::OnConnectCallback onConnect;
  facebook::react::IWebSocketClient::OnClosedCallback onClosed;
  facebook::react::IWebSocketClient::OnMessageCallback onMessage;
};

NetworkWebSocketCallbacks makeWebSocketCallbacks(
    const std::shared_ptr<WebSocketCallbackState> &state,
    const std::shared_ptr<NetworkTransportOwner> &transport,
    std::optional<std::int32_t> socketID) {
  std::weak_ptr<NetworkTransportOwner> weakTransport = transport;
  return NetworkWebSocketCallbacks{
      [state](bool connected, const std::string &error) {
        facebook::react::IWebSocketClient::OnConnectCallback callback;
        {
          std::lock_guard lock(state->mutex);
          callback = state->onConnect;
        }
        if (callback) callback(connected, error);
      },
      [state](const std::string &message) {
        facebook::react::IWebSocketClient::OnMessageCallback callback;
        {
          std::lock_guard lock(state->mutex);
          callback = state->onMessage;
        }
        if (callback) callback(message);
      },
      [weakTransport, socketID](const NetworkBytes &bytes) {
        if (socketID) {
          if (auto transport = weakTransport.lock()) {
            transport->didReceiveWebSocketBinary(*socketID, bytes);
          }
        }
      },
      [state](const std::string &reason) {
        facebook::react::IWebSocketClient::OnClosedCallback callback;
        {
          std::lock_guard lock(state->mutex);
          callback = state->onClosed;
        }
        if (callback) callback(reason);
      }};
}

} // namespace

NetworkTransportOwner::NetworkTransportOwner(NetworkTransport value)
    : value_(std::move(value)) {}

const NetworkTransport &NetworkTransportOwner::value() const noexcept {
  return value_;
}

void NetworkTransportOwner::prepareWebSocket(
    std::int32_t id, BinaryHandler handler) {
  std::optional<PreparedWebSocket> replaced;
  {
    std::lock_guard lock(mutex_);
    replaced = std::move(preparedWebSocket_);
    preparedWebSocket_ = PreparedWebSocket{id, std::move(handler)};
  }
}

std::optional<std::int32_t>
NetworkTransportOwner::consumePreparedWebSocket() {
  std::optional<PreparedWebSocket> prepared;
  {
    std::lock_guard lock(mutex_);
    prepared = std::move(preparedWebSocket_);
    preparedWebSocket_.reset();
    if (prepared) {
      binaryHandlers_.insert_or_assign(
          prepared->id, std::move(prepared->handler));
    }
  }
  return prepared ? std::optional(prepared->id) : std::nullopt;
}

void NetworkTransportOwner::registerWebSocket(
    std::int32_t id, NetworkWebSocket socket) {
  std::optional<NetworkWebSocket> replaced;
  {
    std::lock_guard lock(mutex_);
    if (auto it = webSockets_.find(id); it != webSockets_.end()) {
      replaced.emplace(std::move(it->second));
      it->second = std::move(socket);
    } else {
      webSockets_.emplace(id, std::move(socket));
    }
  }
}

void NetworkTransportOwner::unregisterWebSocket(std::int32_t id) {
  std::optional<NetworkWebSocket> socket;
  BinaryHandler handler;
  {
    std::lock_guard lock(mutex_);
    if (auto it = webSockets_.find(id); it != webSockets_.end()) {
      socket.emplace(std::move(it->second));
      webSockets_.erase(it);
    }
    if (auto it = binaryHandlers_.find(id); it != binaryHandlers_.end()) {
      handler = std::move(it->second);
      binaryHandlers_.erase(it);
    }
  }
}

void NetworkTransportOwner::sendWebSocketBinary(
    std::int32_t id, const NetworkBytes &bytes) {
  std::optional<NetworkWebSocket> socket;
  {
    std::lock_guard lock(mutex_);
    if (auto it = webSockets_.find(id); it != webSockets_.end()) {
      socket.emplace(it->second);
    }
  }
  if (socket) socket->sendBinary(bytes);
}

void NetworkTransportOwner::didReceiveWebSocketBinary(
    std::int32_t id, const NetworkBytes &bytes) {
  BinaryHandler handler;
  {
    std::lock_guard lock(mutex_);
    if (auto it = binaryHandlers_.find(id); it != binaryHandlers_.end()) {
      handler = it->second;
    }
  }
  if (handler) handler(id, bytes);
}

std::shared_ptr<NetworkTransportOwner>
makeNetworkTransportOwner(NetworkTransport transport) {
  return std::make_shared<NetworkTransportOwner>(std::move(transport));
}

namespace {

class HTTPRequestToken final : public facebook::react::http::IRequestToken {
public:
  explicit HTTPRequestToken(NetworkRequestToken token)
      : token_(std::move(token)) {}
  ~HTTPRequestToken() override { cancel(); }
  void cancel() noexcept override {
    if (!cancelled_.exchange(true)) token_.cancel();
  }

private:
  NetworkRequestToken token_;
  std::atomic<bool> cancelled_{false};
};

class NetworkHTTPClient final : public facebook::react::IHttpClient {
public:
  explicit NetworkHTTPClient(std::shared_ptr<NetworkTransportOwner> transport)
      : transport_(std::move(transport)) {}

  std::unique_ptr<facebook::react::http::IRequestToken>
  sendRequest(NetworkCallbacks &&callbacks, const std::string &method,
              const std::string &url, const Headers &headers,
              const Body &body, std::uint32_t timeout,
              std::optional<std::string>) override {
    NetworkHTTPRequest request;
    request.method = method;
    request.url = url;
    request.timeoutMilliseconds = timeout;
    request.headers.reserve(headers.size());
    for (const auto &[name, value] : headers) {
      request.headers.push_back({name, value});
    }
    if (body.string) {
      request.bodyKind = NetworkRequestBodyKind::bytes;
      request.body.assign(body.string->begin(), body.string->end());
    } else if (body.base64) {
      request.bodyKind = NetworkRequestBodyKind::base64;
      request.body.assign(body.base64->begin(), body.base64->end());
    } else if (body.blob || body.formData) {
      request.bodyKind = NetworkRequestBodyKind::unsupported;
    }
    auto state = std::make_shared<HTTPCallbackState>(std::move(callbacks));
    return std::make_unique<HTTPRequestToken>(
        transport_->value().startHTTPRequest(
            request, makeHTTPCallbacks(state)));
  }

private:
  std::shared_ptr<NetworkTransportOwner> transport_;
};

class NetworkWebSocketClient final : public facebook::react::IWebSocketClient {
public:
  explicit NetworkWebSocketClient(
      std::shared_ptr<NetworkTransportOwner> transport)
      : transport_(std::move(transport)),
        state_(std::make_shared<WebSocketCallbackState>()),
        socketID_(transport_->consumePreparedWebSocket()),
        socket_(transport_->value().createWebSocket(
            makeWebSocketCallbacks(state_, transport_, socketID_))) {
    if (socketID_) transport_->registerWebSocket(*socketID_, socket_);
  }

  ~NetworkWebSocketClient() override {
    if (socketID_) transport_->unregisterWebSocket(*socketID_);
    socket_.close("runtime shutdown");
  }

  void setOnClosedCallback(OnClosedCallback &&callback) noexcept override {
    std::lock_guard lock(state_->mutex);
    state_->onClosed = std::move(callback);
  }
  void setOnMessageCallback(OnMessageCallback &&callback) noexcept override {
    std::lock_guard lock(state_->mutex);
    state_->onMessage = std::move(callback);
  }
  void connect(const std::string &url,
               OnConnectCallback &&callback = nullptr) override {
    {
      std::lock_guard lock(state_->mutex);
      state_->onConnect = std::move(callback);
    }
    socket_.connect(url);
  }
  void close(const std::string &reason) override { socket_.close(reason); }
  void send(const std::string &message) override { socket_.send(message); }
  void ping() override { socket_.ping(); }

private:
  std::shared_ptr<NetworkTransportOwner> transport_;
  std::shared_ptr<WebSocketCallbackState> state_;
  std::optional<std::int32_t> socketID_;
  NetworkWebSocket socket_;
};

} // namespace

std::unique_ptr<facebook::react::IHttpClient>
makeHttpClient(std::shared_ptr<NetworkTransportOwner> transport) {
  return std::make_unique<NetworkHTTPClient>(std::move(transport));
}

std::unique_ptr<facebook::react::IWebSocketClient>
makeWebSocketClient(std::shared_ptr<NetworkTransportOwner> transport) {
  return std::make_unique<NetworkWebSocketClient>(std::move(transport));
}

} // namespace nucleus::react
