#pragma once

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <mutex>
#include <queue>
#include <thread>
#include <unordered_set>
#include <vector>

#include <react/runtime/PlatformTimerRegistry.h>

namespace nucleus::react {

// Schedules `TimerManager::callTimer(id)` fires onto a dedicated worker thread.
// The compositor's io_uring loop and the JS runtime live on the main thread;
// timer fires arrive cross-thread and are routed back through the host's
// `CallInvoker` (which queues for the next `drainPendingJSCalls` tick).
class NucleusPlatformTimerRegistry final
    : public facebook::react::PlatformTimerRegistry {
 public:
  using OnFire = std::function<void(uint32_t timerID)>;

  explicit NucleusPlatformTimerRegistry(OnFire onFire);
  ~NucleusPlatformTimerRegistry() noexcept override;

  NucleusPlatformTimerRegistry(const NucleusPlatformTimerRegistry &) = delete;
  NucleusPlatformTimerRegistry &operator=(
      const NucleusPlatformTimerRegistry &) = delete;
  NucleusPlatformTimerRegistry(NucleusPlatformTimerRegistry &&) = delete;
  NucleusPlatformTimerRegistry &operator=(NucleusPlatformTimerRegistry &&) =
      delete;

  void createTimer(uint32_t timerID, double delayMS) override;
  void createRecurringTimer(uint32_t timerID, double delayMS) override;
  void deleteTimer(uint32_t timerID) override;
  void quit() override;

 private:
  using Clock = std::chrono::steady_clock;
  using TimePoint = Clock::time_point;

  struct Entry {
    TimePoint deadline;
    uint32_t id;
    double intervalMS;
    bool recurring;
    bool operator>(const Entry &other) const noexcept {
      return deadline > other.deadline;
    }
  };

  void run();
  void scheduleEntry(uint32_t id, double delayMS, bool recurring);
  static Clock::duration delayFromMs(double ms);

  OnFire onFire_;
  std::mutex mutex_;
  std::condition_variable cv_;
  std::priority_queue<Entry, std::vector<Entry>, std::greater<Entry>> queue_;
  std::unordered_set<uint32_t> live_;
  std::atomic<bool> stopped_{false};
  std::thread worker_;
};

} // namespace nucleus::react
