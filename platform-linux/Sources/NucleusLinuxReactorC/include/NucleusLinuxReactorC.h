#ifndef NUCLEUS_LINUX_REACTOR_C_H
#define NUCLEUS_LINUX_REACTOR_C_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int nucleus_linux_reactor_create_event_fd(void);
int nucleus_linux_reactor_create_timer_fd(void);
int nucleus_linux_reactor_signal(int fd);
int nucleus_linux_reactor_drain_counter(int fd);
int nucleus_linux_reactor_program_timer(int fd, uint64_t nanoseconds,
                                        int enabled);
int nucleus_linux_reactor_create_pipe(int descriptors[2]);

#ifdef __cplusplus
}
#endif

#endif
