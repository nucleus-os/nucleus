#include <NucleusReactRuntime/HostCommandBridge.hpp>

#include <string>
#include <utility>

namespace nucleus::react {

HostCommandHandler::Entry::Entry(Callback callback, void *context, Release release)
    : callback(callback), context(context), release(release) {}

HostCommandHandler::Entry::~Entry() {
  if (release != nullptr) {
    release(context);
  }
}

void HostCommandHandler::set(Callback callback, void *context, Release release) {
  std::shared_ptr<Entry> replacement;
  if (callback == nullptr) {
    if (release != nullptr) {
      release(context);
    }
  } else {
    try {
      replacement = std::make_shared<Entry>(callback, context, release);
    } catch (...) {
      if (release != nullptr) {
        release(context);
      }
      throw;
    }
  }
  std::shared_ptr<Entry> retired;
  {
    std::lock_guard lock(mutex_);
    retired = std::exchange(entry_, std::move(replacement));
  }
  // Releasing Swift captures can run arbitrary deinitializers. Do it after the
  // mutex is unlocked so teardown cannot deadlock by re-entering this bridge.
}

std::shared_ptr<HostCommandHandler::Entry> HostCommandHandler::get() const {
  std::lock_guard lock(mutex_);
  return entry_;
}

HostCommandTurboModule::HostCommandTurboModule(
    std::shared_ptr<facebook::react::CallInvoker> jsInvoker,
    std::shared_ptr<HostCommandHandler> handler)
    : facebook::react::TurboModule("NucleusHostCommand", std::move(jsInvoker)),
      handler_(std::move(handler)) {}

facebook::jsi::Value HostCommandTurboModule::get(
    facebook::jsi::Runtime &runtime,
    const facebook::jsi::PropNameID &propName) {
  if (propName.utf8(runtime) != "invoke") {
    return facebook::jsi::Value::undefined();
  }
  return facebook::jsi::Function::createFromHostFunction(
      runtime,
      propName,
      2,
      [handler = handler_](
          facebook::jsi::Runtime &rt,
          const facebook::jsi::Value &,
          const facebook::jsi::Value *args,
          std::size_t count) -> facebook::jsi::Value {
        const auto entry = handler->get();
        if (entry != nullptr && count >= 1 && args[0].isString()) {
          const std::string command = args[0].asString(rt).utf8(rt);
          const std::string argsJson =
              count >= 2 && args[1].isString()
              ? args[1].asString(rt).utf8(rt)
              : std::string();
          entry->callback(entry->context, command.c_str(), argsJson.c_str());
        }
        return facebook::jsi::Value::undefined();
      });
}

} // namespace nucleus::react
