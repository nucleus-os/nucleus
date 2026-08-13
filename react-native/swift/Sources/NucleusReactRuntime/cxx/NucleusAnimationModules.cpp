#include <NucleusReactRuntime/NucleusAnimationFrameClock.hpp>
#include <NucleusReactRuntime/NucleusAnimationModules.hpp>

#include <reanimated/NativeModules/ReanimatedModuleProxy.h>
#include <reanimated/RuntimeDecorators/RNRuntimeDecorator.h>
#include <reanimated/Tools/PlatformDepMethodsHolder.h>
#include <worklets/NativeModules/WorkletsModuleProxy.h>
#include <worklets/Tools/PlatformLogger.h>
#include <worklets/Tools/RNRuntimeStatus.h>
#include <worklets/Tools/UIScheduler.h>
#include <worklets/WorkletRuntime/BundleModeConfig.h>
#include <worklets/WorkletRuntime/RuntimeBindings.h>

#include <cstdio>
#include <stdexcept>
#include <utility>

namespace {

class NucleusUIScheduler final
    : public worklets::UIScheduler,
      public std::enable_shared_from_this<NucleusUIScheduler> {
public:
  explicit NucleusUIScheduler(
      std::shared_ptr<facebook::react::CallInvoker> jsInvoker)
      : jsInvoker_(std::move(jsInvoker)) {}

  void scheduleOnUI(std::function<void()> job) override {
    worklets::UIScheduler::scheduleOnUI(std::move(job));
    if (scheduledOnUI_.exchange(true)) {
      return;
    }
    jsInvoker_->invokeAsync(
        [weakSelf = weak_from_this()](facebook::jsi::Runtime &) {
          if (auto self = weakSelf.lock()) {
            self->triggerUI();
          }
        });
  }

private:
  std::shared_ptr<facebook::react::CallInvoker> jsInvoker_;
};

facebook::jsi::Value booleanResult(bool value) {
  return facebook::jsi::Value(value);
}

} // namespace

namespace nucleus::react {

class NucleusAnimationModules::Impl final {
public:
  Impl(facebook::jsi::Runtime &runtime,
       std::shared_ptr<facebook::react::CallInvoker> jsInvoker,
       std::shared_ptr<NucleusAnimationFrameClock> frameClock,
       std::thread::id jsThreadId, UIManagerProvider uiManagerProvider)
      : runtime_(runtime), jsInvoker_(std::move(jsInvoker)),
        frameClock_(std::move(frameClock)), jsThreadId_(jsThreadId),
        uiManagerProvider_(std::move(uiManagerProvider)) {}

  ~Impl() { shutdown(); }

  class WorkletsTurboModule final : public facebook::react::TurboModule {
  public:
    explicit WorkletsTurboModule(Impl &owner)
        : facebook::react::TurboModule("WorkletsModule", owner.jsInvoker_),
          owner_(owner) {}

    facebook::jsi::Value
    get(facebook::jsi::Runtime &runtime,
        const facebook::jsi::PropNameID &property) override {
      const auto name = property.utf8(runtime);
      if (name == "installTurboModule") {
        return facebook::jsi::Function::createFromHostFunction(
            runtime, property, 1,
            [this](facebook::jsi::Runtime &runtime,
                   const facebook::jsi::Value &,
                   const facebook::jsi::Value *arguments,
                   std::size_t count) -> facebook::jsi::Value {
              const bool bundleMode =
                  count > 0 && arguments[0].isBool() && arguments[0].getBool();
              if (bundleMode) {
                throw facebook::jsi::JSError(
                    runtime, "Nucleus does not support Worklets bundle mode");
              }
              owner_.installWorklets();
              return booleanResult(true);
            });
      }
      if (name == "start") {
        return facebook::jsi::Function::createFromHostFunction(
            runtime, property, 0,
            [this](facebook::jsi::Runtime &, const facebook::jsi::Value &,
                   const facebook::jsi::Value *,
                   std::size_t) -> facebook::jsi::Value {
              owner_.startWorklets();
              return booleanResult(true);
            });
      }
      if (name == "toggleSlowAnimationsOnUIRuntime") {
        return facebook::jsi::Function::createFromHostFunction(
            runtime, property, 0,
            [](facebook::jsi::Runtime &runtime, const facebook::jsi::Value &,
               const facebook::jsi::Value *,
               std::size_t) -> facebook::jsi::Value {
              throw facebook::jsi::JSError(
                  runtime,
                  "Slow Worklets animations are unsupported on Nucleus");
            });
      }
      return facebook::jsi::Value::undefined();
    }

