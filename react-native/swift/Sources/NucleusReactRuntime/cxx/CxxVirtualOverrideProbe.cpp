#include <NucleusReactRuntime/CxxVirtualOverrideProbe.hpp>

namespace nucleus::react::probe {

std::string runProbe(std::shared_ptr<Observer> observer, const std::string &message) {
  observer->notify(message);
  return message;
}

} // namespace nucleus::react::probe
