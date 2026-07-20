// Skia-backed text/font backend for Nucleus.
//
// This file builds SkParagraphs for the transitional C text ABI. Retained
// paragraph handles are owned by the shared substrate text registry.

#include <nucleus/text/TextRegistry.hpp>
#include <nucleus/text/TextLayoutBuilder.hpp>

#include "include/core/SkColor.h"
#include "include/core/SkCanvas.h"
#include "include/core/SkFont.h"
#include "include/core/SkFontTypes.h"
#include "include/core/SkString.h"
#include "include/core/SkTypeface.h"
#include "modules/skparagraph/include/FontCollection.h"
#include "modules/skparagraph/include/Paragraph.h"
#include "modules/skparagraph/include/ParagraphBuilder.h"
#include "modules/skparagraph/include/ParagraphStyle.h"
#include "modules/skparagraph/include/TextStyle.h"
#define U_DISABLE_RENAMING 1
#include "third_party/externals/icu/source/common/unicode/uchar.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <vector>

namespace {

static sk_sp<SkTypeface> g_typeface;
// Guards the lazy `g_typeface` init and every read of it. The rest of the font
// infra (sharedFontMgr/Collection/Unicode) is already mutex-guarded, but this
// global was not — `TextLayoutService`'s const methods run on any thread (main +
// a Fabric layout thread), so a concurrent first-use raced the non-atomic sk_sp.
static std::mutex g_typeface_mutex;

static SkTypeface* getDefaultTypeface() {
    std::lock_guard<std::mutex> guard(g_typeface_mutex);
    auto fontMgr = nucleus::text::sharedFontMgr();
    if (!g_typeface && fontMgr) {
        const char* families[] = {"Inter", "Cantarell", "Noto Sans", "DejaVu Sans", "Liberation Sans", nullptr};
        for (int i = 0; families[i]; i++) {
            g_typeface = fontMgr->matchFamilyStyle(families[i], SkFontStyle::Normal());
            if (g_typeface) break;
        }
        if (!g_typeface) {
            g_typeface = fontMgr->matchFamilyStyle(nullptr, SkFontStyle::Normal());
        }
    }
    return g_typeface.get();
}

static sk_sp<skia::textlayout::FontCollection> getTextFontCollection() {
    (void)getDefaultTypeface();
    return nucleus::text::sharedFontCollection();
}

static sk_sp<SkUnicode> getTextUnicode() {
    return nucleus::text::sharedUnicode();
}

static int skiaFontWeight(uint32_t weight) {
    switch (weight) {
        case nucleus::text::FontWeightMedium: return SkFontStyle::kMedium_Weight;
        case nucleus::text::FontWeightSemibold: return SkFontStyle::kSemiBold_Weight;
        case nucleus::text::FontWeightBold: return SkFontStyle::kBold_Weight;
        case nucleus::text::FontWeightRegular:
        default: return SkFontStyle::kNormal_Weight;
    }
}

static int skiaFontWidth(uint32_t width) {
    switch (width) {
        case nucleus::text::FontWidthCompressed: return SkFontStyle::kExtraCondensed_Width;
        case nucleus::text::FontWidthCondensed: return SkFontStyle::kCondensed_Width;
        case nucleus::text::FontWidthExpanded: return SkFontStyle::kExpanded_Width;
        case nucleus::text::FontWidthStandard:
        default: return SkFontStyle::kNormal_Width;
    }
}

static SkFontStyle::Slant skiaFontSlant(uint32_t slant) {
    switch (slant) {
        case nucleus::text::FontSlantItalic: return SkFontStyle::kItalic_Slant;
        case nucleus::text::FontSlantOblique: return SkFontStyle::kOblique_Slant;
        case nucleus::text::FontSlantUpright:
        default: return SkFontStyle::kUpright_Slant;
    }
}

static uint32_t nucleusFontWeight(const SkFontStyle& style) {
    const int weight = style.weight();
    if (weight >= SkFontStyle::kBold_Weight) return nucleus::text::FontWeightBold;
    if (weight >= SkFontStyle::kSemiBold_Weight) return nucleus::text::FontWeightSemibold;
    if (weight >= SkFontStyle::kMedium_Weight) return nucleus::text::FontWeightMedium;
    return nucleus::text::FontWeightRegular;
}

static uint32_t nucleusFontWidth(const SkFontStyle& style) {
    const int width = style.width();
    if (width <= SkFontStyle::kExtraCondensed_Width) return nucleus::text::FontWidthCompressed;
    if (width < SkFontStyle::kNormal_Width) return nucleus::text::FontWidthCondensed;
    if (width > SkFontStyle::kNormal_Width) return nucleus::text::FontWidthExpanded;
    return nucleus::text::FontWidthStandard;
}

static uint32_t nucleusFontSlant(const SkFontStyle& style) {
    switch (style.slant()) {
        case SkFontStyle::kItalic_Slant: return nucleus::text::FontSlantItalic;
        case SkFontStyle::kOblique_Slant: return nucleus::text::FontSlantOblique;
        case SkFontStyle::kUpright_Slant:
        default: return nucleus::text::FontSlantUpright;
    }
}

static sk_sp<SkTypeface> matchTextTypeface(nucleus::text::TextStringView family_name, uint32_t weight, uint32_t width, uint32_t slant) {
    (void)getDefaultTypeface();
    const SkFontStyle style(skiaFontWeight(weight), skiaFontWidth(width), skiaFontSlant(slant));
    auto fontMgr = nucleus::text::sharedFontMgr();
    if (fontMgr && family_name.data && family_name.size > 0) {
        SkString family(family_name.data, family_name.size);
        if (auto typeface = fontMgr->matchFamilyStyle(family.c_str(), style)) {
            return typeface;
        }
    }
    if (fontMgr) {
        const char* families[] = {"Inter", "Cantarell", "Noto Sans", "DejaVu Sans", "Liberation Sans", nullptr};
        for (int i = 0; families[i]; i++) {
            if (auto typeface = fontMgr->matchFamilyStyle(families[i], style)) {
                return typeface;
            }
        }
        if (auto typeface = fontMgr->matchFamilyStyle(nullptr, style)) {
            return typeface;
        }
    }
    std::lock_guard<std::mutex> guard(g_typeface_mutex);
    return sk_ref_sp(g_typeface.get());
}

static uint32_t copyFontName(uint8_t* dst, const SkString& name) {
    if (!dst) {
        return 0;
    }
    const size_t len = std::min<size_t>(name.size(), 128);
    if (len > 0) {
        std::memcpy(dst, name.c_str(), len);
    }
    if (len < 128) {
        std::memset(dst + len, 0, 128 - len);
    }
    return static_cast<uint32_t>(len);
}

static skia::textlayout::TextAlign skiaTextAlign(nucleus::text::TextAlignment alignment) {
    switch (alignment) {
        case nucleus::text::TextAlignment::Center:
            return skia::textlayout::TextAlign::kCenter;
        case nucleus::text::TextAlignment::Trailing:
            return skia::textlayout::TextAlign::kEnd;
        case nucleus::text::TextAlignment::Leading:
        default:
            return skia::textlayout::TextAlign::kStart;
    }
}

static SkColor skiaColor(const nucleus::text::TextStyle& text_style) {
    return SkColorSetARGB(
        static_cast<U8CPU>(std::clamp(text_style.alpha, 0.0f, 1.0f) * 255.0f + 0.5f),
        static_cast<U8CPU>(std::clamp(text_style.red, 0.0f, 1.0f) * 255.0f + 0.5f),
        static_cast<U8CPU>(std::clamp(text_style.green, 0.0f, 1.0f) * 255.0f + 0.5f),
        static_cast<U8CPU>(std::clamp(text_style.blue, 0.0f, 1.0f) * 255.0f + 0.5f));
}

static skia::textlayout::TextStyle skiaTextStyle(const nucleus::text::TextStyle& text_style)
{
    using namespace skia::textlayout;

    TextStyle style;
    const float point_size = text_style.pointSize > 1.0f ? text_style.pointSize : 1.0f;
    style.setFontSize(point_size);
    style.setBaselineShift(text_style.baselineShift);
    if (text_style.lineHeight > point_size) {
        style.setHeight(text_style.lineHeight / point_size);
        style.setHeightOverride(true);
        style.setHalfLeading(true);
    }
    style.setFontStyle(SkFontStyle(
        text_style.fontWeight > 0 ? text_style.fontWeight : SkFontStyle::kNormal_Weight,
        SkFontStyle::kNormal_Width,
        text_style.italic ? SkFontStyle::kItalic_Slant : SkFontStyle::kUpright_Slant));
    style.setColor(skiaColor(text_style));
    int decoration = TextDecoration::kNoDecoration;
    if (text_style.underline) decoration |= TextDecoration::kUnderline;
    if (text_style.strikeThrough) decoration |= TextDecoration::kLineThrough;
    style.setDecoration(static_cast<TextDecoration>(decoration));
    // Match macOS: leave outlines untouched. The surface props supply the
    // grayscale geometry and gamma; hinting off keeps stem widths from
    // snapping to the pixel grid.
    style.setFontHinting(SkFontHinting::kNone);
    std::vector<SkString> families;
    if (!text_style.fontFamily.empty()) {
        families.emplace_back(text_style.fontFamily.c_str(), text_style.fontFamily.size());
    } else {
        families.emplace_back("Inter");
        families.emplace_back("Cantarell");
        families.emplace_back("Noto Sans");
        families.emplace_back("DejaVu Sans");
        families.emplace_back("Liberation Sans");
        families.emplace_back("sans-serif");
    }
    style.setFontFamilies(std::move(families));
    if (!text_style.locale.empty()) {
        style.setLocale(SkString(
            text_style.locale.c_str(),
            text_style.locale.size()));
    }
    return style;
}

static skia::textlayout::ParagraphStyle skiaParagraphStyle(
    const nucleus::text::ParagraphStyle& paragraph_style,
    const skia::textlayout::TextStyle& default_text_style)
{
    using namespace skia::textlayout;

    ParagraphStyle paragraph;
    paragraph.turnHintingOff();
    paragraph.setTextDirection(paragraph_style.direction == nucleus::text::ParagraphDirection::Rtl
        ? TextDirection::kRtl : TextDirection::kLtr);
    paragraph.setTextAlign(skiaTextAlign(paragraph_style.alignment));
    if (paragraph_style.maximumNumberOfLines > 0) {
        paragraph.setMaxLines(paragraph_style.maximumNumberOfLines);
    }
    if (paragraph_style.ellipsizeTail || paragraph_style.ellipsisMode == nucleus::text::EllipsisMode::End) {
        paragraph.setEllipsis(u"\u2026");
    }
    paragraph.setTextStyle(default_text_style);
    return paragraph;
}

static bool firstStrongIsRtl(const std::vector<nucleus::text::TextRun>& runs) {
    for (const auto& run : runs) {
        const char* cursor = run.text.data();
        const char* end = cursor + run.text.size();
        while (cursor < end) {
            const unsigned char lead = static_cast<unsigned char>(*cursor++);
            uint32_t cp = lead;
            int continuation = 0;
            if ((lead & 0xe0U) == 0xc0U) { cp = lead & 0x1fU; continuation = 1; }
            else if ((lead & 0xf0U) == 0xe0U) { cp = lead & 0x0fU; continuation = 2; }
            else if ((lead & 0xf8U) == 0xf0U) { cp = lead & 0x07U; continuation = 3; }
            for (int i = 0; i < continuation && cursor < end; ++i)
                cp = (cp << 6U) | (static_cast<unsigned char>(*cursor++) & 0x3fU);
            const UCharDirection direction = u_charDirection(static_cast<UChar32>(cp));
            if (direction == U_RIGHT_TO_LEFT || direction == U_RIGHT_TO_LEFT_ARABIC) return true;
            if (direction == U_LEFT_TO_RIGHT) return false;
        }
    }
    return false;
}

static void appendParagraphText(
    skia::textlayout::ParagraphBuilder* builder,
    const std::string& text,
    const skia::textlayout::TextStyle& style)
{
    builder->pushStyle(style);
    if (!text.empty()) {
        builder->addText(text.c_str(), text.size());
    }
    builder->pop();
}

static std::unique_ptr<skia::textlayout::Paragraph> buildParagraphRuns(
    const std::vector<nucleus::text::TextRun>& runs,
    const nucleus::text::ParagraphStyle& paragraph_style)
{
    using namespace skia::textlayout;

    nucleus::text::TextStyle fallback_style{};
    const nucleus::text::TextStyle& first_style = runs.empty() ? fallback_style : runs.front().style;
    TextStyle default_style = skiaTextStyle(first_style);
    ParagraphStyle paragraph = skiaParagraphStyle(paragraph_style, default_style);
    if (paragraph_style.direction == nucleus::text::ParagraphDirection::Automatic)
        paragraph.setTextDirection(firstStrongIsRtl(runs) ? TextDirection::kRtl : TextDirection::kLtr);
    auto builder = ParagraphBuilder::make(paragraph, getTextFontCollection(), getTextUnicode());
    if (!builder) return nullptr;
    for (const auto& run : runs) {
        TextStyle style = skiaTextStyle(run.style);
        appendParagraphText(builder.get(), run.text, style);
    }
    return builder->Build();
}

static bool sameTextStyle(const nucleus::text::TextStyle& lhs, const nucleus::text::TextStyle& rhs) {
    return lhs.fontFamily == rhs.fontFamily && lhs.locale == rhs.locale
        && lhs.pointSize == rhs.pointSize && lhs.lineHeight == rhs.lineHeight
        && lhs.baselineShift == rhs.baselineShift
        && lhs.fontWeight == rhs.fontWeight
        && lhs.italic == rhs.italic && lhs.underline == rhs.underline
        && lhs.strikeThrough == rhs.strikeThrough && lhs.red == rhs.red
        && lhs.green == rhs.green && lhs.blue == rhs.blue && lhs.alpha == rhs.alpha;
}

static void appendTextRun(
    std::vector<nucleus::text::TextRun>* runs, nucleus::text::TextRun run)
{
    if (run.text.empty()) return;
    if (!runs->empty() && sameTextStyle(runs->back().style, run.style)) {
        runs->back().text += run.text;
    } else {
        runs->push_back(std::move(run));
    }
}

static std::vector<nucleus::text::TextRun> sliceTextRuns(
    const std::vector<nucleus::text::TextRun>& runs, size_t begin, size_t end)
{
    std::vector<nucleus::text::TextRun> result;
    size_t offset = 0;
    for (const auto& run : runs) {
        const size_t run_end = offset + run.text.size();
        const size_t slice_begin = std::max(begin, offset);
        const size_t slice_end = std::min(end, run_end);
        if (slice_begin < slice_end) {
            nucleus::text::TextRun slice = run;
            slice.text = run.text.substr(slice_begin - offset, slice_end - slice_begin);
            appendTextRun(&result, std::move(slice));
        }
        offset = run_end;
        if (offset >= end) break;
    }
    return result;
}

static std::vector<uint32_t> graphemeBreakOffsets(const std::string& text) {
    auto unicode = getTextUnicode();
    auto iterator = unicode ? unicode->makeBreakIterator(SkUnicode::BreakType::kGraphemes) : nullptr;
    if (!iterator || !iterator->setText(text.data(), static_cast<int>(text.size()))) return {};
    std::vector<uint32_t> offsets;
    for (auto position = iterator->first(); !iterator->isDone(); position = iterator->next()) {
        if (position >= 0) offsets.push_back(static_cast<uint32_t>(position));
    }
    if (offsets.empty() || offsets.front() != 0) offsets.insert(offsets.begin(), 0);
    if (offsets.back() != text.size()) offsets.push_back(static_cast<uint32_t>(text.size()));
    return offsets;
}

static std::vector<nucleus::text::TextRun> ellipsizedTextRuns(
    const std::vector<nucleus::text::TextRun>& runs,
    size_t text_size,
    const std::vector<uint32_t>& breaks,
    size_t keep,
    nucleus::text::EllipsisMode mode)
{
    if (mode == nucleus::text::EllipsisMode::Start) {
        auto result = sliceTextRuns(runs, breaks[breaks.size() - 1 - keep], text_size);
        nucleus::text::TextRun ellipsis = result.empty()
            ? (runs.empty() ? nucleus::text::TextRun{} : runs.back())
            : result.front();
        ellipsis.text = "\xE2\x80\xA6";
        result.insert(result.begin(), std::move(ellipsis));
        return result;
    }

    const size_t left = (keep + 1) / 2;
    const size_t right = keep / 2;
    auto result = sliceTextRuns(runs, 0, breaks[left]);
    auto suffix = sliceTextRuns(runs, breaks[breaks.size() - 1 - right], text_size);
    nucleus::text::TextRun ellipsis = !result.empty()
        ? result.back()
        : (!suffix.empty() ? suffix.front() : nucleus::text::TextRun{});
    ellipsis.text = "\xE2\x80\xA6";
    appendTextRun(&result, std::move(ellipsis));
    for (auto& run : suffix) appendTextRun(&result, std::move(run));
    return result;
}

static bool textRunsFit(
    const std::vector<nucleus::text::TextRun>& runs,
    const nucleus::text::ParagraphStyle& paragraph_style)
{
    nucleus::text::ParagraphStyle probe_style = paragraph_style;
    probe_style.width = 0.0f;
    probe_style.maximumNumberOfLines = 0;
    probe_style.ellipsizeTail = false;
    probe_style.ellipsisMode = nucleus::text::EllipsisMode::None;
    auto paragraph = buildParagraphRuns(runs, probe_style);
    if (!paragraph) return false;
    paragraph->layout(std::numeric_limits<float>::max() / 4.0f);
    return paragraph->getMaxIntrinsicWidth() <= paragraph_style.width;
}

static std::vector<nucleus::text::TextRun> truncateTextRuns(
    const std::vector<nucleus::text::TextRun>& runs,
    const nucleus::text::ParagraphStyle& paragraph_style)
{
    std::string text;
    for (const auto& run : runs) text += run.text;
    const auto breaks = graphemeBreakOffsets(text);
    if (text.empty() || breaks.size() <= 1 || textRunsFit(runs, paragraph_style)) return runs;

    size_t low = 0;
    size_t high = breaks.size() - 1;
    while (low < high) {
        const size_t keep = (low + high + 1) / 2;
        const auto candidate = ellipsizedTextRuns(
            runs, text.size(), breaks, keep, paragraph_style.ellipsisMode);
        if (textRunsFit(candidate, paragraph_style)) low = keep;
        else high = keep - 1;
    }
    return ellipsizedTextRuns(runs, text.size(), breaks, low, paragraph_style.ellipsisMode);
}

static std::unique_ptr<skia::textlayout::Paragraph> makeParagraphRuns(
    const std::vector<nucleus::text::TextRun>& runs,
    const nucleus::text::ParagraphStyle& paragraph_style)
{
    const bool custom_ellipsis = paragraph_style.ellipsisMode == nucleus::text::EllipsisMode::Start
        || paragraph_style.ellipsisMode == nucleus::text::EllipsisMode::Middle;
    if (!custom_ellipsis || paragraph_style.width <= 0.0f || paragraph_style.maximumNumberOfLines > 1) {
        return buildParagraphRuns(runs, paragraph_style);
    }
    auto truncated = truncateTextRuns(runs, paragraph_style);
    nucleus::text::ParagraphStyle final_style = paragraph_style;
    final_style.ellipsizeTail = false;
    final_style.ellipsisMode = nucleus::text::EllipsisMode::None;
    return buildParagraphRuns(truncated, final_style);
}

static nucleus::text::ParagraphMetrics paragraphMetrics(
    skia::textlayout::Paragraph* paragraph,
    float layout_width)
{
    std::vector<skia::textlayout::LineMetrics> lines;
    paragraph->getLineMetrics(lines);
    return {
        .width = layout_width,
        .height = paragraph->getHeight(),
        .minIntrinsicWidth = paragraph->getMinIntrinsicWidth(),
        .maxIntrinsicWidth = paragraph->getMaxIntrinsicWidth(),
        .alphabeticBaseline = paragraph->getAlphabeticBaseline(),
        .ideographicBaseline = paragraph->getIdeographicBaseline(),
        .lineCount = static_cast<uint32_t>(std::min<size_t>(lines.size(), std::numeric_limits<uint32_t>::max())),
        .didExceedMaximumLines = paragraph->didExceedMaxLines(),
    };
}

static void fillTextMetrics(
    skia::textlayout::Paragraph* paragraph,
    float layout_width,
    nucleus::text::TextLineMetrics* out_lines,
    size_t line_capacity,
    nucleus::text::ParagraphMetrics* out_metrics)
{
    std::vector<skia::textlayout::LineMetrics> lines;
    paragraph->getLineMetrics(lines);
    out_metrics->width = layout_width;
    out_metrics->height = paragraph->getHeight();
    out_metrics->minIntrinsicWidth = paragraph->getMinIntrinsicWidth();
    out_metrics->maxIntrinsicWidth = paragraph->getMaxIntrinsicWidth();
    out_metrics->alphabeticBaseline = paragraph->getAlphabeticBaseline();
    out_metrics->ideographicBaseline = paragraph->getIdeographicBaseline();
    out_metrics->lineCount = static_cast<uint32_t>(std::min<size_t>(lines.size(), std::numeric_limits<uint32_t>::max()));
    out_metrics->didExceedMaximumLines = paragraph->didExceedMaxLines();

    const size_t n = std::min<size_t>(lines.size(), line_capacity);
    for (size_t i = 0; i < n; i++) {
        const auto& line = lines[i];
        out_lines[i].x = static_cast<float>(line.fLeft);
        out_lines[i].y = static_cast<float>(line.fBaseline - line.fAscent);
        out_lines[i].width = static_cast<float>(line.fWidth);
        out_lines[i].height = static_cast<float>(line.fAscent + line.fDescent);
        out_lines[i].baseline = static_cast<float>(line.fBaseline);
        out_lines[i].ascent = static_cast<float>(line.fAscent);
        out_lines[i].descent = static_cast<float>(line.fDescent);
        out_lines[i].unscaledAscent = static_cast<float>(line.fUnscaledAscent);
        out_lines[i].startIndex = static_cast<uint32_t>(std::min<size_t>(line.fStartIndex, std::numeric_limits<uint32_t>::max()));
        out_lines[i].endIndex = static_cast<uint32_t>(std::min<size_t>(line.fEndIndex, std::numeric_limits<uint32_t>::max()));
        out_lines[i].endExcludingWhitespace = static_cast<uint32_t>(std::min<size_t>(line.fEndExcludingWhitespaces, std::numeric_limits<uint32_t>::max()));
        out_lines[i].endIncludingNewline = static_cast<uint32_t>(std::min<size_t>(line.fEndIncludingNewline, std::numeric_limits<uint32_t>::max()));
        out_lines[i].lineNumber = static_cast<uint32_t>(std::min<size_t>(line.fLineNumber, std::numeric_limits<uint32_t>::max()));
        out_lines[i].hardBreak = line.fHardBreak;
        out_lines[i].isLastVisibleLine = i + 1 == n;
    }
}

static float textLayoutWidth(skia::textlayout::Paragraph* paragraph, const nucleus::text::ParagraphStyle& paragraph_style) {
    paragraph->layout(std::numeric_limits<float>::max() / 4.0f);
    return paragraph_style.width > 0.0f ? paragraph_style.width : std::ceil(paragraph->getMaxIntrinsicWidth());
}

} // namespace

