#include <NucleusTextRenderingBridge/TextRenderingBridge.hpp>

namespace {

using TextLayoutBorrowBody =
    void (*)(uintptr_t paragraph, void *bodyContext);
using TextLayoutBorrow =
    bool (*)(
        uint64_t handle,
        void *bodyContext,
        TextLayoutBorrowBody body);

extern "C" bool nucleus_text_borrow_paragraph(
    uint64_t handle,
    void *bodyContext,
    TextLayoutBorrowBody body) noexcept;
extern "C" bool nucleus_skia_install_text_layout_borrow(
    TextLayoutBorrow borrow) noexcept;

} // namespace

namespace nucleus::text {

TextRenderingBridgeInstallStatus installTextRenderingBridge() noexcept {
  try {
    return nucleus_skia_install_text_layout_borrow(
        &nucleus_text_borrow_paragraph)
        ? TextRenderingBridgeInstallStatus::ready
        : TextRenderingBridgeInstallStatus::conflictingProvider;
  } catch (...) {
    return TextRenderingBridgeInstallStatus::conflictingProvider;
  }
}

} // namespace nucleus::text
