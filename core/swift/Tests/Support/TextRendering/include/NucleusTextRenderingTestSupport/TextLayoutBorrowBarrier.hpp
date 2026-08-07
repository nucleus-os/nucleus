#pragma once

#include <cstdint>
#include <memory>

namespace nucleus::text::testing {

class TextLayoutBorrowBarrier final {
public:
  explicit TextLayoutBorrowBarrier(uint64_t handle);
  ~TextLayoutBorrowBarrier();

  TextLayoutBorrowBarrier(const TextLayoutBorrowBarrier &) = default;
  TextLayoutBorrowBarrier &operator=(
      const TextLayoutBorrowBarrier &) = default;

  bool waitUntilBodyEntered() const;
  void allowBodyToReturn() const;
  bool waitUntilBodyCompleted() const;
  bool borrowSucceeded() const;
  bool bodyCompleted() const;

  struct Impl;

private:
  std::shared_ptr<Impl> impl_;
};

bool borrowInvokesBody(uint64_t handle);
bool missingProviderIsRejected();
bool conflictingProviderIsRejected();

} // namespace nucleus::text::testing
