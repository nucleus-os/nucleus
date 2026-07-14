#include <NucleusReactRuntime/TurboModuleRegistry.hpp>

#include <utility>

namespace nucleus::react {

void TurboModuleRegistry::add(std::string_view name, ModuleFactory factory) {
  factories_[std::string(name)] = std::move(factory);
}

std::shared_ptr<facebook::react::TurboModule> TurboModuleRegistry::lookup(
    const std::string &name,
    std::shared_ptr<facebook::react::CallInvoker> invoker) const {
  auto it = factories_.find(name);
  if (it == factories_.end()) {
    return nullptr;
  }
  return it->second(std::move(invoker));
}

bool TurboModuleRegistry::contains(const std::string &name) const {
  return factories_.find(name) != factories_.end();
}

} // namespace nucleus::react
