import CxxStdlib
@_spi(NucleusCompositor) import NucleusUI
import NucleusReactRuntimeCxxBridge

@MainActor
final class ReactParagraphView: ~Sendable {
    private var textRuns: [TextRun] = []
    private var alignment: TextAlignment = .leading
    private var lineBreakMode: LineBreakMode = .byClipping
    private var numberOfLines: Int = 1
    private var lineHeight: Double?
    private var fallbackColor = Color(1, 1, 1, 1)

    func applyText(_ text: String, attributes: TextAttributesSnapshot?) {
        guard let attributes else {
            textRuns = []
            return
        }
        let font = attributes.font
        fallbackColor = attributes.textColor.map { Color($0.red, $0.green, $0.blue, $0.alpha) } ?? Color(1, 1, 1, 1)
        textRuns = text.isEmpty ? [] : [
            TextRun(text: text, font: font, color: fallbackColor),
        ]
        alignment = attributes.nucleonAlignment
        lineBreakMode = attributes.nucleonLineBreakMode
        numberOfLines = max(1, attributes.maximumNumberOfLines)
        lineHeight = attributes.lineHeight > 0 ? attributes.lineHeight : nil
    }

    var intrinsicContentSize: Size {
        let layout = textLayout(containerWidth: nil)
        return Size(
            width: layout.intrinsicSize.width,
            height: max(layout.intrinsicSize.height, lineHeight ?? 0)
        )
    }

    func displayCommands(containerWidth: Double?) -> [ViewLayerContentCommand] {
        guard !textRuns.isEmpty else {
            return []
        }
        let layout = textLayout(containerWidth: containerWidth)
        let targetLineHeight = lineHeight ?? layout.usedRect.size.height
        let y = max(0, (targetLineHeight - layout.usedRect.size.height) * 0.5)
        return layout.layerContentCommands(
            color: fallbackColor,
            x: 0,
            y: Float(y)
        )
    }

    private func textLayout(containerWidth: Double?) -> TextLayout {
        TextLayout(
            runs: textRuns,
            containerWidth: containerWidth,
            alignment: alignment,
            lineBreakMode: lineBreakMode,
            numberOfLines: numberOfLines
        )
    }
}

private extension TextAttributesSnapshot {
    var font: Font {
        Font(descriptor: FontDescriptor(
            familyName: fontFamily.isEmpty ? nil : fontFamily,
            pointSize: fontSize > 0 ? fontSize : 14,
            weight: nucleonWeight,
            slant: nucleonSlant
        ))
    }

    var nucleonAlignment: TextAlignment {
        switch alignment {
        case .center:
            .center
        case .trailing:
            .trailing
        case .natural, .leading:
            .leading
        }
    }

    var nucleonLineBreakMode: LineBreakMode {
        switch lineBreakMode {
        case .truncatingTail:
            .byTruncatingTail
        case .wordWrapping:
            .byWordWrapping
        case .clipping:
            .byClipping
        }
    }

    private var nucleonWeight: Font.Weight {
        switch fontWeight {
        case 700...:
            .bold
        case 600..<700:
            .semibold
        case 500..<600:
            .medium
        default:
            .regular
        }
    }

    private var nucleonSlant: Font.Slant {
        switch fontSlant {
        case 1:
            .italic
        case 2:
            .oblique
        default:
            .upright
        }
    }
}
