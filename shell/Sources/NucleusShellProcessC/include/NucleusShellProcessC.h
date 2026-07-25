#pragma once

#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

int nucleus_shell_pidfd_open(pid_t pid);
int nucleus_shell_pipe(int descriptors[2]);
int nucleus_shell_set_nonblocking(int descriptor);
// 0 while running, 1 after reap, or a negative errno. `exit_code` is -1 for
// signal death and otherwise contains the normal process exit code.
int nucleus_shell_reap_nohang(pid_t pid, int32_t *exit_code);

#ifdef __cplusplus
}
#endif
