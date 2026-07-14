// Bridge file: C++ holds a Swift class instance and forwards
// virtual calls into Swift. Validates the mixed-library build
// wiring.
//
// This is the canonical Nitro-equivalent pattern: a concrete C++
// subclass of an abstract observer holds a Swift instance and
// dispatches virtual methods to it through the Swift→C++ emitted
// header (`NucleusReactRuntimeCxx.h`), reached through the umbrella
// so the include set stays in one place.

#include <NucleusReactRuntime/SwiftCxxUmbrella.hpp>

#include <memory>
#include <utility>

namespace nucleus::react::probe {

namespace {

class SwiftHandlerBridge final : public Observer {
 public:
  explicit SwiftHandlerBridge(NucleusReactRuntimeCxx::ProbeSwiftHandler swift)
      : swiftPart_(std::move(swift)) {}

  void notify(const std::string &message) override {
    swiftPart_.notify(message);
  }

 private:
  NucleusReactRuntimeCxx::ProbeSwiftHandler swiftPart_;
};

} // namespace

std::shared_ptr<Observer> makeSwiftHandlerBridge(void *swiftHandlerRetained) {
  // `fromUnsafe` is a static method on the Swift class that consumes
  // the retained `Unmanaged` pointer and returns the typed Swift
  // instance. The bridge holds it for the rest of the bridge's life.
  auto swift = NucleusReactRuntimeCxx::ProbeSwiftHandler::fromUnsafe(swiftHandlerRetained);
  return std::make_shared<SwiftHandlerBridge>(std::move(swift));
}

} // namespace nucleus::react::probe
