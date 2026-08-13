#pragma once

#include <functional>
#include <memory>
#include <thread>

#include <ReactCommon/CallInvoker.h>
#include <ReactCommon/TurboModule.h>
#include <jsi/jsi.h>
#include <react/renderer/uimanager/UIManager.h>

namespace nucleus::react {

class NucleusAnimationFrameClock;

// Owns the Worklets and Reanimated native module pair for one React runtime.
// Both modules share the runtime's CallInvoker, presentation clock, and Fabric
// UIManager rather than creating platform-specific queues or timer fallbacks.
class NucleusAnimationModules final {
public:
  using UIManagerProvider =
      std::function<std::shared_ptr<facebook::react::UIManager>()>;

  NucleusAnimationModules(
      facebook::jsi::Runtime &runtime,
      std::shared_ptr<facebook::react::CallInvoker> jsInvoker,
      std::shared_ptr<NucleusAnimationFrameClock> frameClock,
      std::thread::id jsThreadId, UIManagerProvider uiManagerProvider);
  ~NucleusAnimationModules();

  NucleusAnimationModules(const NucleusAnimationModules &) = delete;
  NucleusAnimationModules &operator=(const NucleusAnimationModules &) = delete;

  std::shared_ptr<facebook::react::TurboModule> workletsModule();
  std::shared_ptr<facebook::react::TurboModule> reanimatedModule();
  void shutdown() noexcept;

private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

} // namespace nucleus::react
