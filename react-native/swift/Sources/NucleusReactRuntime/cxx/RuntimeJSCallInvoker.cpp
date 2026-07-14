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
  std::lock_guard<std::mutex> lock(queueMutex_);
  if (shutdown_.load(std::memory_order_acquire)) {
    return;
  }
  queue_.push_back(std::move(func));
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

void RuntimeJSCallInvoker::shutdown() {
  shutdown_.store(true, std::memory_order_release);
  std::lock_guard<std::mutex> lock(queueMutex_);
  queue_.clear();
}

} // namespace nucleus::react
