#include "NucleusCompositorSignalC.h"

#include <pthread.h>
#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <sys/eventfd.h>
#include <sys/signalfd.h>
#include <unistd.h>

int nucleus_compositor_create_exit_signal_fd(void) {
  sigset_t mask;
  if (sigemptyset(&mask) != 0 || sigaddset(&mask, SIGINT) != 0 ||
      sigaddset(&mask, SIGTERM) != 0 ||
      pthread_sigmask(SIG_BLOCK, &mask, NULL) != 0) {
    return -1;
  }
  return signalfd(-1, &mask, SFD_CLOEXEC | SFD_NONBLOCK);
}

int nucleus_compositor_consume_exit_signal(int fd) {
  struct signalfd_siginfo info;
  return read(fd, &info, sizeof(info)) == sizeof(info) ? (int)info.ssi_signo : -1;
}

int nucleus_compositor_create_render_wake_fd(void) {
  return eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
}

int nucleus_compositor_signal_render_wake(int fd) {
  uint64_t value = 1;
  ssize_t result;
  do {
    result = write(fd, &value, sizeof(value));
  } while (result < 0 && errno == EINTR);
  return result == (ssize_t)sizeof(value) || (result < 0 && errno == EAGAIN);
}

int nucleus_compositor_consume_render_wake(int fd) {
  uint64_t value;
  ssize_t result;
  do {
    result = read(fd, &value, sizeof(value));
  } while (result < 0 && errno == EINTR);
  if (result == (ssize_t)sizeof(value)) {
    return 1;
  }
  return result < 0 && errno == EAGAIN ? 0 : -1;
}
