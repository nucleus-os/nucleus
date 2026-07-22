#include "NucleusLinuxSessionC.h"

#include <pthread.h>
#include <signal.h>
#include <sys/signalfd.h>
#include <unistd.h>

int nucleus_session_create_signal_fd(void) {
  sigset_t mask;
  if (signal(SIGPIPE, SIG_IGN) == SIG_ERR || sigemptyset(&mask) != 0 ||
      sigaddset(&mask, SIGCHLD) != 0 || sigaddset(&mask, SIGINT) != 0 ||
      sigaddset(&mask, SIGTERM) != 0 || sigaddset(&mask, SIGHUP) != 0 ||
      pthread_sigmask(SIG_BLOCK, &mask, NULL) != 0) {
    return -1;
  }
  return signalfd(-1, &mask, SFD_CLOEXEC | SFD_NONBLOCK);
}

int nucleus_session_consume_signal(int descriptor) {
  struct signalfd_siginfo info;
  return read(descriptor, &info, sizeof(info)) == sizeof(info)
             ? (int)info.ssi_signo
             : -1;
}
