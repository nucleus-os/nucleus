#include <NucleusReactRuntime/MountingObserver.hpp>

#include <memory>
#include <utility>

namespace nucleus::react {

namespace {

class SwiftMountingObserverBridge final : public MountingObserver {
 public:
  SwiftMountingObserverBridge(MountDidMount didMount, MountDidFinish didFinish)
      : didMount_(std::move(didMount)), didFinish_(std::move(didFinish)) {}

  void didMount(const MountMutation &mutation) override {
    didMount_(mutation);
  }

  void didFinishTransaction(std::int32_t surfaceId) override {
    didFinish_(surfaceId);
  }

 private:
  MountDidMount didMount_;
  MountDidFinish didFinish_;
};

} // namespace

std::shared_ptr<MountingObserver> makeMountingObserver(
    MountDidMount didMount,
    MountDidFinish didFinish) noexcept {
  if (!didMount || !didFinish) {
    return {};
  }
  try {
    return std::make_shared<SwiftMountingObserverBridge>(
        std::move(didMount), std::move(didFinish));
  } catch (...) {
    return {};
  }
}

} // namespace nucleus::react
