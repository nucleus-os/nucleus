import CxxStdlib
import NucleusReactRuntimeCxxBridge
import NucleusTextCxxBridge

// Default Fabric text-measurement handler. Wraps the same Skia text
// backend (`nucleus::text::measureParagraph`) that the legacy C++
// `NucleusTextLayoutManager` used; the bridge builds the
// `TextMeasureRequest` from the RN inputs, this handler measures.
package final class DefaultTextLayoutHandler: Sendable {
    package init() {}

    package func measure(_ request: nucleus.react.TextMeasureRequest)
        -> nucleus.react.TextMeasureResult
    {
        let metrics = nucleus.text.measureParagraph(request.runs, request.paragraphStyle)

        let hasFiniteMaxWidth = request.maximumWidth > 0
        let measuredWidth =
            hasFiniteMaxWidth
            ? Swift::min(metrics.maxIntrinsicWidth, request.maximumWidth)
            : metrics.maxIntrinsicWidth
        return nucleus.react.TextMeasureResult(
            width: Swift.max(0, measuredWidth),
            height: Swift.max(0, metrics.height)
        )
    }
}
