#include <NucleusReactRuntime/HostCommandBridge.hpp>

#include <string>
#include <utility>

namespace nucleus::react {

void HostCommandHandler::set(HostCommand handler) {
  std::shared_ptr<const HostCommand> replacement;
  if (handler) {
    replacement = std::make_shared<const HostCommand>(std::move(handler));
  }
  std::shared_ptr<const HostCommand> retired;
  {
    std::lock_guard lock(mutex_);
    retired = std::exchange(handler_, std::move(replacement));
  }
  // Releasing Swift captures can run arbitrary deinitializers. `retired` drops
  // after the mutex is unlocked so teardown cannot deadlock by re-entering
  // this bridge.
}

std::shared_ptr<const HostCommandHandler::HostCommand> HostCommandHandler::get()
    const {
  std::lock_guard lock(mutex_);
  return handler_;
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
        const auto installed = handler->get();
        if (installed != nullptr && *installed && count >= 1 &&
            args[0].isString()) {
          const std::string command = args[0].asString(rt).utf8(rt);
          const std::string argsJson =
              count >= 2 && args[1].isString()
              ? args[1].asString(rt).utf8(rt)
              : std::string();
          (*installed)(command, argsJson);
        }
        return facebook::jsi::Value::undefined();
      });
}

} // namespace nucleus::react