  private:
    Impl &owner_;
  };

  class ReanimatedTurboModule final : public facebook::react::TurboModule {
  public:
    explicit ReanimatedTurboModule(Impl &owner)
        : facebook::react::TurboModule("ReanimatedModule", owner.jsInvoker_),
          owner_(owner) {}

    facebook::jsi::Value
    get(facebook::jsi::Runtime &runtime,
        const facebook::jsi::PropNameID &property) override {
      if (property.utf8(runtime) != "installTurboModule") {
        return facebook::jsi::Value::undefined();
      }
      return facebook::jsi::Function::createFromHostFunction(
          runtime, property, 0,
          [this](facebook::jsi::Runtime &, const facebook::jsi::Value &,
                 const facebook::jsi::Value *,
                 std::size_t) -> facebook::jsi::Value {
            owner_.installReanimated();
            return booleanResult(true);
          });
    }

  private:
    Impl &owner_;
  };

  std::shared_ptr<facebook::react::TurboModule> workletsModule() {
    if (workletsTurboModule_ == nullptr) {
      workletsTurboModule_ = std::make_shared<WorkletsTurboModule>(*this);
    }
    return workletsTurboModule_;
  }

  std::shared_ptr<facebook::react::TurboModule> reanimatedModule() {
    if (reanimatedTurboModule_ == nullptr) {
      reanimatedTurboModule_ = std::make_shared<ReanimatedTurboModule>(*this);
    }
    return reanimatedTurboModule_;
  }

  void shutdown() noexcept {
    if (runtimeStatus_ != nullptr) {
      runtimeStatus_->setDead();
    }
    reanimatedProxy_.reset();
    workletsProxy_.reset();
    uiScheduler_.reset();
    runtimeStatus_.reset();
  }

private:
  void assertJSThread(const char *operation) const {
    if (std::this_thread::get_id() != jsThreadId_) {
      throw std::runtime_error(std::string(operation) +
                               " must run on the React JS thread");
    }
  }

  void installWorklets() {
    assertJSThread("Worklets installation");
    if (workletsProxy_ != nullptr) {
      return;
    }
    uiScheduler_ = std::make_shared<NucleusUIScheduler>(jsInvoker_);
    runtimeStatus_ = std::make_shared<worklets::RNRuntimeStatus>();
    std::weak_ptr<NucleusAnimationFrameClock> weakClock = frameClock_;
    auto runtimeBindings =
        std::make_shared<worklets::RuntimeBindings>(worklets::RuntimeBindings{
            .requestAnimationFrame =
                [weakClock](std::function<void(const double)> callback) {
                  if (auto clock = weakClock.lock()) {
                    clock->requestNativeFrame(std::move(callback));
                  }
                },
            .nativeLoggingHook = {},
        });
    workletsProxy_ = std::make_shared<worklets::WorkletsModuleProxy>(
        runtime_, jsInvoker_, uiScheduler_,
        [thread = jsThreadId_]() {
          return std::this_thread::get_id() == thread;
        },
        runtimeBindings,
        worklets::BundleModeConfig{
            .enabled = false,
            .script = nullptr,
            .sourceURL = "",
        },
        runtimeStatus_);
  }

  void startWorklets() {
    assertJSThread("Worklets start");
    if (workletsProxy_ == nullptr) {
      throw std::runtime_error("Worklets must be installed before start");
    }
    workletsProxy_->start();
  }

