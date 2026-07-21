#include "NucleusLinuxReactorC.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <sys/eventfd.h>
#include <sys/timerfd.h>
#include <time.h>
#include <unistd.h>

int nucleus_linux_reactor_create_event_fd(void) {
  int fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
  return fd >= 0 ? fd : -errno;
}

int nucleus_linux_reactor_create_timer_fd(void) {
  int fd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
  return fd >= 0 ? fd : -errno;
}

int nucleus_linux_reactor_signal(int fd) {
  uint64_t value = 1;
  ssize_t result;
  do {
    result = write(fd, &value, sizeof(value));
  } while (result < 0 && errno == EINTR);
  if (result == (ssize_t)sizeof(value) ||
      (result < 0 && errno == EAGAIN)) {
    return 0;
  }
  return result < 0 ? -errno : -EIO;
}

int nucleus_linux_reactor_drain_counter(int fd) {
  uint64_t value;
  ssize_t result;
  do {
    result = read(fd, &value, sizeof(value));
  } while (result < 0 && errno == EINTR);
  if (result == (ssize_t)sizeof(value)) {
    return 1;
  }
  if (result < 0 && errno == EAGAIN) {
    return 0;
  }
  return result < 0 ? -errno : -EIO;
}

int nucleus_linux_reactor_program_timer(int fd, uint64_t nanoseconds,
                                        int enabled) {
  struct itimerspec specification = {0};
  if (enabled) {
    if (nanoseconds == 0) {
      nanoseconds = 1;
    }
    uint64_t seconds = nanoseconds / 1000000000ULL;
    uint64_t remaining_nanoseconds = nanoseconds % 1000000000ULL;
    if (seconds > (uint64_t)INT64_MAX) {
      seconds = (uint64_t)INT64_MAX;
      remaining_nanoseconds = 999999999ULL;
    }
    specification.it_value.tv_sec = (time_t)seconds;
    specification.it_value.tv_nsec = (long)remaining_nanoseconds;
  }
  return timerfd_settime(fd, 0, &specification, NULL) == 0 ? 0 : -errno;
}

int nucleus_linux_reactor_create_pipe(int descriptors[2]) {
  if (pipe(descriptors) != 0) {
    return -errno;
  }
  for (int index = 0; index < 2; ++index) {
    int status_flags = fcntl(descriptors[index], F_GETFL);
    if (status_flags < 0 ||
        fcntl(descriptors[index], F_SETFD, FD_CLOEXEC) != 0 ||
        fcntl(descriptors[index], F_SETFL,
              status_flags | O_NONBLOCK) != 0) {
      int error = errno;
      close(descriptors[0]);
      close(descriptors[1]);
      descriptors[0] = -1;
      descriptors[1] = -1;
      return -error;
    }
  }
  return 0;
}
