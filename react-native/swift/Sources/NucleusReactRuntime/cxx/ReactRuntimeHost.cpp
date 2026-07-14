#include <NucleusReactRuntime/DeviceEventEmitter.hpp>
#include <NucleusReactRuntime/HostCommandBridge.hpp>
#include <NucleusReactRuntime/MountingObserver.hpp>
#include <NucleusReactRuntime/NucleusDeviceInfoModule.hpp>
#include <NucleusReactRuntime/NucleusPlatformTimerRegistry.hpp>
#include <NucleusReactRuntime/NucleusSourceCodeModule.hpp>
#include <NucleusReactRuntime/NucleusAppStateModule.hpp>
#include <NucleusReactRuntime/ReactRuntimeHost.hpp>
#include <NucleusReactRuntime/ReactRuntimeHostFacade.hpp>
#include <NucleusReactRuntime/RuntimeJSCallInvoker.hpp>
#include <NucleusReactRuntime/TextLayoutManager.hpp>
#include <NucleusReactRuntime/TurboModuleRegistry.hpp>

#include <hermes/hermes.h>
#include <folly/dynamic.h>
#include <folly/json.h>
#include <jsi/JSIDynamic.h>
#include <jsi/jsi-inl.h>
#include <jsi/jsi.h>
#include <react/renderer/componentregistry/ComponentDescriptorProvider.h>
#include <react/renderer/componentregistry/ComponentDescriptorProviderRegistry.h>
#include <react/renderer/componentregistry/native/NativeComponentRegistryBinding.h>
#include <react/renderer/components/image/ImageComponentDescriptor.h>
#include <react/renderer/components/image/ImageProps.h>
#include <react/renderer/components/root/RootComponentDescriptor.h>
#include <react/renderer/components/scrollview/ScrollViewComponentDescriptor.h>
#include <react/renderer/components/text/ParagraphComponentDescriptor.h>
#include <react/renderer/components/text/ParagraphState.h>
#include <react/renderer/components/text/RawTextProps.h>
#include <react/renderer/components/text/RawTextComponentDescriptor.h>
#include <react/renderer/components/text/TextComponentDescriptor.h>
#include <react/renderer/components/view/LayoutConformanceComponentDescriptor.h>
#include <react/renderer/components/view/BaseViewProps.h>
#include <react/renderer/components/view/ConcreteViewShadowNode.h>
#include <react/renderer/components/view/ViewEventEmitter.h>
#include <react/renderer/components/view/ViewComponentDescriptor.h>
#include <react/renderer/components/view/ViewShadowNode.h>
#include <react/renderer/textlayoutmanager/TextLayoutManager.h>
#include <react/renderer/core/EventBeat.h>
#include <react/renderer/core/ConcreteState.h>
#include <react/renderer/core/ShadowNode.h>
#include <react/renderer/mounting/MountingCoordinator.h>
#include <react/coremodules/AppStateModule.h>
#include <react/logging/NativeExceptionsManager.h>
#include <react/nativemodule/webperformance/NativePerformance.h>
#include <react/nativemodule/core/ReactCommon/TurboModuleBinding.h>
#include <react/nativemodule/dom/NativeDOM.h>
#include <react/nativemodule/featureflags/NativeReactNativeFeatureFlags.h>
#include <react/nativemodule/microtasks/NativeMicrotasks.h>
#include <react/runtime/nativeviewconfig/LegacyUIManagerConstantsProviderBinding.h>
#include <react/renderer/runtimescheduler/RuntimeScheduler.h>
#include <react/renderer/runtimescheduler/RuntimeSchedulerBinding.h>
#include <react/renderer/scheduler/Scheduler.h>
#include <react/renderer/scheduler/SchedulerDelegate.h>
#include <react/renderer/scheduler/SchedulerToolbox.h>
#include <react/renderer/scheduler/SurfaceHandler.h>
#include <react/renderer/uimanager/AppRegistryBinding.h>
#include <react/renderer/uimanager/UIManagerBinding.h>
#include <react/renderer/graphics/Color.h>
#include <react/runtime/TimerManager.h>
#include <react/utils/ContextContainer.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <exception>
#include <fstream>
#include <iterator>
#include <limits>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

namespace {

void logRuntimeHost(const char *message) {
  if (std::getenv("NUCLEUS_RN_HOST_DEBUG") != nullptr) {
    std::fprintf(stderr, "rn-host: %s\n", message);
    std::fflush(stderr);
    return;
  }
#if !defined(NUCLEUS_RN_HOST_DEBUG)
  (void)message;
#else
  std::fprintf(stderr, "rn-host: %s\n", message);
  std::fflush(stderr);
#endif
}

template <typename... Args>
void logRuntimeHostf(const char *format, Args... args) {
  if (std::getenv("NUCLEUS_RN_HOST_DEBUG") != nullptr) {
    std::fprintf(stderr, "rn-host: ");
    std::fprintf(stderr, format, args...);
    std::fprintf(stderr, "\n");
    std::fflush(stderr);
    return;
  }
#if defined(NUCLEUS_RN_HOST_DEBUG)
  std::fprintf(stderr, "rn-host: ");
  std::fprintf(stderr, format, args...);
  std::fprintf(stderr, "\n");
  std::fflush(stderr);
#else
  (void)format;
  ((void)args, ...);
#endif
}

template <typename Fn>
nucleus::react::RuntimeHostResult invokeRuntimeHostEntry(Fn &&fn) {
  try {
    fn();
    return {};
  } catch (const std::exception &exception) {
    return nucleus::react::RuntimeHostResult{.succeeded = false, .error = exception.what()};
  } catch (...) {
    return nucleus::react::RuntimeHostResult{
        .succeeded = false, .error = "unknown C++ exception"};
  }
}

template <typename Fn>
nucleus::react::RuntimeHostResult invokeRuntimeHostStringEntry(Fn &&fn) {
  try {
    return nucleus::react::RuntimeHostResult{.stringValue = fn()};
  } catch (const std::exception &exception) {
    return nucleus::react::RuntimeHostResult{.succeeded = false, .error = exception.what()};
  } catch (...) {
    return nucleus::react::RuntimeHostResult{
        .succeeded = false, .error = "unknown C++ exception"};
  }
}

template <typename Fn>
nucleus::react::RuntimeHostResult invokeRuntimeHostUnsignedEntry(Fn &&fn) {
  try {
    return nucleus::react::RuntimeHostResult{.unsignedValue = fn()};
  } catch (const std::exception &exception) {
    return nucleus::react::RuntimeHostResult{.succeeded = false, .error = exception.what()};
  } catch (...) {
    return nucleus::react::RuntimeHostResult{
        .succeeded = false, .error = "unknown C++ exception"};
  }
}

} // namespace

namespace facebook::react {

const char RCTViewComponentName[] = "RCTView";

class RCTViewShadowNode final
    : public ConcreteViewShadowNode<RCTViewComponentName, ViewShadowNodeProps, ViewEventEmitter> {
 public:
  RCTViewShadowNode(
      const ShadowNodeFragment &fragment,
      const ShadowNodeFamily::Shared &family,
      ShadowNodeTraits traits)
      : ConcreteViewShadowNode(fragment, family, traits) {}

  RCTViewShadowNode(
      const ShadowNode &sourceShadowNode,
      const ShadowNodeFragment &fragment)
      : ConcreteViewShadowNode(sourceShadowNode, fragment) {}
};

class RCTViewComponentDescriptor final
    : public ConcreteComponentDescriptor<RCTViewShadowNode> {
 public:
  using ConcreteShadowNode = RCTViewShadowNode;

  explicit RCTViewComponentDescriptor(
      const ComponentDescriptorParameters &parameters)
      : ConcreteComponentDescriptor(parameters) {}
};

} // namespace facebook::react

namespace {

class FileBuffer final : public facebook::jsi::Buffer {
 public:
  explicit FileBuffer(const char *path) {
    logRuntimeHostf("FileBuffer open path=%s", path);
    std::ifstream in(path, std::ios::binary);
    if (!in) {
      throw std::runtime_error(std::string("failed to open bytecode file: ") + path);
    }
    data_ = std::vector<std::uint8_t>(
        std::istreambuf_iterator<char>(in),
        std::istreambuf_iterator<char>());
    logRuntimeHostf(
        "FileBuffer loaded size=%zu first4=%02x %02x %02x %02x",
        data_.size(),
        data_.size() > 0 ? data_[0] : 0,
        data_.size() > 1 ? data_[1] : 0,
        data_.size() > 2 ? data_[2] : 0,
        data_.size() > 3 ? data_[3] : 0);
  }

  std::size_t size() const override {
    return data_.size();
  }

  const std::uint8_t *data() const override {
    return data_.data();
  }

 private:
  std::vector<std::uint8_t> data_;
};

} // namespace

namespace nucleus::react {

class ReactRuntimeHostImpl final {
 public:
  ReactRuntimeHostImpl()
      : runtime_(facebook::hermes::makeHermesRuntime(
            ::hermes::vm::RuntimeConfig::Builder()
                .withMicrotaskQueue(true)
                .withIntl(true)
                .build())) {
    logRuntimeHostf("ReactRuntimeHostImpl constructed this=%p runtime=%p", this, runtime_.get());
    if (runtime_ == nullptr) {
      throw std::runtime_error("failed to create Hermes runtime");
    }
    jsThreadId_ = std::this_thread::get_id();
    jsInvoker_ = std::make_shared<RuntimeJSCallInvoker>(*runtime_, jsThreadId_);
    deviceEventEmitter_ =
        std::make_shared<DeviceEventEmitter>(*runtime_, jsInvoker_);
    // Mutable backing store for `NucleusDeviceInfoModule::getConstants`.
    // Swift updates it via `setDisplayMetrics`; the TurboModule reads
    // it on every JS-side `Dimensions.get()` lookup.
    displayMetricsState_ = std::make_shared<DisplayMetricsState>();
    sourceCodeState_ = std::make_shared<SourceCodeState>();
    appStateState_ = std::make_shared<AppStateState>();
    // TimerManager owns the JSI globals (setTimeout, setInterval,
    // requestAnimationFrame, clearTimeout, clearInterval,
    // cancelAnimationFrame). Timer fires arrive on the registry's worker
    // thread and route back to the JS thread via `jsInvoker_`. Each
    // dispatched callback drains microtasks so React's commit phase
    // observes Promise resolutions queued by user code.
    auto timerRegistry = std::make_unique<NucleusPlatformTimerRegistry>(
        [this](uint32_t id) {
          if (timerManager_ != nullptr) {
            timerManager_->callTimer(static_cast<facebook::react::TimerHandle>(id));
          }
        });
    timerManager_ = std::make_unique<facebook::react::TimerManager>(
        std::move(timerRegistry));
    timerManager_->setRuntimeExecutor(
        [invoker = jsInvoker_](
            std::function<void(facebook::jsi::Runtime &)> &&fn) {
          invoker->invokeAsync(
              [fn = std::move(fn)](facebook::jsi::Runtime &rt) mutable {
                fn(rt);
                rt.drainMicrotasks();
              });
        });
    logRuntimeHost("installConsole begin");
    installConsole();
    logRuntimeHost("installConsole end");
    logRuntimeHost("installHostRuntimeBindings begin");
    installHostRuntimeBindings();
    logRuntimeHost("installHostRuntimeBindings end");
  }

