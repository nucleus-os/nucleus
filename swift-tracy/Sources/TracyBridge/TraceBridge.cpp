#include <TracyBridge/TraceBridge.h>

// Tracy's own switch (`-Xcc -DTRACY_ENABLE`) is the single toggle for the whole
// tracing stack. When it is set, the Tracy client translation unit
// compiles the instrumentation and defines the ___tracy_* symbols, so this
// bridge's calls must turn on to match. Enabling only one side would either
// reference undefined ___tracy_* symbols or link a client nothing calls, so
// TRACY_ENABLE implies SWIFT_TRACY_ENABLED here.
#if defined(TRACY_ENABLE) && !defined(SWIFT_TRACY_ENABLED)
#define SWIFT_TRACY_ENABLED 1
#endif

#if SWIFT_TRACY_ENABLED

#include <cstring>
#include <deque>
#include <mutex>
#include <string>

struct ___tracy_c_zone_context {
  uint32_t id;
  int32_t active;
};

// Tracy's static source-location record. Layout matches Tracy's
// `___tracy_source_location_data` (we declare the C entry points by hand rather
// than pulling in TracyC.h). A `name` of nullptr means "no custom name".
struct ___tracy_source_location_data {
  const char *name;
  const char *function;
  const char *file;
  uint32_t line;
  uint32_t color;
};

// Static source locations are interned once and live for the process lifetime,
// so Tracy never frees them. This is deliberately NOT the allocated-srcloc API
// (`___tracy_alloc_srcloc*` / `___tracy_emit_zone_begin_alloc`): those return a
// single-use, Tracy-owned pointer freed after one `emit_zone_begin_alloc`, so
// caching and re-emitting one is a use-after-free + double-free.
extern "C" ___tracy_c_zone_context ___tracy_emit_zone_begin(
    const ___tracy_source_location_data *srcloc, int32_t active);
extern "C" void ___tracy_emit_zone_end(___tracy_c_zone_context ctx);
extern "C" void ___tracy_emit_zone_text(___tracy_c_zone_context ctx, const char *txt, size_t size);
extern "C" void ___tracy_emit_zone_value(___tracy_c_zone_context ctx, uint64_t value);
extern "C" void ___tracy_set_thread_name(const char *name);
// Tracy's message C API is severity-based: the old ___tracy_emit_message{,C}
// entry points were replaced by ___tracy_emit_logString(severity, color,
// callstack_depth, size, txt). Severity 2 is TracyMessageSeverityInfo.
constexpr int8_t kTracySeverityInfo = 2;
extern "C" void ___tracy_emit_logString(
    int8_t severity, int32_t color, int32_t callstack_depth, size_t size, const char *txt);
extern "C" void ___tracy_emit_plot(const char *name, double val);
extern "C" void ___tracy_emit_plot_int(const char *name, int64_t val);
extern "C" void ___tracy_emit_frame_mark_start(const char *name);
extern "C" void ___tracy_emit_frame_mark_end(const char *name);
extern "C" int32_t ___tracy_connected(void);

namespace {

struct SourceLocationSlot final {
  std::string name;
  std::string function;
  std::string file;
  uint32_t line{0};
  uint32_t color{0};
  // Points at this slot's own persistent strings; valid for the slot's (i.e.
  // the process's) lifetime. `&loc` is handed to Tracy and must stay stable —
  // see the std::deque note below.
  ___tracy_source_location_data loc{};
};

std::mutex sourceLocationLock;
// std::deque, NOT std::vector: a static source location's address (`&slot.loc`)
// and its string pointers must never move once registered with Tracy. deque
// keeps existing elements at stable addresses across push_back; vector would
// reallocate and dangle every previously-registered srcloc.
std::deque<SourceLocationSlot> sourceLocationSlots;
std::mutex internedStringLock;
// std::deque for the same reason as sourceLocationSlots: internString hands
// Tracy a `c_str()` it must keep forever (plot names), and a std::vector
// reallocation would move the strings (dangling the small-string-optimized
// ones). deque keeps each interned string at a stable address.
std::deque<std::string> internedStrings;

std::string stringFromBytes(const char *bytes, size_t length)
{
  return bytes == nullptr || length == 0 ? std::string{} : std::string(bytes, length);
}

bool matches(
    const SourceLocationSlot &slot,
    const std::string &name,
    const std::string &function,
    const std::string &file,
    uint32_t line,
    uint32_t color)
{
  return slot.line == line &&
      slot.color == color &&
      slot.name == name &&
      slot.function == function &&
      slot.file == file;
}

const ___tracy_source_location_data *sourceLocation(
    const char *nameBytes,
    size_t nameLength,
    const char *functionBytes,
    size_t functionLength,
    const char *fileBytes,
    size_t fileLength,
    uint32_t line,
    uint32_t color)
{
  auto name = stringFromBytes(nameBytes, nameLength);
  auto function = stringFromBytes(functionBytes, functionLength);
  auto file = stringFromBytes(fileBytes, fileLength);

  std::scoped_lock lock(sourceLocationLock);
  for (const auto &slot : sourceLocationSlots) {
    if (matches(slot, name, function, file, line, color)) {
      return &slot.loc;
    }
  }

  auto &slot = sourceLocationSlots.emplace_back(SourceLocationSlot{
      .name = std::move(name),
      .function = std::move(function),
      .file = std::move(file),
      .line = line,
      .color = color,
  });
  // Build the static record only after the slot is at its final, stable deque
  // address, pointing at the slot's own persistent strings. A null name field
  // is Tracy's convention for "no custom name".
  slot.loc = ___tracy_source_location_data{
      .name = slot.name.empty() ? nullptr : slot.name.c_str(),
      .function = slot.function.c_str(),
      .file = slot.file.c_str(),
      .line = line,
      .color = color,
  };
  return &slot.loc;
}

const char *internString(const char *bytes, size_t length)
{
  auto value = stringFromBytes(bytes, length);
  std::scoped_lock lock(internedStringLock);
  for (const auto &candidate : internedStrings) {
    if (candidate == value) {
      return candidate.c_str();
    }
  }
  internedStrings.push_back(std::move(value));
  return internedStrings.back().c_str();
}

} // namespace

