#pragma once

#include <cstdint>
#include <cstddef>
#include <string>
#include <vector>

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

struct TextStringView final {
  const char *data{nullptr};
  size_t size{0};
};

struct TextStyle final {
  std::string fontFamily;
  float pointSize{14.0f};
  float lineHeight{0.0f};
  int fontWeight{400};
  bool italic{false};
  float red{1.0f};
  float green{1.0f};
  float blue{1.0f};
  float alpha{1.0f};
};

struct TextRun final {
  std::string text;
  TextStyle style;
};

struct ParagraphStyle final {
  float width{0.0f};
  uint32_t maximumNumberOfLines{0};
  TextAlignment alignment{TextAlignment::Leading};
  bool ellipsizeTail{false};
};

struct ParagraphMetrics final {
  float width{0.0f};
  float height{0.0f};
  float minIntrinsicWidth{0.0f};
  float maxIntrinsicWidth{0.0f};
  float alphabeticBaseline{0.0f};
  float ideographicBaseline{0.0f};
  uint32_t lineCount{0};
  bool didExceedMaximumLines{false};
};

struct TextRunView final {
  TextStringView text;
  TextStringView fontFamily;
  float pointSize{14.0f};
  float lineHeight{0.0f};
  uint32_t weight{FontWeightRegular};
  uint32_t width{FontWidthStandard};
  uint32_t slant{FontSlantUpright};
  float red{1.0f};
  float green{1.0f};
  float blue{1.0f};
  float alpha{1.0f};
};

struct TextLineMetrics final {
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

struct TextPosition final {
  uint32_t utf16Offset{0};
  uint32_t affinity{TextAffinityDownstream};
};

struct TextRect final {
  float x{0.0f};
  float y{0.0f};
  float width{0.0f};
  float height{0.0f};
  uint32_t direction{TextDirectionLtr};
};

struct FontMetrics final {
  float ascender{0.0f};
  float descender{0.0f};
  float leading{0.0f};
  float capHeight{0.0f};
  float xHeight{0.0f};
};

struct ResolvedFontDescriptor final {
  char familyName[128]{};
  uint32_t familyNameLength{0};
  char postScriptName[128]{};
  uint32_t postScriptNameLength{0};
  float pointSize{0.0f};
  uint32_t weight{FontWeightRegular};
  uint32_t width{FontWidthStandard};
  uint32_t slant{FontSlantUpright};
};

class TextLayoutService final {
 public:
  bool resolveFont(
      TextStringView familyName,
      float pointSize,
      uint32_t weight,
      uint32_t width,
      uint32_t slant,
      ResolvedFontDescriptor *outDescriptor) const;

  bool queryFontMetrics(
      TextStringView familyName,
      float pointSize,
      uint32_t weight,
      uint32_t width,
      uint32_t slant,
      FontMetrics *outMetrics) const;

  bool createRuns(
      const TextRunView *runs,
      size_t runCount,
      const ParagraphStyle *style,
      uint64_t *outHandle,
      ParagraphMetrics *outMetrics) const;

  bool measureRuns(
      const TextRunView *runs,
      size_t runCount,
      const ParagraphStyle *style,
      TextLineMetrics *outLines,
      size_t lineCapacity,
      ParagraphMetrics *outMetrics) const;

  void retain(uint64_t handle) const;
  void release(uint64_t handle) const;

  bool metrics(
      uint64_t handle,
      TextLineMetrics *outLines,
      size_t lineCapacity,
      ParagraphMetrics *outMetrics) const;

  bool glyphPositionAt(
      uint64_t handle,
      float x,
      float y,
      TextPosition *outPosition) const;

  bool rectsForRange(
      uint64_t handle,
      uint32_t startUtf16Offset,
      uint32_t endUtf16Offset,
      TextRect *outRects,
      size_t rectCapacity,
      uint32_t *outRectCount) const;
};

ParagraphMetrics measureParagraph(
    const std::vector<TextRun> &runs,
    const ParagraphStyle &style);

uint64_t registerParagraph(
    const std::vector<TextRun> &runs,
    const ParagraphStyle &style,
    ParagraphMetrics *outMetrics);

} // namespace nucleus::text
