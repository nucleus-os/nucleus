#pragma once

#include <memory>
#include <mutex>
#include <string>

#include <FBReactNativeSpec/FBReactNativeSpecJSI.h>
// Pulls in the `facebook::react::SourceCodeConstants` typedef. We don't
// instantiate the portable `SourceCodeModule` class itself — its body
// references `DevServerHelper::getBundleUrl()`, and `DevServerHelper.cpp`
// is excluded from `react_cxx_platform` (OpenSSL + dev-server stack).
// Including only the header is safe; the class isn't referenced.
#include <react/devsupport/SourceCodeModule.h>

namespace nucleus::react {

struct SourceCodeState {
  std::mutex mutex;
  std::string scriptURL;
};

// Nucleus-side SourceCode TurboModule backed by the source URL of the most recently
// evaluated bundle/script.
// without dragging in `facebook::react::SourceCodeModule`'s
// `DevServerHelper` dependency. `DevServerHelper.cpp` is excluded from
// our `react_cxx_platform` build (OpenSSL + dev-server stack), so the
// portable `SourceCodeModule.cpp`'s unconditional reference to
// `getBundleUrl()` would fail at link time even when constructed with
// a null helper.
class NucleusSourceCodeModule final
    : public facebook::react::NativeSourceCodeCxxSpec<NucleusSourceCodeModule> {
 public:
  explicit NucleusSourceCodeModule(
      std::shared_ptr<facebook::react::CallInvoker> jsInvoker,
      std::shared_ptr<SourceCodeState> state);

  facebook::react::SourceCodeConstants getConstants(facebook::jsi::Runtime &rt);

 private:
  std::shared_ptr<SourceCodeState> state_;
};

} // namespace nucleus::react
