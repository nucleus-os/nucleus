#pragma once

#ifdef __cplusplus
extern "C" {
#endif

int nucleus_compositor_create_exit_signal_fd(void);
int nucleus_compositor_consume_exit_signal(int fd);

#ifdef __cplusplus
}
#endif
