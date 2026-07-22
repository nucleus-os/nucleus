#pragma once

#ifdef __cplusplus
extern "C" {
#endif

int nucleus_session_create_signal_fd(void);
int nucleus_session_consume_signal(int descriptor);

#ifdef __cplusplus
}
#endif
