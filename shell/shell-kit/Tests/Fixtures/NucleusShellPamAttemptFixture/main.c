#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int read_all(void *buffer, size_t count) {
  size_t filled = 0;
  while (filled < count) {
    ssize_t result = read(STDIN_FILENO, (char *)buffer + filled, count - filled);
    if (result <= 0) return 0;
    filled += (size_t)result;
  }
  return 1;
}

static void write_all(const void *buffer, size_t count) {
  size_t written = 0;
  while (written < count) {
    ssize_t result =
        write(STDOUT_FILENO, (const char *)buffer + written, count - written);
    if (result <= 0) _exit(9);
    written += (size_t)result;
  }
}

int main(void) {
  uint32_t service_length = 0;
  if (!read_all(&service_length, sizeof(service_length)) ||
      service_length > 256) return 8;
  char service[257] = {0};
  if (!read_all(service, service_length)) return 8;
  uint32_t password_length = 0;
  if (!read_all(&password_length, sizeof(password_length)) ||
      password_length > 1024) return 8;
  char password[1024];
  if (!read_all(password, password_length)) return 8;
  memset(password, 0, sizeof(password));

  if (strcmp(service, "exit-first") == 0) return 1;
  if (strcmp(service, "crash") == 0) {
    raise(SIGSEGV);
    return 8;
  }
  if (strcmp(service, "silent") == 0) {
    for (;;) pause();
  }
  if (strcmp(service, "malformed") == 0) {
    const uint8_t frame[] = {9, 0, 0, 0, 0};
    write_all(frame, sizeof(frame));
    return 0;
  }
  if (strcmp(service, "partial") == 0) {
    const uint8_t partial[] = {1, 4, 0};
    write_all(partial, sizeof(partial));
    return 0;
  }
  if (strcmp(service, "oversized") == 0) {
    const uint8_t frame[] = {1, 1, 16, 0, 0};
    write_all(frame, sizeof(frame));
    return 0;
  }

  const uint8_t accepted[] = {1, 0, 0, 0, 0};
  write_all(accepted, sizeof(accepted));
  if (strcmp(service, "linger") == 0) {
    for (;;) pause();
  }
  return 0;
}
