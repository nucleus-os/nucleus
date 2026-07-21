#include <NucleusReactRuntime/RuntimeJSCallInvoker.hpp>

#include <cstdio>
#include <exception>
#include <stdexcept>
#include <string>
#include <utility>

namespace nucleus::react {

namespace {

[[noreturn]] void throwInvokerOutOfThread(const char *context) {
  throw std::runtime_error(
      std::string("RuntimeJSCallInvoker::") + context +
      " called from non-JS thread");
}

void runOrLogException(
    const char *context,
    facebook::react::CallFunc &func,
    facebook::jsi::Runtime &runtime) {
  try {
    func(runtime);
  } catch (const std::exception &exception) {
    std::fprintf(
        stderr,
        "RuntimeJSCallInvoker::%s exception: %s\n",
        context,
        exception.what());
    std::fflush(stderr);
  } catch (...) {
    std::fprintf(
        stderr,
        "RuntimeJSCallInvoker::%s unknown exception\n",
        context);
    std::fflush(stderr);
  }
}

} // namespace

RuntimeJSCallInvoker::RuntimeJSCallInvoker(
    facebook::jsi::Runtime &runtime,
    std::thread::id jsThreadId)
    : runtime_(runtime), jsThreadId_(jsThreadId) {}

RuntimeJSCallInvoker::WakeEntry::WakeEntry(
    WakeCallback callback,
    void *context,
    WakeContextRelease release)
    : callback(callback), context(context), release(release) {}

RuntimeJSCallInvoker::WakeEntry::~WakeEntry() {
  if (release != nullptr) {
    release(context);
  }
}

void RuntimeJSCallInvoker::invokeAsync(
    facebook::react::CallFunc &&func) noexcept {
  if (shutdown_.load(std::memory_order_acquire)) {
    return;
  }
  if (std::this_thread::get_id() == jsThreadId_) {
    runOrLogException("invokeAsync", func, runtime_);
    return;
  }
  std::shared_ptr<WakeEntry> wake;
  {
    std::lock_guard<std::mutex> lock(queueMutex_);
    if (shutdown_.load(std::memory_order_acquire)) {
      return;
    }
    const bool wasEmpty = queue_.empty();
    queue_.push_back(std::move(func));
    if (wasEmpty) {
      wake = wakeEntry_;
    }
  }
  if (wake != nullptr && wake->callback != nullptr) {
    wake->callback(wake->context);
  }
}

void RuntimeJSCallInvoker::invokeSync(facebook::react::CallFunc &&func) {
  if (std::this_thread::get_id() != jsThreadId_) {
    throwInvokerOutOfThread("invokeSync");
  }
  func(runtime_);
}

std::size_t RuntimeJSCallInvoker::drainPending() {
  if (std::this_thread::get_id() != jsThreadId_) {
    throwInvokerOutOfThread("drainPending");
  }
  std::deque<facebook::react::CallFunc> pending;
  {
    std::lock_guard<std::mutex> lock(queueMutex_);
    pending.swap(queue_);
  }
  std::size_t drained = 0;
  for (auto &func : pending) {
    runOrLogException("drainPending", func, runtime_);
    ++drained;
  }
  return drained;
}

void RuntimeJSCallInvoker::setWakeHandler(
    WakeCallback callback,
    void *context,
    WakeContextRelease release) {
  std::shared_ptr<WakeEntry> next;
  if (callback != nullptr || context != nullptr || release != nullptr) {
    next = std::make_shared<WakeEntry>(callback, context, release);
  }
  bool hasPending = false;
  {
    std::lock_guard<std::mutex> lock(queueMutex_);
    wakeEntry_ = next;
    hasPending = !queue_.empty();
  }
  if (hasPending && next != nullptr && next->callback != nullptr) {
    next->callback(next->context);
  }
}

void RuntimeJSCallInvoker::shutdown() {
  shutdown_.store(true, std::memory_order_release);
  std::lock_guard<std::mutex> lock(queueMutex_);
  queue_.clear();
  wakeEntry_.reset();
}

} // namespace nucleus::react