  void installReanimated() {
    assertJSThread("Reanimated installation");
    if (reanimatedProxy_ != nullptr) {
      return;
    }
    if (workletsProxy_ == nullptr) {
      throw std::runtime_error("Worklets must be installed before Reanimated");
    }
    auto uiManager = uiManagerProvider_();
    if (uiManager == nullptr) {
      throw std::runtime_error("Fabric must be installed before Reanimated");
    }

    std::weak_ptr<NucleusAnimationFrameClock> weakClock = frameClock_;
    reanimated::PlatformDepMethodsHolder methods{
        .requestRender =
            [weakClock](std::function<void(const double)> callback) {
              if (auto clock = weakClock.lock()) {
                clock->requestNativeFrame(std::move(callback));
              }
            },
        .synchronouslyUpdateUIPropsFunction =
            [weakManager = std::weak_ptr<facebook::react::UIManager>(
                 uiManager)](const int tag, const folly::dynamic &props) {
              if (auto manager = weakManager.lock()) {
                manager->synchronouslyUpdateViewOnUIThread(tag, props);
              }
            },
        .getAnimationTimestamp =
            [weakClock]() {
              if (auto clock = weakClock.lock()) {
                return clock->now().count();
              }
              return 0.0;
            },
        .registerSensor = [](int, int, int,
                             std::function<void(double[], int)>) { return -1; },
        .unregisterSensor = [](int) {},
        .setGestureStateFunction = [](int, int) {},
        .subscribeForKeyboardEvents = [](std::function<void(int, int)>, bool,
                                         bool) { return -1; },
        .unsubscribeFromKeyboardEvents = [](int) {},
        .maybeFlushUIUpdatesQueueFunction = [] {},
        .attachPseudoSelector = [](facebook::react::Tag,
                                   reanimated::PseudoSelector,
                                   std::function<void(bool)>) {},
        .detachPseudoSelector = [](facebook::react::Tag,
                                   reanimated::PseudoSelector) {},
        .cssCanRouteProperty =
            [](const std::string &, const reanimated::css::EasingConfig &) {
              return false;
            },
        .cssApplyTransition =
            [](facebook::react::Tag, const std::string &,
               const reanimated::css::PlatformValue &,
               const reanimated::css::PlatformValue &,
               const reanimated::CSSTransitionPropertySettings *,
               double) { return false; },
        .cssRemoveTransition = [](facebook::react::Tag, const std::string &) {},
        .platformAnimationFactory = nullptr,
    };

    reanimatedProxy_ = std::make_shared<reanimated::ReanimatedModuleProxy>(
        workletsProxy_->getUIWorkletRuntime(), uiScheduler_, runtime_,
        jsInvoker_, methods, false);
    reanimatedProxy_->init(methods);
    reanimated::RNRuntimeDecorator::decorate(
        runtime_, workletsProxy_->getUIWorkletRuntime()->getJSIRuntime(),
        reanimatedProxy_);
    reanimatedProxy_->initializeFabric(uiManager);
  }

  facebook::jsi::Runtime &runtime_;
  std::shared_ptr<facebook::react::CallInvoker> jsInvoker_;
  std::shared_ptr<NucleusAnimationFrameClock> frameClock_;
  std::thread::id jsThreadId_;
  UIManagerProvider uiManagerProvider_;
  std::shared_ptr<NucleusUIScheduler> uiScheduler_;
  std::shared_ptr<worklets::RNRuntimeStatus> runtimeStatus_;
  std::shared_ptr<worklets::WorkletsModuleProxy> workletsProxy_;
  std::shared_ptr<reanimated::ReanimatedModuleProxy> reanimatedProxy_;
  std::shared_ptr<WorkletsTurboModule> workletsTurboModule_;
  std::shared_ptr<ReanimatedTurboModule> reanimatedTurboModule_;
};

NucleusAnimationModules::NucleusAnimationModules(
    facebook::jsi::Runtime &runtime,
    std::shared_ptr<facebook::react::CallInvoker> jsInvoker,
    std::shared_ptr<NucleusAnimationFrameClock> frameClock,
    std::thread::id jsThreadId, UIManagerProvider uiManagerProvider)
    : impl_(std::make_unique<Impl>(runtime, std::move(jsInvoker),
                                   std::move(frameClock), jsThreadId,
                                   std::move(uiManagerProvider))) {}

NucleusAnimationModules::~NucleusAnimationModules() = default;

std::shared_ptr<facebook::react::TurboModule>
NucleusAnimationModules::workletsModule() {
  return impl_->workletsModule();
}

std::shared_ptr<facebook::react::TurboModule>
NucleusAnimationModules::reanimatedModule() {
  return impl_->reanimatedModule();
}

void NucleusAnimationModules::shutdown() noexcept { impl_->shutdown(); }

} // namespace nucleus::react

namespace worklets {

void PlatformLogger::log(const char *value) {
  std::fprintf(stderr, "%s\n", value);
}

void PlatformLogger::log(const std::string &value) { log(value.c_str()); }

void PlatformLogger::log(const double value) {
  std::fprintf(stderr, "%f\n", value);
}

void PlatformLogger::log(const int value) {
  std::fprintf(stderr, "%d\n", value);
}

void PlatformLogger::log(const bool value) {
  std::fprintf(stderr, "%s\n", value ? "true" : "false");
}

} // namespace worklets
