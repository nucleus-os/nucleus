#define _GNU_SOURCE
#include "NucleusLinuxSessionC.h"

#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

int nucleus_session_create_pipe(int descriptors[2], int nonblocking) {
  int flags = O_CLOEXEC | (nonblocking ? O_NONBLOCK : 0);
  return pipe2(descriptors, flags) == 0 ? 0 : -errno;
}
