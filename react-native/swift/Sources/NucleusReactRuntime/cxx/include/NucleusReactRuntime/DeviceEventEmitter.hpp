#pragma once

#include <atomic>
#include <memory>
#include <optional>
#include <string>

#include <folly/dynamic.h>
#include <jsi/jsi.h>

namespace nucleus::react {

class RuntimeJSCallInvoker;

// Thread-safe facade around RCTDeviceEventEmitter. Any thread may call
// `emit`; the dispatch hops to the JS thread via the supplied invoker.
//
// The emitter resolves the JS-side emit function lazily on the first call.
// It looks up `globalThis.__nucleusEmitDeviceEvent` first (a hook for tests
// or future runtime shims) and falls back to `globalThis.RCTDeviceEventEmitter.emit`.
// If neither is present at emit time, the event is logged and dropped.
class DeviceEventEmitter final {
 public:
  DeviceEventEmitter(
      facebook::jsi::Runtime &runtime,
      std::shared_ptr<RuntimeJSCallInvoker> invoker);

  DeviceEventEmitter(const DeviceEventEmitter &) = delete;
  DeviceEventEmitter &operator=(const DeviceEventEmitter &) = delete;
  DeviceEventEmitter(DeviceEventEmitter &&) = delete;
  DeviceEventEmitter &operator=(DeviceEventEmitter &&) = delete;

  // Thread-safe. Schedules a JS-thread call to the resolved emit function.
  // Payload is converted from folly::dynamic to jsi::Value inside the
  // JS-thread closure. Pass `folly::dynamic(nullptr)` for events with no
  // payload.
  void emit(std::string eventName, folly::dynamic payload);

  // Stop accepting events. Idempotent; thread-safe.
  void shutdown();

 private:
  facebook::jsi::Runtime &runtime_;
  std::shared_ptr<RuntimeJSCallInvoker> invoker_;
  std::optional<facebook::jsi::Function> emitFn_;
  std::atomic<bool> shutdown_{false};

  // Must be called on the JS thread. Returns nullptr if the resolution fails.
  facebook::jsi::Function *resolveEmitFn();
};

} // namespace nucleus::react
