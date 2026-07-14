#pragma once

#ifdef __cplusplus
extern "C" {
#endif

int nucleus_shell_create_exit_signal_fd(void);
int nucleus_shell_consume_exit_signal(int fd);

#ifdef __cplusplus
}
#endif