  ~ReactRuntimeHostImpl() {
    // Stop the timer worker before any other shutdown so no more fires
    // race against `jsInvoker_`'s queue or `runtime_`'s teardown. The
    // timer map still holds `jsi::Function`s; those destruct when
    // `timerManager_` itself destructs, which happens while `runtime_`
    // is still alive (`timerManager_` is declared after `runtime_` so
    // it tears down first).
    if (timerManager_ != nullptr) {
      timerManager_->quit();
    }
    if (deviceEventEmitter_ != nullptr) {
      deviceEventEmitter_->shutdown();
    }
    if (jsInvoker_ != nullptr) {
      jsInvoker_->shutdown();
    }
    if (swiftTextLayoutHandle_ != nullptr) {
      nucleus::react::releaseSwiftTextLayoutManagerHandle(swiftTextLayoutHandle_);
      swiftTextLayoutHandle_ = nullptr;
    }
  }

  std::shared_ptr<RuntimeJSCallInvoker> jsInvoker() const { return jsInvoker_; }
  std::shared_ptr<DeviceEventEmitter> deviceEventEmitter() const {
    return deviceEventEmitter_;
  }
  std::thread::id jsThreadId() const { return jsThreadId_; }

  std::size_t drainPendingJSCalls() {
    if (jsInvoker_ == nullptr) {
      return 0;
    }
    return jsInvoker_->drainPending();
  }

  void evaluateJavaScriptSource(const char *source, const char *sourceUrl) {
    setSourceURL(sourceUrl == nullptr ? "" : sourceUrl);
    auto buffer = std::make_shared<facebook::jsi::StringBuffer>(
        source == nullptr ? std::string() : std::string(source));
    runtime_->evaluateJavaScript(
        buffer, sourceUrl == nullptr ? "" : sourceUrl);
    runtime_->drainMicrotasks();
  }

  std::string evaluateJavaScriptForString(const char *source, const char *sourceUrl) {
    auto buffer = std::make_shared<facebook::jsi::StringBuffer>(
        source == nullptr ? std::string() : std::string(source));
    auto value = runtime_->evaluateJavaScript(
        buffer, sourceUrl == nullptr ? "" : sourceUrl);
    runtime_->drainMicrotasks();
    if (value.isString()) {
      return value.getString(*runtime_).utf8(*runtime_);
    }
    if (value.isUndefined() || value.isNull()) {
      return {};
    }
    return value.toString(*runtime_).utf8(*runtime_);
  }

  void emitDeviceEvent(const char *name, const char *payloadJson) {
    if (deviceEventEmitter_ == nullptr || name == nullptr) {
      return;
    }
    folly::dynamic payload = nullptr;
    if (payloadJson != nullptr && payloadJson[0] != '\0') {
      try {
        payload = folly::parseJson(payloadJson);
      } catch (const std::exception &exception) {
        logRuntimeHostf(
            "emitDeviceEvent JSON parse failed name=%s error=%s",
            name,
            exception.what());
        return;
      }
    }
    deviceEventEmitter_->emit(std::string(name), std::move(payload));
  }

  void setCommandHandler(
      void (*callback)(void *ctx, const char *command, const char *argsJson),
      void *context,
      void (*release)(void *ctx)) {
    commandHandler_->set(callback, context, release);
  }

  void setAppState(const char *state) {
    const std::string next = state == nullptr ? "active" : state;
    if (next != "active" && next != "inactive" && next != "background") {
      throw std::invalid_argument("app state must be active, inactive, or background");
    }
    {
      std::lock_guard<std::mutex> lock(appStateState_->mutex);
      if (appStateState_->value == next) return;
      appStateState_->value = next;
    }
    const auto payload = "{\"app_state\":\"" + next + "\"}";
    emitDeviceEvent("appStateDidChange", payload.c_str());
  }

  void evaluateBytecode(const char *path) {
    setSourceURL(path == nullptr ? "" : path);
    logRuntimeHostf("evaluateBytecode begin this=%p runtime=%p path=%s", this, runtime_.get(), path);
    auto bytecode = std::make_shared<FileBuffer>(path);
    logRuntimeHostf("evaluateJavaScript begin buffer=%p size=%zu", bytecode.get(), bytecode->size());
    runtime_->evaluateJavaScript(bytecode, path);
    runtime_->drainMicrotasks();
    logRuntimeHost("evaluateJavaScript end");
  }

  void installFabricRuntime() {
    if (fabric_ != nullptr) {
      logRuntimeHost("installFabricRuntime skipped existing");
      return;
    }
    if (swiftTextLayoutHandle_ == nullptr) {
      throw std::runtime_error(
          "installFabricRuntime requires setSwiftTextLayoutManagerHandle first");
    }
    logRuntimeHostf("installFabricRuntime begin this=%p runtime=%p", this, runtime_.get());
    void *textLayoutHandle = swiftTextLayoutHandle_;
    swiftTextLayoutHandle_ = nullptr;
    fabric_ = std::make_unique<FabricRuntime>(
        *runtime_, jsThreadId_, textLayoutHandle);
    if (mountingObserver_ != nullptr) {
      fabric_->setMountingObserver(mountingObserver_);
    }
    logRuntimeHostf("installFabricRuntime end fabric=%p", fabric_.get());
  }

  void registerSurface(int surfaceId) {
    if (fabric_ == nullptr) {
      throw std::runtime_error("Fabric runtime is not installed");
    }
    fabric_->registerSurface(surfaceId);
  }

  void configureSurface(int surfaceId, double width, double height) {
    if (fabric_ == nullptr) {
      throw std::runtime_error("Fabric runtime is not installed");
    }
    fabric_->configureSurface(surfaceId, width, height);
  }

  void stopSurface(int surfaceId) {
    if (fabric_ == nullptr) {
      return;
    }
    fabric_->stopSurface(surfaceId);
  }

  void runApplication(int surfaceId, const char *appKey) {
    if (fabric_ == nullptr) {
      throw std::runtime_error("Fabric runtime is not installed");
    }
    facebook::react::AppRegistryBinding::startSurface(
        *runtime_,
        static_cast<facebook::react::SurfaceId>(surfaceId),
        appKey == nullptr ? "" : appKey,
        folly::dynamic::object(),
        facebook::react::DisplayMode::Visible);
    runtime_->drainMicrotasks();
  }

  std::size_t surfaceCount() const {
    if (fabric_ == nullptr) {
      return 0;
    }
    return fabric_->surfaceCount();
  }

  nucleus::react::FabricMountReport readFabricMountReport() const {
    if (fabric_ == nullptr) {
      return {};
    }
    return fabric_->report();
  }

  void setMountingObserver(std::shared_ptr<nucleus::react::MountingObserver> observer) {
    mountingObserver_ = std::move(observer);
    if (fabric_ != nullptr) {
      fabric_->setMountingObserver(mountingObserver_);
    }
  }

  void setDisplayMetrics(double width, double height, double scale, double fontScale) {
    if (displayMetricsState_ == nullptr) {
      return;
    }
    std::lock_guard<std::mutex> lock(displayMetricsState_->mutex);
    displayMetricsState_->windowWidth = width;
    displayMetricsState_->windowHeight = height;
    displayMetricsState_->scale = scale > 0.0 ? scale : 1.0;
    displayMetricsState_->fontScale = fontScale > 0.0 ? fontScale : 1.0;
  }

  void setSwiftTextLayoutManagerHandle(void *swiftHandlerRetained) {
    if (fabric_ != nullptr) {
      // Fabric already consumed any prior handle and built its
      // `TextLayoutManager` from it. Re-keying the context container
      // mid-flight isn't supported; drop the late handle to keep
      // ownership balanced.
      nucleus::react::releaseSwiftTextLayoutManagerHandle(swiftHandlerRetained);
      return;
    }
    if (swiftTextLayoutHandle_ != nullptr) {
      nucleus::react::releaseSwiftTextLayoutManagerHandle(swiftTextLayoutHandle_);
    }
    swiftTextLayoutHandle_ = swiftHandlerRetained;
  }

 private:
  class ConstantsTurboModule final : public facebook::react::TurboModule {
   public:
    using ConstantsFactory = std::function<facebook::jsi::Object(facebook::jsi::Runtime &)>;

    ConstantsTurboModule(
        std::string name,
        std::shared_ptr<facebook::react::CallInvoker> jsInvoker,
        ConstantsFactory constantsFactory)
        : facebook::react::TurboModule(std::move(name), std::move(jsInvoker)),
          constantsFactory_(std::move(constantsFactory)) {}

    facebook::jsi::Value get(
        facebook::jsi::Runtime &runtime,
        const facebook::jsi::PropNameID &propName) override {
      const auto name = propName.utf8(runtime);
      if (name == "getConstants") {
        return facebook::jsi::Function::createFromHostFunction(
            runtime,
            propName,
            0,
            [factory = constantsFactory_](
                facebook::jsi::Runtime &runtime,
                const facebook::jsi::Value &,
                const facebook::jsi::Value *,
                std::size_t) -> facebook::jsi::Value {
              return factory(runtime);
            });
      }
      return facebook::jsi::Value::undefined();
    }

   private:
    ConstantsFactory constantsFactory_;
  };

  class ImmediateEventBeat final : public facebook::react::EventBeat {
   public:
    ImmediateEventBeat(
        std::shared_ptr<OwnerBox> ownerBox,
        facebook::react::RuntimeScheduler &runtimeScheduler,
        std::thread::id jsThreadId)
        : EventBeat(std::move(ownerBox), runtimeScheduler),
          jsThreadId_(jsThreadId) {}

    void request() const override {
      assertOnJSThread("request");
      EventBeat::request();
      if (isInducing_) {
        return;
      }
      isInducing_ = true;
      induce();
      isInducing_ = false;
    }

    void requestSynchronous() const override {
      assertOnJSThread("requestSynchronous");
      EventBeat::requestSynchronous();
      if (isInducing_) {
        return;
      }
      isInducing_ = true;
      induce();
      isInducing_ = false;
    }

   private:
    void assertOnJSThread(const char *context) const {
      if (std::this_thread::get_id() == jsThreadId_) {
        return;
      }
      throw std::runtime_error(
          std::string("ImmediateEventBeat::") + context +
          " called from non-JS thread");
    }

    std::thread::id jsThreadId_;
    mutable bool isInducing_{false};
  };

  class NucleusMountingObserver final {
   public:
    NucleusMountingObserver() = default;

    nucleus::react::FabricMountReport report() const {
      return {
          static_cast<unsigned int>(transactionCount_),
          static_cast<unsigned int>(eventCount_),
      };
    }

    void setObserver(std::shared_ptr<nucleus::react::MountingObserver> observer) {
      observer_ = std::move(observer);
    }

