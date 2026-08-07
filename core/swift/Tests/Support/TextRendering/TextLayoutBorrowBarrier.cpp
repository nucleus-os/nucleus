#include <NucleusTextRenderingTestSupport/TextLayoutBorrowBarrier.hpp>

#include <condition_variable>
#include <mutex>
#include <thread>

namespace {

using TextLayoutBorrowBody =
    void (*)(uintptr_t paragraph, void *bodyContext);

extern "C" bool nucleus_skia_borrow_text_layout(
    uint64_t handle,
    void *bodyContext,
    TextLayoutBorrowBody body);
extern "C" uint8_t
nucleus_skia_install_text_layout_borrow_status(
    bool (*)(
        uint64_t handle,
        void *bodyContext,
        TextLayoutBorrowBody body));

bool conflictingBorrowProvider(
    uint64_t,
    void *,
    TextLayoutBorrowBody) {
  return false;
}

} // namespace

namespace nucleus::text::testing {

struct TextLayoutBorrowBarrier::Impl final {
  std::mutex mutex;
  std::condition_variable condition;
  std::thread thread;
  bool entered{false};
  bool mayReturn{false};
  bool succeeded{false};
  bool completed{false};
  bool finished{false};
};

namespace {

void blockingBorrowBody(
    uintptr_t paragraph,
    void *rawImpl) {
  auto *impl =
      static_cast<TextLayoutBorrowBarrier::Impl *>(rawImpl);
  if (paragraph == 0 || impl == nullptr) {
    return;
  }
  std::unique_lock lock(impl->mutex);
  impl->entered = true;
  impl->condition.notify_all();
  impl->condition.wait(
      lock,
      [&] { return impl->mayReturn; });
  impl->completed = true;
}

void markBorrowBody(
    uintptr_t paragraph,
    void *rawInvoked) {
  if (paragraph != 0 && rawInvoked != nullptr) {
    *static_cast<bool *>(rawInvoked) = true;
  }
}

} // namespace

TextLayoutBorrowBarrier::TextLayoutBorrowBarrier(
    uint64_t handle)
    : impl_(std::make_shared<Impl>()) {
  const std::shared_ptr<Impl> impl = impl_;
  impl_->thread = std::thread([impl, handle] {
    const bool succeeded =
        nucleus_skia_borrow_text_layout(
            handle,
            impl.get(),
            &blockingBorrowBody);
    std::lock_guard lock(impl->mutex);
    impl->succeeded = succeeded;
    impl->finished = true;
    impl->condition.notify_all();
  });
}

TextLayoutBorrowBarrier::~TextLayoutBorrowBarrier() {
  allowBodyToReturn();
  if (impl_ && impl_->thread.joinable()) {
    impl_->thread.join();
  }
}

bool TextLayoutBorrowBarrier::waitUntilBodyEntered() const {
  if (!impl_) {
    return false;
  }
  std::unique_lock lock(impl_->mutex);
  impl_->condition.wait(
      lock,
      [&] {
        return impl_->entered
            || impl_->finished;
      });
  return impl_->entered;
}

void TextLayoutBorrowBarrier::allowBodyToReturn() const {
  if (!impl_) {
    return;
  }
  {
    std::lock_guard lock(impl_->mutex);
    impl_->mayReturn = true;
  }
  impl_->condition.notify_all();
}

bool TextLayoutBorrowBarrier::waitUntilBodyCompleted() const {
  if (!impl_) {
    return false;
  }
  std::unique_lock lock(impl_->mutex);
  impl_->condition.wait(
      lock,
      [&] { return impl_->completed; });
  return impl_->completed;
}

bool TextLayoutBorrowBarrier::borrowSucceeded() const {
  if (!impl_) {
    return false;
  }
  std::lock_guard lock(impl_->mutex);
  return impl_->succeeded;
}

bool TextLayoutBorrowBarrier::bodyCompleted() const {
  if (!impl_) {
    return false;
  }
  std::lock_guard lock(impl_->mutex);
  return impl_->completed;
}

bool borrowInvokesBody(uint64_t handle) {
  bool invoked = false;
  const bool borrowed = nucleus_skia_borrow_text_layout(
      handle,
      &invoked,
      &markBorrowBody);
  return borrowed && invoked;
}

bool missingProviderIsRejected() {
  constexpr uint8_t missingProvider = 3;
  return nucleus_skia_install_text_layout_borrow_status(
      nullptr) == missingProvider;
}

bool conflictingProviderIsRejected() {
  constexpr uint8_t conflictingProvider = 2;
  return nucleus_skia_install_text_layout_borrow_status(
      &conflictingBorrowProvider) == conflictingProvider;
}

} // namespace nucleus::text::testing