namespace nucleus::text {

static std::vector<TextRun> collectRuns(const TextRunView *runs, size_t runCount)
{
    std::vector<TextRun> result;
    result.reserve(runCount);
    for (size_t index = 0; index < runCount; ++index) {
        TextRun run;
        if (runs[index].text.data && runs[index].text.size > 0) {
            run.text.assign(runs[index].text.data, runs[index].text.size);
        }
        if (runs[index].fontFamily.data && runs[index].fontFamily.size > 0) {
            run.style.fontFamily.assign(runs[index].fontFamily.data, runs[index].fontFamily.size);
        }
        if (runs[index].locale.data && runs[index].locale.size > 0) {
            run.style.locale.assign(runs[index].locale.data, runs[index].locale.size);
        }
        run.style.pointSize = runs[index].pointSize;
        run.style.lineHeight = runs[index].lineHeight;
        run.style.baselineShift = runs[index].baselineShift;
        switch (runs[index].weight) {
            case FontWeightMedium:
                run.style.fontWeight = SkFontStyle::kMedium_Weight;
                break;
            case FontWeightSemibold:
                run.style.fontWeight = SkFontStyle::kSemiBold_Weight;
                break;
            case FontWeightBold:
                run.style.fontWeight = SkFontStyle::kBold_Weight;
                break;
            case FontWeightRegular:
                run.style.fontWeight = SkFontStyle::kNormal_Weight;
                break;
            default:
                run.style.fontWeight = static_cast<int>(std::clamp<uint32_t>(runs[index].weight, 1U, 1000U));
                break;
        }
        run.style.italic = runs[index].slant == FontSlantItalic || runs[index].slant == FontSlantOblique;
        run.style.underline = runs[index].underline;
        run.style.strikeThrough = runs[index].strikeThrough;
        run.style.red = runs[index].red;
        run.style.green = runs[index].green;
        run.style.blue = runs[index].blue;
        run.style.alpha = runs[index].alpha;
        result.push_back(std::move(run));
    }
    return result;
}

bool TextLayoutService::resolveFont(
    TextStringView familyName,
    float pointSize,
    uint32_t weight,
    uint32_t width,
    uint32_t slant,
    ResolvedFontDescriptor *outDescriptor) const
{
    if (!outDescriptor) {
        return false;
    }
    const float size = pointSize > 1.0f ? pointSize : 1.0f;
    auto typeface = matchTextTypeface(familyName, weight, width, slant);
    if (!typeface) {
        return false;
    }

    SkString resolvedFamily;
    typeface->getFamilyName(&resolvedFamily);
    SkString postScriptName;
    if (!typeface->getPostScriptName(&postScriptName) || postScriptName.isEmpty()) {
        postScriptName = resolvedFamily;
    }

    outDescriptor->familyNameLength = copyFontName(reinterpret_cast<uint8_t*>(outDescriptor->familyName), resolvedFamily);
    outDescriptor->postScriptNameLength = copyFontName(reinterpret_cast<uint8_t*>(outDescriptor->postScriptName), postScriptName);
    outDescriptor->pointSize = size;
    const SkFontStyle resolvedStyle = typeface->fontStyle();
    outDescriptor->weight = nucleusFontWeight(resolvedStyle);
    outDescriptor->width = nucleusFontWidth(resolvedStyle);
    outDescriptor->slant = nucleusFontSlant(resolvedStyle);
    return true;
}

bool TextLayoutService::queryFontMetrics(
    TextStringView familyName,
    float pointSize,
    uint32_t weight,
    uint32_t width,
    uint32_t slant,
    FontMetrics *outMetrics) const
{
    if (!outMetrics) {
        return false;
    }
    const float size = pointSize > 1.0f ? pointSize : 1.0f;
    auto typeface = matchTextTypeface(familyName, weight, width, slant);
    if (!typeface) {
        return false;
    }
    SkFont font(typeface, size);
    SkFontMetrics metrics;
    font.getMetrics(&metrics);
    outMetrics->ascender = std::max(0.0f, -metrics.fAscent);
    outMetrics->descender = std::max(0.0f, metrics.fDescent);
    outMetrics->leading = std::max(0.0f, metrics.fLeading);
    outMetrics->capHeight = metrics.fCapHeight > 0.0f ? metrics.fCapHeight : size * 0.7f;
    outMetrics->xHeight = metrics.fXHeight > 0.0f ? metrics.fXHeight : size * 0.5f;
    return true;
}

bool TextLayoutService::createRuns(
    const TextRunView *runs,
    size_t runCount,
    const ParagraphStyle *style,
    uint64_t *outHandle,
    ParagraphMetrics *outMetrics) const
{
    if (!style || !outHandle || (runCount > 0 && !runs)) {
        return false;
    }
    *outHandle = registerParagraph(collectRuns(runs, runCount), *style, outMetrics);
    return *outHandle != 0;
}

bool TextLayoutService::measureRuns(
    const TextRunView *runs,
    size_t runCount,
    const ParagraphStyle *style,
    TextLineMetrics *outLines,
    size_t lineCapacity,
    ParagraphMetrics *outMetrics) const
{
    if (!style || !outMetrics || (runCount > 0 && !runs)) {
        return false;
    }
    auto paragraph = makeParagraphRuns(collectRuns(runs, runCount), *style);
    if (!paragraph) {
        return false;
    }
    const float layout_width = textLayoutWidth(paragraph.get(), *style);
    paragraph->layout(layout_width);
    fillTextMetrics(paragraph.get(), layout_width, outLines, lineCapacity, outMetrics);
    return true;
}

void TextLayoutService::retain(uint64_t handle) const
{
    retainParagraph(handle);
}

void TextLayoutService::release(uint64_t handle) const
{
    releaseParagraph(handle);
}

bool TextLayoutService::metrics(
    uint64_t handle,
    TextLineMetrics *outLines,
    size_t lineCapacity,
    ParagraphMetrics *outMetrics) const
{
    auto paragraph = lookupParagraph(handle);
    if (!paragraph || !outMetrics) {
        return false;
    }
    fillTextMetrics(paragraph.get(), paragraphLayoutWidth(handle), outLines, lineCapacity, outMetrics);
    return true;
}

bool TextLayoutService::glyphPositionAt(
    uint64_t handle,
    float x,
    float y,
    TextPosition *outPosition) const
{
    auto paragraph = lookupParagraph(handle);
    if (!paragraph || !outPosition) {
        return false;
    }
    const auto position = paragraph->getGlyphPositionAtCoordinate(x, y);
    outPosition->utf16Offset = static_cast<uint32_t>(std::max<int32_t>(0, position.position));
    outPosition->affinity = position.affinity == skia::textlayout::Affinity::kUpstream
        ? TextAffinityUpstream
        : TextAffinityDownstream;
    return true;
}

bool TextLayoutService::caretForOffset(
    uint64_t handle,
    uint32_t utf16Offset,
    uint32_t affinity,
    TextCaret *outCaret) const
{
    auto paragraph = lookupParagraph(handle);
    if (!paragraph || !outCaret) return false;
    const bool upstream = affinity == TextAffinityUpstream;
    if (upstream && utf16Offset == 0) return false;
    const size_t queryOffset = upstream && utf16Offset > 0 ? utf16Offset - 1 : utf16Offset;
    skia::textlayout::Paragraph::GlyphInfo glyph{};
    if (!paragraph->getGlyphInfoAtUTF16Offset(queryOffset, &glyph)) return false;
    const bool rtl = glyph.fDirection == skia::textlayout::TextDirection::kRtl;
    const SkRect bounds = glyph.fGraphemeLayoutBounds;
    *outCaret = {
        .x = upstream ? (rtl ? bounds.left() : bounds.right())
                      : (rtl ? bounds.right() : bounds.left()),
        .y = bounds.top(),
        .height = bounds.height(),
        .direction = rtl ? TextDirectionRtl : TextDirectionLtr,
        .affinity = upstream ? TextAffinityUpstream : TextAffinityDownstream,
    };
    return true;
}

bool TextLayoutService::rectsForRange(
    uint64_t handle,
    uint32_t startUtf16Offset,
    uint32_t endUtf16Offset,
    TextRect *outRects,
    size_t rectCapacity,
    uint32_t *outRectCount) const
{
    auto paragraph = lookupParagraph(handle);
    if (!paragraph || !outRectCount || endUtf16Offset < startUtf16Offset) {
        return false;
    }
    const auto boxes = paragraph->getRectsForRange(
        startUtf16Offset,
        endUtf16Offset,
        skia::textlayout::RectHeightStyle::kTight,
        skia::textlayout::RectWidthStyle::kTight);
    *outRectCount = static_cast<uint32_t>(std::min<size_t>(boxes.size(), std::numeric_limits<uint32_t>::max()));
    const size_t n = std::min<size_t>(boxes.size(), rectCapacity);
    for (size_t i = 0; i < n; i++) {
        const auto& box = boxes[i];
        outRects[i].x = box.rect.x();
        outRects[i].y = box.rect.y();
        outRects[i].width = box.rect.width();
        outRects[i].height = box.rect.height();
        outRects[i].direction = box.direction == skia::textlayout::TextDirection::kRtl
            ? TextDirectionRtl
            : TextDirectionLtr;
    }
    return true;
}

bool TextLayoutService::inkBounds(uint64_t handle, TextBounds *outBounds) const
{
    auto paragraph = lookupParagraph(handle);
    if (!paragraph || !outBounds) return false;
    SkRect bounds = SkRect::MakeEmpty();
    paragraph->extendedVisit([&](int, const skia::textlayout::Paragraph::ExtendedVisitorInfo* info) {
        if (!info) return;
        for (int index = 0; index < info->count; ++index) {
            SkRect glyph = info->bounds[index];
            glyph.offset(info->positions[index]);
            glyph.offset(info->origin);
            if (!glyph.isEmpty()) bounds.join(glyph);
        }
    });
    if (bounds.isEmpty()) {
        *outBounds = {};
    } else {
        *outBounds = {
            .left = bounds.left(), .top = bounds.top(),
            .right = bounds.right(), .bottom = bounds.bottom(),
        };
    }
    return true;
}

bool TextLayoutService::graphemeBreaks(
    TextStringView text, uint32_t *outUtf8Offsets, size_t capacity, uint32_t *outCount) const
{
    if (!outCount || (!text.data && text.size != 0)) return false;
    auto unicode = getTextUnicode();
    auto iterator = unicode ? unicode->makeBreakIterator(SkUnicode::BreakType::kGraphemes) : nullptr;
    if (!iterator || !iterator->setText(text.data, static_cast<int>(text.size))) return false;
    std::vector<uint32_t> offsets;
    for (auto position = iterator->first(); !iterator->isDone(); position = iterator->next()) {
        if (position >= 0) offsets.push_back(static_cast<uint32_t>(position));
    }
    if (offsets.empty() || offsets.back() != text.size) offsets.push_back(static_cast<uint32_t>(text.size));
    *outCount = static_cast<uint32_t>(offsets.size());
    const size_t count = std::min(capacity, offsets.size());
    for (size_t i = 0; i < count; ++i) outUtf8Offsets[i] = offsets[i];
    return true;
}

void TextLayoutService::invalidateFontCollection() const
{
    nucleus::text::invalidateSharedFonts();
    std::lock_guard<std::mutex> guard(g_typeface_mutex);
    g_typeface.reset();
}

bool TextLayoutService::paint(uint64_t handle, SkCanvas *canvas, float x, float y) const
{
    auto paragraph = lookupParagraph(handle);
    if (!paragraph || !canvas) {
        return false;
    }
    paragraph->paint(canvas, x, y);
    return true;
}

ParagraphMetrics measureParagraph(
    const std::vector<TextRun> &runs,
    const ParagraphStyle &style)
{
    auto paragraph = makeParagraphRuns(runs, style);
    if (!paragraph) {
        return {};
    }
    const float layout_width = textLayoutWidth(paragraph.get(), style);
    paragraph->layout(layout_width);
    return paragraphMetrics(paragraph.get(), layout_width);
}

uint64_t registerParagraph(
    const std::vector<TextRun> &runs,
    const ParagraphStyle &style,
    ParagraphMetrics *outMetrics)
{
    auto paragraph = makeParagraphRuns(runs, style);
    if (!paragraph) {
        return 0;
    }
    paragraph->layout(std::numeric_limits<float>::max() / 4.0f);
    const float layout_width = style.width > 0.0f ? style.width : std::ceil(paragraph->getMaxIntrinsicWidth());
    paragraph->layout(layout_width);
    if (outMetrics) {
        *outMetrics = paragraphMetrics(paragraph.get(), layout_width);
    }
    return registerParagraph(std::move(paragraph), layout_width);
}

} // namespace nucleus::text

