#pragma once

#include <array>
#include <functional>
#include <memory>
#include <string>

#include <NucleusReactRuntime/MountingObserver.hpp>
#include <NucleusReactRuntime/NetworkTransport.hpp>
#include <NucleusReactRuntime/ReactRuntimeHost.hpp>
#include <NucleusReactRuntime/TextLayoutManager.hpp>

namespace nucleus::react {

class ReactRuntimeHostImpl;

struct RuntimeHostResult {
  bool succeeded{true};
  std::array<char, 512> errorStorage{};
  std::string stringValue;
  unsigned int unsignedValue{0};

  static RuntimeHostResult failure(const char *message) noexcept;
};

class ReactRuntimeHostFacade final {
 public:
  explicit ReactRuntimeHostFacade(NetworkTransport networkTransport) noexcept;
  ~ReactRuntimeHostFacade() noexcept;

  ReactRuntimeHostFacade(const ReactRuntimeHostFacade &) = delete;
  ReactRuntimeHostFacade &operator=(const ReactRuntimeHostFacade &) = delete;
  ReactRuntimeHostFacade(ReactRuntimeHostFacade &&other) noexcept;
  ReactRuntimeHostFacade &operator=(ReactRuntimeHostFacade &&other) noexcept;

  RuntimeHostResult initializationResult() const noexcept;

  RuntimeHostResult evaluateBytecode(const std::string &path) noexcept;
  RuntimeHostResult evaluateJavaScriptSource(
      const std::string &source,
      const std::string &sourceUrl) noexcept;
  // Evaluates `source`, drains microtasks, and returns the stringified
  // result. The Swift `CxxStdlib` overlay converts the returned
  // `std::string` to a Swift `String` automatically via the
  // `String(_:)` initializer.
  RuntimeHostResult evaluateJavaScriptForString(
      const std::string &source,
      const std::string &sourceUrl) noexcept;
  RuntimeHostResult installFabric() noexcept;
  RuntimeHostResult registerSurface(int surfaceId) noexcept;
  RuntimeHostResult configureSurface(int surfaceId, double width, double height) noexcept;
  RuntimeHostResult stopSurface(int surfaceId) noexcept;
  RuntimeHostResult runApplication(int surfaceId, const std::string &appKey) noexcept;
  // Drain cross-thread CallInvoker work queued by `invokeAsync` (timer
  // fires, native-module callbacks). Each drained callback also drains
  // microtasks queued by the user code it invoked. Must be called on
  // the JS thread (i.e. the thread that constructed this facade).
  // Returns the number of callbacks drained.
  RuntimeHostResult drainPendingJSCalls() noexcept;
  using JSWorkWake = std::function<void()>;
  // Installs a thread-safe wake invoked when cross-thread JS work first enters
  // an empty invoker queue. Replacing the wake, or shutting the runtime down,
  // retires the previous callable once every in-flight signal has released it.
  RuntimeHostResult setJSWorkWakeHandler(JSWorkWake wake) noexcept;
  using AnimationFrameRequest = std::function<bool()>;
  using AnimationFrameCancel = std::function<void()>;
  // Installs the embedding platform's one-shot presentation callback. The
  // runtime coalesces all native-animation and requestAnimationFrame demand
  // into at most one outstanding request.
  RuntimeHostResult setAnimationFrameScheduler(
      AnimationFrameRequest requestFrame,
      AnimationFrameCancel cancelFrame) noexcept;
  // Delivers a CLOCK_MONOTONIC timestamp from the selected presentation
  // source. Regressing timestamps are clamped to the last delivered value.
  RuntimeHostResult deliverAnimationFrame(
      unsigned long long timestampNanoseconds) noexcept;
  // Thread-safe. Schedules a JS-thread call to the global device-event
  // emitter with `name` and the optionally JSON-encoded `payloadJson`. The
  // event is dropped if the JS-side emitter is not installed yet.
  RuntimeHostResult emitDeviceEvent(const std::string &name, const std::string &payloadJson) noexcept;
  // The JS→native command seam (counterpart to emitDeviceEvent). Installs the callable the
  // `NucleusHostCommand` TurboModule forwards `invoke(command, argsJson)` to; the embedding
  // host routes it to its native services. `handler` runs on the JS thread; the Swift
  // closure copies its inputs and schedules the typed handler on MainActor.
  using HostCommand =
      std::function<void(const std::string &command, const std::string &argsJson)>;
  // Replacing a handler, or destroying the runtime, retires the previous callable after no
  // invocation can still reference it.
  RuntimeHostResult setCommandHandler(HostCommand handler) noexcept;
  RuntimeHostResult setAppState(const std::string &state) noexcept;
  unsigned int surfaceCount() const noexcept;
  FabricMountReport readFabricMountReport() const noexcept;
  RuntimeHostResult setMountingObserver(std::shared_ptr<MountingObserver> observer) noexcept;
  // The closure is consumed when `installFabric()` constructs the React Native
  // text layout manager with its context container.
  RuntimeHostResult setTextMeasureFunction(TextMeasureFunction measure) noexcept;
  // Updates the `DeviceInfo` TurboModule's window/screen metrics.
  // Width/height are logical points (`output px / scale`). Swift
  // calls this from `OverlayReactRuntime` whenever the primary
  // output's frame info updates, and tests prime it before
  // `evaluateBundle`.
  RuntimeHostResult setDisplayMetrics(
      double width,
      double height,
      double scale,
      double fontScale) noexcept;

  static bool hermesCanCreateRuntime() noexcept;
  static unsigned int hermesBytecodeVersion() noexcept;
  static bool hermesIntlDateTimeFormatWorks() noexcept;

 private:
  std::unique_ptr<ReactRuntimeHostImpl> impl_;
  RuntimeHostResult initializationResult_{};
};

} // namespace nucleus::react