    void captureTransaction(
        const std::shared_ptr<const facebook::react::MountingCoordinator> &mountingCoordinator) {
      const auto surfaceId = mountingCoordinator->getSurfaceId();
      logRuntimeHostf(
          "captureTransaction begin coordinator=%p surface=%d",
          mountingCoordinator.get(),
          surfaceId);
      auto transaction = mountingCoordinator->pullTransaction(false);
      if (!transaction.has_value()) {
        logRuntimeHost("captureTransaction no transaction");
        return;
      }
      const auto &mutations = transaction->getMutations();
      logRuntimeHostf(
          "captureTransaction pulled mutations=%zu",
          mutations.size());
      transactionCount_ += 1;
      std::size_t mutationIndex = 0;
      for (const auto &mutation : mutations) {
        const auto &shadowView = activeShadowView(mutation);
        logRuntimeHostf(
            "captureTransaction mutation[%zu] type=%s tag=%d parent=%d component=%s props=%p",
            mutationIndex,
            typeName(mutation.type),
            tagOrMissing(shadowView),
            mutation.parentTag,
            shadowView.componentName == nullptr ? "<null>" : shadowView.componentName,
            shadowView.props.get());
        emitEvent(surfaceId, mutation);
        eventCount_ += 1;
        mutationIndex += 1;
      }
      if (observer_ != nullptr) {
        observer_->didFinishTransaction(static_cast<std::int32_t>(surfaceId));
      }
      logRuntimeHostf(
          "captureTransaction end transactions=%zu events=%zu",
          transactionCount_,
          eventCount_);
    }

   private:
    enum class EventType : int {
      Create = 1,
      Delete = 2,
      Insert = 3,
      Remove = 4,
      Update = 5,
    };

    enum class TextAlignmentValue : int {
      Natural = 0,
      Leading = 1,
      Center = 2,
      Trailing = 3,
    };

    enum class LineBreakModeValue : int {
      Clipping = 0,
      TruncatingTail = 1,
      WordWrapping = 2,
    };

    struct TextPayload final {
      bool hasAttributes{false};
      std::string fontFamily;
      float fontSize{14.0f};
      int fontWeight{400};
      int fontSlant{0};
      bool hasTextColor{false};
      float textRed{1.0f};
      float textGreen{1.0f};
      float textBlue{1.0f};
      float textAlpha{1.0f};
      double lineHeight{0.0};
      TextAlignmentValue alignment{TextAlignmentValue::Natural};
      int maximumNumberOfLines{1};
      LineBreakModeValue lineBreakMode{LineBreakModeValue::Clipping};
    };

    static const facebook::react::ShadowView &activeShadowView(
        const facebook::react::ShadowViewMutation &mutation) {
      switch (mutation.type) {
        case facebook::react::ShadowViewMutation::Delete:
        case facebook::react::ShadowViewMutation::Remove:
          return mutation.oldChildShadowView;
        case facebook::react::ShadowViewMutation::Create:
        case facebook::react::ShadowViewMutation::Insert:
        case facebook::react::ShadowViewMutation::Update:
          return mutation.newChildShadowView;
      }
    }

    static EventType eventType(facebook::react::ShadowViewMutation::Type type) {
      switch (type) {
        case facebook::react::ShadowViewMutation::Create:
          return EventType::Create;
        case facebook::react::ShadowViewMutation::Delete:
          return EventType::Delete;
        case facebook::react::ShadowViewMutation::Insert:
          return EventType::Insert;
        case facebook::react::ShadowViewMutation::Remove:
          return EventType::Remove;
        case facebook::react::ShadowViewMutation::Update:
          return EventType::Update;
      }
    }

    static const char *typeName(facebook::react::ShadowViewMutation::Type type) {
      switch (eventType(type)) {
        case EventType::Create:
          return "Create";
        case EventType::Delete:
          return "Delete";
        case EventType::Insert:
          return "Insert";
        case EventType::Remove:
          return "Remove";
        case EventType::Update:
          return "Update";
      }
    }

    static int tagOrMissing(const facebook::react::ShadowView &shadowView) {
      return shadowView.componentHandle == 0 ? -1 : shadowView.tag;
    }

    static const facebook::react::BaseViewProps *viewProps(
        const facebook::react::ShadowView &shadowView) {
      if (shadowView.props == nullptr || shadowView.componentName == nullptr) {
        return nullptr;
      }
      const std::string_view componentName(shadowView.componentName);
      if (componentName != "View" && componentName != "RCTView") {
        return nullptr;
      }
      return static_cast<const facebook::react::BaseViewProps *>(shadowView.props.get());
    }

    static const facebook::react::ImageProps *imageProps(
        const facebook::react::ShadowView &shadowView) {
      if (shadowView.props == nullptr || shadowView.componentName == nullptr) {
        return nullptr;
      }
      const std::string_view componentName(shadowView.componentName);
      if (componentName != "Image" && componentName != "RCTImage") {
        return nullptr;
      }
      return static_cast<const facebook::react::ImageProps *>(shadowView.props.get());
    }

    static const facebook::react::RawTextProps *rawTextProps(
        const facebook::react::ShadowView &shadowView) {
      if (shadowView.props == nullptr || shadowView.componentName == nullptr) {
        return nullptr;
      }
      const std::string_view componentName(shadowView.componentName);
      if (componentName != "RawText" && componentName != "RCTRawText") {
        return nullptr;
      }
      return static_cast<const facebook::react::RawTextProps *>(shadowView.props.get());
    }

    static std::string textContent(const facebook::react::ShadowView &shadowView) {
      if (const auto *props = rawTextProps(shadowView)) {
        return props->text;
      }
      if (shadowView.state == nullptr || shadowView.componentName == nullptr) {
        return "";
      }
      const std::string_view componentName(shadowView.componentName);
      if (componentName != "Paragraph" && componentName != "RCTParagraph") {
        return "";
      }
      auto paragraphState =
          std::static_pointer_cast<const facebook::react::ConcreteState<facebook::react::ParagraphState>>(
              shadowView.state);
      return paragraphState->getData().attributedString.getString();
    }

    static const facebook::react::ParagraphState *paragraphData(
        const facebook::react::ShadowView &shadowView) {
      if (shadowView.state == nullptr || shadowView.componentName == nullptr) {
        return nullptr;
      }
      const std::string_view componentName(shadowView.componentName);
      if (componentName != "Paragraph" && componentName != "RCTParagraph") {
        return nullptr;
      }
      auto paragraphState =
          std::static_pointer_cast<const facebook::react::ConcreteState<facebook::react::ParagraphState>>(
              shadowView.state);
      return &paragraphState->getData();
    }

    static TextAlignmentValue textAlignmentValue(
        const std::optional<facebook::react::TextAlignment> &alignment) {
      if (!alignment.has_value()) {
        return TextAlignmentValue::Natural;
      }
      switch (*alignment) {
        case facebook::react::TextAlignment::Center:
          return TextAlignmentValue::Center;
        case facebook::react::TextAlignment::Right:
          return TextAlignmentValue::Trailing;
        case facebook::react::TextAlignment::Left:
          return TextAlignmentValue::Leading;
        case facebook::react::TextAlignment::Natural:
        case facebook::react::TextAlignment::Justified:
        default:
          return TextAlignmentValue::Natural;
      }
    }

    static LineBreakModeValue lineBreakModeValue(
        const std::optional<facebook::react::LineBreakMode> &lineBreakMode,
        facebook::react::EllipsizeMode ellipsizeMode) {
      if (lineBreakMode.has_value()) {
        switch (*lineBreakMode) {
          case facebook::react::LineBreakMode::Tail:
            return LineBreakModeValue::TruncatingTail;
          case facebook::react::LineBreakMode::Word:
          case facebook::react::LineBreakMode::Char:
            return LineBreakModeValue::WordWrapping;
          case facebook::react::LineBreakMode::Clip:
          case facebook::react::LineBreakMode::Head:
          case facebook::react::LineBreakMode::Middle:
          default:
            return LineBreakModeValue::Clipping;
        }
      }
      return ellipsizeMode == facebook::react::EllipsizeMode::Tail
          ? LineBreakModeValue::TruncatingTail
          : LineBreakModeValue::Clipping;
    }

    static TextPayload textPayload(const facebook::react::ShadowView &shadowView) {
      TextPayload payload;
      const auto *data = paragraphData(shadowView);
      if (data == nullptr) {
        return payload;
      }

      payload.hasAttributes = true;
      payload.maximumNumberOfLines = data->paragraphAttributes.maximumNumberOfLines > 0
          ? data->paragraphAttributes.maximumNumberOfLines
          : 1;
      payload.lineBreakMode = lineBreakModeValue(std::nullopt, data->paragraphAttributes.ellipsizeMode);

      const facebook::react::TextAttributes *attributes = &data->attributedString.getBaseTextAttributes();
      for (const auto &fragment : data->attributedString.getFragments()) {
        if (!fragment.isAttachment() && !fragment.string.empty()) {
          attributes = &fragment.textAttributes;
          break;
        }
      }

      payload.fontFamily = attributes->fontFamily;
      if (!std::isnan(attributes->fontSize) && attributes->fontSize > 0.0f) {
        payload.fontSize = attributes->fontSize;
      }
      if (attributes->fontWeight.has_value()) {
        payload.fontWeight = static_cast<int>(*attributes->fontWeight);
      }
      if (attributes->fontStyle.has_value()) {
        switch (*attributes->fontStyle) {
          case facebook::react::FontStyle::Italic:
            payload.fontSlant = 1;
            break;
          case facebook::react::FontStyle::Oblique:
            payload.fontSlant = 2;
            break;
          case facebook::react::FontStyle::Normal:
          default:
            payload.fontSlant = 0;
            break;
        }
      }
      if (attributes->foregroundColor) {
        const auto color = facebook::react::colorComponentsFromColor(attributes->foregroundColor);
        payload.hasTextColor = true;
        payload.textRed = color.red;
        payload.textGreen = color.green;
        payload.textBlue = color.blue;
        payload.textAlpha = color.alpha;
      }
      if (!std::isnan(attributes->lineHeight) && attributes->lineHeight > 0.0f) {
        payload.lineHeight = attributes->lineHeight;
      }
      payload.alignment = textAlignmentValue(attributes->alignment);
      payload.lineBreakMode = lineBreakModeValue(
          attributes->lineBreakMode,
          data->paragraphAttributes.ellipsizeMode);
      return payload;
    }

    static std::optional<facebook::react::ColorComponents> backgroundColor(
        const facebook::react::ShadowView &shadowView) {
      const auto *props = viewProps(shadowView);
      if (props == nullptr) {
        return std::nullopt;
      }
      if (!facebook::react::isColorMeaningful(props->backgroundColor)) {
        return std::nullopt;
      }
      return facebook::react::colorComponentsFromColor(props->backgroundColor);
    }

    static int layoutDirectionValue(facebook::react::LayoutDirection direction) {
      switch (direction) {
        case facebook::react::LayoutDirection::Undefined:
          return 0;
        case facebook::react::LayoutDirection::LeftToRight:
          return 1;
        case facebook::react::LayoutDirection::RightToLeft:
          return 2;
      }
    }

