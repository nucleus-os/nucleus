#include "log_prefix.h"

#include <stdint.h>
#include <string.h>
#include <time.h>

static uint64_t g_log_start_mono_ns = 0;

static uint64_t timespec_to_ns(const struct timespec* ts) {
    return (uint64_t)ts->tv_sec * 1000000000ull + (uint64_t)ts->tv_nsec;
}

static uint64_t log_start_mono_ns(uint64_t mono_ns) {
    uint64_t start_ns = __atomic_load_n(&g_log_start_mono_ns, __ATOMIC_RELAXED);
    if (start_ns != 0) return start_ns;

    uint64_t expected = 0;
    if (__atomic_compare_exchange_n(
            &g_log_start_mono_ns,
            &expected,
            mono_ns,
            0,
            __ATOMIC_RELAXED,
            __ATOMIC_RELAXED))
    {
        return mono_ns;
    }
    return expected;
}

size_t nucleus_log_prefix(char* buf, size_t cap) {
    if (!buf || cap == 0) return 0;

    struct timespec realtime_ts = {};
    struct timespec mono_ts = {};
    const int realtime_ok = clock_gettime(CLOCK_REALTIME, &realtime_ts);
    const int mono_ok = clock_gettime(CLOCK_MONOTONIC, &mono_ts);

    const uint64_t mono_ns = mono_ok == 0 ? timespec_to_ns(&mono_ts) : 0;
    const uint64_t start_ns = mono_ok == 0 ? log_start_mono_ns(mono_ns) : 0;
    const double delta_s = mono_ok == 0 ? (double)(mono_ns - start_ns) / 1000000000.0 : 0.0;

    char time_buf[32] = {0};
    char tz_buf[16] = {0};
    if (realtime_ok == 0) {
        const time_t real_sec = realtime_ts.tv_sec;
        struct tm local_tm = {};
        if (localtime_r(&real_sec, &local_tm) != NULL) {
            if (strftime(time_buf, sizeof(time_buf), "%Y-%m-%d %H:%M:%S", &local_tm) == 0) {
                time_buf[0] = '\0';
            }
            if (strftime(tz_buf, sizeof(tz_buf), "%z", &local_tm) == 0) {
                tz_buf[0] = '\0';
            }
        }
    }

    const long millis = realtime_ok == 0 ? realtime_ts.tv_nsec / 1000000L : 0L;
    const int written = snprintf(
        buf,
        cap,
        "[%s.%03ld%s%s t+%.3fs] ",
        time_buf[0] != '\0' ? time_buf : "unknown-time",
        millis,
        tz_buf[0] != '\0' ? " " : "",
        tz_buf,
        delta_s);
    if (written <= 0) return 0;
    const size_t len = (size_t)written;
    if (len >= cap) return cap - 1;
    return len;
}

void nucleus_log_vstderr(FILE* stream, const char* format, va_list args) {
    FILE* target = stream ? stream : stderr;
    flockfile(target);

    char prefix[96];
    const size_t prefix_len = nucleus_log_prefix(prefix, sizeof(prefix));
    if (prefix_len > 0) {
        (void)fwrite(prefix, 1, prefix_len, target);
    }
    (void)vfprintf(target, format, args);
    (void)fflush(target);

    funlockfile(target);
}

void nucleus_log_stderr(FILE* stream, const char* format, ...) {
    va_list args;
    va_start(args, format);
    nucleus_log_vstderr(stream, format, args);
    va_end(args);
}
