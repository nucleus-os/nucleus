#pragma once

#include <cstdint>
#include <cstddef>
#include <optional>
#include <span>
#include <string>
#include <swift/bridging>
#include <vector>

class SkCanvas;

namespace nucleus::text {

enum : uint32_t {
  FontWeightRegular = 0,
  FontWeightMedium = 1,
  FontWeightSemibold = 2,
  FontWeightBold = 3,
};

enum : uint32_t {
  FontWidthCompressed = 0,
  FontWidthCondensed = 1,
  FontWidthStandard = 2,
  FontWidthExpanded = 3,
};

enum : uint32_t {
  FontSlantUpright = 0,
  FontSlantItalic = 1,
  FontSlantOblique = 2,
};

enum : uint32_t {
  TextAffinityUpstream = 0,
  TextAffinityDownstream = 1,
};

enum : uint32_t {
  TextDirectionLtr = 0,
  TextDirectionRtl = 1,
};

enum class TextAlignment : uint8_t {
  Leading,
  Center,
  Trailing,
};

enum class TextLineBreakMode : uint8_t {
  Clipping,
  TruncatingTail,
  WordWrapping,
};

enum class EllipsisMode : uint8_t { None, Start, Middle, End };
enum class ParagraphDirection : uint8_t { Automatic, Ltr, Rtl };

struct SWIFT_ESCAPABLE SWIFT_SELF_CONTAINED TextStyle final {
  std::string fontFamily;
  std::string locale;
  float pointSize{14.0f};
  float lineHeight{0.0f};
  float baselineShift{0.0f};
  int fontWeight{400};
  bool italic{false};
  bool underline{false};
  bool strikeThrough{false};
  float red{1.0f};
  float green{1.0f};
  float blue{1.0f};
  float alpha{1.0f};
};

struct SWIFT_ESCAPABLE SWIFT_SELF_CONTAINED TextRun final {
  std::string text;
  TextStyle style;
};

struct SWIFT_ESCAPABLE SWIFT_SELF_CONTAINED ParagraphStyle final {
  float width{0.0f};
  uint32_t maximumNumberOfLines{0};
  TextAlignment alignment{TextAlignment::Leading};
  bool ellipsizeTail{false};
  EllipsisMode ellipsisMode{EllipsisMode::None};
  ParagraphDirection direction{ParagraphDirection::Automatic};
};

struct SWIFT_ESCAPABLE SWIFT_SELF_CONTAINED ParagraphMetrics final {
  float width{0.0f};
  float height{0.0f};
  float minIntrinsicWidth{0.0f};
  float maxIntrinsicWidth{0.0f};
  float alphabeticBaseline{0.0f};
  float ideographicBaseline{0.0f};
  uint32_t lineCount{0};
  bool didExceedMaximumLines{false};
};

struct SWIFT_ESCAPABLE SWIFT_SELF_CONTAINED TextLineMetrics final {
  float x{0.0f};
  float y{0.0f};
  float width{0.0f};
  float height{0.0f};
  float baseline{0.0f};
  float ascent{0.0f};
  float descent{0.0f};
  float unscaledAscent{0.0f};
  uint32_t startIndex{0};
  uint32_t endIndex{0};
  uint32_t endExcludingWhitespace{0};
  uint32_t endIncludingNewline{0};
  uint32_t lineNumber{0};
  bool hardBreak{false};
  bool isLastVisibleLine{false};
};

struct SWIFT_ESCAPABLE SWIFT_SELF_CONTAINED TextPosition final {
  uint32_t utf16Offset{0};
  uint32_t affinity{TextAffinityDownstream};
};

struct SWIFT_ESCAPABLE SWIFT_SELF_CONTAINED TextCaret final {
  float x{0.0f};
  float y{0.0f};
  float height{0.0f};
  uint32_t direction{TextDirectionLtr};
  uint32_t affinity{TextAffinityDownstream};
};

struct SWIFT_ESCAPABLE SWIFT_SELF_CONTAINED TextRect final {
  float x{0.0f};
  float y{0.0f};
  float width{0.0f};
  float height{0.0f};
  uint32_t direction{TextDirectionLtr};
};

struct SWIFT_ESCAPABLE SWIFT_SELF_CONTAINED FontMetrics final {
  float ascender{0.0f};
  float descender{0.0f};
  float leading{0.0f};
  float capHeight{0.0f};
  float xHeight{0.0f};
};

struct SWIFT_ESCAPABLE SWIFT_SELF_CONTAINED ResolvedFontDescriptor final {
  char familyName[128]{};
  uint32_t familyNameLength{0};
  char postScriptName[128]{};
  uint32_t postScriptNameLength{0};
  float pointSize{0.0f};
  uint32_t weight{FontWeightRegular};
  uint32_t width{FontWidthStandard};
  uint32_t slant{FontSlantUpright};
};

// The handle and the metrics of the layout pass that produced it, returned
// together so a caller cannot observe one without the other.
struct SWIFT_ESCAPABLE SWIFT_SELF_CONTAINED CreatedLayout final {
  uint64_t handle{0};
  ParagraphMetrics metrics;
};

/// An owning batch of styled UTF-8 runs. Swift constructs this value before
/// entering the layout service, so no pointer into Swift storage can escape or
/// become invalid while C++ copies nested string views.
class SWIFT_ESCAPABLE SWIFT_SELF_CONTAINED TextRunList final {
 public:
  TextRunList() noexcept;
  TextRunList(const TextRunList &) = delete;
  TextRunList &operator=(const TextRunList &) = delete;
  TextRunList(TextRunList &&) noexcept = default;
  TextRunList &operator=(TextRunList &&) noexcept = default;
  ~TextRunList() noexcept = default;