    void emitEvent(
        facebook::react::SurfaceId surfaceId,
        const facebook::react::ShadowViewMutation &mutation) {
      if (observer_ == nullptr) {
        return;
      }
      logRuntimeHostf(
          "emitEvent begin type=%s parent=%d",
          typeName(mutation.type),
          mutation.parentTag);
      const auto &shadowView = activeShadowView(mutation);
      const auto *props = viewProps(shadowView);
      logRuntimeHostf(
          "emitEvent active tag=%d component=%s props=%p",
          tagOrMissing(shadowView),
          shadowView.componentName == nullptr ? "<null>" : shadowView.componentName,
          shadowView.props.get());
      const auto &frame = shadowView.layoutMetrics.frame;
      const auto color = backgroundColor(shadowView);
      auto text = textContent(shadowView);
      auto textAttributes = textPayload(shadowView);
      logRuntimeHostf(
          "emitEvent payload type=%s tag=%d component=%s frame=(%.1f,%.1f %.1fx%.1f) background=%d text_len=%zu",
          typeName(mutation.type),
          tagOrMissing(shadowView),
          shadowView.componentName == nullptr ? "" : shadowView.componentName,
          frame.origin.x,
          frame.origin.y,
          frame.size.width,
          frame.size.height,
          color.has_value() ? 1 : 0,
          text.size());
      observer_->didMount(buildMountMutation(
          surfaceId, mutation, shadowView, props, frame, color, text, textAttributes));
      logRuntimeHostf(
          "emitEvent end type=%s tag=%d component=%s",
          typeName(mutation.type),
          tagOrMissing(shadowView),
          shadowView.componentName == nullptr ? "" : shadowView.componentName);
    }

    // Packs the per-mutation data into the typed `MountMutation` shape
    // that `MountingObserver::didMount` consumes. Takes the same
    // already-computed inputs as the legacy callback so both paths
    // see identical data.
    static nucleus::react::MountMutation buildMountMutation(
        facebook::react::SurfaceId surfaceId,
        const facebook::react::ShadowViewMutation &mutation,
        const facebook::react::ShadowView &shadowView,
        const facebook::react::BaseViewProps *props,
        const facebook::react::Rect &frame,
        const std::optional<facebook::react::ColorComponents> &color,
        const std::string &text,
        const TextPayload &textAttributes) {
      nucleus::react::MountMutation out{};
      out.surfaceId = static_cast<std::int32_t>(surfaceId);
      out.type = mountEventType(eventType(mutation.type));
      out.tag = tagOrMissing(shadowView);
      out.parentTag = mutation.parentTag;
      out.oldTag = tagOrMissing(mutation.oldChildShadowView);
      out.newTag = tagOrMissing(mutation.newChildShadowView);
      out.index = mutation.index;
      out.componentName = shadowView.componentName == nullptr
          ? std::string{}
          : std::string{shadowView.componentName};
      if (props != nullptr && !props->nativeId.empty()) {
        out.nativeId = props->nativeId;
      }
      out.frame = nucleus::react::Rect{
          .x = frame.origin.x,
          .y = frame.origin.y,
          .width = frame.size.width,
          .height = frame.size.height,
      };
      if (color.has_value()) {
        out.backgroundColor = nucleus::react::Color{
            .red = color->red,
            .green = color->green,
            .blue = color->blue,
            .alpha = color->alpha,
        };
      }
      out.layoutDirection = mountLayoutDirection(shadowView.layoutMetrics.layoutDirection);
      if (!text.empty()) {
        out.text = text;
      }
      if (textAttributes.hasAttributes) {
        nucleus::react::TextAttributes attrs{};
        attrs.fontFamily = textAttributes.fontFamily;
        attrs.fontSize = textAttributes.fontSize;
        attrs.fontWeight = textAttributes.fontWeight;
        attrs.fontSlant = textAttributes.fontSlant;
        if (textAttributes.hasTextColor) {
          attrs.textColor = nucleus::react::Color{
              .red = textAttributes.textRed,
              .green = textAttributes.textGreen,
              .blue = textAttributes.textBlue,
              .alpha = textAttributes.textAlpha,
          };
        }
        attrs.lineHeight = textAttributes.lineHeight;
        attrs.alignment = static_cast<nucleus::react::TextAlignment>(
            static_cast<int>(textAttributes.alignment));
        attrs.maximumNumberOfLines = textAttributes.maximumNumberOfLines;
        attrs.lineBreakMode = static_cast<nucleus::react::LineBreakMode>(
            static_cast<int>(textAttributes.lineBreakMode));
        out.textAttributes = std::move(attrs);
      }
      if (const auto *imgProps = imageProps(shadowView);
          imgProps != nullptr && !imgProps->sources.empty() &&
          !imgProps->sources.front().uri.empty()) {
        out.imageSource = imgProps->sources.front().uri;
      }
      return out;
    }

    static nucleus::react::MountEventType mountEventType(EventType type) {
      switch (type) {
        case EventType::Create:
          return nucleus::react::MountEventType::Create;
        case EventType::Delete:
          return nucleus::react::MountEventType::Delete;
        case EventType::Insert:
          return nucleus::react::MountEventType::Insert;
        case EventType::Remove:
          return nucleus::react::MountEventType::Remove;
        case EventType::Update:
          return nucleus::react::MountEventType::Update;
      }
    }

    static nucleus::react::LayoutDirection mountLayoutDirection(
        facebook::react::LayoutDirection direction) {
      switch (direction) {
        case facebook::react::LayoutDirection::Undefined:
          return nucleus::react::LayoutDirection::Undefined;
        case facebook::react::LayoutDirection::LeftToRight:
          return nucleus::react::LayoutDirection::LeftToRight;
        case facebook::react::LayoutDirection::RightToLeft:
          return nucleus::react::LayoutDirection::RightToLeft;
      }
    }

    std::size_t transactionCount_{0};
    std::size_t eventCount_{0};
    std::shared_ptr<nucleus::react::MountingObserver> observer_;
  };

  class FabricSchedulerDelegate final : public facebook::react::SchedulerDelegate {
   public:
    explicit FabricSchedulerDelegate(NucleusMountingObserver &observer)
        : observer_(observer) {}

    void schedulerDidFinishTransaction(
        const std::shared_ptr<const facebook::react::MountingCoordinator> &mountingCoordinator) override {
      logRuntimeHostf(
          "schedulerDidFinishTransaction begin coordinator=%p",
          mountingCoordinator.get());
      observer_.captureTransaction(mountingCoordinator);
      logRuntimeHost("schedulerDidFinishTransaction end");
    }

    void schedulerShouldRenderTransactions(
        const std::shared_ptr<const facebook::react::MountingCoordinator> &mountingCoordinator) override {
      logRuntimeHostf(
          "schedulerShouldRenderTransactions coordinator=%p",
          mountingCoordinator.get());
    }

    void schedulerShouldMergeReactRevision(facebook::react::SurfaceId) override {}

    void schedulerDidRequestPreliminaryViewAllocation(
        const facebook::react::ShadowNode &) override {}

    void schedulerDidDispatchCommand(
        const facebook::react::ShadowView &,
        const std::string &,
        const folly::dynamic &) override {}

    void schedulerDidSendAccessibilityEvent(
        const facebook::react::ShadowView &,
        const std::string &) override {}

    void schedulerDidSetIsJSResponder(
        const facebook::react::ShadowView &,
        bool,
        bool) override {}

    void schedulerShouldSynchronouslyUpdateViewOnUIThread(
        facebook::react::Tag,
        const folly::dynamic &) override {}

    void schedulerDidUpdateShadowTree(
        const std::unordered_map<facebook::react::Tag, folly::dynamic> &) override {}

    void schedulerDidCaptureViewSnapshot(
        facebook::react::Tag,
        facebook::react::SurfaceId) override {}

    void schedulerDidSetViewSnapshot(
        facebook::react::Tag,
        facebook::react::Tag,
        facebook::react::SurfaceId) override {}

    void schedulerDidClearPendingSnapshots() override {}

   private:
    NucleusMountingObserver &observer_;
  };

  class FabricRuntime final {
   public:
    FabricRuntime(
        facebook::jsi::Runtime &runtime,
        std::thread::id jsThreadId,
        void *swiftTextLayoutManagerHandle)
        : runtime_(runtime),
          jsThreadId_(jsThreadId),
          contextContainer_(std::make_shared<facebook::react::ContextContainer>()),
          runtimeExecutor_([this](
                               std::function<void(facebook::jsi::Runtime &)> &&callback) {
            callback(runtime_);
          }),
          runtimeScheduler_(std::make_shared<facebook::react::RuntimeScheduler>(
              runtimeExecutor_)),
          delegate_(mountingObserver_) {
      logRuntimeHostf("FabricRuntime ctor begin this=%p runtime=%p", this, &runtime_);
      installMinimalAppRegistryBinding();
      logRuntimeHost("FabricRuntime minimal AppRegistry installed");
      contextContainer_->insert(
          facebook::react::RuntimeSchedulerKey,
          std::weak_ptr<facebook::react::RuntimeScheduler>(runtimeScheduler_));
      contextContainer_->insert(
          facebook::react::TextLayoutManagerKey,
          std::shared_ptr<const facebook::react::TextLayoutManager>(
              nucleus::react::makeSwiftTextLayoutManagerBridge(
                  swiftTextLayoutManagerHandle, contextContainer_)));

      facebook::react::RuntimeSchedulerBinding::createAndInstallIfNeeded(
          runtime_,
          runtimeScheduler_);
      logRuntimeHost("FabricRuntime scheduler binding installed");

      facebook::react::SchedulerToolbox toolbox{
          .contextContainer = contextContainer_,
          .componentRegistryFactory = [this](const facebook::react::EventDispatcher::Weak &eventDispatcher,
                                        const std::shared_ptr<const facebook::react::ContextContainer> &contextContainer) {
            auto providerRegistry =
                std::make_shared<facebook::react::ComponentDescriptorProviderRegistry>();
            auto addProvider = [&providerRegistry](auto provider) {
              providerRegistry->add(provider);
            };
            addProvider(facebook::react::concreteComponentDescriptorProvider<
                facebook::react::RootComponentDescriptor>());
            addProvider(facebook::react::concreteComponentDescriptorProvider<
                facebook::react::ViewComponentDescriptor>());
            addProvider(facebook::react::concreteComponentDescriptorProvider<
                facebook::react::RCTViewComponentDescriptor>());
            addProvider(facebook::react::concreteComponentDescriptorProvider<
                facebook::react::ParagraphComponentDescriptor>());
            addProvider(facebook::react::concreteComponentDescriptorProvider<
                facebook::react::TextComponentDescriptor>());
            addProvider(facebook::react::concreteComponentDescriptorProvider<
                facebook::react::RawTextComponentDescriptor>());
            addProvider(facebook::react::concreteComponentDescriptorProvider<
                facebook::react::ImageComponentDescriptor>());
            addProvider(facebook::react::concreteComponentDescriptorProvider<
                facebook::react::ScrollViewComponentDescriptor>());
            addProvider(facebook::react::concreteComponentDescriptorProvider<
                facebook::react::LayoutConformanceComponentDescriptor>());
            auto registry = providerRegistry->createComponentDescriptorRegistry(
                facebook::react::ComponentDescriptorParameters{
                    .eventDispatcher = eventDispatcher,
                    .contextContainer = contextContainer,
                    .flavor = nullptr});
            providerRegistries_.push_back(std::move(providerRegistry));
            return registry;
          },
          .bridgelessBindingsExecutor = std::nullopt,
          .runtimeExecutor = runtimeExecutor_,
          .eventBeatFactory = [this](std::shared_ptr<facebook::react::EventBeat::OwnerBox> ownerBox) {
            return std::make_unique<ImmediateEventBeat>(
                std::move(ownerBox),
                *runtimeScheduler_,
                jsThreadId_);
          },
          .commitHooks = {},
          .animationChoreographer = nullptr,
      };

      scheduler_ = std::make_unique<facebook::react::Scheduler>(
          toolbox,
          nullptr,
          &delegate_);
      logRuntimeHostf("FabricRuntime scheduler created scheduler=%p", scheduler_.get());
      facebook::react::UIManagerBinding::createAndInstallIfNeeded(
          runtime_,
          scheduler_->getUIManager());
      logRuntimeHost("FabricRuntime UIManager binding installed");
    }

