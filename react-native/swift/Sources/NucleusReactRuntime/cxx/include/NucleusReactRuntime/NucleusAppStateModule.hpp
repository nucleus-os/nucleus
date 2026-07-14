#pragma once

#include <memory>
#include <mutex>
#include <string>

#include <react/coremodules/AppStateModule.h>

namespace nucleus::react {

struct AppStateState {
  std::mutex mutex;
  std::string value{"active"};
};

class NucleusAppStateModule final
    : public facebook::react::NativeAppStateCxxSpec<NucleusAppStateModule> {
 public:
  NucleusAppStateModule(
      std::shared_ptr<facebook::react::CallInvoker> jsInvoker,
      std::shared_ptr<AppStateState> state);

  facebook::react::AppStateConstants getConstants(facebook::jsi::Runtime &rt);
  void getCurrentAppState(
      facebook::jsi::Runtime &rt,
      const facebook::react::AsyncCallback<facebook::react::AppState> &success,
      facebook::jsi::Function error);
  void addListener(facebook::jsi::Runtime &rt, const std::string &eventName);
  void removeListeners(facebook::jsi::Runtime &rt, double count);

 private:
  std::shared_ptr<AppStateState> state_;
};

} // namespace nucleus::react
