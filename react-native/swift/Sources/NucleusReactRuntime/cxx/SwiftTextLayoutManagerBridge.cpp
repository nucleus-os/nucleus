// Bridge file: C++ holds a Swift `SwiftTextLayoutManager` instance
// and forwards `facebook::react::TextLayoutManager::measure(...)`
// virtual calls into Swift. Catalog item 7's production-shape
// application of the pattern proven by `SwiftMountingObserverBridge.cpp`.
//
// `<NucleusReactRuntimeCxx.h>` is only reachable through the
// umbrella, never from any modulemap-visible header.

#include <NucleusReactRuntime/SwiftCxxUmbrella.hpp>

#include <react/renderer/attributedstring/AttributedString.h>
#include <react/renderer/attributedstring/AttributedStringBox.h>
#include <react/renderer/attributedstring/ParagraphAttributes.h>
#include <react/renderer/attributedstring/TextAttributes.h>
#include <react/renderer/core/LayoutConstraints.h>
#include <react/renderer/core/LayoutPrimitives.h>
#include <react/renderer/graphics/Color.h>
#include <react/renderer/graphics/Size.h>
#include <react/renderer/textlayoutmanager/TextLayoutContext.h>
#include <react/renderer/textlayoutmanager/TextLayoutManager.h>

#include <algorithm>
#include <cmath>
#include <memory>
#include <utility>
#include <vector>

