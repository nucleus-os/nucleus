#pragma once

#include <atomic>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <vector>

#include <jsi/jsi.h>
#include <react/renderer/animationbackend/AnimationChoreographer.h>

namespace nucleus::react {

// One presentation-clock authority for a React runtime. It serves both React
// Native's shared animation backend and the JavaScript requestAnimationFrame
// globals while keeping ordinary timeouts on PlatformTimerRegistry.
class NucleusAnimationFrameClock final
    : public facebook::react::AnimationChoreographer {
public:
  using RequestFrame = std::function<bool()>;
  using CancelFrame = std::function<void()>;
  using NativeFrameCallback = std::function<void(double)>;

  explicit NucleusAnimationFrameClock(facebook::jsi::Runtime &runtime);
  ~NucleusAnimationFrameClock() noexcept override;

  NucleusAnimationFrameClock(const NucleusAnimationFrameClock &) = delete;
  NucleusAnimationFrameClock &
  operator=(const NucleusAnimationFrameClock &) = delete;
  NucleusAnimationFrameClock(NucleusAnimationFrameClock &&) = delete;
  NucleusAnimationFrameClock &operator=(NucleusAnimationFrameClock &&) = delete;

  void attachGlobals();
  void setScheduler(RequestFrame requestFrame, CancelFrame cancelFrame);
  void requestNativeFrame(NativeFrameCallback callback);
  void deliver(std::uint64_t timestampNanoseconds);
  void shutdown() noexcept;

  void resume() override;
  void pause() override;
  facebook::react::AnimationTimestamp now() const override;

private:
  using AnimationFrameHandle = int;

  bool hasDemand() const noexcept;
  void requestIfNeeded();
  void cancelIfIdle();
  double timestampMilliseconds(std::uint64_t timestampNanoseconds) const;

  facebook::jsi::Runtime &runtime_;
  RequestFrame requestFrame_;
  CancelFrame cancelFrame_;
  std::map<AnimationFrameHandle, facebook::jsi::Function> callbacks_;
  std::vector<NativeFrameCallback> nativeCallbacks_;
  AnimationFrameHandle nextHandle_{1};
  bool nativeAnimationsActive_{false};
  bool frameOutstanding_{false};
  bool stopped_{false};
  std::atomic<std::uint64_t> lastTimestampNanoseconds_{0};
};

} // namespace nucleus::react
