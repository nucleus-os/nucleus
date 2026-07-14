#pragma once

#include <memory>
#include <mutex>

#include <ReactCommon/TurboModule.h>

namespace nucleus::react {

/// Thread-safe ownership boundary for the Swift JS-command callback. Replacing
/// a handler retires its context only after every in-flight invocation releases
/// its shared entry.
class HostCommandHandler final {
 public:
  using Callback = void (*)(void *, const char *, const char *);
  using Release = void (*)(void *);

  struct Entry final {
    Callback callback;
    void *context;
    Release release;

    Entry(Callback callback, void *context, Release release);
    Entry(const Entry &) = delete;
    Entry &operator=(const Entry &) = delete;
    ~Entry();
  };

  void set(Callback callback, void *context, Release release);
  std::shared_ptr<Entry> get() const;

 private:
  mutable std::mutex mutex_;
  std::shared_ptr<Entry> entry_;
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