    ~FabricRuntime() {
      logRuntimeHostf("FabricRuntime dtor begin this=%p", this);
      for (auto &[_, surface] : surfaces_) {
        stopSurface(*surface);
      }
      logRuntimeHost("FabricRuntime dtor end");
    }

    nucleus::react::FabricMountReport report() const {
      return mountingObserver_.report();
    }

    void setMountingObserver(std::shared_ptr<nucleus::react::MountingObserver> observer) {
      mountingObserver_.setObserver(std::move(observer));
    }

    void registerSurface(int surfaceId) {
      (void)ensureSurface(surfaceId);
    }

    void configureSurface(int surfaceId, double width, double height) {
      auto &surface = ensureSurface(surfaceId);
      const auto maxWidth = static_cast<facebook::react::Float>(
          width > 0 ? width : std::numeric_limits<facebook::react::Float>::infinity());
      const auto maxHeight = static_cast<facebook::react::Float>(
          height > 0 ? height : std::numeric_limits<facebook::react::Float>::infinity());
      const auto minWidth = static_cast<facebook::react::Float>(width > 0 ? width : 0);
      const auto minHeight = static_cast<facebook::react::Float>(height > 0 ? height : 0);
      surface.constraintLayout(
          facebook::react::LayoutConstraints{
              .minimumSize = {.width = minWidth, .height = minHeight},
              .maximumSize = {.width = maxWidth, .height = maxHeight},
              .layoutDirection = facebook::react::LayoutDirection::LeftToRight},
          facebook::react::LayoutContext{});
      if (surface.getStatus() == facebook::react::SurfaceHandler::Status::Registered) {
        surface.start();
        logRuntimeHostf("FabricRuntime surface started id=%d", surfaceId);
      }
    }

    void stopSurface(int surfaceId) {
      const auto id = static_cast<facebook::react::SurfaceId>(surfaceId);
      auto found = surfaces_.find(id);
      if (found == surfaces_.end()) {
        return;
      }
      stopSurface(*found->second);
      surfaces_.erase(found);
    }

    std::size_t surfaceCount() const {
      return surfaces_.size();
    }

   private:
    facebook::react::SurfaceHandler &ensureSurface(int surfaceId) {
      const auto id = static_cast<facebook::react::SurfaceId>(surfaceId);
      auto found = surfaces_.find(id);
      if (found != surfaces_.end()) {
        return *found->second;
      }
      auto surface = std::make_unique<facebook::react::SurfaceHandler>("", id);
      auto &ref = *surface;
      scheduler_->registerSurface(ref);
      logRuntimeHostf("FabricRuntime surface registered id=%d", surfaceId);
      surfaces_.emplace(id, std::move(surface));
      return ref;
    }

    void stopSurface(facebook::react::SurfaceHandler &surface) {
      if (surface.getStatus() == facebook::react::SurfaceHandler::Status::Running) {
        surface.stop();
      }
      if (surface.getStatus() == facebook::react::SurfaceHandler::Status::Registered) {
        scheduler_->unregisterSurface(surface);
      }
    }

    void installMinimalAppRegistryBinding() {
      auto noopName = facebook::jsi::PropNameID::forAscii(runtime_, "noop");
      auto noop = facebook::jsi::Function::createFromHostFunction(
          runtime_,
          noopName,
          0,
          [](facebook::jsi::Runtime &,
             const facebook::jsi::Value &,
             const facebook::jsi::Value *,
             std::size_t) {
            return facebook::jsi::Value::undefined();
          });
      auto appRegistry = facebook::jsi::Object(runtime_);
      appRegistry.setProperty(runtime_, "runApplication", noop);
      appRegistry.setProperty(
          runtime_,
          "setSurfaceProps",
          facebook::jsi::Function::createFromHostFunction(
              runtime_,
              noopName,
              0,
              [](facebook::jsi::Runtime &,
                 const facebook::jsi::Value &,
                 const facebook::jsi::Value *,
                 std::size_t) {
                return facebook::jsi::Value::undefined();
              }));
      runtime_.global().setProperty(runtime_, "RN$AppRegistry", std::move(appRegistry));
      runtime_.global().setProperty(
          runtime_,
          "RN$stopSurface",
          facebook::jsi::Function::createFromHostFunction(
              runtime_,
              noopName,
              0,
              [](facebook::jsi::Runtime &,
                 const facebook::jsi::Value &,
                 const facebook::jsi::Value *,
                 std::size_t) {
                return facebook::jsi::Value::undefined();
              }));
    }

    facebook::jsi::Runtime &runtime_;
    std::thread::id jsThreadId_;
    std::shared_ptr<facebook::react::ContextContainer> contextContainer_;
    facebook::react::RuntimeExecutor runtimeExecutor_;
    std::shared_ptr<facebook::react::RuntimeScheduler> runtimeScheduler_;
    // A descriptor registry retains references into its provider registry. Keep
    // providers alive for exactly this Fabric runtime's lifetime.
    std::vector<std::shared_ptr<facebook::react::ComponentDescriptorProviderRegistry>>
        providerRegistries_;
    NucleusMountingObserver mountingObserver_;
    FabricSchedulerDelegate delegate_;
    std::unique_ptr<facebook::react::Scheduler> scheduler_;
    std::unordered_map<
        facebook::react::SurfaceId,
        std::unique_ptr<facebook::react::SurfaceHandler>>
        surfaces_;
  };

  void installConsole() {
    auto console = facebook::jsi::Object(*runtime_);
    auto installConsoleMethod = [this, &console](const char *name) {
      auto propName = facebook::jsi::PropNameID::forAscii(*runtime_, name);
      auto log = facebook::jsi::Function::createFromHostFunction(
        *runtime_,
        propName,
        1,
        [this](
            facebook::jsi::Runtime &runtime,
            const facebook::jsi::Value &,
            const facebook::jsi::Value *args,
            std::size_t count) -> facebook::jsi::Value {
          std::string message;
          for (std::size_t i = 0; i < count; ++i) {
            if (i != 0) {
              message += " ";
            }
            message += args[i].toString(runtime).utf8(runtime);
          }
          logRuntimeHostf("console.%s: %s", "message", message.c_str());
          return facebook::jsi::Value::undefined();
        });
      console.setProperty(*runtime_, name, std::move(log));
    };
    installConsoleMethod("log");
    installConsoleMethod("warn");
    installConsoleMethod("error");
    runtime_->global().setProperty(*runtime_, "console", std::move(console));
  }



  static facebook::jsi::Object makePlatformConstants(facebook::jsi::Runtime &runtime) {
    auto version = facebook::jsi::Object(runtime);
    version.setProperty(runtime, "major", 0);
    version.setProperty(runtime, "minor", 86);
    version.setProperty(runtime, "patch", 0);
    version.setProperty(runtime, "prerelease", "rc.0");

    auto constants = facebook::jsi::Object(runtime);
    constants.setProperty(runtime, "isTesting", true);
    constants.setProperty(runtime, "isDisableAnimations", false);
    constants.setProperty(runtime, "reactNativeVersion", std::move(version));
    constants.setProperty(runtime, "forceTouchAvailable", false);
    constants.setProperty(runtime, "osVersion", "0.1.1");
    constants.setProperty(runtime, "systemName", "Nucleus");
    constants.setProperty(runtime, "interfaceIdiom", "desktop");
    constants.setProperty(runtime, "isMacCatalyst", false);
    return constants;
  }

  void registerCoreTurboModules() {
    // `PlatformConstants` stays on the iOS-shape hand-rolled implementation:
    // the bundle's `Platform.nucleus.js` derives from `Platform.ios.js`, so
    // JS that drops into native-side constants (e.g. `Platform.constants`)
    // expects `systemName`, `interfaceIdiom`, etc. The portable
    // `PlatformConstantsModule` is Android-only and would mis-shape these.
    turboModuleRegistry_.add(
        "PlatformConstants",
        [](std::shared_ptr<facebook::react::CallInvoker> invoker) {
          return std::make_shared<ConstantsTurboModule>(
              "PlatformConstants",
              std::move(invoker),
              makePlatformConstants);
        });
    // `DeviceInfo` returns real window/screen dimensions from the
    // shared `DisplayMetricsState` that Swift updates via
    // `setDisplayMetrics`. The portable `DeviceInfoModule` hardcodes
    // 1280×720; the Nucleus subclass overrides `getConstants` to read
    // the live state.
    turboModuleRegistry_.add(
        "DeviceInfo",
        [state = displayMetricsState_](
            std::shared_ptr<facebook::react::CallInvoker> invoker) {
          return std::make_shared<NucleusDeviceInfoModule>(
              std::move(invoker), state);
        });
    // `NucleusHostCommand` — the JS→native command seam. JS calls `invoke(command,
    // argsJson)`; the module forwards to the embedding host's installed callback (the shell
    // routes e.g. "activate"/"close" to its Wayland foreign-toplevel client). Shares the
    // impl's handler so a later setCommandHandler is seen by already-created instances.
    turboModuleRegistry_.add(
        "NucleusHostCommand",
        [handler = commandHandler_](
            std::shared_ptr<facebook::react::CallInvoker> invoker) {
          return std::make_shared<HostCommandTurboModule>(std::move(invoker), handler);
        });
    turboModuleRegistry_.add(
        "AppState",
        [state = appStateState_](std::shared_ptr<facebook::react::CallInvoker> invoker) {
          return std::make_shared<NucleusAppStateModule>(std::move(invoker), state);
        });
    // `SourceCode` returns empty `scriptURL`. We don't use the portable
    // `facebook::react::SourceCodeModule` because it unconditionally
    // references `DevServerHelper::getBundleUrl()`, and
    // `DevServerHelper.cpp` is excluded from `react_cxx_platform` (it
    // pulls OpenSSL and the dev-server HTTP stack we don't link).
    turboModuleRegistry_.add(
        "SourceCode",
        [state = sourceCodeState_](std::shared_ptr<facebook::react::CallInvoker> invoker) {
          return std::make_shared<NucleusSourceCodeModule>(std::move(invoker), state);
        });
    turboModuleRegistry_.add(
        facebook::react::NativePerformance::kModuleName,
        [](std::shared_ptr<facebook::react::CallInvoker> invoker) {
          return std::make_shared<facebook::react::NativePerformance>(std::move(invoker));
        });
    // Portable `ExceptionsManager`: routes JS errors to our
    // host-runtime logger. JsErrorHandler::ParsedError is logged
    // verbatim; richer formatting (LogBox surface, sourcemaps) lands
    // when DevSupport does.
    turboModuleRegistry_.add(
        "ExceptionsManager",
        [](std::shared_ptr<facebook::react::CallInvoker> invoker) {
          facebook::react::JsErrorHandler::OnJsError onError =
              [](facebook::jsi::Runtime & /*runtime*/,
                 const facebook::react::JsErrorHandler::ProcessedError &error) {
                logRuntimeHostf(
                    "ExceptionsManager: %s",
                    error.message.c_str());
              };
          return std::make_shared<facebook::react::NativeExceptionsManager>(
              std::move(onError), std::move(invoker));
        });
    turboModuleRegistry_.add(
        facebook::react::NativeDOM::kModuleName,
        [](std::shared_ptr<facebook::react::CallInvoker> invoker) {
          return std::make_shared<facebook::react::NativeDOM>(std::move(invoker));
        });
    turboModuleRegistry_.add(
        facebook::react::NativeMicrotasks::kModuleName,
        [](std::shared_ptr<facebook::react::CallInvoker> invoker) {
          return std::make_shared<facebook::react::NativeMicrotasks>(
              std::move(invoker));
        });
    turboModuleRegistry_.add(
        facebook::react::NativeReactNativeFeatureFlags::kModuleName,
        [](std::shared_ptr<facebook::react::CallInvoker> invoker) {
          return std::make_shared<facebook::react::NativeReactNativeFeatureFlags>(
              std::move(invoker));
        });
  }

