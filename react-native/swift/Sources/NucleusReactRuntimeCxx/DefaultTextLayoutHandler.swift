import CxxStdlib
import NucleusReactRuntimeCxxBridge
import NucleusTextCxxBridge

// Default Fabric text-measurement handler. The bridge builds the
// `TextMeasureRequest` from the RN inputs and this handler measures it
// through the Skia text backend (`nucleus::text::measureParagraph`).
package final class DefaultTextLayoutHandler: Sendable {
    package init() {}

    package func measure(_ request: nucleus.react.TextMeasureRequest)
        -> nucleus.react.TextMeasureResult
    {
        let metrics = nucleus.text.measureParagraph(request.runs, request.paragraphStyle)

        let hasFiniteMaxWidth = request.maximumWidth > 0
        let measuredWidth =
            hasFiniteMaxWidth
            ? Swift.min(metrics.maxIntrinsicWidth, request.maximumWidth)
            : metrics.maxIntrinsicWidth
        return nucleus.react.TextMeasureResult(
            width: Swift.max(0, measuredWidth),
            height: Swift.max(0, metrics.height)
        )
    }
}
