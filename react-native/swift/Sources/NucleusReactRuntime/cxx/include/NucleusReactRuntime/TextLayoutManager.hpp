#pragma once

#include <cstddef>
#include <memory>
#include <vector>

#include <nucleus/text/TextLayoutBuilder.hpp>

namespace facebook::react {
class ContextContainer;
class TextLayoutManager;
} // namespace facebook::react

namespace nucleus::react {

// Typed request the bridge hands to Swift. The bridge owns
// flattening the RN inputs into this shape so the Swift handler
// stays free of `facebook::react` headers.
struct TextMeasureRequest {
  std::vector<nucleus::text::TextRun> runs;
  nucleus::text::ParagraphStyle paragraphStyle;
  // Max width Swift should treat as "no constraint" when 0. The
  // bridge clamps the returned size against the original RN
  // constraints, so Swift does not need them in raw form.
  float maximumWidth;
  std::size_t attachmentCount;
};

struct TextMeasureResult {
  float width;
  float height;
};

// Wraps a Swift `SwiftTextLayoutManager` instance in a concrete
// C++ `facebook::react::TextLayoutManager`. `swiftHandlerRetained`
// must be the result of `SwiftTextLayoutManager.toUnsafe()`.
//
// The `contextContainer` argument is forwarded to the
// `TextLayoutManager` base ctor so existing RN call sites that
// look it up by key see the same shape they always did.
std::shared_ptr<facebook::react::TextLayoutManager>
makeSwiftTextLayoutManagerBridge(
    void *swiftHandlerRetained,
    std::shared_ptr<const facebook::react::ContextContainer> contextContainer);

// Releases a retained Swift `SwiftTextLayoutManager` handle without
// constructing a bridge — used by the facade when a second handle is
// installed before the first was consumed by `FabricRuntime`.
void releaseSwiftTextLayoutManagerHandle(void *swiftHandlerRetained);

// Test-only helper. Swift's CxxStdlib import refuses to instantiate
// `std::vector<nucleus::text::TextRun>` from scratch (un-specialized
// class templates are unavailable). Tests get a ready-to-use request
// through this builder so they can drive `DefaultTextLayoutHandler`
// without going through the Fabric bridge.
TextMeasureRequest makeSingleRunMeasureRequest(
    const char *text,
    float pointSize,
    float maximumWidth);

} // namespace nucleus::react
