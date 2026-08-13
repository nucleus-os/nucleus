#include <NucleusReactRuntime/NucleusAnimationFrameClock.hpp>

#include <algorithm>
#include <chrono>
#include <utility>

namespace nucleus::react {

NucleusAnimationFrameClock::NucleusAnimationFrameClock(
    facebook::jsi::Runtime &runtime)
    : runtime_(runtime) {}

NucleusAnimationFrameClock::~NucleusAnimationFrameClock() noexcept {
  shutdown();
}

void NucleusAnimationFrameClock::attachGlobals() {
  runtime_.global().setProperty(
      runtime_, "requestAnimationFrame",
      facebook::jsi::Function::createFromHostFunction(
          runtime_,
          facebook::jsi::PropNameID::forAscii(runtime_,
                                              "requestAnimationFrame"),
          1,
          [this](facebook::jsi::Runtime &runtime, const facebook::jsi::Value &,
                 const facebook::jsi::Value *arguments,
                 std::size_t count) -> facebook::jsi::Value {
            if (count == 0) {
              throw facebook::jsi::JSError(
                  runtime,
                  "requestAnimationFrame must be called with at least one "
                  "argument (i.e: a callback)");
            }
            if (!arguments[0].isObject() ||
                !arguments[0].asObject(runtime).isFunction(runtime)) {
              throw facebook::jsi::JSError(
                  runtime,
                  "The first argument to requestAnimationFrame must be a "
                  "function.");
            }

            const auto handle = nextHandle_++;
            callbacks_.emplace(
                handle, arguments[0].getObject(runtime).getFunction(runtime));
            requestIfNeeded();
            return facebook::jsi::Value(handle);
          }));

  runtime_.global().setProperty(
      runtime_, "cancelAnimationFrame",
      facebook::jsi::Function::createFromHostFunction(
          runtime_,
          facebook::jsi::PropNameID::forAscii(runtime_, "cancelAnimationFrame"),
          1,
          [this](facebook::jsi::Runtime &, const facebook::jsi::Value &,
                 const facebook::jsi::Value *arguments,
                 std::size_t count) -> facebook::jsi::Value {
            if (count > 0 && arguments[0].isNumber()) {
              const auto handle =
                  static_cast<AnimationFrameHandle>(arguments[0].asNumber());
              callbacks_.erase(handle);
              cancelIfIdle();
            }
            return facebook::jsi::Value::undefined();
          }));
}

void NucleusAnimationFrameClock::setScheduler(RequestFrame requestFrame,
                                              CancelFrame cancelFrame) {
  auto previousCancel = std::move(cancelFrame_);
  if (frameOutstanding_) {
    frameOutstanding_ = false;
    if (previousCancel) {
      previousCancel();
    }
  }
  requestFrame_ = std::move(requestFrame);
  cancelFrame_ = std::move(cancelFrame);
  requestIfNeeded();
}

void NucleusAnimationFrameClock::requestNativeFrame(
    NativeFrameCallback callback) {
  if (stopped_ || !callback) {
    return;
  }
  nativeCallbacks_.push_back(std::move(callback));
  requestIfNeeded();
}

void NucleusAnimationFrameClock::deliver(std::uint64_t timestampNanoseconds) {
  if (stopped_ || !frameOutstanding_) {
    return;
  }
  frameOutstanding_ = false;

  const auto previous =
      lastTimestampNanoseconds_.load(std::memory_order_relaxed);
  const auto monotonicTimestamp = std::max(previous, timestampNanoseconds);
  lastTimestampNanoseconds_.store(monotonicTimestamp,
                                  std::memory_order_relaxed);

  if (nativeAnimationsActive_) {
    onAnimationFrame(facebook::react::AnimationTimestamp(
        std::chrono::nanoseconds(monotonicTimestamp)));
  }

  auto callbacks = std::move(callbacks_);
  callbacks_.clear();
  const auto timestamp =
      facebook::jsi::Value(timestampMilliseconds(monotonicTimestamp));
  for (auto &[_, callback] : callbacks) {
    callback.call(runtime_, timestamp);
  }
  auto nativeCallbacks = std::move(nativeCallbacks_);
  nativeCallbacks_.clear();
  for (auto &callback : nativeCallbacks) {
    callback(timestampMilliseconds(monotonicTimestamp));
  }

  requestIfNeeded();
}

void NucleusAnimationFrameClock::shutdown() noexcept {
  if (stopped_) {
    return;
  }
  stopped_ = true;
  nativeAnimationsActive_ = false;
  callbacks_.clear();
  nativeCallbacks_.clear();
  auto cancel = std::move(cancelFrame_);
  requestFrame_ = {};
  if (frameOutstanding_) {
    frameOutstanding_ = false;
    if (cancel) {
      cancel();
    }
  }
}

void NucleusAnimationFrameClock::resume() {
  if (stopped_ || nativeAnimationsActive_) {
    return;
  }
  nativeAnimationsActive_ = true;
  requestIfNeeded();
}

void NucleusAnimationFrameClock::pause() {
  if (!nativeAnimationsActive_) {
    return;
  }
  nativeAnimationsActive_ = false;
  cancelIfIdle();
}

facebook::react::AnimationTimestamp NucleusAnimationFrameClock::now() const {
  auto timestamp = lastTimestampNanoseconds_.load(std::memory_order_relaxed);
  if (timestamp == 0) {
    timestamp = static_cast<std::uint64_t>(
        std::chrono::duration_cast<std::chrono::nanoseconds>(
            std::chrono::steady_clock::now().time_since_epoch())
            .count());
  }
  return facebook::react::AnimationTimestamp(
      std::chrono::nanoseconds(timestamp));
}

bool NucleusAnimationFrameClock::hasDemand() const noexcept {
  return nativeAnimationsActive_ || !callbacks_.empty() ||
         !nativeCallbacks_.empty();
}

void NucleusAnimationFrameClock::requestIfNeeded() {
  if (stopped_ || frameOutstanding_ || !hasDemand() || !requestFrame_) {
    return;
  }
  frameOutstanding_ = requestFrame_();
}

void NucleusAnimationFrameClock::cancelIfIdle() {
  if (hasDemand() || !frameOutstanding_) {
    return;
  }
  frameOutstanding_ = false;
  if (cancelFrame_) {
    cancelFrame_();
  }
}

double NucleusAnimationFrameClock::timestampMilliseconds(
    std::uint64_t timestampNanoseconds) const {
  return static_cast<double>(timestampNanoseconds) / 1'000'000.0;
}

} // namespace nucleus::react
