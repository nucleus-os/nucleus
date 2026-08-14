#pragma once

#include <cstdint>

namespace nucleus::text {

enum class TextRenderingBridgeInstallStatus : uint8_t {
  ready,
  conflictingProvider,
};

TextRenderingBridgeInstallStatus installTextRenderingBridge() noexcept;

} // namespace nucleus::text