  void installTurboModuleBinding() {
    auto invoker =
        std::static_pointer_cast<facebook::react::CallInvoker>(jsInvoker_);
    auto *registry = &turboModuleRegistry_;
    facebook::react::TurboModuleBinding::install(
        *runtime_,
        [registry, invoker](
            facebook::jsi::Runtime &,
            const std::string &name)
            -> std::shared_ptr<facebook::react::TurboModule> {
          return registry->lookup(name, invoker);
        });
  }

  void installCallableModuleBinding() {
    auto registerName =
        facebook::jsi::PropNameID::forAscii(*runtime_, "registerCallableModule");
    auto registerCallableModule = facebook::jsi::Function::createFromHostFunction(
        *runtime_,
        registerName,
        2,
        [this](
            facebook::jsi::Runtime &runtime,
            const facebook::jsi::Value &,
            const facebook::jsi::Value *args,
            std::size_t count) -> facebook::jsi::Value {
          if (count != 2) {
            throw facebook::jsi::JSError(
                runtime,
                "registerCallableModule requires exactly 2 arguments");
          }
          if (!args[0].isString()) {
            throw facebook::jsi::JSError(
                runtime,
                "The first argument to registerCallableModule must be a string");
          }
          if (!args[1].isObject() ||
              !args[1].getObject(runtime).isFunction(runtime)) {
            throw facebook::jsi::JSError(
                runtime,
                "The second argument to registerCallableModule must be a function");
          }
          auto name = args[0].asString(runtime).utf8(runtime);
          auto factory = args[1].getObject(runtime).getFunction(runtime);
          callableModules_.erase(name);
          callableModules_.emplace(std::move(name), std::move(factory));
          return facebook::jsi::Value::undefined();
        });
    runtime_->global().setProperty(
        *runtime_,
        "RN$registerCallableModule",
        std::move(registerCallableModule));
  }

  facebook::jsi::Function makeDefaultErrorHandler() {
    auto handlerName =
        facebook::jsi::PropNameID::forAscii(*runtime_, "defaultErrorHandler");
    return facebook::jsi::Function::createFromHostFunction(
        *runtime_,
        handlerName,
        2,
        [](
            facebook::jsi::Runtime &runtime,
            const facebook::jsi::Value &,
            const facebook::jsi::Value *args,
            std::size_t count) -> facebook::jsi::Value {
          if (count > 0) {
            auto message = args[0].toString(runtime).utf8(runtime);
            logRuntimeHostf("ErrorUtils: %s", message.c_str());
          }
          return facebook::jsi::Value::undefined();
        });
  }

  void dispatchErrorToHandler(
      facebook::jsi::Runtime &runtime,
      const facebook::jsi::Value &error,
      bool isFatal) {
    if (!errorHandler_.has_value()) {
      auto message = error.toString(runtime).utf8(runtime);
      logRuntimeHostf("Unhandled JS error: %s", message.c_str());
      return;
    }
    facebook::jsi::Value handlerArgs[] = {
        facebook::jsi::Value(runtime, error),
        facebook::jsi::Value(isFatal)};
    errorHandler_->call(
        runtime,
        static_cast<const facebook::jsi::Value *>(handlerArgs),
        static_cast<std::size_t>(2));
  }

  void installErrorUtilsBinding() {
    auto errorUtils = facebook::jsi::Object(*runtime_);

    auto setGlobalHandlerName =
        facebook::jsi::PropNameID::forAscii(*runtime_, "setGlobalHandler");
    errorUtils.setProperty(
        *runtime_,
        "setGlobalHandler",
        facebook::jsi::Function::createFromHostFunction(
            *runtime_,
            setGlobalHandlerName,
            1,
            [this](
                facebook::jsi::Runtime &runtime,
                const facebook::jsi::Value &,
                const facebook::jsi::Value *args,
                std::size_t count) -> facebook::jsi::Value {
              if (count == 0 || !args[0].isObject() ||
                  !args[0].getObject(runtime).isFunction(runtime)) {
                throw facebook::jsi::JSError(
                    runtime,
                    "ErrorUtils.setGlobalHandler requires a function");
              }
              errorHandler_.emplace(args[0].getObject(runtime).getFunction(runtime));
              return facebook::jsi::Value::undefined();
            }));

    auto getGlobalHandlerName =
        facebook::jsi::PropNameID::forAscii(*runtime_, "getGlobalHandler");
    errorUtils.setProperty(
        *runtime_,
        "getGlobalHandler",
        facebook::jsi::Function::createFromHostFunction(
            *runtime_,
            getGlobalHandlerName,
            0,
            [this](
                facebook::jsi::Runtime &runtime,
                const facebook::jsi::Value &,
                const facebook::jsi::Value *,
                std::size_t) -> facebook::jsi::Value {
              if (errorHandler_.has_value()) {
                return facebook::jsi::Value(runtime, *errorHandler_);
              }
              auto handler = makeDefaultErrorHandler();
              return facebook::jsi::Value(runtime, handler);
            }));

    auto makeReportFunction = [this](
                                  const char *name,
                                  bool isFatal) {
      return facebook::jsi::Function::createFromHostFunction(
          *runtime_,
          facebook::jsi::PropNameID::forAscii(*runtime_, name),
          1,
          [this, isFatal](
              facebook::jsi::Runtime &runtime,
              const facebook::jsi::Value &,
              const facebook::jsi::Value *args,
              std::size_t count) -> facebook::jsi::Value {
            if (count > 0) {
              dispatchErrorToHandler(runtime, args[0], isFatal);
            }
            return facebook::jsi::Value::undefined();
          });
    };
    errorUtils.setProperty(*runtime_, "reportError", makeReportFunction("reportError", false));
    errorUtils.setProperty(
        *runtime_,
        "reportFatalError",
        makeReportFunction("reportFatalError", true));

    auto applyName = facebook::jsi::PropNameID::forAscii(*runtime_, "applyWithGuard");
    auto applyWithGuard = facebook::jsi::Function::createFromHostFunction(
        *runtime_,
        applyName,
        3,
        [this](
            facebook::jsi::Runtime &runtime,
            const facebook::jsi::Value &,
            const facebook::jsi::Value *args,
            std::size_t count) -> facebook::jsi::Value {
          if (count == 0 || !args[0].isObject() ||
              !args[0].getObject(runtime).isFunction(runtime)) {
            return facebook::jsi::Value::undefined();
          }

          auto function = args[0].getObject(runtime).getFunction(runtime);
          std::vector<facebook::jsi::Value> callArgs;
          if (count > 2 && args[2].isObject()) {
            auto argsObject = args[2].getObject(runtime);
            if (argsObject.isArray(runtime)) {
              auto array = argsObject.getArray(runtime);
              const auto length = array.length(runtime);
              callArgs.reserve(length);
              for (std::size_t i = 0; i < length; ++i) {
                callArgs.emplace_back(array.getValueAtIndex(runtime, i));
              }
            }
          }

          try {
            if (count > 1 && args[1].isObject()) {
              auto thisObject = args[1].getObject(runtime);
              return function.callWithThis(
                  runtime,
                  thisObject,
                  static_cast<const facebook::jsi::Value *>(callArgs.data()),
                  callArgs.size());
            }
            return function.call(
                runtime,
                static_cast<const facebook::jsi::Value *>(callArgs.data()),
                callArgs.size());
          } catch (const facebook::jsi::JSError &error) {
            dispatchErrorToHandler(runtime, error.value(), true);
            return facebook::jsi::Value::undefined();
          }
        });
    errorUtils.setProperty(*runtime_, "applyWithGuard", std::move(applyWithGuard));
    errorUtils.setProperty(
        *runtime_,
        "applyWithGuardIfNeeded",
        errorUtils.getPropertyAsFunction(*runtime_, "applyWithGuard"));
    errorUtils.setProperty(
        *runtime_,
        "guard",
        facebook::jsi::Function::createFromHostFunction(
            *runtime_,
            facebook::jsi::PropNameID::forAscii(*runtime_, "guard"),
            1,
            [](
                facebook::jsi::Runtime &runtime,
                const facebook::jsi::Value &,
                const facebook::jsi::Value *args,
                std::size_t count) -> facebook::jsi::Value {
              if (count > 0) {
                return facebook::jsi::Value(runtime, args[0]);
              }
              return facebook::jsi::Value::undefined();
            }));
    errorUtils.setProperty(
        *runtime_,
        "inGuard",
        facebook::jsi::Function::createFromHostFunction(
            *runtime_,
            facebook::jsi::PropNameID::forAscii(*runtime_, "inGuard"),
            0,
            [](
                facebook::jsi::Runtime &,
                const facebook::jsi::Value &,
                const facebook::jsi::Value *,
                std::size_t) -> facebook::jsi::Value {
              return facebook::jsi::Value(false);
            }));

    runtime_->global().setProperty(*runtime_, "ErrorUtils", std::move(errorUtils));
  }

