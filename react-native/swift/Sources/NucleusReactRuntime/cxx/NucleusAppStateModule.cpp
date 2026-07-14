#include <NucleusReactRuntime/NucleusAppStateModule.hpp>

namespace nucleus::react {

NucleusAppStateModule::NucleusAppStateModule(
    std::shared_ptr<facebook::react::CallInvoker> jsInvoker,
    std::shared_ptr<AppStateState> state)
    : NativeAppStateCxxSpec(std::move(jsInvoker)), state_(std::move(state)) {}

facebook::react::AppStateConstants NucleusAppStateModule::getConstants(
    facebook::jsi::Runtime &) {
  std::lock_guard<std::mutex> lock(state_->mutex);
  return facebook::react::AppStateConstants{.initialAppState = state_->value};
}

void NucleusAppStateModule::getCurrentAppState(
    facebook::jsi::Runtime &,
    const facebook::react::AsyncCallback<facebook::react::AppState> &success,
    facebook::jsi::Function) {
  std::lock_guard<std::mutex> lock(state_->mutex);
  success({facebook::react::AppState{.app_state = state_->value}});
}

void NucleusAppStateModule::addListener(facebook::jsi::Runtime &, const std::string &) {}
void NucleusAppStateModule::removeListeners(facebook::jsi::Runtime &, double) {}

} // namespace nucleus::react
