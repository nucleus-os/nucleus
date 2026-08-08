#pragma once

#include <functional>
#include <memory>
#include <mutex>
#include <string>

#include <ReactCommon/TurboModule.h>

namespace nucleus::react {

/// Thread-safe ownership boundary for the Swift JS-command callback. Replacing
/// a handler retires the previous callable only after every in-flight
/// invocation releases its shared reference.
class HostCommandHandler final {
 public:
  using HostCommand =
      std::function<void(const std::string &command, const std::string &argsJson)>;

  void set(HostCommand handler);
  std::shared_ptr<const HostCommand> get() const;

 private:
  mutable std::mutex mutex_;
  std::shared_ptr<const HostCommand> handler_;
};

class HostCommandTurboModule final : public facebook::react::TurboModule {
 public:
  HostCommandTurboModule(
      std::shared_ptr<facebook::react::CallInvoker> jsInvoker,
      std::shared_ptr<HostCommandHandler> handler);

  facebook::jsi::Value get(
      facebook::jsi::Runtime &runtime,
      const facebook::jsi::PropNameID &propName) override;

 private:
  std::shared_ptr<HostCommandHandler> handler_;
};

} // namespace nucleus::react
