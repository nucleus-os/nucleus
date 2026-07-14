#include "NucleusShellSignalC.h"

#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <sys/signalfd.h>
#include <unistd.h>

int nucleus_shell_create_exit_signal_fd(void) {
  sigset_t mask;
  if (sigemptyset(&mask) != 0 || sigaddset(&mask, SIGINT) != 0 ||
      sigaddset(&mask, SIGTERM) != 0 ||
      pthread_sigmask(SIG_BLOCK, &mask, NULL) != 0) {
    return -1;
  }
  return signalfd(-1, &mask, SFD_CLOEXEC | SFD_NONBLOCK);
}

int nucleus_shell_consume_exit_signal(int fd) {
  struct signalfd_siginfo info;
  return read(fd, &info, sizeof(info)) == sizeof(info) ? (int)info.ssi_signo : -1;
}