// ── Text-layout draw seam ───────────────────────────────────────────────────
// The render core (NucleusSkiaGraphite) paints paragraphs itself but must not
// depend on this RN-coupled text backend. Dependency inversion: the render core
// owns the resolver slot (nucleus_skia_set_text_layout_resolver, declared in
// NucleusSkiaGraphite/Graphite.hpp), and we register our handle→Paragraph*
// resolver into it at startup. The render core then resolves + paints directly —
// no global-symbol lookup, no upward link edge from the render core. Forward-
// declared here (a one-line C-ABI contract) so this file needs no render-core
// include path.
extern "C" void nucleus_skia_set_text_layout_resolver(uintptr_t (*resolve)(uint64_t)) __attribute__((weak));

extern "C" uintptr_t nucleus_text_layout_paragraph(uint64_t handle)
{
    return reinterpret_cast<uintptr_t>(nucleus::text::lookupParagraph(handle).get());
}

namespace {
struct TextLayoutResolverRegistration {
    TextLayoutResolverRegistration()
    {
        if (nucleus_skia_set_text_layout_resolver) {
            nucleus_skia_set_text_layout_resolver(&nucleus_text_layout_paragraph);
        }
    }
};
// Runs at startup (static init); only stores a function pointer, so it is
// independent of any other static initialization order.
const TextLayoutResolverRegistration g_text_layout_resolver_registration;
} // namespace
