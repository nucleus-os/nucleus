#include <NucleusReactRuntime/NetworkTransport.hpp>

namespace nucleus::react {

NetworkHTTPCallbacks::NetworkHTTPCallbacks(
    Upload upload, Response response, Header header,
    FinishHeaders finishHeaders, Body body, Completion completion) noexcept
    : upload_(std::move(upload)), response_(std::move(response)),
      header_(std::move(header)), finishHeaders_(std::move(finishHeaders)),
      body_(std::move(body)), completion_(std::move(completion)) {}

void NetworkHTTPCallbacks::didSendBody(
    std::int64_t sent, std::int64_t total) const noexcept {
  try { if (upload_) upload_(sent, total); } catch (...) {}
}

void NetworkHTTPCallbacks::didReceiveResponse(std::uint16_t status) const noexcept {
  try { if (response_) response_(status); } catch (...) {}
}

void NetworkHTTPCallbacks::didReceiveHeader(
    const std::string &name, const std::string &value) const noexcept {
  try { if (header_) header_(name, value); } catch (...) {}
}

void NetworkHTTPCallbacks::didFinishHeaders() const noexcept {
  try { if (finishHeaders_) finishHeaders_(); } catch (...) {}
}

std::int64_t NetworkHTTPCallbacks::didReceiveBody(
    std::int64_t received, std::int64_t total,
    const std::vector<std::uint8_t> &bytes) const noexcept {
  try { return body_ ? body_(received, total, bytes) : 0; } catch (...) { return 0; }
}

void NetworkHTTPCallbacks::didComplete(
    const std::string &error, bool timedOut) const noexcept {
  try { if (completion_) completion_(error, timedOut); } catch (...) {}
}

NetworkRequestToken::NetworkRequestToken(Cancel cancel) noexcept
    : cancel_(std::move(cancel)) {}

void NetworkRequestToken::cancel() const noexcept {
  try { if (cancel_) cancel_(); } catch (...) {}
}

NetworkWebSocketCallbacks::NetworkWebSocketCallbacks(
    Connect connect, Text text, Close close) noexcept
    : connect_(std::move(connect)), text_(std::move(text)),
      close_(std::move(close)) {}

void NetworkWebSocketCallbacks::didConnect(
    bool connected, const std::string &error) const noexcept {
  try { if (connect_) connect_(connected, error); } catch (...) {}
}

void NetworkWebSocketCallbacks::didReceiveText(
    const std::string &text) const noexcept {
  try { if (text_) text_(text); } catch (...) {}
}

void NetworkWebSocketCallbacks::didClose(
    const std::string &reason) const noexcept {
  try { if (close_) close_(reason); } catch (...) {}
}

NetworkWebSocket::NetworkWebSocket(
    Connect connect, Send send, Ping ping, Close close) noexcept
    : connect_(std::move(connect)), send_(std::move(send)),
      ping_(std::move(ping)), close_(std::move(close)) {}

void NetworkWebSocket::connect(const std::string &url) const noexcept {
  try { if (connect_) connect_(url); } catch (...) {}
}

void NetworkWebSocket::send(const std::string &text) const noexcept {
  try { if (send_) send_(text); } catch (...) {}
}

void NetworkWebSocket::ping() const noexcept {
  try { if (ping_) ping_(); } catch (...) {}
}

void NetworkWebSocket::close(const std::string &reason) const noexcept {
  try { if (close_) close_(reason); } catch (...) {}
}

NetworkTransport::NetworkTransport(
    StartHTTPRequest startHTTPRequest,
    CreateWebSocket createWebSocket) noexcept
    : startHTTPRequest_(std::move(startHTTPRequest)),
      createWebSocket_(std::move(createWebSocket)) {}

NetworkRequestToken NetworkTransport::startHTTPRequest(
    const NetworkHTTPRequest &request,
    NetworkHTTPCallbacks callbacks) const noexcept {
  try {
    return startHTTPRequest_
        ? startHTTPRequest_(request, std::move(callbacks))
        : NetworkRequestToken{};
  } catch (...) {
    return {};
  }
}

NetworkWebSocket NetworkTransport::createWebSocket(
    NetworkWebSocketCallbacks callbacks) const noexcept {
  try {
    return createWebSocket_
        ? createWebSocket_(std::move(callbacks))
        : NetworkWebSocket{};
  } catch (...) {
    return {};
  }
}

} // namespace nucleus::react