  void installHostRuntimeBindings() {
    auto global = runtime_->global();
    global.setProperty(*runtime_, "global", global);
    installErrorUtilsBinding();
    installUIManagerInteropBindings();
    installNativeComponentAvailabilityBindings();
    registerCoreTurboModules();
    installTurboModuleBinding();
    global.setProperty(*runtime_, "RN$Bridgeless", true);
    installCallableModuleBinding();
    auto nativeModuleProxy = facebook::jsi::Object(*runtime_);
    auto sourceCode = facebook::jsi::Object(*runtime_);
    auto getConstantsName = facebook::jsi::PropNameID::forAscii(*runtime_, "getConstants");
    sourceCode.setProperty(
        *runtime_,
        "getConstants",
        facebook::jsi::Function::createFromHostFunction(
            *runtime_,
            getConstantsName,
            0,
            [state = sourceCodeState_](
                facebook::jsi::Runtime &runtime,
                const facebook::jsi::Value &,
                const facebook::jsi::Value *,
                std::size_t) -> facebook::jsi::Value {
              auto constants = facebook::jsi::Object(runtime);
              std::lock_guard<std::mutex> lock(state->mutex);
              constants.setProperty(runtime, "scriptURL", state->scriptURL);
              return constants;
            }));
    nativeModuleProxy.setProperty(*runtime_, "SourceCode", std::move(sourceCode));
    auto deviceInfo = facebook::jsi::Object(*runtime_);
    deviceInfo.setProperty(
        *runtime_,
        "getConstants",
        facebook::jsi::Function::createFromHostFunction(
            *runtime_,
            getConstantsName,
            0,
            [state = displayMetricsState_](
                facebook::jsi::Runtime &runtime,
                const facebook::jsi::Value &,
                const facebook::jsi::Value *,
                std::size_t) -> facebook::jsi::Value {
              auto window = facebook::jsi::Object(runtime);
              std::lock_guard<std::mutex> lock(state->mutex);
              window.setProperty(runtime, "width", state->windowWidth);
              window.setProperty(runtime, "height", state->windowHeight);
              window.setProperty(runtime, "scale", state->scale);
              window.setProperty(runtime, "fontScale", state->fontScale);
              auto dimensions = facebook::jsi::Object(runtime);
              dimensions.setProperty(runtime, "window", window);
              dimensions.setProperty(runtime, "screen", window);
              auto constants = facebook::jsi::Object(runtime);
              constants.setProperty(runtime, "Dimensions", dimensions);
              return constants;
            }));
    nativeModuleProxy.setProperty(*runtime_, "DeviceInfo", std::move(deviceInfo));
    global.setProperty(*runtime_, "nativeModuleProxy", std::move(nativeModuleProxy));

    // Bootstrap `performance.now()` for `TimerManager::attachGlobals` —
    // its `requestAnimationFrame` shim wraps the user callback with one
    // that calls `performance.now()` and crashes if the global is
    // missing. RN's standard `setUpPerformance` is wired by the
    // the full NativePerformance TurboModule replaces this during InitializeCore.
    installMinimalPerformanceGlobal();
    timerManager_->attachGlobals(*runtime_);
    // `setImmediate`/`clearImmediate` are not hand-installed here: React Native's
    // JS layer (`InitializeCore` / `@react-native/js-polyfills`, pulled in by every
    // Metro-built bundle) defines them on top of the Timing module that
    // `attachGlobals` wires. A C++ stub here would also have to *evaluate JS
    // source*, which the lean Hermes VM cannot compile (it runs bytecode only).
  }

  void installMinimalPerformanceGlobal() {
    if (runtime_->global().hasProperty(*runtime_, "performance")) {
      return;
    }
    auto performance = facebook::jsi::Object(*runtime_);
    auto nowName = facebook::jsi::PropNameID::forAscii(*runtime_, "now");
    performance.setProperty(
        *runtime_,
        "now",
        facebook::jsi::Function::createFromHostFunction(
            *runtime_,
            nowName,
            0,
            [](facebook::jsi::Runtime &,
               const facebook::jsi::Value &,
               const facebook::jsi::Value *,
               std::size_t) -> facebook::jsi::Value {
              const auto now = std::chrono::steady_clock::now().time_since_epoch();
              const auto ms = std::chrono::duration<double, std::milli>(now).count();
              return facebook::jsi::Value(ms);
            }));
    runtime_->global().setProperty(
        *runtime_, "performance", std::move(performance));
  }

  static folly::dynamic makePhasedEvent(
      const char *bubbled,
      const char *captured,
      bool skipBubbling = false) {
    folly::dynamic phased = folly::dynamic::object("bubbled", bubbled)("captured", captured);
    if (skipBubbling) {
      phased["skipBubbling"] = true;
    }
    return folly::dynamic::object("phasedRegistrationNames", std::move(phased));
  }

  static folly::dynamic makeDirectEvent(const char *registrationName) {
    return folly::dynamic::object("registrationName", registrationName);
  }

  static folly::dynamic makeGenericBubblingEventTypes() {
    folly::dynamic events = folly::dynamic::object();
    events["topChange"] = makePhasedEvent("onChange", "onChangeCapture");
    events["topTouchStart"] = makePhasedEvent("onTouchStart", "onTouchStartCapture");
    events["topTouchMove"] = makePhasedEvent("onTouchMove", "onTouchMoveCapture");
    events["topTouchEnd"] = makePhasedEvent("onTouchEnd", "onTouchEndCapture");
    events["topTouchCancel"] = makePhasedEvent("onTouchCancel", "onTouchCancelCapture");
    events["topClick"] = makePhasedEvent("onClick", "onClickCapture");
    events["topPointerDown"] = makePhasedEvent("onPointerDown", "onPointerDownCapture");
    events["topPointerMove"] = makePhasedEvent("onPointerMove", "onPointerMoveCapture");
    events["topPointerUp"] = makePhasedEvent("onPointerUp", "onPointerUpCapture");
    events["topPointerCancel"] = makePhasedEvent("onPointerCancel", "onPointerCancelCapture");
    events["topPointerEnter"] = makePhasedEvent(
        "onPointerEnter", "onPointerEnterCapture", true);
    events["topPointerLeave"] = makePhasedEvent(
        "onPointerLeave", "onPointerLeaveCapture", true);
    events["topPointerOver"] = makePhasedEvent("onPointerOver", "onPointerOverCapture");
    events["topPointerOut"] = makePhasedEvent("onPointerOut", "onPointerOutCapture");
    events["topGotPointerCapture"] =
        makePhasedEvent("onGotPointerCapture", "onGotPointerCaptureCapture");
    events["topLostPointerCapture"] =
        makePhasedEvent("onLostPointerCapture", "onLostPointerCaptureCapture");
    return events;
  }

  static folly::dynamic makeGenericDirectEventTypes() {
    folly::dynamic events = folly::dynamic::object();
    events["topLayout"] = makeDirectEvent("onLayout");
    return events;
  }

  static folly::dynamic makeViewManagerConfig(const std::string &name) {
    folly::dynamic nativeProps = folly::dynamic::object();
    nativeProps["backgroundColor"] = "Color";
    nativeProps["nativeID"] = "String";
    nativeProps["style"] = "Object";
    nativeProps["pointerEvents"] = "String";

    folly::dynamic config = folly::dynamic::object();
    config["uiViewClassName"] = name;
    config["baseModuleName"] = nullptr;
    config["NativeProps"] = std::move(nativeProps);
    config["bubblingEventTypes"] = folly::dynamic::object();
    config["directEventTypes"] = folly::dynamic::object();
    config["Commands"] = folly::dynamic::object();
    config["Constants"] = folly::dynamic::object();
    return config;
  }

  static const std::vector<std::string> &knownComponentNames() {
    static const std::vector<std::string> names{
        "RCTView",
        "View",
        "RootView",
        "Paragraph",
        "Text",
        "RawText",
        "Image",
        "ScrollView",
        "UnimplementedView",
        "LayoutConformance",
    };
    return names;
  }

  static bool isShellComponentName(const std::string &name) {
    const auto &names = knownComponentNames();
    if (std::find(names.begin(), names.end(), name) != names.end()) {
      return true;
    }
    return name == "RCTParagraph" || name == "RCTText" || name == "RCTRawText";
  }

  static facebook::jsi::Value getUIManagerConstants(facebook::jsi::Runtime &runtime) {
    folly::dynamic names = folly::dynamic::array;
    for (const auto &name : knownComponentNames()) {
      names.push_back(name);
    }
    folly::dynamic constants = folly::dynamic::object();
    constants["LazyViewManagersEnabled"] = true;
    constants["ViewManagerNames"] = names;
    for (const auto &name : knownComponentNames()) {
      constants[name] = makeViewManagerConfig(name);
    }
    constants["genericBubblingEventTypes"] = makeGenericBubblingEventTypes();
    constants["genericDirectEventTypes"] = makeGenericDirectEventTypes();
    return facebook::jsi::valueFromDynamic(runtime, constants);
  }

  static facebook::jsi::Value getViewManagerConfig(
      facebook::jsi::Runtime &runtime,
      const std::string &name) {
    if (!isShellComponentName(name)) {
      return facebook::jsi::Value::null();
    }
    return facebook::jsi::valueFromDynamic(runtime, makeViewManagerConfig(name));
  }

  static facebook::jsi::Value getDefaultEventTypes(facebook::jsi::Runtime &runtime) {
    folly::dynamic payload = folly::dynamic::object();
    payload["bubblingEventTypes"] = makeGenericBubblingEventTypes();
    payload["directEventTypes"] = makeGenericDirectEventTypes();
    return facebook::jsi::valueFromDynamic(runtime, payload);
  }

  void installUIManagerInteropBindings() {
    using facebook::react::LegacyUIManagerConstantsProviderBinding::install;
    install(*runtime_, "getConstants", getUIManagerConstants);
    install(*runtime_, "getConstantsForViewManager", getViewManagerConfig);
    install(*runtime_, "getDefaultEventTypes", getDefaultEventTypes);
  }

  void installNativeComponentAvailabilityBindings() {
    facebook::react::bindHasComponentProvider(
        *runtime_,
        [](const std::string &name) {
          return isShellComponentName(name);
        });
  }

  void setSourceURL(std::string url) {
    std::lock_guard<std::mutex> lock(sourceCodeState_->mutex);
    sourceCodeState_->scriptURL = std::move(url);
  }

