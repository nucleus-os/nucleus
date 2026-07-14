#pragma once

#include <cstddef>
#include <cstdint>

namespace swift_tracy {

struct ZoneContext final {
  uint32_t id{0};
  int32_t active{0};
};

class TraceBridge final {
 public:
  static bool enabled();
  static bool connected();

  static ZoneContext beginZone(
      const char *name,
      size_t nameLength,
      const char *function,
      size_t functionLength,
      const char *file,
      size_t fileLength,
      uint32_t line,
      uint32_t color);

  static void endZone(ZoneContext zone);
  static void zoneValue(ZoneContext zone, uint64_t value);
  static void zoneText(ZoneContext zone, const char *text, size_t textLength);

  static void setThreadName(const char *name, size_t nameLength);
  static void message(const char *text, size_t textLength);
  static void messageColor(const char *text, size_t textLength, uint32_t color);
  static void plot(const char *name, double value);
  static void plotInt(const char *name, int64_t value);
  static void frameMarkStart(const char *name);
  static void frameMarkEnd(const char *name);
};

} // namespace swift_tracy