namespace nucleus::react {

namespace {

nucleus::text::TextStyle textStyle(
    const facebook::react::TextAttributes &attributes) {
  nucleus::text::TextStyle style;
  style.fontFamily = attributes.fontFamily;
  style.pointSize = std::isnan(attributes.fontSize) ? 14.0f : attributes.fontSize;
  if (!std::isnan(attributes.lineHeight) && attributes.lineHeight > 0.0f) {
    style.lineHeight = attributes.lineHeight;
  }
  if (attributes.fontWeight.has_value()) {
    style.fontWeight = static_cast<int>(*attributes.fontWeight);
  }
  style.italic = attributes.fontStyle.has_value() &&
      (*attributes.fontStyle == facebook::react::FontStyle::Italic ||
       *attributes.fontStyle == facebook::react::FontStyle::Oblique);
  if (attributes.foregroundColor) {
    style.red = static_cast<float>(facebook::react::redFromColor(attributes.foregroundColor)) / 255.0f;
    style.green = static_cast<float>(facebook::react::greenFromColor(attributes.foregroundColor)) / 255.0f;
    style.blue = static_cast<float>(facebook::react::blueFromColor(attributes.foregroundColor)) / 255.0f;
    style.alpha = static_cast<float>(facebook::react::alphaFromColor(attributes.foregroundColor)) / 255.0f;
  }
  return style;
}

nucleus::text::TextAlignment textAlignment(
    const facebook::react::AttributedStringBox &attributedStringBox) {
  for (const auto &fragment : attributedStringBox.getValue().getFragments()) {
    if (!fragment.textAttributes.alignment.has_value()) {
      continue;
    }
    switch (*fragment.textAttributes.alignment) {
      case facebook::react::TextAlignment::Center:
        return nucleus::text::TextAlignment::Center;
      case facebook::react::TextAlignment::Right:
        return nucleus::text::TextAlignment::Trailing;
      case facebook::react::TextAlignment::Natural:
      case facebook::react::TextAlignment::Left:
      case facebook::react::TextAlignment::Justified:
      default:
        return nucleus::text::TextAlignment::Leading;
    }
  }
  return nucleus::text::TextAlignment::Leading;
}

TextMeasureRequest buildRequest(
    const facebook::react::AttributedStringBox &attributedStringBox,
    const facebook::react::ParagraphAttributes &paragraphAttributes,
    const facebook::react::LayoutConstraints &layoutConstraints) {
  TextMeasureRequest request;
  request.attachmentCount = 0;
  for (const auto &fragment : attributedStringBox.getValue().getFragments()) {
    if (fragment.isAttachment()) {
      ++request.attachmentCount;
      continue;
    }
    request.runs.push_back(nucleus::text::TextRun{
        .text = fragment.string,
        .style = textStyle(fragment.textAttributes),
    });
  }
  if (request.runs.empty()) {
    request.runs.push_back(nucleus::text::TextRun{});
  }

  const auto maxWidth = layoutConstraints.maximumSize.width;
  const bool hasFiniteMaxWidth = std::isfinite(maxWidth) && maxWidth > 0.0f;
  request.maximumWidth = hasFiniteMaxWidth ? maxWidth : 0.0f;

  nucleus::text::ParagraphStyle style;
  if (hasFiniteMaxWidth) {
    style.width = maxWidth;
  }
  style.maximumNumberOfLines = paragraphAttributes.maximumNumberOfLines > 0
      ? static_cast<uint32_t>(paragraphAttributes.maximumNumberOfLines)
      : 0;
  style.ellipsizeTail =
      paragraphAttributes.ellipsizeMode == facebook::react::EllipsizeMode::Tail;
  style.alignment = textAlignment(attributedStringBox);
  request.paragraphStyle = std::move(style);
  return request;
}

class SwiftTextLayoutManagerBridge final
    : public facebook::react::TextLayoutManager {
 public:
  SwiftTextLayoutManagerBridge(
      NucleusReactRuntimeCxx::SwiftTextLayoutManager swift,
      const std::shared_ptr<const facebook::react::ContextContainer>
          &contextContainer)
      : facebook::react::TextLayoutManager(contextContainer),
        swiftPart_(std::move(swift)) {}

  facebook::react::TextMeasurement measure(
      const facebook::react::AttributedStringBox &attributedStringBox,
      const facebook::react::ParagraphAttributes &paragraphAttributes,
      const facebook::react::TextLayoutContext &layoutContext,
      const facebook::react::LayoutConstraints &layoutConstraints) const override {
    (void)layoutContext;

    TextMeasureRequest request = buildRequest(
        attributedStringBox, paragraphAttributes, layoutConstraints);
    const auto attachmentCount = request.attachmentCount;

    TextMeasureResult result = swiftPart_.measure(request);

    facebook::react::TextMeasurement::Attachments attachments;
    attachments.reserve(attachmentCount);
    for (std::size_t i = 0; i < attachmentCount; ++i) {
      attachments.push_back(facebook::react::TextMeasurement::Attachment{
          .frame = {.origin = {.x = 0, .y = 0},
                    .size = {.width = 0, .height = 0}},
          .isClipped = false,
      });
    }

    return facebook::react::TextMeasurement{
        .size = layoutConstraints.clamp(facebook::react::Size{
            .width = std::ceil(std::max(0.0f, result.width)),
            .height = std::ceil(std::max(0.0f, result.height)),
        }),
        .attachments = std::move(attachments),
    };
  }

 private:
  mutable NucleusReactRuntimeCxx::SwiftTextLayoutManager swiftPart_;
};

} // namespace

std::shared_ptr<facebook::react::TextLayoutManager>
makeSwiftTextLayoutManagerBridge(
    void *swiftHandlerRetained,
    std::shared_ptr<const facebook::react::ContextContainer> contextContainer) {
  auto swift = NucleusReactRuntimeCxx::SwiftTextLayoutManager::fromUnsafe(
      swiftHandlerRetained);
  return std::make_shared<SwiftTextLayoutManagerBridge>(
      std::move(swift), contextContainer);
}

TextMeasureRequest makeSingleRunMeasureRequest(
    const char *text,
    float pointSize,
    float maximumWidth) {
  TextMeasureRequest request;
  nucleus::text::TextStyle style;
  if (pointSize > 0.0f) {
    style.pointSize = pointSize;
  }
  request.runs.push_back(nucleus::text::TextRun{
      .text = text == nullptr ? std::string() : std::string(text),
      .style = std::move(style),
  });
  nucleus::text::ParagraphStyle paragraphStyle;
  if (maximumWidth > 0.0f) {
    paragraphStyle.width = maximumWidth;
  }
  request.paragraphStyle = std::move(paragraphStyle);
  request.maximumWidth = maximumWidth > 0.0f ? maximumWidth : 0.0f;
  request.attachmentCount = 0;
  return request;
}

void releaseSwiftTextLayoutManagerHandle(void *swiftHandlerRetained) {
  if (swiftHandlerRetained == nullptr) {
    return;
  }
  // `fromUnsafe` is `takeRetainedValue`; letting the returned value
  // go out of scope drops the retain.
  (void)NucleusReactRuntimeCxx::SwiftTextLayoutManager::fromUnsafe(
      swiftHandlerRetained);
}

} // namespace nucleus::react
