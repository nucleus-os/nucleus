#pragma once

#ifdef __cplusplus
extern "C" {
#endif

int nucleus_shell_create_exit_signal_fd(void);
int nucleus_shell_consume_exit_signal(int fd);
int nucleus_shell_create_render_wake_fd(void);
int nucleus_shell_signal_render_wake(int fd);
int nucleus_shell_consume_render_wake(int fd);

#ifdef __cplusplus
}
#endif
