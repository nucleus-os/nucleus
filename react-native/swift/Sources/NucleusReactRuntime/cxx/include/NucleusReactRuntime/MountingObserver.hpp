#pragma once

#include <cstdint>
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

enum class LayoutDirection : int {
  Undefined = 0,
  LeftToRight = 1,
  RightToLeft = 2,
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
  std::string componentName;
  std::optional<std::string> nativeId;
  Rect frame;
  std::optional<Color> backgroundColor;
  LayoutDirection layoutDirection;
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
// The concrete subclass `SwiftMountingObserverBridge` (defined in
// `swift/Sources/NucleusReactRuntime/cxx/SwiftMountingObserverBridge.cpp`)
// holds a Swift `SwiftMountingObserver` instance through the emitted
// `NucleusReactRuntimeCxx.h` and forwards both calls to Swift.
class MountingObserver {
 public:
  virtual ~MountingObserver() = default;
  virtual void didMount(const MountMutation &mutation) = 0;
  virtual void didFinishTransaction(std::int32_t surfaceId) = 0;
};

// Wraps a Swift `SwiftMountingObserver` instance in a concrete C++
// `MountingObserver`. `swiftObserverRetained` must be the result of
// `SwiftMountingObserver.toUnsafe()` (an `Unmanaged.passRetained`
// pointer); ownership transfers into the returned bridge.
//
// Using `void *` keeps this public header free of Swift-emitted
// types so it stays inside the Swift module's modulemap without
// creating an import cycle. The bridge `.cpp` `#include`s
// `<NucleusReactRuntimeCxx.h>` and converts the pointer back to the
// typed Swift instance via `SwiftMountingObserver::fromUnsafe`.
std::shared_ptr<MountingObserver> makeSwiftMountingObserverBridge(
    void *swiftObserverRetained);

} // namespace nucleus::react
