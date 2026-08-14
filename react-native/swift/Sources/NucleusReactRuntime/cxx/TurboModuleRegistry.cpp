#include <NucleusReactRuntime/TurboModuleRegistry.hpp>

#include <utility>

namespace nucleus::react {

void TurboModuleRegistry::add(std::string_view name, ModuleFactory factory) {
  auto ownedName = std::string(name);
  modules_.erase(ownedName);
  factories_[std::move(ownedName)] = std::move(factory);
}

std::shared_ptr<facebook::react::TurboModule> TurboModuleRegistry::lookup(
    const std::string &name,
    std::shared_ptr<facebook::react::CallInvoker> invoker) const {
  auto module = modules_.find(name);
  if (module != modules_.end()) {
    return module->second;
  }
  auto it = factories_.find(name);
  if (it == factories_.end()) {
    return nullptr;
  }
  auto created = it->second(std::move(invoker));
  if (created != nullptr) {
    modules_.emplace(name, created);
  }
  return created;
}

void TurboModuleRegistry::clearModules() noexcept { modules_.clear(); }

bool TurboModuleRegistry::contains(const std::string &name) const {
  return factories_.find(name) != factories_.end();
}

} // namespace nucleus::react
