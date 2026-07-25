#pragma once

#include <cstdint>
#include <memory>

namespace nucleus::text::testing {

class TextLayoutBorrowProbe final {
public:
  explicit TextLayoutBorrowProbe(uint64_t handle);
  ~TextLayoutBorrowProbe();

  TextLayoutBorrowProbe(const TextLayoutBorrowProbe &) = default;
  TextLayoutBorrowProbe &operator=(
      const TextLayoutBorrowProbe &) = default;

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
