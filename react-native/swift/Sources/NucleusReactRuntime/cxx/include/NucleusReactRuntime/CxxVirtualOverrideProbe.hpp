#pragma once

#include <memory>
#include <string>

namespace nucleus::react::probe {

// Validates the build wiring that catalog item 1
// (`docs/swift-cxx-stdlib-cleanup-catalog.md`) needs: the
// runtime-host library is a mixed C++/Swift artifact where C++
// "bridge" classes hold Swift class instances and forward virtual
// calls into Swift via `NucleusReactRuntimeCxx.h`.
//
// `Observer` is the abstract C++ interface. The concrete subclass
// `SwiftHandlerBridge` lives in `CxxVirtualOverrideBridge.cpp` and
// holds a `NucleusReactRuntimeCxx::ProbeSwiftHandler` instance,
// forwarding `notify(...)` to that Swift class.
class Observer {
 public:
  virtual ~Observer() = default;
  virtual void notify(const std::string &message) = 0;
};

// Calls `observer->notify(message)` and echoes the message back.
// Takes the observer by `shared_ptr` so Swift can pass the value
// returned from `makeSwiftHandlerBridge` directly.
std::string runProbe(std::shared_ptr<Observer> observer, const std::string &message);

// Wraps a Swift `ProbeSwiftHandler` instance in a concrete C++
// Observer. `swiftHandlerRetained` must be the result of
// `ProbeSwiftHandler.toUnsafe()` (an `Unmanaged.passRetained`
// pointer); ownership transfers into the returned bridge, which
// releases it when the bridge is destroyed.
//
// Using `void *` keeps the public header free of Swift-emitted
// types so this header can stay inside the Swift module's
// modulemap. The bridge `.cpp` `#include`s `<NucleusReactRuntimeCxx.h>`
// and converts the pointer back to the typed Swift instance via
// `ProbeSwiftHandler::fromUnsafe`. This is the same pattern Nitro
// uses to avoid the Swift-importer cycle (`bridge.cpp` of
// `react-native-nitro` calls `HybridChildSpec_cxx::fromUnsafe`).
std::shared_ptr<Observer> makeSwiftHandlerBridge(void *swiftHandlerRetained);

} // namespace nucleus::react::probe