#endif

extern "C" bool swift_tracy_enabled(void)
{
#if SWIFT_TRACY_ENABLED
  return true;
#else
  return false;
#endif
}

extern "C" bool swift_tracy_connected(void)
{
#if SWIFT_TRACY_ENABLED
  return ___tracy_connected() != 0;
#else
  return false;
#endif
}

extern "C" SwiftTracyZoneContext swift_tracy_begin_zone(
    const char *name,
    size_t nameLength,
    const char *function,
    size_t functionLength,
    const char *file,
    size_t fileLength,
    uint32_t line,
    uint32_t color)
{
#if SWIFT_TRACY_ENABLED
  const auto *loc = sourceLocation(
      name,
      nameLength,
      function,
      functionLength,
      file,
      fileLength,
      line,
      color);
  if (loc == nullptr) {
    return {};
  }
  const auto context = ___tracy_emit_zone_begin(loc, 1);
  return SwiftTracyZoneContext{context.id, context.active};
#else
  (void)name;
  (void)nameLength;
  (void)function;
  (void)functionLength;
  (void)file;
  (void)fileLength;
  (void)line;
  (void)color;
  return {};
#endif
}

extern "C" void swift_tracy_end_zone(SwiftTracyZoneContext zone)
{
#if SWIFT_TRACY_ENABLED
  ___tracy_emit_zone_end(___tracy_c_zone_context{zone.id, zone.active});
#else
  (void)zone;
#endif
}

extern "C" void swift_tracy_zone_value(SwiftTracyZoneContext zone, uint64_t value)
{
#if SWIFT_TRACY_ENABLED
  ___tracy_emit_zone_value(___tracy_c_zone_context{zone.id, zone.active}, value);
#else
  (void)zone;
  (void)value;
#endif
}

extern "C" void swift_tracy_zone_text(
    SwiftTracyZoneContext zone,
    const char *text,
    size_t textLength)
{
#if SWIFT_TRACY_ENABLED
  ___tracy_emit_zone_text(___tracy_c_zone_context{zone.id, zone.active}, text, textLength);
#else
  (void)zone;
  (void)text;
  (void)textLength;
#endif
}

extern "C" void swift_tracy_set_thread_name(const char *name, size_t nameLength)
{
#if SWIFT_TRACY_ENABLED
  auto copy = stringFromBytes(name, nameLength);
  ___tracy_set_thread_name(copy.c_str());
#else
  (void)name;
  (void)nameLength;
#endif
}

extern "C" void swift_tracy_message(const char *text, size_t textLength)
{
#if SWIFT_TRACY_ENABLED
  ___tracy_emit_logString(kTracySeverityInfo, 0, 0, textLength, text);
#else
  (void)text;
  (void)textLength;
#endif
}

extern "C" void swift_tracy_message_color(
    const char *text,
    size_t textLength,
    uint32_t color)
{
#if SWIFT_TRACY_ENABLED
  ___tracy_emit_logString(kTracySeverityInfo, static_cast<int32_t>(color), 0, textLength, text);
#else
  (void)text;
  (void)textLength;
  (void)color;
#endif
}

extern "C" void swift_tracy_plot(const char *name, double value)
{
#if SWIFT_TRACY_ENABLED
  const auto *stableName = internString(name, std::strlen(name));
  if (stableName != nullptr) {
    ___tracy_emit_plot(stableName, value);
  }
#else
  (void)name;
  (void)value;
#endif
}

extern "C" void swift_tracy_plot_int(const char *name, int64_t value)
{
#if SWIFT_TRACY_ENABLED
  const auto *stableName = internString(name, std::strlen(name));
  if (stableName != nullptr) {
    ___tracy_emit_plot_int(stableName, value);
  }
#else
  (void)name;
  (void)value;
#endif
}

extern "C" void swift_tracy_frame_mark_start(const char *name)
{
#if SWIFT_TRACY_ENABLED
  const auto *stableName = internString(name, std::strlen(name));
  if (stableName != nullptr) ___tracy_emit_frame_mark_start(stableName);
#else
  (void)name;
#endif
}

extern "C" void swift_tracy_frame_mark_end(const char *name)
{
#if SWIFT_TRACY_ENABLED
  const auto *stableName = internString(name, std::strlen(name));
  if (stableName != nullptr) ___tracy_emit_frame_mark_end(stableName);
#else
  (void)name;
#endif
}
