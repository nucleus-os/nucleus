#ifndef NUCLEUS_LOG_PREFIX_H
#define NUCLEUS_LOG_PREFIX_H

#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

size_t nucleus_log_prefix(char* buf, size_t cap);
void nucleus_log_stderr(FILE* stream, const char* format, ...);
void nucleus_log_vstderr(FILE* stream, const char* format, va_list args);

#ifdef __cplusplus
}
#endif

#define NUCLEUS_LOG_STDERR(...) nucleus_log_stderr(stderr, __VA_ARGS__)

#endif
