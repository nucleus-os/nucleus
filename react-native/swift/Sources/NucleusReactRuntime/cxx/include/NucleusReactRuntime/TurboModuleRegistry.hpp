#pragma once

#include <functional>
#include <memory>
#include <string>
#include <string_view>
#include <unordered_map>

#include <ReactCommon/CallInvoker.h>
#include <ReactCommon/TurboModule.h>

namespace nucleus::react {

// Table-driven factory for TurboModules. Replaces the hardcoded if-ladder
// that used to live inside ReactRuntimeHost. Modules register their factory
// once at host construction; the TurboModuleBinding dispatch lambda invokes
// `lookup` on each `__turboModuleProxy` access from JS.
class TurboModuleRegistry final {
 public:
  using ModuleFactory = std::function<std::shared_ptr<facebook::react::TurboModule>(
      std::shared_ptr<facebook::react::CallInvoker> invoker)>;

  TurboModuleRegistry() = default;
  TurboModuleRegistry(const TurboModuleRegistry &) = delete;
  TurboModuleRegistry &operator=(const TurboModuleRegistry &) = delete;

  // Register a factory under `name`. Replaces any prior entry for the same
  // name, so reinstalling during host re-init is well defined. Accepts both
  // `std::string` and `std::string_view` callers; upstream RN spec headers
  // expose `kModuleName` as `std::string_view`.
  void add(std::string_view name, ModuleFactory factory);

  // Returns the module instance produced by the registered factory, or
  // nullptr if no factory is registered for `name`. The factory may cache or
  // construct fresh per-call; the registry itself does not memoize.
  std::shared_ptr<facebook::react::TurboModule> lookup(
      const std::string &name,
      std::shared_ptr<facebook::react::CallInvoker> invoker) const;

  bool contains(const std::string &name) const;

  std::size_t size() const noexcept { return factories_.size(); }

 private:
  std::unordered_map<std::string, ModuleFactory> factories_;
};

} // namespace nucleus::react
