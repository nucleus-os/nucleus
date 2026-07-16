#include <nucleus/text/TextRegistry.hpp>

#include <include/core/SkFontMgr.h>
#include <include/ports/SkFontMgr_fontconfig.h>
#include <include/ports/SkFontScanner_FreeType.h>
#include <modules/skparagraph/include/FontCollection.h>
#include <modules/skparagraph/include/Paragraph.h>
#include <modules/skunicode/include/SkUnicode_icu.h>

#include <fontconfig/fontconfig.h>

#include <atomic>
#include <mutex>
#include <unordered_map>

namespace nucleus::text {
namespace {

struct ParagraphRecord final {
  ParagraphPtr paragraph;
  float layoutWidth{0.0f};
  uint32_t refCount{1};
};

std::mutex g_paragraph_mutex;
std::unordered_map<uint64_t, ParagraphRecord> g_paragraphs;
std::atomic<uint64_t> g_next_handle{1};

std::mutex g_font_mutex;
sk_sp<SkFontMgr> g_font_mgr;
sk_sp<skia::textlayout::FontCollection> g_font_collection;
sk_sp<SkUnicode> g_unicode;

} // namespace

uint64_t registerParagraph(ParagraphPtr paragraph, float layoutWidth) {
  if (!paragraph) {
    return 0;
  }

  uint64_t handle = g_next_handle.fetch_add(1, std::memory_order_relaxed);
  if (handle == 0) {
    handle = g_next_handle.fetch_add(1, std::memory_order_relaxed);
  }

  std::lock_guard<std::mutex> lock(g_paragraph_mutex);
  g_paragraphs.emplace(handle, ParagraphRecord{
      .paragraph = std::move(paragraph),
      .layoutWidth = layoutWidth,
      .refCount = 1,
  });
  return handle;
}

uint64_t registerParagraph(
    std::unique_ptr<skia::textlayout::Paragraph> paragraph,
    float layoutWidth) {
  return registerParagraph(ParagraphPtr(std::move(paragraph)), layoutWidth);
}

void retainParagraph(uint64_t handle) {
  if (handle == 0) {
    return;
  }
  std::lock_guard<std::mutex> lock(g_paragraph_mutex);
  auto it = g_paragraphs.find(handle);
  if (it != g_paragraphs.end()) {
    it->second.refCount += 1;
  }
}

void releaseParagraph(uint64_t handle) {
  if (handle == 0) {
    return;
  }
  std::lock_guard<std::mutex> lock(g_paragraph_mutex);
  auto it = g_paragraphs.find(handle);
  if (it == g_paragraphs.end()) {
    return;
  }
  if (it->second.refCount <= 1) {
    g_paragraphs.erase(it);
  } else {
    it->second.refCount -= 1;
  }
}

ParagraphPtr lookupParagraph(uint64_t handle) {
  if (handle == 0) {
    return nullptr;
  }
  std::lock_guard<std::mutex> lock(g_paragraph_mutex);
  auto it = g_paragraphs.find(handle);
  return it == g_paragraphs.end() ? nullptr : it->second.paragraph;
}

float paragraphLayoutWidth(uint64_t handle) {
  if (handle == 0) {
    return 0.0f;
  }
  std::lock_guard<std::mutex> lock(g_paragraph_mutex);
  auto it = g_paragraphs.find(handle);
  return it == g_paragraphs.end() ? 0.0f : it->second.layoutWidth;
}

sk_sp<SkFontMgr> sharedFontMgr() {
  std::lock_guard<std::mutex> lock(g_font_mutex);
  if (!g_font_mgr) {
    g_font_mgr = SkFontMgr_New_FontConfig(FcConfigReference(FcConfigGetCurrent()), SkFontScanner_Make_FreeType());
  }
  return g_font_mgr;
}

sk_sp<skia::textlayout::FontCollection> sharedFontCollection() {
  std::lock_guard<std::mutex> lock(g_font_mutex);
  if (!g_font_collection) {
    auto collection = sk_make_sp<skia::textlayout::FontCollection>();
    if (!g_font_mgr) {
      g_font_mgr = SkFontMgr_New_FontConfig(FcConfigReference(FcConfigGetCurrent()), SkFontScanner_Make_FreeType());
    }
    collection->setDefaultFontManager(g_font_mgr);
    collection->enableFontFallback();
    g_font_collection = std::move(collection);
  }
  return g_font_collection;
}

sk_sp<SkUnicode> sharedUnicode() {
  std::lock_guard<std::mutex> lock(g_font_mutex);
  if (!g_unicode) {
    g_unicode = SkUnicodes::ICU::Make();
  }
  return g_unicode;
}

void invalidateSharedFonts() {
  std::lock_guard<std::mutex> lock(g_font_mutex);
  g_font_collection.reset();
  g_font_mgr.reset();
}

} // namespace nucleus::text
