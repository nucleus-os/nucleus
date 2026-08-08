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

void RuntimeJSCallInvoker::invokeAsync(
    facebook::react::CallFunc &&func) noexcept {
  if (shutdown_.load(std::memory_order_acquire)) {
    return;
  }
  if (std::this_thread::get_id() == jsThreadId_) {
    runOrLogException("invokeAsync", func, runtime_);
    return;
  }
  std::shared_ptr<const JSWorkWake> wake;
  {
    std::lock_guard<std::mutex> lock(queueMutex_);
    if (shutdown_.load(std::memory_order_acquire)) {
      return;
    }
    const bool wasEmpty = queue_.empty();
    queue_.push_back(std::move(func));
    if (wasEmpty) {
      wake = wake_;
    }
  }
  if (wake != nullptr && *wake) {
    (*wake)();
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

void RuntimeJSCallInvoker::setWakeHandler(JSWorkWake wake) {
  std::shared_ptr<const JSWorkWake> next;
  if (wake) {
    next = std::make_shared<const JSWorkWake>(std::move(wake));
  }
  bool hasPending = false;
  std::shared_ptr<const JSWorkWake> retired;
  {
    std::lock_guard<std::mutex> lock(queueMutex_);
    retired = std::exchange(wake_, next);
    hasPending = !queue_.empty();
  }
  // `retired` drops here, outside the lock. Destroying the previous wake
  // releases its Swift captures, which can run arbitrary deinitializers; doing
  // that under `queueMutex_` would let teardown deadlock by re-entering this
  // invoker.
  retired.reset();
  if (hasPending && next != nullptr && *next) {
    (*next)();
  }
}

void RuntimeJSCallInvoker::shutdown() {
  shutdown_.store(true, std::memory_order_release);
  std::shared_ptr<const JSWorkWake> retired;
  {
    std::lock_guard<std::mutex> lock(queueMutex_);
    queue_.clear();
    retired = std::exchange(wake_, nullptr);
  }
  // Retired outside the lock, for the reason given in `setWakeHandler`.
}

} // namespace nucleus::react