  // Declared before `runtime_` so it outlives the JS runtime. The
  // TurboModuleBinding lambda installed on the runtime captures a raw
  // pointer to the registry; the registry must remain valid until that
  // lambda is destroyed (which happens when `runtime_` is destroyed).
  TurboModuleRegistry turboModuleRegistry_;
  std::unique_ptr<facebook::jsi::Runtime> runtime_;
  // Declared after `runtime_` so destruction order is timer-manager →
  // runtime. The manager's `timers_` map holds live `jsi::Function`s
  // that must be destroyed while the runtime is still alive.
  std::unique_ptr<facebook::react::TimerManager> timerManager_;
  std::thread::id jsThreadId_{};
  std::shared_ptr<RuntimeJSCallInvoker> jsInvoker_;
  std::shared_ptr<DeviceEventEmitter> deviceEventEmitter_;
  // The JS→native command handler, shared with every NucleusHostCommand instance; the
  // callback stays null (invoke is a no-op) until an embedding host installs one.
  std::shared_ptr<HostCommandHandler> commandHandler_ =
      std::make_shared<HostCommandHandler>();
  std::unique_ptr<FabricRuntime> fabric_;
  std::unordered_map<std::string, facebook::jsi::Function> callableModules_;
  std::optional<facebook::jsi::Function> errorHandler_;
  std::shared_ptr<nucleus::react::MountingObserver> mountingObserver_;
  std::shared_ptr<DisplayMetricsState> displayMetricsState_;
  std::shared_ptr<SourceCodeState> sourceCodeState_;
  std::shared_ptr<AppStateState> appStateState_;
  // Retained Swift `SwiftTextLayoutManager` handle waiting to be
  // consumed by `installFabricRuntime()`. Released in the dtor if
  // Fabric never installs.
  void *swiftTextLayoutHandle_{nullptr};
};

bool hermesCanCreateRuntime() {
  try {
    return facebook::hermes::makeHermesRuntime(
        ::hermes::vm::RuntimeConfig::Builder()
            .withIntl(true)
            .build()) != nullptr;
  } catch (...) {
    return false;
  }
}

unsigned int hermesBytecodeVersion() {
  try {
    auto *root = facebook::jsi::castInterface<facebook::hermes::IHermesRootAPI>(
        facebook::hermes::makeHermesRootAPI());
    if (root == nullptr) {
      throw std::runtime_error("Hermes root API is unavailable");
    }
    return root->getBytecodeVersion();
  } catch (...) {
    return 0;
  }
}

bool hermesIntlDateTimeFormatWorks() {
  try {
    auto runtime = facebook::hermes::makeHermesRuntime(
        ::hermes::vm::RuntimeConfig::Builder()
            .withIntl(true)
            .build());
    if (runtime == nullptr) {
      return false;
    }

    auto script = std::make_shared<facebook::jsi::StringBuffer>(
        R"JS(
(() => {
  if (typeof Intl !== "object" || typeof Intl.DateTimeFormat !== "function") {
    return false;
  }
  const date = new Date(Date.UTC(2020, 0, 2, 3, 4, 5));
  const time = date.toLocaleTimeString("en-US", {
    hour: "numeric",
    minute: "2-digit",
    timeZone: "UTC",
  });
  const formatted = new Intl.DateTimeFormat("en-US", {
    hour: "numeric",
    minute: "2-digit",
    timeZone: "UTC",
  }).format(date);
  const number = (1234567.5).toLocaleString("en-US");
  return typeof time === "string" &&
    typeof formatted === "string" &&
    typeof number === "string" &&
    time.length > 0 &&
    formatted.length > 0 &&
    number.length > 0 &&
    time.indexOf("not implemented") === -1 &&
    formatted.indexOf("not implemented") === -1 &&
    number.indexOf("not implemented") === -1 &&
    "a".localeCompare("b", "en-US") < 0;
})()
)JS");
    auto value = runtime->evaluateJavaScript(script, "nucleus-hermes-intl-test.js");
    return value.isBool() && value.getBool();
  } catch (...) {
    return false;
  }
}

ReactRuntimeHostFacade::ReactRuntimeHostFacade() {
  try {
    impl_ = std::make_unique<ReactRuntimeHostImpl>();
  } catch (const std::exception &exception) {
    initializationError_ = exception.what();
  } catch (...) {
    initializationError_ = "unknown C++ exception";
  }
}

ReactRuntimeHostFacade::~ReactRuntimeHostFacade() = default;

ReactRuntimeHostFacade::ReactRuntimeHostFacade(ReactRuntimeHostFacade &&other) noexcept
    : impl_(std::move(other.impl_)),
      initializationError_(std::move(other.initializationError_)) {}

ReactRuntimeHostFacade &ReactRuntimeHostFacade::operator=(
    ReactRuntimeHostFacade &&other) noexcept {
  impl_ = std::move(other.impl_);
  initializationError_ = std::move(other.initializationError_);
  return *this;
}

RuntimeHostResult ReactRuntimeHostFacade::initializationResult() const {
  if (impl_ != nullptr) {
    return {};
  }
  return RuntimeHostResult{
      .succeeded = false,
      .error = initializationError_.empty()
          ? "React runtime host facade is moved-from"
          : initializationError_};
}

RuntimeHostResult ReactRuntimeHostFacade::evaluateBytecode(const std::string &path) {
  return invokeRuntimeHostEntry([this, &path] {
    if (impl_ == nullptr) {
      throw std::runtime_error("React runtime host facade is moved-from");
    }
    impl_->evaluateBytecode(path.c_str());
  });
}

RuntimeHostResult ReactRuntimeHostFacade::evaluateJavaScriptSource(
    const std::string &source,
    const std::string &sourceUrl) {
  return invokeRuntimeHostEntry([this, &source, &sourceUrl] {
    if (impl_ == nullptr) {
      throw std::runtime_error("React runtime host facade is moved-from");
    }
    impl_->evaluateJavaScriptSource(source.c_str(), sourceUrl.c_str());
  });
}

RuntimeHostResult ReactRuntimeHostFacade::evaluateJavaScriptForString(
    const std::string &source,
    const std::string &sourceUrl) {
  return invokeRuntimeHostStringEntry([this, &source, &sourceUrl] {
    if (impl_ == nullptr) {
      throw std::runtime_error("React runtime host facade is moved-from");
    }
    return impl_->evaluateJavaScriptForString(source.c_str(), sourceUrl.c_str());
  });
}

RuntimeHostResult ReactRuntimeHostFacade::installFabric() {
  return invokeRuntimeHostEntry([this] {
    if (impl_ == nullptr) {
      throw std::runtime_error("React runtime host facade is moved-from");
    }
    impl_->installFabricRuntime();
  });
}

RuntimeHostResult ReactRuntimeHostFacade::registerSurface(int surfaceId) {
  return invokeRuntimeHostEntry([this, surfaceId] {
    if (impl_ == nullptr) {
      throw std::runtime_error("React runtime host facade is moved-from");
    }
    impl_->registerSurface(surfaceId);
  });
}

RuntimeHostResult ReactRuntimeHostFacade::configureSurface(
    int surfaceId,
    double width,
    double height) {
  return invokeRuntimeHostEntry([this, surfaceId, width, height] {
    if (impl_ == nullptr) {
      throw std::runtime_error("React runtime host facade is moved-from");
    }
    impl_->configureSurface(surfaceId, width, height);
  });
}

RuntimeHostResult ReactRuntimeHostFacade::stopSurface(int surfaceId) {
  return invokeRuntimeHostEntry([this, surfaceId] {
    if (impl_ == nullptr) {
      return;
    }
    impl_->stopSurface(surfaceId);
  });
}

RuntimeHostResult ReactRuntimeHostFacade::runApplication(
    int surfaceId,
    const std::string &appKey) {
  return invokeRuntimeHostEntry([this, surfaceId, &appKey] {
    if (impl_ == nullptr) {
      throw std::runtime_error("React runtime host facade is moved-from");
    }
    impl_->runApplication(surfaceId, appKey.c_str());
  });
}

RuntimeHostResult ReactRuntimeHostFacade::drainPendingJSCalls() {
  return invokeRuntimeHostUnsignedEntry([this] {
    if (impl_ == nullptr) {
      return 0u;
    }
    return static_cast<unsigned int>(impl_->drainPendingJSCalls());
  });
}

RuntimeHostResult ReactRuntimeHostFacade::emitDeviceEvent(
    const std::string &name,
    const std::string &payloadJson) {
  // emitDeviceEvent is intentionally callable from any thread; it does not
  // touch impl_'s JSI state directly.
  if (impl_ == nullptr) {
    return RuntimeHostResult{.succeeded = false, .error = "React runtime host facade is moved-from"};
  }
  return invokeRuntimeHostEntry([this, &name, &payloadJson] {
    impl_->emitDeviceEvent(name.c_str(), payloadJson.c_str());
  });
}

RuntimeHostResult ReactRuntimeHostFacade::setCommandHandler(
    HostCommandCallback callback,
    void *context,
    HostCommandContextRelease release) {
  if (impl_ == nullptr) {
    if (release != nullptr) {
      release(context);
    }
    return RuntimeHostResult{.succeeded = false, .error = "React runtime host facade is moved-from"};
  }
  return invokeRuntimeHostEntry([this, callback, context, release] {
    impl_->setCommandHandler(callback, context, release);
  });
}

RuntimeHostResult ReactRuntimeHostFacade::setAppState(const std::string &state) {
  return invokeRuntimeHostEntry([this, &state] {
    if (impl_ == nullptr) {
      throw std::runtime_error("React runtime host facade is moved-from");
    }
    impl_->setAppState(state.c_str());
  });
}

unsigned int ReactRuntimeHostFacade::surfaceCount() const {
  try {
    if (impl_ == nullptr) {
      return 0u;
    }
    return static_cast<unsigned int>(impl_->surfaceCount());
  } catch (...) {
    return 0u;
  }
}

FabricMountReport ReactRuntimeHostFacade::readFabricMountReport() const {
  try {
    if (impl_ == nullptr) {
      return FabricMountReport{};
    }
    return impl_->readFabricMountReport();
  } catch (...) {
    return FabricMountReport{};
  }
}

RuntimeHostResult ReactRuntimeHostFacade::setMountingObserver(
    std::shared_ptr<MountingObserver> observer) {
  return invokeRuntimeHostEntry([this, observer = std::move(observer)]() mutable {
    if (impl_ == nullptr) {
      throw std::runtime_error("React runtime host facade is moved-from");
    }
    impl_->setMountingObserver(std::move(observer));
  });
}

RuntimeHostResult ReactRuntimeHostFacade::setSwiftTextLayoutManagerHandle(
    void *swiftHandlerRetained) {
  return invokeRuntimeHostEntry([this, swiftHandlerRetained] {
    if (impl_ == nullptr) {
      // Don't leak the retained Swift reference if the facade was
      // moved-from before the call arrived.
      nucleus::react::releaseSwiftTextLayoutManagerHandle(swiftHandlerRetained);
      throw std::runtime_error("React runtime host facade is moved-from");
    }
    impl_->setSwiftTextLayoutManagerHandle(swiftHandlerRetained);
  });
}

RuntimeHostResult ReactRuntimeHostFacade::setDisplayMetrics(
    double width,
    double height,
    double scale,
    double fontScale) {
  if (impl_ == nullptr) {
    return RuntimeHostResult{.succeeded = false, .error = "React runtime host facade is moved-from"};
  }
  // Thread-safe: the impl's `displayMetricsState_` is mutex-protected
  // and the TurboModule reads it on demand. Safe to call from any
  // thread (the compositor frame-update path is main-thread today,
  // but networking-driven hot-reload may not be).
  return invokeRuntimeHostEntry([this, width, height, scale, fontScale] {
    impl_->setDisplayMetrics(width, height, scale, fontScale);
  });
}

bool ReactRuntimeHostFacade::hermesCanCreateRuntime() {
  return ::nucleus::react::hermesCanCreateRuntime();
}

unsigned int ReactRuntimeHostFacade::hermesBytecodeVersion() {
  return ::nucleus::react::hermesBytecodeVersion();
}

bool ReactRuntimeHostFacade::hermesIntlDateTimeFormatWorks() {
  return ::nucleus::react::hermesIntlDateTimeFormatWorks();
}

std::shared_ptr<ReactRuntimeHostFacade> makeReactRuntimeHostFacade() {
  return std::make_shared<ReactRuntimeHostFacade>();
}

} // namespace nucleus::react
