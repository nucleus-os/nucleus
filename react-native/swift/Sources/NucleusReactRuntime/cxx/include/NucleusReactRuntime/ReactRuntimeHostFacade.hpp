#pragma once

#include <memory>
#include <string>

#include <NucleusReactRuntime/MountingObserver.hpp>
#include <NucleusReactRuntime/ReactRuntimeHost.hpp>
#include <NucleusReactRuntime/TextLayoutManager.hpp>

namespace nucleus::react {

class ReactRuntimeHostImpl;

struct RuntimeHostResult {
  bool succeeded{true};
  std::string error;
  std::string stringValue;
  unsigned int unsignedValue{0};
};

class ReactRuntimeHostFacade final {
 public:
  ReactRuntimeHostFacade();
  ~ReactRuntimeHostFacade();

  ReactRuntimeHostFacade(const ReactRuntimeHostFacade &) = delete;
  ReactRuntimeHostFacade &operator=(const ReactRuntimeHostFacade &) = delete;
  ReactRuntimeHostFacade(ReactRuntimeHostFacade &&other) noexcept;
  ReactRuntimeHostFacade &operator=(ReactRuntimeHostFacade &&other) noexcept;

  RuntimeHostResult initializationResult() const;

  RuntimeHostResult evaluateBytecode(const std::string &path);
  RuntimeHostResult evaluateJavaScriptSource(
      const std::string &source,
      const std::string &sourceUrl);
  // Evaluates `source`, drains microtasks, and returns the stringified
  // result. The Swift `CxxStdlib` overlay converts the returned
  // `std::string` to a Swift `String` automatically via the
  // `String(_:)` initializer.
  RuntimeHostResult evaluateJavaScriptForString(
      const std::string &source,
      const std::string &sourceUrl);
  RuntimeHostResult installFabric();
  RuntimeHostResult registerSurface(int surfaceId);
  RuntimeHostResult configureSurface(int surfaceId, double width, double height);
  RuntimeHostResult stopSurface(int surfaceId);
  RuntimeHostResult runApplication(int surfaceId, const std::string &appKey);
  // Drain cross-thread CallInvoker work queued by `invokeAsync` (timer
  // fires, native-module callbacks). Each drained callback also drains
  // microtasks queued by the user code it invoked. Must be called on
  // the JS thread (i.e. the thread that constructed this facade).
  // Returns the number of callbacks drained.
  RuntimeHostResult drainPendingJSCalls();
  using JSWorkWakeCallback = void (*)(void *ctx);
  using JSWorkWakeContextRelease = void (*)(void *ctx);
  // Installs a thread-safe wake invoked when cross-thread JS work first enters
  // an empty invoker queue. Ownership of `context` transfers to the runtime.
  RuntimeHostResult setJSWorkWakeHandler(
      JSWorkWakeCallback callback,
      void *context,
      JSWorkWakeContextRelease release);
  // Thread-safe. Schedules a JS-thread call to the global device-event
  // emitter with `name` and the optionally JSON-encoded `payloadJson`. The
  // event is dropped if the JS-side emitter is not installed yet.
  RuntimeHostResult emitDeviceEvent(const std::string &name, const std::string &payloadJson);
  // The JS→native command seam (counterpart to emitDeviceEvent). Installs a C callback the
  // `NucleusHostCommand` TurboModule forwards `invoke(command, argsJson)` to; the embedding
  // host routes it to its native services. A plain C callback + opaque context so a Swift
  // closure can bridge without a C++ vtable. `callback` runs on the JS thread.
  using HostCommandCallback = void (*)(void *ctx, const char *command, const char *argsJson);
  using HostCommandContextRelease = void (*)(void *ctx);
  // Takes ownership of `context`. The runtime calls `release` after no invocation can
  // still reference it, including when a handler is replaced or the runtime is destroyed.
  RuntimeHostResult setCommandHandler(
      HostCommandCallback callback,
      void *context,
      HostCommandContextRelease release);
  RuntimeHostResult setAppState(const std::string &state);
  unsigned int surfaceCount() const;
  FabricMountReport readFabricMountReport() const;
  RuntimeHostResult setMountingObserver(std::shared_ptr<MountingObserver> observer);
  // Installs a retained Swift `SwiftTextLayoutManager` handle. The
  // handle is the result of `SwiftTextLayoutManager.toUnsafe()`;
  // ownership transfers in. The handle is consumed when
  // `installFabric()` runs and builds the `ContextContainer` the
  // text layout manager bridge needs. If called twice before
  // `installFabric()`, the previous handle is released.
  RuntimeHostResult setSwiftTextLayoutManagerHandle(void *swiftHandlerRetained);
  // Updates the `DeviceInfo` TurboModule's window/screen metrics.
  // Width/height are logical points (`output px / scale`). Swift
  // calls this from `OverlayReactRuntime` whenever the primary
  // output's frame info updates, and tests prime it before
  // `evaluateBundle`.
  RuntimeHostResult setDisplayMetrics(
      double width,
      double height,
      double scale,
      double fontScale);

  static bool hermesCanCreateRuntime();
  static unsigned int hermesBytecodeVersion();
  static bool hermesIntlDateTimeFormatWorks();

 private:
  std::unique_ptr<ReactRuntimeHostImpl> impl_;
  std::string initializationError_;
};

std::shared_ptr<ReactRuntimeHostFacade> makeReactRuntimeHostFacade();

} // namespace nucleus::react