  bool append(
      std::span<const uint8_t> text [[clang::noescape]],
      std::span<const uint8_t> fontFamily [[clang::noescape]],
      std::span<const uint8_t> locale [[clang::noescape]],
      float pointSize,
      float lineHeight,
      float baselineShift,
      uint32_t weight,
      uint32_t width,
      uint32_t slant,
      bool underline,
      bool strikeThrough,
      float red,
      float green,
      float blue,
      float alpha) noexcept;

 private:
  friend class TextLayoutService;
  std::vector<TextRun> runs_;
};

class SWIFT_ESCAPABLE SWIFT_SELF_CONTAINED TextLayoutService final {
 public:
  bool resolveFont(
      std::span<const uint8_t> familyName [[clang::noescape]],
      float pointSize,
      uint32_t weight,
      uint32_t width,
      uint32_t slant,
      ResolvedFontDescriptor &outDescriptor) const noexcept;

  bool queryFontMetrics(
      std::span<const uint8_t> familyName [[clang::noescape]],
      float pointSize,
      uint32_t weight,
      uint32_t width,
      uint32_t slant,
      FontMetrics &outMetrics) const noexcept;

  std::optional<CreatedLayout> createRuns(
      const TextRunList &runs,
      const ParagraphStyle &style) const noexcept;

  bool measureRuns(
      const TextRunList &runs,
      const ParagraphStyle &style,
      std::span<TextLineMetrics> outLines [[clang::noescape]],
      ParagraphMetrics &outMetrics) const noexcept;

  void retain(uint64_t handle) const noexcept;
  void release(uint64_t handle) const noexcept;

  bool metrics(
      uint64_t handle,
      std::span<TextLineMetrics> outLines [[clang::noescape]],
      ParagraphMetrics &outMetrics) const noexcept;

  std::optional<TextPosition> glyphPositionAt(uint64_t handle, float x, float y)
      const noexcept;

  std::optional<TextCaret> caretForOffset(
      uint64_t handle,
      uint32_t utf16Offset,
      uint32_t affinity) const noexcept;

  bool rectsForRange(
      uint64_t handle,
      uint32_t startUtf16Offset,
      uint32_t endUtf16Offset,
      std::span<TextRect> outRects [[clang::noescape]],
      uint32_t &outRectCount) const noexcept;

  bool graphemeBreaks(
      std::span<const uint8_t> text [[clang::noescape]],
      std::span<uint32_t> outUtf8Offsets [[clang::noescape]],
      uint32_t &outCount) const noexcept;
  void invalidateFontCollection() const noexcept;

  bool paint(uint64_t handle, SkCanvas *canvas, float x, float y) const noexcept;
};

ParagraphMetrics measureParagraph(
    const std::vector<TextRun> &runs,
    const ParagraphStyle &style) noexcept;

uint64_t registerParagraph(
    const std::vector<TextRun> &runs,
    const ParagraphStyle &style,
    ParagraphMetrics *outMetrics) noexcept;

} // namespace nucleus::text
