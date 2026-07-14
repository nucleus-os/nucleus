// Bridge file: C++ holds a Swift `SwiftMountingObserver` instance
// and forwards `MountingObserver::didMount(...)` virtual calls into
// Swift. This is catalog item 1's production-shape application of
// the pattern proven by `CxxVirtualOverrideBridge.cpp`.
//
// `<NucleusReactRuntimeCxx.h>` is only reachable through the
// umbrella, not from any modulemap-visible header — including the
// emitted header through the modulemap would form a cycle where the
// Swift module imports its own emitted output during compilation.

#include <NucleusReactRuntime/SwiftCxxUmbrella.hpp>

#include <memory>
#include <utility>

namespace nucleus::react {

namespace {

class SwiftMountingObserverBridge final : public MountingObserver {
 public:
  explicit SwiftMountingObserverBridge(
      NucleusReactRuntimeCxx::SwiftMountingObserver swift)
      : swiftPart_(std::move(swift)) {}

  void didMount(const MountMutation &mutation) override {
    swiftPart_.didMount(mutation);
  }

  void didFinishTransaction(std::int32_t surfaceId) override {
    swiftPart_.didFinishTransaction(surfaceId);
  }

 private:
  NucleusReactRuntimeCxx::SwiftMountingObserver swiftPart_;
};

} // namespace

std::shared_ptr<MountingObserver> makeSwiftMountingObserverBridge(
    void *swiftObserverRetained) {
  auto swift = NucleusReactRuntimeCxx::SwiftMountingObserver::fromUnsafe(
      swiftObserverRetained);
  return std::make_shared<SwiftMountingObserverBridge>(std::move(swift));
}

} // namespace nucleus::react
