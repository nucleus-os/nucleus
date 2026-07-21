#pragma once

#ifdef __cplusplus
extern "C" {
#endif

int nucleus_compositor_create_exit_signal_fd(void);
int nucleus_compositor_consume_exit_signal(int fd);
int nucleus_compositor_create_render_wake_fd(void);
int nucleus_compositor_signal_render_wake(int fd);
int nucleus_compositor_consume_render_wake(int fd);

#ifdef __cplusplus
}
#endif
