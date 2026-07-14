#pragma once

#include <memory>
#include <mutex>

#include <react/coremodules/DeviceInfoModule.h>

namespace nucleus::react {

// Mutable backing store the host updates in response to output-size
// changes; `NucleusDeviceInfoModule` reads it under the lock during
// `getConstants`. Defaults are zero so JS that queries before the host
// configures a surface gets a sentinel rather than a stale value.
struct DisplayMetricsState {
  std::mutex mutex;
  double windowWidth{0.0};
  double windowHeight{0.0};
  double scale{1.0};
  double fontScale{1.0};
};

class NucleusDeviceInfoModule final
    : public facebook::react::NativeDeviceInfoCxxSpec<NucleusDeviceInfoModule> {
 public:
  NucleusDeviceInfoModule(
      std::shared_ptr<facebook::react::CallInvoker> jsInvoker,
      std::shared_ptr<DisplayMetricsState> state);

  facebook::react::DeviceInfoConstants getConstants(facebook::jsi::Runtime &rt);

 private:
  std::shared_ptr<DisplayMetricsState> state_;
};

} // namespace nucleus::react
