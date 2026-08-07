#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <string>

namespace nucleus::react {

enum class MountEventType : int {
  Create = 1,
  Delete = 2,
  Insert = 3,
  Remove = 4,
  Update = 5,
};

enum class MountComponentKind : int {
  Other = 0,
  Root = 1,
  View = 2,
  Text = 3,
  Image = 4,
};

enum class TextAlignment : int {
  Natural = 0,
  Leading = 1,
  Center = 2,
  Trailing = 3,
};

enum class LineBreakMode : int {
  Clipping = 0,
  TruncatingTail = 1,
  WordWrapping = 2,
};

struct Color {
  float red;
  float green;
  float blue;
  float alpha;
};

struct Rect {
  double x;
  double y;
  double width;
  double height;
};

struct TextAttributes {
  std::string fontFamily;
  float fontSize;
  int fontWeight;
  int fontSlant;
  std::optional<Color> textColor;
  double lineHeight;
  TextAlignment alignment;
  int maximumNumberOfLines;
  LineBreakMode lineBreakMode;
};

// Value-type mount mutation. Replaces the 34 positional arguments of
// the legacy `FabricMountEventCallback` shape. `std::optional` fields
// collapse the existing `hasFoo` flag + companion field pairs.
struct MountMutation {
  std::int32_t surfaceId;
  MountEventType type;
  std::int32_t tag;
  std::int32_t parentTag;
  std::int32_t oldTag;
  std::int32_t newTag;
  int index;
  MountComponentKind componentKind;
  std::string componentName;
  std::optional<std::string> nativeId;
  Rect frame;
  std::optional<Color> backgroundColor;
  std::optional<std::string> text;
  std::optional<TextAttributes> textAttributes;
  // Source URI for `<Image>` components. The Swift consumer
  // resolves this through the substrate image registry; only
  // present when the mutation targets an Image component.
  std::optional<std::string> imageSource;
};

// Abstract C++ observer of Fabric mount mutations. C++ code in
// `ReactRuntimeHost.cpp` holds a `std::shared_ptr<MountingObserver>`
// and, for each Fabric scheduler transaction, calls
// `didMount(mutation)` for every mutation in the transaction followed
// by a single `didFinishTransaction(surfaceId)` to mark the batch
// boundary.
//
class MountingObserver {
 public:
  virtual ~MountingObserver() = default;
  virtual void didMount(const MountMutation &mutation) = 0;
  virtual void didFinishTransaction(std::int32_t surfaceId) = 0;
};

using MountDidMount = std::function<void(const MountMutation &mutation)>;
using MountDidFinish = std::function<void(std::int32_t surfaceId)>;

std::shared_ptr<MountingObserver> makeMountingObserver(
    MountDidMount didMount,
    MountDidFinish didFinish) noexcept;

} // namespace nucleus::react
