#define _GNU_SOURCE
#include "NucleusAndroidProcessLifecycleC.h"

#include <errno.h>
#include <signal.h>
#include <sys/prctl.h>
#include <unistd.h>

int nucleus_android_require_parent_lifetime(
    int signal_number,
    int32_t expected_parent_pid) {
    if (signal_number <= 0 || expected_parent_pid <= 1) {
        errno = EINVAL;
        return -1;
    }
    const pid_t expected_parent = (pid_t)expected_parent_pid;
    if (getppid() != expected_parent) {
        errno = ECHILD;
        return -1;
    }
    if (prctl(PR_SET_PDEATHSIG, signal_number) < 0) return -1;
    if (getppid() != expected_parent) {
        errno = ECHILD;
        return -1;
    }
    return 0;
}
