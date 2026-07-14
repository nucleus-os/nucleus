#include <NucleusReactRuntime/NucleusSourceCodeModule.hpp>

#include <utility>

namespace nucleus::react {

NucleusSourceCodeModule::NucleusSourceCodeModule(
    std::shared_ptr<facebook::react::CallInvoker> jsInvoker,
    std::shared_ptr<SourceCodeState> state)
    : NativeSourceCodeCxxSpec(std::move(jsInvoker)), state_(std::move(state)) {}

facebook::react::SourceCodeConstants NucleusSourceCodeModule::getConstants(
    facebook::jsi::Runtime & /*rt*/) {
  std::lock_guard<std::mutex> lock(state_->mutex);
  return facebook::react::SourceCodeConstants{.scriptURL = state_->scriptURL};
}

} // namespace nucleus::react
