#include <NucleusReactRuntime/NucleusPlatformTimerRegistry.hpp>

#include <utility>

namespace nucleus::react {

NucleusPlatformTimerRegistry::Clock::duration
NucleusPlatformTimerRegistry::delayFromMs(double ms) {
  const auto clamped = ms < 0.0 ? 0.0 : ms;
  return std::chrono::duration_cast<Clock::duration>(
      std::chrono::duration<double, std::milli>(clamped));
}

NucleusPlatformTimerRegistry::NucleusPlatformTimerRegistry(OnFire onFire)
    : onFire_(std::move(onFire)) {
  worker_ = std::thread([this] { run(); });
}

NucleusPlatformTimerRegistry::~NucleusPlatformTimerRegistry() noexcept {
  quit();
}

void NucleusPlatformTimerRegistry::createTimer(
    uint32_t timerID,
    double delayMS) {
  scheduleEntry(timerID, delayMS, /*recurring=*/false);
}

void NucleusPlatformTimerRegistry::createRecurringTimer(
    uint32_t timerID,
    double delayMS) {
  scheduleEntry(timerID, delayMS, /*recurring=*/true);
}

void NucleusPlatformTimerRegistry::deleteTimer(uint32_t timerID) {
  std::lock_guard<std::mutex> lock(mutex_);
  live_.erase(timerID);
  cv_.notify_one();
}

void NucleusPlatformTimerRegistry::quit() {
  if (stopped_.exchange(true)) {
    return;
  }
  cv_.notify_all();
  if (worker_.joinable()) {
    worker_.join();
  }
}

void NucleusPlatformTimerRegistry::scheduleEntry(
    uint32_t id,
    double delayMS,
    bool recurring) {
  const auto clampedMS = delayMS < 0.0 ? 0.0 : delayMS;
  const auto deadline = Clock::now() + delayFromMs(clampedMS);
  std::lock_guard<std::mutex> lock(mutex_);
  if (stopped_.load(std::memory_order_acquire)) {
    return;
  }
  live_.insert(id);
  queue_.push(Entry{deadline, id, clampedMS, recurring});
  cv_.notify_one();
}

void NucleusPlatformTimerRegistry::run() {
  std::unique_lock<std::mutex> lock(mutex_);
  while (!stopped_.load(std::memory_order_acquire)) {
    if (queue_.empty()) {
      cv_.wait(lock, [this] {
        return stopped_.load(std::memory_order_acquire) || !queue_.empty();
      });
      continue;
    }
    const auto next = queue_.top();
    if (next.deadline > Clock::now()) {
      cv_.wait_until(lock, next.deadline);
      continue;
    }
    queue_.pop();
    if (live_.find(next.id) == live_.end()) {
      continue;
    }
    if (next.recurring) {
      const auto reschedule = Clock::now() + delayFromMs(next.intervalMS);
      queue_.push(Entry{reschedule, next.id, next.intervalMS, true});
    } else {
      live_.erase(next.id);
    }
    const auto fireId = next.id;
    auto fire = onFire_;
    lock.unlock();
    if (fire) {
      fire(fireId);
    }
    lock.lock();
  }
}

} // namespace nucleus::react
