#pragma once

#include <atomic>
#include <cstddef>
#include <deque>
#include <mutex>
#include <memory>
#include <thread>

#include <ReactCommon/CallInvoker.h>
#include <jsi/jsi.h>

namespace nucleus::react {

// CallInvoker that posts cross-thread `invokeAsync` calls onto a queue drained
// on the JS thread. Same-thread `invokeAsync` runs inline to preserve the
// synchronous-dispatch behavior the existing TurboModules rely on.
//
// `invokeSync` always asserts the caller is on the JS thread; misuse aborts
// rather than risking JSI access from another thread.
class RuntimeJSCallInvoker final : public facebook::react::CallInvoker {
 public:
  RuntimeJSCallInvoker(
      facebook::jsi::Runtime &runtime,
      std::thread::id jsThreadId);

  RuntimeJSCallInvoker(const RuntimeJSCallInvoker &) = delete;
  RuntimeJSCallInvoker &operator=(const RuntimeJSCallInvoker &) = delete;
  RuntimeJSCallInvoker(RuntimeJSCallInvoker &&) = delete;
  RuntimeJSCallInvoker &operator=(RuntimeJSCallInvoker &&) = delete;

  void invokeAsync(facebook::react::CallFunc &&func) noexcept override;
  void invokeSync(facebook::react::CallFunc &&func) override;

  // Run every callback queued by cross-thread `invokeAsync`. Returns the
  // number of callbacks drained. Must be called on the JS thread.
  std::size_t drainPending();

  using WakeCallback = void (*)(void *context);
  using WakeContextRelease = void (*)(void *context);

  // Install the embedding host's thread-safe event-loop wake. A transition
  // from an empty cross-thread queue to a non-empty queue signals once.
  void setWakeHandler(
      WakeCallback callback,
      void *context,
      WakeContextRelease release);

  // Stop accepting work and drop any queued callbacks. Idempotent and
  // thread-safe.
  void shutdown();

  bool isShutdown() const noexcept {
    return shutdown_.load(std::memory_order_acquire);
  }

  std::thread::id jsThreadId() const noexcept { return jsThreadId_; }

 private:
  struct WakeEntry {
    WakeEntry(
        WakeCallback callback,
        void *context,
        WakeContextRelease release);
    ~WakeEntry();

    WakeCallback callback;
    void *context;
    WakeContextRelease release;
  };

  facebook::jsi::Runtime &runtime_;
  std::thread::id jsThreadId_;
  std::mutex queueMutex_;
  std::deque<facebook::react::CallFunc> queue_;
  std::shared_ptr<WakeEntry> wakeEntry_;
  std::atomic<bool> shutdown_{false};
};

} // namespace nucleus::react
