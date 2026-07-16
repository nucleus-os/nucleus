#pragma once

#include <cstdint>
#include <memory>

namespace skia::textlayout {
class FontCollection;
class Paragraph;
}

class SkFontMgr;
class SkUnicode;
template <typename T>
class sk_sp;

namespace nucleus::text {

using ParagraphPtr = std::shared_ptr<::skia::textlayout::Paragraph>;

uint64_t registerParagraph(ParagraphPtr paragraph, float layoutWidth);
uint64_t registerParagraph(
    std::unique_ptr<::skia::textlayout::Paragraph> paragraph,
    float layoutWidth);
void retainParagraph(uint64_t handle);
void releaseParagraph(uint64_t handle);
ParagraphPtr lookupParagraph(uint64_t handle);
float paragraphLayoutWidth(uint64_t handle);
sk_sp<SkFontMgr> sharedFontMgr();
sk_sp<::skia::textlayout::FontCollection> sharedFontCollection();
sk_sp<SkUnicode> sharedUnicode();
void invalidateSharedFonts();

} // namespace nucleus::text
