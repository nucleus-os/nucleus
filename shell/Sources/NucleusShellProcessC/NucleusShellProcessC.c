#define _GNU_SOURCE
#include "NucleusShellProcessC.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>

int nucleus_shell_pidfd_open(pid_t pid) {
  return (int)syscall(SYS_pidfd_open, pid, 0);
}

int nucleus_shell_pipe(int descriptors[2]) {
  return pipe2(descriptors, O_CLOEXEC);
}

int nucleus_shell_set_nonblocking(int descriptor) {
  int flags = fcntl(descriptor, F_GETFL);
  if (flags < 0) {
    return -1;
  }
  return fcntl(descriptor, F_SETFL, flags | O_NONBLOCK);
}

int nucleus_shell_reap_nohang(pid_t pid, int32_t *exit_code) {
  int status = 0;
  pid_t result;
  do {
    result = waitpid(pid, &status, WNOHANG);
  } while (result < 0 && errno == EINTR);
  if (result == 0) {
    return 0;
  }
  if (result < 0) {
    return -errno;
  }
  *exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
  return 1;
}
