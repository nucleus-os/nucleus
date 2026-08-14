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
using ParagraphBorrowBody = void (*)(uintptr_t paragraph, void *bodyContext);

uint64_t registerParagraph(ParagraphPtr paragraph, float layoutWidth) noexcept;
uint64_t registerParagraph(
    std::unique_ptr<::skia::textlayout::Paragraph> paragraph,
    float layoutWidth) noexcept;
void retainParagraph(uint64_t handle) noexcept;
void releaseParagraph(uint64_t handle) noexcept;
ParagraphPtr lookupParagraph(uint64_t handle) noexcept;
bool borrowParagraph(
    uint64_t handle,
    void *bodyContext,
    ParagraphBorrowBody body) noexcept;
float paragraphLayoutWidth(uint64_t handle) noexcept;
sk_sp<SkFontMgr> sharedFontMgr() noexcept;
sk_sp<::skia::textlayout::FontCollection> sharedFontCollection() noexcept;
sk_sp<SkUnicode> sharedUnicode() noexcept;
void invalidateSharedFonts() noexcept;

} // namespace nucleus::text
