#ifndef NUCLEUS_ANDROID_PROCESS_LIFECYCLE_C_H
#define NUCLEUS_ANDROID_PROCESS_LIFECYCLE_C_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int nucleus_android_require_parent_lifetime(
    int signal_number,
    int32_t expected_parent_pid);

#ifdef __cplusplus
}
#endif

#endif
