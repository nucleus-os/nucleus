#include <NucleusReactRuntime/DeviceEventEmitter.hpp>
#include <NucleusReactRuntime/RuntimeJSCallInvoker.hpp>

#include <cstdio>
#include <utility>

#include <jsi/JSIDynamic.h>

namespace nucleus::react {

namespace {

void logEmitterDrop(const char *reason, const std::string &eventName) {
  std::fprintf(
      stderr,
      "DeviceEventEmitter dropping event %s: %s\n",
      eventName.c_str(),
      reason);
  std::fflush(stderr);
}

} // namespace

DeviceEventEmitter::DeviceEventEmitter(
    facebook::jsi::Runtime &runtime,
    std::shared_ptr<RuntimeJSCallInvoker> invoker)
    : runtime_(runtime), invoker_(std::move(invoker)) {}

void DeviceEventEmitter::emit(std::string eventName, folly::dynamic payload) {
  if (shutdown_.load(std::memory_order_acquire)) {
    return;
  }
  if (invoker_ == nullptr) {
    logEmitterDrop("invoker is null", eventName);
    return;
  }
  invoker_->invokeAsync(
      [this, name = std::move(eventName), payload = std::move(payload)](
          facebook::jsi::Runtime &runtime) mutable {
        if (shutdown_.load(std::memory_order_acquire)) {
          return;
        }
        auto *fn = resolveEmitFn();
        if (fn == nullptr) {
          logEmitterDrop("no JS-side emit function resolved", name);
          return;
        }
        auto jsName = facebook::jsi::String::createFromUtf8(runtime, name);
        if (payload.isNull()) {
          fn->call(runtime, std::move(jsName));
        } else {
          auto jsPayload =
              facebook::jsi::valueFromDynamic(runtime, payload);
          fn->call(runtime, std::move(jsName), std::move(jsPayload));
        }
      });
}

void DeviceEventEmitter::shutdown() {
  shutdown_.store(true, std::memory_order_release);
  emitFn_.reset();
}

facebook::jsi::Function *DeviceEventEmitter::resolveEmitFn() {
  if (emitFn_.has_value()) {
    return &emitFn_.value();
  }
  auto global = runtime_.global();
  auto custom = global.getProperty(runtime_, "__nucleusEmitDeviceEvent");
  if (custom.isObject() &&
      custom.getObject(runtime_).isFunction(runtime_)) {
    emitFn_ = custom.getObject(runtime_).getFunction(runtime_);
    return &emitFn_.value();
  }
  auto emitter = global.getProperty(runtime_, "RCTDeviceEventEmitter");
  if (!emitter.isObject()) {
    return nullptr;
  }
  auto emitterObj = emitter.getObject(runtime_);
  auto emitProp = emitterObj.getProperty(runtime_, "emit");
  if (!emitProp.isObject() ||
      !emitProp.getObject(runtime_).isFunction(runtime_)) {
    return nullptr;
  }
  emitFn_ = emitProp.getObject(runtime_).getFunction(runtime_);
  return &emitFn_.value();
}

} // namespace nucleus::react
