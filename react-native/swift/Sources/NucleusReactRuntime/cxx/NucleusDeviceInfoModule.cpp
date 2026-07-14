#include <NucleusReactRuntime/NucleusDeviceInfoModule.hpp>

#include <utility>

namespace nucleus::react {

NucleusDeviceInfoModule::NucleusDeviceInfoModule(
    std::shared_ptr<facebook::react::CallInvoker> jsInvoker,
    std::shared_ptr<DisplayMetricsState> state)
    : NativeDeviceInfoCxxSpec(std::move(jsInvoker)), state_(std::move(state)) {}

facebook::react::DeviceInfoConstants NucleusDeviceInfoModule::getConstants(
    facebook::jsi::Runtime & /*rt*/) {
  double width = 0.0;
  double height = 0.0;
  double scale = 1.0;
  double fontScale = 1.0;
  if (state_ != nullptr) {
    std::lock_guard<std::mutex> lock(state_->mutex);
    width = state_->windowWidth;
    height = state_->windowHeight;
    scale = state_->scale;
    fontScale = state_->fontScale;
  }
  facebook::react::DisplayMetrics metrics{width, height, scale, fontScale};
  facebook::react::DimensionsPayload dimensions{
      .window = metrics,
      .screen = metrics,
  };
  return facebook::react::DeviceInfoConstants{
      .Dimensions = std::move(dimensions),
  };
}

} // namespace nucleus::react
